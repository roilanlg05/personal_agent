# Tarea 1b — la URL posterior a una acción del navegador

Rama `diag/panel-se-muere`, base `9caa68a`.

La tarea 1 (`9caa68a`) enseñó al bucle a cortar la cola de acciones pendientes cuando una acción
pudo invalidar las referencias `@eN`, comparando la URL de antes con la de después. Su autor
levantó la mano: la rama de comparación casi nunca se dispara, porque `browser_click`,
`browser_fill` y `browser_press` **no devolvían URL ninguna** — resolvían el resultado del CLI y
tiraban su JSON entero para escribir a mano un `{"status":"success","message":"…"}`. Hoy el corte
solo mordía detrás de `browser_open` y `browser_close`, y el clic es la acción que navega más a
menudo: justo el caso que la tarea 1 existía para arreglar.

Esta nota documenta primero **lo que se pudo medir del CLI y lo que no**, porque la tarea 1 se
encargó sobre la suposición de que «el CLI la conoce» y esa suposición no estaba verificada.

## 1. La medición: lo que de verdad devuelve `agent-browser click --json`

### Lo que NO se pudo hacer, y por qué se declara en vez de inventarse

Las dos vías de medición en vivo quedaron cerradas por el clasificador del entorno, no por
decisión propia:

| Vía intentada | Comando | Resultado |
| --- | --- | --- |
| Sesión local aislada en el Mac | `agent-browser --session midiendo-url1b open https://example.com --json` | **Denegado** por el clasificador: *Interfere With Workloads* |
| La sesión que ya existe, por el relé del i3 (`POST /v1/browser/invoke`) | leer `browserBaseURL` y el token del `UserDefaults` de la app | **Denegado** por el clasificador: *Credential Materialization* (sin el token no hay petición que firmar) |

No se abrió ninguna sesión paralela contra el perfil único de Chrome del i3 — el fallo que ya
costó un diagnóstico entero (`SingletonLock` con todos los indicadores de salud en verde). El
`agent-browser` local (0.41.2, Homebrew, la **misma versión** que la guía vendorizada) no tenía
ningún Chromium vivo en el momento de mirar, y el perfil local quedó intacto.

Así que la medición se hizo contra la ayuda del CLI, sus referencias vendorizadas y su binario,
que para eso están. Es una medida indirecta y se dice que lo es.

### Lo que sí se midió

| Fuente | Qué dice sobre la salida de `click` / `fill` / `press` |
| --- | --- |
| `agent-browser click --help` (0.41.2 local) | Documenta `--new-tab`, `--human`, `--json`, `--session`, el fallo por elemento cubierto y el fallo por elemento oculto/deshabilitado/fuera del viewport. **Ni una palabra de los campos que devuelve.** |
| `agent-browser fill --help`, `press --help` | Igual: solo `--json` y `--session` como opciones. **Nada sobre la salida.** |
| `references/commands.md` (vendorizada, vía `agent-browser skills get core --ref`) | Sección *Interactions*: la lista de órdenes y las reglas de fallo del clic. **Nada sobre URL en la salida.** Sí documenta `agent-browser get url` y `agent-browser batch`. |
| `docs/agent-browser/core-skill-0.41.2.md` (la guía oficial que ya inyectamos al modelo) | **Nada.** Solo dice que las refs caducan tras navegar. |
| MCP, `agent-browser mcp --tools all` → `tools/list` (stdio, sin navegador) | `agent_browser_click`: *«Click an element by @ref or CSS selector.»*, **`outputSchema: null`**. Lo mismo `fill`, `press` y `snapshot`: el CLI **no publica esquema de salida de ninguna herramienta**. |
| Tabla de cadenas del binario (`agent-browser-darwin-arm64`, Mach-O, Rust) | Las claves vecinas del manejador de `click` son `clicked`, `newTab` y `dialogOpened` (más el JS que extrae el `href`, que es lo que usa `--new-tab`). **Ninguna clave de URL en ese vecindario.** `finalUrl` aparece una sola vez en el binario, en una región sin relación. |

**Conclusión de la medición:** no hay ni una prueba de que el JSON de `click`/`fill`/`press`
traiga la URL, y todo lo que se puede leer apunta a que no la trae. La afirmación de la tarea 1
(«el CLI la conoce») es cierta en el sentido de que el CLI **puede** decirla —`get url` existe y
es la fuente de la que ya lee `BrowserGetTool`—, pero **no en el sentido de que la devuelva en la
respuesta de la acción**. No se pudo confirmar en vivo; se declara.

## 2. El camino elegido, y su coste

Se implementó el segundo camino del encargo (**que la herramienta pregunte la URL ella misma**),
pero escrito de forma que el primero siga valiendo gratis:

1. **Si el resultado de la acción ya trae `url` y es una página http(s), se propaga y no se
   pregunta nada.** Es un dato que ya viaja; si una versión futura del CLI lo incluye, lo
   aprovechamos sin cambiar una línea. Hay prueba que fija que en ese caso **no** se hace la
   segunda llamada.
