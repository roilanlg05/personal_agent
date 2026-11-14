# La guía oficial de `agent-browser` delante del modelo (2026-11-08)

Rama `diag/panel-se-muere`.

## El problema

El CLI `agent-browser` trae una guía de uso escrita por su autor PARA agentes de IA. Se obtiene
con `agent-browser skills get core` y son 14457 bytes de markdown: el bucle
`open → snapshot → actuar → snapshot`, cómo se leen los `@eN`, cómo se espera a que una página
cambie (la sección de esperas dice, textualmente, que los agentes fallan más por esperas malas
que por selectores malos), cómo se extraen datos, pestañas, iframes, diálogos, y una lista de
diagnósticos para los fallos típicos (`Ref not found`, `page_wedged`, «el click no hace nada
porque hay un overlay encima»…).

Nuestro agente conduce ese mismo CLI a través de ocho herramientas `browser_*`, y nunca había
visto esa guía. Trabajaba con una línea escrita a mano en el prompt del sistema.

## Lo que se ha hecho

Tres piezas.

### 1. El texto oficial, vendorizado

`Gemma/Gemma/Agent/BrowserCoreSkill.swift` — fichero GENERADO, no se edita a mano. Es la salida
del comando metida en un literal de cadena **cruda** (`#"""…"""#`) para que el markdown entre sin
escapes y sin que Swift interprete nada.

El generador es `scripts/vendor-agent-browser-core-skill.py`, y la fuente queda archivada en
`docs/agent-browser/core-skill-0.41.2.md` para poder diffear la próxima captura contra
ésta cuando subamos de versión del CLI.

Procedencia, en la cabecera del fichero generado (Resolución C):

| Campo | Valor |
| --- | --- |
| Comando | `agent-browser skills get core` |
| Versión del CLI | 0.41.2 (la que pinea `gemma-memory/browser/Dockerfile`, que es el CLI que corre en el i3) |
| Fecha de captura | 2026-11-08 |
| Tamaño | 14457 bytes UTF-8, 252 líneas, termina en salto de línea |

El tamaño está **pineado por un test**
(`BrowserCoreSkillTests.test_la_guia_vendorizada_mide_exactamente_lo_que_dice_su_cabecera`), más
anclas de principio, de final y de tres trozos del interior. Si alguien re-captura la guía desde
otra versión del CLI y no actualiza la cabecera, el test se pone rojo.

**El round-trip se verificó, no se asumió.** El primer intento salió a 14456 bytes: Swift descarta
el salto de línea que precede al delimitador de cierre de un literal multilínea, así que el
literal medía un byte MENOS que el fichero. El generador deja ahora una línea en blanco extra
antes del cierre, y se comprobó con un programa Swift suelto que
`BrowserCoreSkill.text == <contenido del fichero>` y que los dos miden 14457 bytes. El script
aborta si el texto trae CRLF o si contiene el terminador del literal crudo.

### 2. Nuestras reglas, UNA sola fuente renderizada en dos sitios

Esto es el rediseño que pidió el usuario a mitad del trabajo: «¿por qué no poner las reglas de
nosotros en la skill cuando la descargues? Así no tenemos reglas de la misma herramienta en dos
lugares diferentes».

`Gemma/Gemma/Agent/BrowserRules.swift` — `enum BrowserRules` con dos constantes:

- `BrowserRules.text`: nuestras reglas enteras, como UNA sola línea de prompt (2256 bytes). Es
  literalmente el texto que antes vivía incrustado en la prosa de `Agent.systemPromptText`.
- `BrowserRules.closeRule`: el candado de cierre, aparte porque se renderiza en TRES sitios.

Se renderiza en:

1. `Agent.systemPromptText`, donde estaba la línea del navegador, ahora como
   `\(BrowserRules.text)`.
2. `Agent.browserGuideBlock()`, pegada DELANTE del texto oficial.

**El texto oficial se queda intacto**: nuestras reglas van DELANTE, no DENTRO. Es lo que permite
diffear la copia contra la salida del CLI al subir de versión, y hay un test que lo afirma
(`test_el_texto_oficial_no_lleva_nuestras_reglas_dentro`).

#### Por qué DOS renderizaciones y no solo la inyectada