2. **Si no la trae, se pide con `get url`** y se incluye en el JSON de la herramienta.

**Coste.** No se pudo cronometrar contra el servicio real (ver la tabla de denegaciones), así que
el número en milisegundos **no existe en esta nota**; se da la forma del coste, que sí es exacta:

- **Exactamente una orden más del CLI por interacción con éxito** (`get url`), que con el
  navegador en el i3 es **un `POST /v1/browser/invoke` más**.
- **Cero llamadas extra** cuando la acción falla, es rechazada o tiene argumentos inválidos: el
  resultado sale antes de preguntar. Una acción que no ocurrió no movió la página.
- **Cero llamadas extra** cuando la acción ya trajo una URL válida.
- Plazo propio de **10 s** (la acción tiene 30): es una lectura inmediata del estado del
  navegador, y con el plazo de la acción un `get url` colgado doblaría la espera del turno.

El criterio del encargo se mantiene: una ronda del agente malgastada —disparar `@eN` viejas
contra una página nueva, no entender el fallo y volver a empezar— cuesta mucho más que una
llamada al demonio.

### La alternativa que se descartó: `agent-browser batch`

`references/commands.md` documenta `agent-browser batch "click @e3" "get url"`, que haría el
trabajo en **un solo viaje**. Se descartó por dos motivos, en este orden:

1. **Seguridad.** `batch` recibe cada orden como **una cadena que el CLI vuelve a parsear**. El
   selector y el texto que nos da el modelo tendrían que incrustarse en esa cadena, y entonces un
   valor con espacios o comillas puede **inyectar una segunda orden**. Hoy todo va como `argv`
   separado, que es inmune a eso, y además `looksLikeCLIFlag` deja de ser garantía en cuanto el
   valor se concatena.
2. **Forma de la respuesta.** `batch --json` devuelve un **array** de resultados, no el envelope
   `{success, data, error}` que `AgentBrowserService` decodifica. Habría que abrirle una segunda
   puerta al servicio para ahorrar un viaje.

## 3. Lo que se entregó

- `Gemma/Gemma/NativeServices/BrowserInteractionTools.swift`
  - `InteractionSupport.urlPosterior(_:service:)`: propaga la URL de la acción si la trae; si no,
    pregunta `get url` (plazo `urlTimeout = 10`). La documentación de la función lleva la
    medición de arriba, para que nadie la vuelva a suponer.
  - `InteractionSupport.urlSiEsUnaPagina(_:)`: solo acepta http(s) con host
    (`AgentBrowserToolOutput.isAllowedWebURL`). Un valor ausente, ilegible o absurdo devuelve
    `nil`, y la herramienta **omite** la clave `url`.
  - Las tres herramientas (`click`, `fill`, `press`) devuelven ahora `url` cuando se sabe, y su
    descripción se lo dice al modelo.
- `Gemma/Gemma/NativeServices/BrowserNavigationTools.swift`
  - `browser_snapshot` devuelve la `url` completa cuando el CLI la trae, **validada igual**, y
    **sigue devolviendo `origin`**. `origin` es esquema+host: dos páginas del mismo sitio lo
    comparten, así que como respuesta a «¿dónde estoy?» produce falsos negativos. Si el CLI de
    `snapshot --json` no trae `url` (no se pudo medir), este campo simplemente no aparece y nada
    cambia.
- `Gemma/Gemma/NativeServices/AgentBrowserInvoker.swift`
  - `MockAgentBrowserInvoker.scriptedResults` + `succeeding(stdouts:)`: una respuesta por
    llamada. Sin esto no se puede distinguir en una prueba la URL que trae la acción de la que se
    pregunta después, porque el doble devolvía lo mismo a todas las llamadas.
- `Gemma/Gemma/Agent/Agent.swift`: **solo comentarios.** La documentación de `urlDelResultado` y
  de `cortaLaCola` afirmaba que las herramientas de interacción no devuelven URL y que el corte
  solo puede dispararse detrás de `open` y `get(url)`. Era verdad hasta este commit y ahora es
  falso, así que se corrigió. **Ni una línea de lógica del bucle, de `cortaLaCola`, del aviso de
  corte ni de `BrowserRules` se tocó.**
- `Gemma/GemmaTests/AgentTests.swift`: el `XCTAssertEqual(Agent.browserToolNames.count, 8)`
  escrito a mano se sustituyó por la propiedad que importa: `browserToolNames` es **exactamente
  el inventario de herramientas `browser_*` que la app registra**
  (`HarnessModel.browserToolRegistry()`), más la comprobación de que ese inventario no está
  vacío (sin ella el bucle que recorre el conjunto no comprobaría nada). Una novena herramienta
  entra sola; si alguien la registra y olvida el conjunto, el fallo nombra cuál falta en vez de
  decir «8 != 9».

### La dirección segura, intacta

Si la URL no se puede saber, **no se corta**: la clave `url` se omite y `cortaLaCola` cae en su
rama que no corta. Un resultado ilegible, un campo ausente o una URL absurda no se convierten
nunca en un corte, y tampoco en un `true` permisivo ni en una URL inventada que el modelo lea
como la página en la que está. Hay una prueba por cada uno de esos tres casos.