Está escrito en el comentario de la constante, para que nadie lo «simplifique» después. Meter las
reglas sólo en la guía inyectada sería un fallo de seguridad, no una limpieza: la guía llega con
el RESULTADO de la primera herramienta de navegador, o sea DESPUÉS de que el modelo ya haya
decidido y ejecutado esa primera acción. «Nunca teclees una contraseña» hay que saberlo ANTES de
llamar a `browser_fill`, no después. Lo mismo con el candado de `browser_close` y con que la
página abierta suele ser el entregable: esas reglas gobiernan la DECISIÓN de actuar, así que
tienen que estar presentes desde el primer token.

Hay un test que mide justo eso:
`test_las_reglas_estan_desde_el_primer_token_no_solo_en_la_guia` captura el prompt del sistema de
la PRIMERA llamada al modelo y comprueba que las reglas ya están ahí.

#### Por qué una sola constante

El riesgo de tener las reglas escritas en dos sitios no es la repetición: es que DIVERJAN.
Mientras las dos renderizaciones salgan de la misma constante, no pueden.
`test_nuestras_reglas_salen_de_una_sola_constante` lo clava afirmando que el texto de la
constante aparece LITERAL en las dos renderizaciones: si alguien forkea una copia a mano, la
copia deja de coincidir y el test se pone rojo (mutación M7 más abajo).

#### HALLAZGO: las reglas estaban en TRES sitios, no en dos

El encargo decía «están en dos sitios». Al extraer la constante apareció un tercero: el candado
de cierre estaba escrito **dos veces con palabras distintas**, una en el prompt del sistema y
otra en `Agent.toolResultNote` (la nota que se añade al prompt vivo tras cada herramienta). Las
dos versiones:

- Prompt: «You do NOT close the browser. … `browser_close` is gated by the app: it works only
  when the user asked to close in this turn, and otherwise returns `refused` with the page still
  open. That refusal is correct behaviour, not an error to retry.»
- Nota: «When the task IS finished, leave the browser open … You do not close it — `browser_close`
  works only if the user asked to close in this turn, and otherwise returns `refused` with the
  page intact, which is correct and must not be retried.»

Mismo fondo, redacción divergente. Es exactamente el problema que el usuario estaba señalando, y
ya había empezado a pasar. Unidas: `BrowserRules.closeRule` se renderiza ahora en los tres
sitios, y `test_el_candado_de_cierre_sale_de_la_misma_constante_en_los_tres_sitios` lo fija.

La nota de resultado quedó además más corta: perdió su copia a mano y ganó la interpolación.

#### La línea del navegador sigue siendo UNA línea