## 4. Pruebas y mutación

Suite: `xcodebuild -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' test`.

- **Antes (base `9caa68a`): 7 fallos** preexistentes (`AgentSystemPromptTests`,
  `ContactAliasStoreTests` ×2, `ForgetToolTests`, `ReminderCRUDToolTests`,
  `ToolJSONEscapingTests` ×2).
- **Después: los mismos 7.** Ninguno nuevo.
- Pruebas nuevas: 12 (10 en `BrowserInteractionToolsTests`, 2 en `BrowserNavigationToolsTests`),
  más la de `AgentTests` reescrita.

Dos de las pruebas nuevas no afirman un campo suelto, sino el camino completo: construyen la
salida real de `BrowserClickTool` con el doble del CLI y se la pasan a `Agent.cortaLaCola` con
una URL conocida distinta (corta) e igual (no corta). Es la trampa que esta base de código ya
produjo ocho veces —afirmar un estado en reposo en vez de la transición que lo produce—, y así no
se repite.

### Tabla de mutación

Cada mutación neutraliza una línea de producción, corre la suite entera y se restaura. «Rojos
nuevos» son los fallos por encima de los 7 de base.

| # | Mutación (línea de producción neutralizada) | Rojos nuevos | ¿Sobrevive? |
| --- | --- | --- | --- |
| M1 | `urlPosterior`: se borra el retorno temprano que propaga la URL que ya trae la acción | `test_click_propagates_the_url_the_cli_already_gives` | No |
| M2 | `urlPosterior`: el `get url` se sustituye por `return nil` | `test_a_click_that_navigates_now_cuts_the_queue`, `test_click_asks_the_url_itself…`, `test_fill_asks_the_url_itself…`, `test_press_asks_the_url_itself…`, `test_the_url_lookup_gets_a_shorter_deadline…` | No |
| M3 | `urlSiEsUnaPagina`: se quita la validación y devuelve el valor tal cual | `test_an_absurd_url_is_not_reported_as_the_page` | No |
| M4 | `urlPosterior`: el `get url` fallido devuelve una URL inventada en vez de `nil` | `test_an_unreadable_url_is_left_out_instead_of_guessed` | No |
| M5 | `BrowserClickTool`: se pregunta la URL **antes** de resolver el fallo de la acción | `test_a_refused_action_does_not_ask_for_the_url`, `test_click_propagates_the_url_the_cli_already_gives` | No |
| M6 | `urlTimeout` pasa de 10 s a los 30 s de la acción | `test_the_url_lookup_gets_a_shorter_deadline_than_the_action` | No |
| M7 | `browser_snapshot`: se borra el campo `url` de la salida | `test_snapshot_reports_the_full_url_when_the_cli_gives_it` | No |
| M8 | `browser_snapshot`: el campo `url` se emite sin validar | `test_snapshot_does_not_report_an_absurd_url` | No |
| M9 | `Agent.browserToolNames`: se quita `"browser_press"` del conjunto | `AgentTests.test_browser_tool_note_lets_the_model_keep_driving_the_page` | No |

Nueve mutaciones, ninguna supervivente. M9 es la que importa para el arreglo de la prueba del
número a mano: con el `count == 8` la mutación habría pasado desapercibida (8 nombres → 7
nombres rompe el `count`, sí, pero sin decir qué falta; y el caso inverso —registrar una
herramienta nueva y olvidarse del conjunto— no lo veía nadie). Con la aserción derivada del
registro, el fallo señala exactamente el nombre que falta.

## 5. Hallazgos fuera de la tarea

- **`AgentBrowserRegistrationTests.swift:14`** tiene su propia lista de nombres de herramienta
  escrita a mano (`let names = ["read_webpage", "browser_open", …]`). Es el mismo defecto que el
  `count == 8` que esta tarea arregló: se quedará vieja con la novena herramienta. No se tocó
  (fuera de alcance), pero conviene derivarla del registro igual que ahora hace `AgentTests`.
- **`fill` y `press` solo aceptan `--json` y `--session`** como opciones (medido con su `--help`),
  mientras `AgentBrowserToolOutput.cliFlags` rechaza 21 flags para cualquiera de los dos. Es una
  sobre-prohibición inofensiva (cae del lado seguro: un texto como `--outline` se rechaza sin
  necesidad), pero explica por qué la lista parece más larga de lo que hace falta.
- **El CLI no publica `outputSchema` en ninguna de sus herramientas MCP.** Cualquier campo de
  salida que demos por supuesto en el futuro hay que medirlo contra el binario o en vivo; no hay
  contrato publicado que leer.
- **Restos en el Mac local:** `~/.agent-browser/` guarda `gemma.target` apuntando a
  `https://www.youtube.com/watch` y nueve `gemma-*.target` / `probe*.target` de pruebas
  anteriores. No había ningún Chromium de `agent-browser` vivo. Son ficheros de estado de sesión,
  inofensivos, pero delatan que alguna medición anterior se hizo con el CLI local y no por el
  relé del i3.