Dos tests de `AgentSystemPromptTests` localizan nuestras reglas partiendo el prompt por saltos de
línea y buscando la que contiene `browser_open(url)`; esperan encontrar en ESA línea tanto la
prohibición de la contraseña como el candado de cierre. Funciona porque el literal del prompt usa
continuaciones `\` y las seis líneas de fuente se renderizan como una sola.

`BrowserRules.text` conserva esa forma (es un literal multilínea con continuaciones `\`), y se
verificó que **la línea renderizada es byte a byte la misma que en `HEAD`**: 2257 bytes, un solo
salto de línea, comparando el render de `git show HEAD:…Agent.swift` contra el render de la
constante nueva con `closeRule` interpolado. Por eso **ninguna ancla de `AgentSystemPromptTests`
hubo que re-apuntar**: los cinco tests de ese fichero que no estaban rotos de antes siguen verdes
sin tocarlos.

### 3. La inyección: una vez por turno, al primer uso

En el bucle de herramientas de `Agent.run`, el prompt vivo se va construyendo añadiendo
`Agent.toolResultNote(...)` tras cada herramienta ejecutada. La guía viaja con la nota de la
PRIMERA herramienta de navegador del turno (`Agent.browserToolNames`), y sólo con ésa; un flag
local `browserGuideInjected` lo garantiza.

El bloque inyectado son 17347 bytes: `BrowserRules.text` (2256) + frase de precedencia (630) +
texto oficial (14457), con dos saltos de línea entre cada pieza.

La frase de precedencia (`Agent.browserGuidePreamble`) dice tres cosas: que las reglas de arriba
son las nuestras y son las que gobiernan; que si la guía las contradice ganan las nuestras; y que
la guía documenta una CLI de shell, así que sus líneas `agent-browser …` describen lo que hacen
nuestras herramientas y no son órdenes que el modelo pueda ejecutar.

No es decorativa. La guía oficial dice, textualmente, «Run `agent-browser close` when you're
done», que choca de frente con el candado de cierre de la app. Hay un test que afirma que esa
contradicción sigue existiendo en el texto oficial, para que si la guía deja de decirlo nos
enteremos de que la frase ya no protege nada.

#### Por qué aquí y no en el prompt del sistema

- Un turno que no toca el navegador no paga nada. La mayoría de los turnos son preguntas que se
  contestan de memoria; en el prompt del sistema los 14 KB se los cobraríamos a todos. El usuario
  tiene aparcada precisamente la tarea (B) de recortar el prompt para mejorar el TTFT en caliente.
- Llega cuando sirve: la nota de resultado es lo ÚLTIMO que el modelo lee antes de decidir el
  paso siguiente sobre una página ya abierta.
- Una sola vez: el prompt vivo es acumulativo, así que inyectarla en cada llamada la repetiría
  hasta diez veces en un turno de conducción (`maxBrowserIterations` = 10).

## Los tests

Doce nuevos, todos en `Gemma/GemmaTests/BrowserCoreSkillTests.swift`.

Resolución A pide medir la inyección por CONDUCTA y CONTANDO apariciones. Se mide sobre el
prompt vivo que recibe el modelo, con un runtime guionizado (`ScriptedRoundsRuntime`) que, ronda
a ronda, pide las herramientas que le diga el guion y nunca las ejecuta. El prompt vivo es
acumulativo, así que el ÚLTIMO prompt es el que contiene todo lo que el turno fue añadiendo, y es
donde se cuentan las apariciones con `components(separatedBy:).count - 1`. Un `contains` no
sirve: el fallo que importa —inyectar la guía en cada llamada y repetirla hasta diez veces en un
turno de conducción— pasa un `contains` tan bien como el comportamiento correcto.

| Test | Qué fija |
| --- | --- |
| `test_la_guia_vendorizada_mide_exactamente_lo_que_dice_su_cabecera` | 14457 bytes + prefijo, sufijo y tres anclas del interior |
| `test_el_texto_oficial_no_lleva_nuestras_reglas_dentro` | el texto oficial queda diffeable contra el CLI |
| `test_nuestras_reglas_salen_de_una_sola_constante` | `BrowserRules.text` aparece LITERAL en las dos renderizaciones; sigue siendo una sola línea; cabe entera en la línea de `browser_open(url)` |
| `test_el_candado_de_cierre_sale_de_la_misma_constante_en_los_tres_sitios` | `closeRule` en reglas, prompt, nota y guía |
| `test_las_reglas_estan_desde_el_primer_token_no_solo_en_la_guia` | el prompt del sistema de la PRIMERA llamada ya las lleva |
| `test_un_turno_sin_navegador_nunca_lleva_la_guia` | 0 apariciones de guía, frase y reglas |
| `test_el_primer_browser_del_turno_lleva_la_guia_exactamente_una_vez` | 1 aparición; y va DETRÁS de la nota de esa herramienta |
| `test_tres_llamadas_de_navegador_en_una_ronda_siguen_llevando_la_guia_una_vez` | 1 guía con TRES herramientas en una ronda, y 3 notas |
| `test_tres_rondas_de_navegador_siguen_llevando_la_guia_una_vez` | 1 guía con TRES rondas |
| `test_la_guia_llega_cuando_aparece_el_navegador_aunque_el_turno_empiece_sin_el` | 0 tras `web_search`, 1 tras el `browser_open` siguiente |
| `test_nuestras_reglas_van_delante_del_texto_oficial_con_la_frase_de_precedencia` | orden reglas → frase → guía, y que la contradicción del `close` sigue en la guía |
| `test_el_prompt_del_sistema_no_carga_con_la_guia_oficial` | los 14 KB no se cobran a todos los turnos |
| `test_nuestras_reglas_siguen_en_el_prompt_del_sistema` | la guía se AÑADE, no reemplaza nuestras reglas |

(Son trece filas porque la tabla lista también el test del prompt del sistema que ya estaba en la
primera versión del fichero.)

## Mutaciones (Resolución B)

Diez mutaciones, suite completa en cada una. La columna de rojos lista sólo los que se SUMAN a
los 7 fallos de base. **Ninguna sobrevivió.**

| Mutación | Rojos nuevos |
| --- | --- |
| **M1** quitar el bloque de inyección entero | `test_el_primer_browser_del_turno_lleva_la_guia_exactamente_una_vez`, `test_la_guia_llega_cuando_aparece_el_navegador…`, `test_nuestras_reglas_van_delante_del_texto_oficial…`, `test_tres_llamadas_de_navegador_en_una_ronda…`, `test_tres_rondas_de_navegador…` (5) |
| **M2** quitar la guarda `!browserGuideInjected` | `test_tres_llamadas_de_navegador_en_una_ronda…`, `test_tres_rondas_de_navegador…` (2) |
| **M3** bloque sin la frase de precedencia | `test_la_guia_llega_cuando_aparece_el_navegador…`, `test_nuestras_reglas_van_delante…`, `test_tres_llamadas…`, `test_tres_rondas…` (4) |
| **M4** bloque sin nuestras reglas delante | `test_el_candado_de_cierre_sale_de_la_misma_constante_en_los_tres_sitios`, `test_el_primer_browser_del_turno…`, `test_nuestras_reglas_salen_de_una_sola_constante`, `test_nuestras_reglas_van_delante…`, `test_tres_llamadas…`, `test_tres_rondas…` (6) |
| **M5** borrar una línea del texto oficial vendorizado | `test_la_guia_vendorizada_mide_exactamente_lo_que_dice_su_cabecera` (1) |
| **M6** inyectar la guía ANTES de la nota en lugar de detrás | `test_el_primer_browser_del_turno_lleva_la_guia_exactamente_una_vez` (1) |
| **M7** forkear una copia a mano de las reglas en el prompt del sistema | `AgentBrowserRegistrationTests.test_system_prompt_teaches_reading_pages_and_the_interactive_loop`, `AgentSystemPromptTests.test_el_prompt_no_convierte_un_campo_de_correo_en_una_negativa`, `AgentSystemPromptTests.test_the_browser_line_does_not_send_the_model_to_do_logins`, `test_el_candado_de_cierre…`, `test_las_reglas_estan_desde_el_primer_token…`, `test_nuestras_reglas_salen_de_una_sola_constante`, `test_nuestras_reglas_siguen_en_el_prompt_del_sistema` (7) |
| **M8** forkear una copia a mano del candado en la nota de resultado | `test_el_candado_de_cierre_sale_de_la_misma_constante_en_los_tres_sitios` (1) |
| **M9** frase de precedencia sin «THE RULES ABOVE WIN» | `test_nuestras_reglas_van_delante_del_texto_oficial_con_la_frase_de_precedencia` (1) |
| **M10** mutar una frase DE LA CONSTANTE (`You do NOT close` → `You MAY close`) | `AgentSystemPromptTests.test_el_prompt_no_manda_cerrar_el_navegador_en_ningun_caso`, `test_nuestras_reglas_siguen_en_el_prompt_del_sistema` (2) |

M10 es la que pedía el rediseño: tocar la constante en UN sitio pone rojo el test que afirma la
intención **tanto en el prompt como en la nota de resultado** (ese test itera sobre los dos y
afirma lo mismo en cada uno), o sea que la mutación llegó a las dos renderizaciones a la vez. Si
hubiera una copia escondida, una de las dos habría seguido verde.

M7 es su complemento: forkear una copia a mano pone rojo
`test_nuestras_reglas_salen_de_una_sola_constante` y arrastra consigo tres tests de prompt que ya
existían.

M6 merece una nota. La mutación es sutil —la guía se inyecta igual, sólo cambia de sitio— y la
captura una sola aserción: la que compara el índice de la nota contra el índice de la guía en el
prompt vivo.

## Los números

| Medida | Antes | Después |
| --- | --- | --- |
| Tests fallando (suite completa) | 7 | 7 |
| Tests nuevos | — | 12 |
| Línea del navegador renderizada en el prompt del sistema | 2257 bytes | 2257 bytes (byte a byte igual) |
| Bloque inyectado en un turno de navegador | 0 | 17347 bytes (2256 reglas + 630 frase + 14457 guía) |
| Coste en un turno que no toca el navegador | 0 | 0 |

Los 7 fallos son los de base, todos previos a esta rama:
`AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`,
`ContactAliasStoreTests` (×2), `ForgetToolTests.test_forget_calls_endpoint_and_returns_count`,
`ReminderCRUDToolTests.test_update_mueve_la_hora`, `ToolJSONEscapingTests` (×2).

## Resolución D: qué podría romper, y lo que NO toqué

Nada se rompió: ningún test mide el tamaño del prompt, ningún límite de tokens salta, y la suite
quedó en los mismos 7 fallos. Pero hay dos cosas que son decisión del usuario, no mía, así que
están aquí sin tocar.

**1. En el camino on-device, los 14 KB se cortan en silencio.** `RuntimeFactory` devuelve
`LlamaCppRuntime` cuando el proveedor es `.onDevice`, y ahí el contexto por defecto es 4096
tokens (`GenerationSettings.contextLength`, y 8192 en una de las rutas de carga de
`LlamaCppRuntime`). `LlamaContext` no revienta: aplica una ventana deslizante
(`maxPromptTokens = nCtx - 512`, conserva ~500 tokens de cabecera y el resto de cola). Los 17 KB
del bloque inyectado son ~4300 tokens, y el prompt del sistema ya son ~4000: en un contexto de
4096 la guía se iría entera por el agujero del medio **sin un solo aviso**. En el camino de
servidor (MLX en el Mac, o un proveedor de API, que es lo que corre hoy) no hay problema.

Si el usuario quiere usar el navegador con el modelo on-device, la guía hay que recortarla o hay
que subir el contexto. **Cuánto recortar es decisión suya, no mía**, así que no he recortado nada.
Lo barato sería quedarse con las secciones de bucle, esperas y diagnóstico y tirar las de
`electron`/`slack`/`vercel-sandbox`/WebGPU, que no aplican a nuestro caso — pero eso rompe el
«byte a byte como lo imprime el CLI», que es lo que hace la copia diffeable, así que es un
intercambio que tiene que elegir él.

**2. Nuestras reglas viajan dos veces en un turno de navegador.** Están en el prompt del sistema
y otra vez delante de la guía inyectada: 2256 bytes repetidos en la ventana de contexto. Es el
diseño que pidió el usuario y tiene su razón (precedencia justo delante del texto que contradice,
y presencia desde el primer token), pero la repetición es real y conviene decirlo en voz alta.

## Pendiente

- **El E2E lo hace el usuario en la app.** Esto no se puede probar de verdad sin un modelo
  conduciendo una página: lo que los tests fijan es que la guía llega, una vez, en el sitio
  correcto y con nuestras reglas por delante. Que el modelo la APROVECHE (que use `wait --text`
  en lugar de dormir, que re-snapshotee tras navegar, que reconozca un `page_wedged`) es
  observación en vivo.
- La guía recomienda cosas que nuestras ocho herramientas no exponen: `find role/text/label`,
  `wait --text/--url/--fn`, `eval --stdin`, `screenshot --annotate`, pestañas, `frame`, `dialog`,
  `doctor`. El modelo va a leer sobre ellas y no va a poder llamarlas. Es un argumento para
  ampliar el registro de herramientas, no para recortar la guía — y es material para la cola de
  trabajo del navegador.

---

# Apéndice: Resoluciones 12 y 13 (2026-11-08, misma sesión)

Dos resoluciones del coordinador sobre las preocupaciones 1 y 3 del informe de arriba. Las dos se
implementan **dentro de `BrowserRules`**, que para eso es la fuente única.

## Nota sobre el hallazgo del candado divergido

Conviene decirlo más fuerte de lo que quedó arriba: **el candado de cierre ya había divergido**.
No es una mejora preventiva, es un arreglo. Las reglas no estaban en dos sitios sino en TRES, y en
dos de ellos la misma regla estaba escrita con palabras distintas:

- Prompt del sistema: «You do NOT close the browser. … `browser_close` **is gated by the app**: it
  works only when the user asked to close in this turn, and otherwise returns `refused` with the
  page **still open**. That refusal is **correct behaviour, not an error to retry**.»
- `Agent.toolResultNote`: «When the task IS finished, **leave the browser open** … You do not
  close it — `browser_close` works only if the user asked to close in this turn, and otherwise
  returns `refused` with the page **intact**, which is **correct and must not be retried**.»

Mismo fondo, tres diferencias de redacción. El test que las protegía
(`AgentSystemPromptTests.test_el_prompt_no_manda_cerrar_el_navegador_en_ningun_caso`) tenía que
aceptar las dos formas con alternativas (`"not an error to retry" || "must not be retried" ||
"correct behaviour"`), que es la cicatriz que deja una regla duplicada. Esa divergencia es
exactamente lo que el usuario intuía cuando pidió la fuente única, y ya había pasado.

## Resolución 12 — el manual es más grande que el agente, y se dice en voz alta

La guía documenta `find role/text/label`, `wait --text/--url/--fn`, `eval --stdin`,
`screenshot --annotate`, `tab`, `frame`, `dialog`, `doctor`. Nuestro agente **no tiene ninguna de
esas**.

Es el mismo defecto que documentamos en browser-use y que no vamos a importar: su prompt le
promete al modelo cajas numeradas dibujadas sobre la captura que por defecto no existen, y el
modelo acaba leyendo la descripción de algo que no ha recibido. Nosotros estaríamos haciéndolo un
nivel más arriba: darle el manual de un CLI entero y un subconjunto de herramientas.

**Lo hecho:** `BrowserRules.toolInventoryNote`, una línea que viaja DELANTE del texto oficial
(orden del bloque: reglas → inventario → frase de precedencia → guía). Dice que el documento
describe el CLI COMPLETO, enumera las herramientas que de verdad tiene, y dice que cualquier otro
comando que la guía mencione **no existe para él** por bien que lo explique, que esas secciones se
leen como contexto de cómo se comporta el navegador, y que si un paso necesitara un comando que no
tiene diga qué paso no puede hacer en lugar de fingir que lo ejecuta.

**La lista se DERIVA de `Agent.browserToolNames`**, no se escribe a mano:

```swift
let nombres = Agent.browserToolNames.sorted().map { "`\($0)`" }.joined(separator: ", ")
```

El test `test_el_inventario_de_herramientas_sale_de_browserToolNames` no comprueba que los nombres
estén: comprueba que el **conjunto nombrado sea EXACTAMENTE `Agent.browserToolNames`** (extrae los
trozos entre acentos graves, filtra los que empiezan por `browser_` y compara conjuntos), y que la
cuenta de la frase salga del conjunto. Si mañana se añade un `browser_find`, la línea lo nombra
sola; si alguien la vuelve a escribir a mano, el test se pone rojo (mutaciones M13 y M14).

**CORRECCIÓN DE UN NÚMERO:** el encargo y la resolución hablan de «nueve herramientas». Son
**OCHO**. `Agent.browserToolNames` = `browser_click`, `browser_close`, `browser_fill`,
`browser_get`, `browser_open`, `browser_press`, `browser_snapshot`, `browser_wait`. Un `grep` de
`"browser_[a-z_]*"` sobre todo `Gemma/Gemma` no encuentra una novena. (`read_webpage` existe pero
no es del navegador: es de una sola llamada y queda fuera del conjunto a propósito.) Por eso la
línea no lleva el número escrito: lo interpola de `Agent.browserToolNames.count`.

**El texto oficial no se poda.** Dejarlo byte a byte es lo que permite diffear la próxima captura
contra ésta; si se recortan las secciones de comandos que no tenemos, la siguiente actualización
es a ciegas. `test_el_texto_oficial_conserva_los_comandos_que_no_tenemos` lo fija nombrando seis
de esos comandos.

## Resolución 13 — la guía no se inyecta si no cabe

**No se recorta. Se deja de inyectar.** Y el motivo no es ahorrar tokens.

`LlamaContext` no falla cuando el prompt no cabe. Desliza la ventana:

```swift
let maxPromptTokens = max(512, nCtx - 512)
if tokensList.count > maxPromptTokens {
    let keepHeader = min(500, tokensList.count / 3)
    let keepTail = maxPromptTokens - keepHeader
    tokensList = Array(tokensList.prefix(keepHeader)) + Array(tokensList.suffix(keepTail))
}
```

Conserva ~500 tokens de cabecera y el resto de cola, y **se come el medio en silencio**. Lo que se
cae por ese agujero no es sólo la guía: el prompt del sistema son 5824 tokens estimados, así que
lo que se cae puede ser la prohibición de teclear contraseñas y el candado de cierre. Una guía a
medias que además desaloja la prohibición de teclear contraseñas es estrictamente peor que no
tener guía: cuesta tokens, no entrega nada y se lleva por delante lo único que no puede faltar.

### Cómo se sabe si cabe

`ToolCallingRuntime` gana una capacidad opcional con implementación por omisión:

```swift
var contextTokenBudget: Int? { get }   // extensión por omisión: nil
```

- `LlamaCppRuntime` la implementa devolviendo la ventana con la que se cargó (guarda
  `loadedContextLength` en `load`).
- `ServerRuntime` **no la implementa**: se queda con el `nil` por omisión, porque la ventana la
  fija el modelo remoto.
- Todos los dobles de test del proyecto se quedan también con el `nil`, así que ninguno hubo que
  tocar.

Cambio pequeño: 1 requisito de protocolo + 1 extensión por omisión + 1 propiedad almacenada y 1
propiedad calculada en `LlamaCppRuntime`. No hizo falta nada grande, así que no hubo que pararlo.

`Agent` decide con una función pura y testable:

```swift
nonisolated static func browserGuideFits(systemPrompt: String, livePrompt: String, budgetTokens: Int?) -> Bool
```

**`nil` = cabe.** Es el caso del camino que corre hoy y está afirmado con prueba propia
(`test_en_el_camino_de_servidor_la_guia_sigue_llegando`), que además pasa un `livePrompt` de medio
millón de caracteres con `budgetTokens: nil` y exige `true`: `nil` significa «no hay ventana
declarada», nunca «no sé, mejor no».

### El umbral y su procedencia

Dos números, ninguno a ojo.

| Número | De dónde sale |
| --- | --- |
| 512 tokens de margen para la respuesta | `LlamaContext.generate`: `maxPromptTokens = max(512, nCtx - 512)`. Es el margen que YA aplica el camino on-device, no uno nuevo. |
| 3 bytes por token | La regla de pulgar habitual para inglés es ~4. Se usa 3 **a propósito**, o sea se SOBREestima el número de tokens. |

Por qué 3 y no 4: los dos errores no cuestan lo mismo. Quedarse corto significa no inyectar una
guía que sí cabía — se pierde una ayuda. Pasarse significa inyectarla cuando no cabe — la ventana
desliza y se puede comer el prompt del sistema, donde viven las reglas de seguridad. Se redondea
al lado que falla barato.

### Las medidas reales (2026-11-08)

| Medida | Bytes | Tokens estimados (bytes/3) |
| --- | --- | --- |
| Prompt del sistema renderizado | 17471 | 5824 |
| Bloque inyectado completo | 18002 | 6001 |
| — nuestras reglas | 2256 | |
| — inventario de herramientas | 653 | |
| — frase de precedencia | 630 | |
| — texto oficial | 14457 | |

Presupuesto de prompt por ventana: 4096 → 3584 tokens; 8192 → 7680; 32768 → 32256.

Decisión que sale de esos números:

| Ventana | Sistema + bloque | Presupuesto | ¿Se inyecta? |
| --- | --- | --- | --- |
| 4096 (por omisión de `GenerationSettings`) | 11825 | 3584 | **No** |
| 8192 (la que usa `LlamaCppRuntime.ensureLoaded`) | 11825 | 7680 | **No** |
| 32768 | 11825 | 32256 | Sí |
| `nil` (servidor: el camino que corre hoy) | — | — | **Sí** |

La decisión es robusta al divisor: con 4 bytes/token en lugar de 3 saldrían ~4368 + ~4501 = 8869
tokens, que sigue pasándose de 7680. En las dos ventanas on-device la guía no cabe con ninguna de
las dos estimaciones.

### HALLAZGO que no es de esta tarea

Con la ventana de 4096, **el prompt del sistema SOLO ya se pasa del presupuesto**: 5824 tokens
estimados contra 3584. Sin guía ninguna, en el camino on-device con la ventana por omisión,
`LlamaContext` ya está deslizando y comiéndose el medio del prompt del sistema. Esto no lo
introduce esta tarea y no se arregla aquí, pero queda afirmado en
`test_las_ventanas_reales_del_camino_on_device` para que no se pierda. Es material para la tarea
aparcada (B) de recortar el prompt.

## Mutaciones del apéndice

Suite completa en cada una. Rojos = los que SUMAN sobre los 7 de base.

| Mutación | Rojos nuevos |
| --- | --- |
| **M11** la guarda ignora el presupuesto y siempre devuelve `true` | `test_la_guia_no_se_inyecta_si_no_cabe_en_la_ventana`, `test_el_calculo_de_si_cabe`, `test_las_ventanas_reales_del_camino_on_device` (3) |
| **M12** `LlamaCppRuntime.contextTokenBudget` devuelve `nil` | `test_el_camino_on_device_declara_su_ventana` (1) — **ver abajo: a la primera SOBREVIVIÓ** |
| **M13** el inventario pierde una herramienta (`dropLast()`) | `test_el_inventario_de_herramientas_sale_de_browserToolNames` (1) |
| **M14** el inventario se escribe a mano en vez de derivarse | `test_el_inventario_de_herramientas_sale_de_browserToolNames` (1) |
| **M15** el inventario sale del bloque inyectado | `test_el_inventario…`, `test_en_el_camino_de_servidor_la_guia_sigue_llegando`, `test_nuestras_reglas_van_delante_del_texto_oficial…` (3) |
| **M16** la estimación de tokens se vuelve optimista (3 → 40 bytes/token) | `test_la_guia_no_se_inyecta_si_no_cabe_en_la_ventana`, `test_el_calculo_de_si_cabe`, `test_las_ventanas_reales_del_camino_on_device` (3) |

### M12 sobrevivió a la primera, y eso era el agujero

En la primera tanda **M12 no puso NADA rojo**. La guarda miraba el presupuesto, el camino de
servidor seguía funcionando, los dos tests de ventana pasaban… y el único sitio donde la guarda
hace falta no estaba cubierto por nada: si `LlamaCppRuntime` devolvía `nil`, se interpretaba como
«cabe» y la protección desaparecía en el camino on-device sin que ningún test se enterara.

Arreglado con dos cambios:

1. `LlamaCppRuntime.contextTokenBudget` deja de poder ser `nil`: devuelve
   `loadedContextLength ?? LlamaCppRuntime.fallbackContextTokens`, y el fallback es 8192 — la
   ventana con la que `ensureLoaded` carga el modelo cuando nadie le dice otra cosa. Declarar una
   ventana estrecha de más es el lado barato; declarar ninguna (`nil` = «cabe») es el caro.
2. `test_el_camino_on_device_declara_su_ventana`, que exige `contextTokenBudget` no-`nil`, que
   valga el fallback, que el fallback sea 8192, y que con esa ventana `browserGuideFits` diga
   `false` — o sea que la guarda hace algo real ahí. Se comprueba sin cargar modelo, porque en los
   tests no hay `.gguf`; que tras un `load` real declare la ventana de ese `load` no es testeable
   aquí y queda dicho en el comentario del runtime.

**Segundo hallazgo del mismo episodio, metodológico:** la primera versión de M12 reemplazaba
`return loadedContextLength` por `return nil`, y tras el arreglo esa cadena quedó como PREFIJO de
la línea nueva, así que la mutación producía `return nil ?? Self.fallbackContextTokens` — que
sigue devolviendo 8192. La mutación se había vuelto un no-op y «sobrevivía» por eso, no por falta
de test. Hubo que re-apuntar el ancla a la línea entera para verla roja. Una mutación que no
compila distinto a lo que uno cree es una mutación que miente igual que un test que pasa por el
motivo equivocado.

## Números finales

| Medida | Valor |
| --- | --- |
| Tests fallando (suite completa) | 7, los de base |
| Tests nuevos en `BrowserCoreSkillTests` | 22 |
| Mutaciones comprobadas en rojo | 16 (10 + 6), ninguna sobrevive |
| Ficheros de producción tocados | `Agent.swift`, `BrowserRules.swift`, `BrowserCoreSkill.swift`, `ToolCallingRuntime.swift`, `LlamaCppRuntime.swift` |
