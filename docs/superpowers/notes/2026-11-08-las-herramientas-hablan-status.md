# Las herramientas hablan `status` — rama del bucle de navegación

**Rama:** `diag/panel-se-muere`, sobre `471c2ba`.
**Encargo:** arreglar la raíz que encontró el arreglo anterior
(`2026-11-08-arreglo-superficie-al-usuario.md`, sección «Lo que descubrí fuera de la tarea»):
herramientas que reportan su resultado en PROSA en vez de en un objeto JSON con `status`. De ahí
salen dos textos falsos en la pantalla del usuario, en direcciones opuestas, y un parche en el
bucle.

**Un cambio, tres defectos:**

1. **Un éxito salía con CRUZ ROJA.** `ToolLogRow.summarize` empieza por parsear el resultado; lo
   que no es un objeto JSON cae en la rama de fallo. `forget` contestaba «Forgot 3 item(s)
   matching 'x'.» —tres recuerdos olvidados de verdad— y la fila lo pintaba en rojo.
2. **Un error salía con TILDE VERDE y «listo».** `ToolJSONOutput.error(_:)` emitía `{"error": …}`:
   un objeto JSON **sin** `status`, así que no entraba en la rama de fallo, caía en `case nil` y
   se resumía como «listo». Es el camino de las guardas de argumentos de medio registro y lo
   dispara el modelo llamando con los argumentos mal. **Era la peor de las dos:** un error pintado
   como éxito hace que el usuario crea que algo pasó, que es su queja literal.
3. **El presupuesto de fallos había tenido que aceptar la prosa como éxito** para no matar turnos
   en los que `forget` sí había funcionado — con el precio, declarado en el código, de que un
   FALLO en prosa («memory unavailable») también reiniciara.

**Pruebas:** base **4 fallos / 1.205 verdes** → después **4 fallos / 1.216 verdes**. Los cuatro
fallos son preexistentes y ninguno es de esta rama; además **uno de los cinco de la base declarada
se ha arreglado** (ver «El quinto rojo de la base»), así que la base real pasó de 5 a 4.

---

## El censo, verificado por mí

El censo heredado decía **seis** herramientas. **Son ocho, y una de las seis estaba mal
nombrada.** Lo verifiqué sobre las **ochenta** herramientas que conforman `AgentTool` en el
proyecto, no sobre la lista heredada: un script recorre cada declaración
(`struct|final class|class X: AgentTool`), aísla el cuerpo de su `func run(argsJSON:)` por
emparejamiento de llaves y marca el que no pasa por ninguno de los constructores de salida
(`ToolJSONOutput`, `AgentBrowserToolOutput`, `ScheduleToolSupport`, `ScheduleRange`); una segunda
pasada busca cualquier `return "…"` o `return algo.userMessage` a cualquier profundidad del cuerpo
de `run`. El grep a pelo no sirve para esto: media docena de ficheros tienen funciones *ayudantes*
que devuelven prosa —`SendMessageTool.message(for:…)`, `RunShortcutTool.message(for:…)`,
`MusicPlaybackControl.doneMessage(…)`, `TaskTools.taskStatus(…)`, `RoutineTools`— y esa prosa
acaba dentro de un `message` del JSON, que es correcto.

| # | herramienta | fichero | en el censo heredado | estado(s) que le di |
|---|---|---|---|---|
| 1 | `forget` | `Gemma/Gemma/Memory/ForgetTool.swift` | sí | `success` (+`forgotten_count`) · `not_found` · `missing_fields` · `memory_unavailable` · `failed` |
| 2 | `save_memory` | `Gemma/Gemma/Memory/SaveMemoryTool.swift` | sí | `success` (+`entity`, `merged_into`) · `invalid_entity` · `memory_unavailable` · `failed` |
| 3 | `reflect` | `Gemma/Gemma/Memory/ReflectTool.swift` | sí | `success` (sin ramas) |
| 4 | `add_shift` | `Gemma/Gemma/AtoZ/AtoZTools.swift` | sí | `success` · `dry_run` · `confirmation_required` · `unknown` · `missing_fields` · `failed` |
| 5 | `drop_shift` | `Gemma/Gemma/AtoZ/AtoZTools.swift` | sí | los mismos que `add_shift` |
| 6 | `list_available_shifts` | `Gemma/Gemma/AtoZ/AtoZTools.swift` | **mal: el censo decía `get_shifts`** | `success` (+`count`, `shifts`) · `no_content` · `failed` |
| 7 | **`update_event`** | `Gemma/Gemma/Memory/ScheduleTools.swift` | **NO — la séptima** | `success` (+`event`) · `not_found` · `ambiguous` · `conflict` · `missing_fields` · `invalid_datetime` · `memory_unavailable` · `failed` |
| 8 | **`get_current_time`** | `Gemma/Gemma/Agent/CurrentTimeTool.swift` | **NO — la octava** | `success` (+`local_time`) |

### Lo que el censo heredado tenía mal, en concreto

- **`get_shifts` NO EXISTE.** Ninguna herramienta del proyecto se llama así; no aparece en ningún
  `registry.register`, y el único sitio donde se lee ese nombre es el propio comentario de
  `Agent.reiniciaElPresupuesto` que el censo copió. La tercera herramienta de A to Z es
  `list_available_shifts` (`ListAvailableShiftsTool`), y sí contestaba en prosa
  («Turnos encontrados:\n• [ID: …] …»), así que el censo acertaba el número de A to Z y fallaba el
  nombre.
- **`update_event` es la séptima, y es una MUTACIÓN de la agenda.** Esta es la que más importa de
  las dos nuevas, por dónde vive: `ScheduleTools.swift`. La cabecera de ese fichero documenta los
  seis defectos que SP1 arregló, y el sexto dice literalmente *«Nada de esto tenía `status`.
  Devolvían prosa en inglés que el modelo tenía que interpretar en vez de leer»*. Se arregló en
  `check_schedule`, `create_event`, `query_schedule` y `cancel_events` — las cuatro hermanas, en
  el mismo fichero— y `update_event` se quedó fuera. Así que el agente tenía una mutación de
  agenda cuyo resultado la fila pintaba en rojo cuando funcionaba, y en la que el modelo tenía que
  distinguir en prosa «no lo encontré» de «hay varios» de «choca con otro».
- **`get_current_time` es la octava.** Devolvía `fmt.string(from: Date())` a pelo: «Nov 8, 2026 at
  3:04 PM». Preguntar la hora —lo que no puede fallar— salía en el chat con cruz roja.

### Y lo que NO es prosa, aunque un grep lo diría

Dejo anotado el falso positivo porque el siguiente que repita el censo se lo va a encontrar: hay
`return "…"` en `SendMessageTool`, `RunShortcutTool`, `MusicPlaybackControl`, `TaskTools`,
`RoutineTools` y `ScheduleTools`, y **ninguno es la salida de un `run`**: son ayudantes que
construyen el `message` que va DENTRO del JSON, que es exactamente lo que el contrato pide. Por
eso el censo hay que hacerlo sobre el cuerpo de `run`, no sobre el fichero.

**Después del cambio, el mismo script no encuentra ninguna de las ochenta fuera del contrato.**
Es la condición que el punto 3 necesitaba.

---

## Qué estado le di a cada una, y por qué

### El criterio, que es uno y se aplica ocho veces

Dos reglas y nada más:

1. **El éxito se declara `success`, no con un verbo.** `Agent.estadosDeExito` son `success` y
   `no_content`, y es el conjunto que REINICIA el presupuesto de fallos del turno. Un
   `status: "updated"` o `"forgotten"` leería mejor, pero cae en el tercer estado («ni éxito ni
   fallo») y no reiniciaría nada: sería volver a meter el defecto 3 por otra puerta. La semántica
   va en las otras claves (`forgotten_count`, `event`, `entity`), no en el nombre del estado.
   *(Nota honesta: `create_event` y `cancel_events` ya usan `"created"` y `"cancelled"`, así que
   ese agujero existe desde antes en sus hermanas. No lo he tocado — no es de este encargo— pero
   queda dicho, porque un éxito que no reinicia el presupuesto es el mismo defecto 3.)*
2. **Lo que no se hizo no se pinta como hecho.** De ahí `not_found` en un `forget` que no encontró
   nada, `dry_run` en una simulación de A to Z y `conflict` en un `update_event` que no cambió
   nada. Es la regla del usuario: si el agente no lo hizo, no puede decir que lo hizo.

### Los estados, uno a uno

| estado | dónde | por qué ese y no otro |
|---|---|---|
| `success` | las ocho, camino bueno | el contrato. Reinicia el presupuesto y la fila dice «listo». |
| `no_content` | `list_available_shifts` con lista vacía | está en `estadosDeExito` y su definición es exactamente esto: «funcionó pero no hay nada que reportar». Si fuera fallo, cinco consultas a semanas sin turnos matarían el turno del usuario. |
| `missing_fields` | guardas de `forget`, `update_event`, `add_shift`, `drop_shift` | el estado que ya usa `ScheduleRange.parse` para un argumento que no llegó. Pinta cruz roja pero **no** gasta presupuesto (no está en `Agent.estadosDeFallo`), que es lo correcto: el modelo puede arreglarlo él solo. |
| `invalid_datetime` | `update_event` con un `start` ilegible | el mismo que emiten sus cuatro hermanas por `ScheduleRange`. Y se **distingue** de `missing_fields`: las dos ramas salían antes por la misma frase, así que el modelo no sabía si tenía que preguntarle la hora al usuario o solo reescribir en ISO la que ya tenía. |
| `invalid_entity` | `save_memory` con entidad vacía o de relleno | familia `invalid_*`, abierta a propósito, con su frase ya existente («los datos no valían»). La guarda no distingue «no mandaste nada» de «mandaste una frase», y la acción del modelo es la misma en los dos casos. |
| `memory_unavailable` | `forget`, `save_memory`, `update_event` | ya existía y es el caso cotidiano: el servicio del i3 al otro lado de Tailscale. Frase: «la memoria no respondió». |
| `not_found` | `forget` que no encontró nada, `update_event` que no encontró el evento | cruz roja, sin gastar presupuesto. Un `success` ahí sería la mentira: el usuario pidió algo, no se hizo nada. |
| `ambiguous` / `conflict` | `update_event` | los dos ya están en `needsYouStatuses`: ni éxito ni fallo, icono propio, «necesita algo de ti». Es la definición literal — la herramienta no pudo seguir y espera una elección del usuario. |
| `confirmation_required` | `add_shift`/`drop_shift` sin confirmar | igual: ya estaba en `needsYouStatuses`. |
| `unknown` | `add_shift`/`drop_shift` con `unknownOutcome` | ya estaba en `needsYouStatuses`, y encaja: la mutación se envió, la verificación no resolvió, y lo honesto es que el usuario lo mire en su app — que es justo lo que el `message` le dice al modelo. |
| `failed` | el resto de los fallos, y **todos** los `AtoZFailure` | ver abajo. |
| **`dry_run`** | `add_shift`/`drop_shift` en modo simulado | **el único estado NUEVO.** Ver abajo. |

### `error`, para `ToolJSONOutput.error(_:)` (punto 2)

El encargo pedía mirar si ya existe el estado bueno antes de inventar uno. Existen tres
candidatos y elegí `error`:

- **`error`** es el estado genérico del contrato, existe desde el principio, está en
  `ToolLogRow.failureStatuses` («falló») y en `Agent.estadosDeFallo`.
- **Y es el único que es cierto en todos los sitios de llamada**, que es el dato que decide.
  `ToolJSONOutput.error(_:)` **no es solo la guarda de argumentos**: el censo de sus más de
  cincuenta llamadas incluye también «No se encontró ningún lugar con 'x'», «No se pudo actualizar
  la nota: …», «No se pudo buscar el contacto '…': …» y «No se pudo generar la URL de navegación».
  `invalid_arguments` —que en este proyecto **no existe** como estado emitido; solo se menciona en
  un comentario sobre lo que devuelve el CLI del navegador— y `missing_fields` serían mentira en
  ese segundo grupo.
- Los estados finos siguen disponibles para quien quiera precisar en su propia llamada, y así los
  usan ya `ScheduleRange.parse` y `CreateCalendarEventTool`. Migrar los cincuenta y tantos sitios
  uno a uno es otro trabajo; lo que no podía seguir es que el camino por omisión saliera en verde.

**La clave `error` se queda**, y no por compatibilidad ciega: una veintena de pruebas de todo el
registro la leen para comprobar que el motivo viajó entero y escapado (`ToolJSONEscapingTests`,
`NoteCRUDTests`, `PendingDefectsTests`…), y dice algo distinto que `status` — una es el motivo, la
otra el estado. La salida es ahora `{"error": "…", "status": "error"}`.

**Y el mismo arreglo en el camino de al lado:** el `guard` de `ToolJSONOutput.object(_:)` devolvía
`{"error": "El tool no pudo serializar su respuesta."}`, también sin `status`. No puede pasar por
`error(_:)` —es justo el camino en el que serializar falló— así que lleva el `status` escrito en el
literal.

### `dry_run`, el único estado nuevo

`AtoZConfig` trae el **modo simulado activado de fábrica**, así que `.dryRun` es el camino NORMAL
de una aceptación de turno: se valida la confirmación, se pasan todas las puertas de seguridad y
**no se envía nada a Amazon**. Miré los estados que ya hay antes de añadirlo:

- `rejected` («no se aceptó») insinúa que Amazon dijo no, y Amazon no ha visto la petición.
- `not_available` («no está disponible») es falso: está disponible, es el usuario quien la tiene
  en simulación.
- `refused` («el navegador no lo hizo») está censado como exclusivo del navegador.
- `error`/`failed` dirían que algo se rompió, y no se rompió nada.
- `confirmation_required` diría que falta que el usuario conteste en el chat, y lo que falta es que
  cambie un ajuste.

Ninguno dice la verdad, y la verdad aquí es justo lo que el usuario necesita leer sobre la
herramienta que le coge turnos de trabajo. Frase nueva en la tabla de `ToolLogRow`, que es donde el
encargo dice que vivan: **«no se hizo de verdad: era una prueba»**. Va en
`ToolLogRow.failureStatuses` (cruz roja) y **no** en `Agent.estadosDeFallo` (no mata el turno),
que es el criterio ya escrito en ese conjunto: entra lo que significa «no pude», se queda fuera lo
que significa «contesté, y la respuesta es no».

### Todos los `AtoZFailure` → `failed`, y por qué no once estados

`AtoZFailure` tiene once casos (`notConfigured`, `sessionExpired`, `accessDenied`,
`shiftUnavailable`, `serverError(Int)`…). Se podría trazar un mapa fino, y lo decidí **no** hacer:

- Los once significan «no pude» y repetir no lo cambia, así que para el **bucle** son todos lo
  mismo: `failed` gasta presupuesto, que es lo correcto.
- Para el **usuario**, los once caben en «no se pudo hacer»: ninguna distinción le cambia lo que
  tiene que hacer.
- Para el **modelo**, el detalle no se pierde: `failure.userMessage` entero viaja en `message` y en
  `reason`, y ahí sí es accionable («abre Ajustes y pulsa Iniciar sesión en A to Z»).

Once estados nuevos no cambiarían nada de lo que alguien ve ni de lo que el bucle hace. Queda
anotado como posible refinamiento, no como deuda.

### Una pieza nueva y pura: `AtoZToolOutput`

`Gemma/Gemma/AtoZ/AtoZToolOutput.swift`. El camino que produce los resultados de A to Z atraviesa
`AtoZClient.shared`: ajustes, sesión, caché de oportunidades y red. Una traducción escrita dentro
de cada herramienta solo se podría medir levantando todo eso — y de hecho **las tres herramientas
de A to Z no tenían ni una prueba de `run`**; `AtoZTests` solo comprueba sus nombres y el número
de parámetros. Con la decisión fuera, en una función pura sobre un enum cerrado, los cinco
resultados se miden sin red y sin ajustes. `AtoZAddShiftResult` y `AtoZDropShiftResult` son el
mismo enum escrito dos veces, así que se normalizan a un `Outcome` común en el que los dos casos
con éxito llevan la descripción del turno en vez de la oportunidad entera.

---

## El punto 3: el precio que el presupuesto pagaba, quitado

`Agent.reiniciaElPresupuesto(resultado:)` aceptaba «no es un objeto JSON» como éxito. El defecto
que eso arreglaba era real y está medido en el informe anterior: ocho herramientas registradas
contestaban en prosa y su éxito no reiniciaba nada, así que cinco fallos intercalados con cinco
`forget` que funcionaron mataban el turno. **El precio, declarado entonces en el propio código:**
un FALLO en prosa («memory unavailable») también reiniciaba, y el presupuesto se quedaba sin
dientes justo contra el turno que de verdad no avanza.

**Lo quité**, y la comprobación que el encargo pedía antes de quitarlo es el censo de arriba: el
script recorre las ochenta herramientas del registro y **ninguna** contesta fuera del contrato.
No queda ningún éxito en prosa que el reinicio tenga que rescatar. La función ahora es
`esExito(resultado:)` y nada más.

**La función se queda** aunque hoy coincida con `esExito`: es el punto donde la decisión está
escrita y el único sitio al que mirar el día que vuelva a aparecer una herramienta de fuera del
contrato. `esFallo` y `esExito` siguen siendo dos funciones distintas por el mismo motivo.

**La prueba:** `AgentTests.test_el_presupuesto_se_reinicia_con_el_contrato_y_no_con_la_prosa`, con
cuatro mitades (ver la siguiente sección) y la mutación **M11**, que resucita el parche entero y
muere.

Lo único que sigue llegando al bucle sin ser JSON es el `DUPLICATE_CALL_IGNORED` que escribe el
propio bucle, y ya no hace falta nombrarlo: no es un objeto JSON, no es `success`, no reinicia.

**Lo que NO toqué**, como pedía el encargo: `cortaLaCola`, `urlDemostrada`, `esFallo`,
`maxConsecutiveFailures`, `pareceAtascado`, `recortaElHistorial`, `browserGuideFits`,
`executedMutations`, `activeTools = []`, `BrowserCloseIntent` y `BrowserCloseTool`. De `esFallo`
cambié **solo su comentario**, que decía que `forget` contesta en prosa: dejarlo habría sido dejar
una mentira escrita en el freno de al lado.

---

## Las pruebas que declaraban la conducta vieja, con la decisión sobre cada una

Es el corazón del encargo. **Trece pruebas** afirmaban la prosa literalmente. Ninguna se borró;
cada una se re-apuntó a la propiedad que protegía. Y cuatro más se quedaron **verdes pero
vacuas** —el patrón que el encargo avisaba—, que es el caso que no se ve, y también están aquí.

### Las que se pusieron ROJAS por el cambio de contrato (13)

| prueba | qué afirmaba | decisión y por qué |
|---|---|---|
| `SaveMemoryToolTests.test_save_calls_endpoint_and_returns_saved_string` | `out.contains("Saved")` y `contains("sushi")` | **Re-apuntada** y renombrada a `…_and_declares_what_it_saved`. La propiedad nunca fue la palabra «Saved»: era que el usuario sepa **qué** se guardó. Ahora `status: success` + `entity` + `kind`. |
| `SaveMemoryToolTests.test_save_merged_response_is_still_saved_string` | `contains("Saved")` sobre una respuesta con `mergedInto` | **Re-apuntada y REFORZADA.** Protegía que un guardado FUNDIDO siga contando como guardado. Las dos ramas devolvían la misma frase (`r.mergedInto != nil ? "Saved: x" : "Saved: x"`, literal en el código), así que la fusión era invisible para todo el mundo; ahora la prueba exige además `merged_into == "n1"`. |
| `SaveMemoryToolTests.test_save_no_client_is_safe` | `== "memory unavailable"` | **Re-apuntada** a `status: memory_unavailable`, y se le añade lo que la frase sola no podía afirmar: `Agent.esFallo(resultado:)` es `true`, o sea que un servicio caído **no** puede contar como un guardado. |
| `SaveMemoryToolTests.test_save_junk_entity_discarded_before_http` | `== "nothing to save"` | **Re-apuntada y REFORZADA.** Su propiedad real es la que dice su nombre: la basura no gasta un viaje de red. La prueba vieja la «afirmaba» comparando frases con el cliente a `nil` y razonando en un comentario que si no se filtrara saldría otra frase. Ahora hay un doble que **cuenta peticiones** y exige cero, más `status: invalid_entity`. |
| `SaveMemoryToolTests.test_save_http_error_returns_memory_error` | `contains("memory error")` | **Re-apuntada** a `status: failed` + `esFallo`. |
| `ForgetToolTests.test_forget_calls_endpoint_and_returns_count` | `contains("3")` y `contains("Forgot")` | **Re-apuntada** a `forgotten_count == 3`. La propiedad era que el **número** llegue, no la frase que lo envolvía. **Esta prueba además ya estaba roja en la base por otro motivo; ver más abajo.** |
| `ForgetToolTests.test_forget_no_client_is_safe` | `== "memory unavailable"` | **Re-apuntada** a `memory_unavailable` + `esFallo`. |
| `ForgetToolTests.test_forget_empty_query_is_noop` | `== "nothing to forget"` | **Re-apuntada** a `missing_fields`. |
| `UpdateEventToolTests.test_update_event_tool_reports_not_found` | `lowercased().contains("couldn't find")` | **Re-apuntada** a `not_found`, más `!esExito`: no encontrar el evento no puede contar como haberlo cambiado. |
| `UpdateEventToolTests.test_update_event_tool_echoes_updated_event` | `contains("Updated")` y `contains("Miami")` | **Re-apuntada.** Lo que protegía —que el evento tal como quedó vuelva entero— sigue protegido, ahora leyendo `event.location` y `event.title` del objeto en vez de buscando subcadenas. |
| `UpdateEventToolTests.test_update_event_tool_conflict_asks` | `contains("NOT changed")` y `contains("dentist")` | **Re-apuntada.** `status: conflict` + `conflicts[0].title == "dentist"`: **con qué choca es la mitad que no se puede perder**, porque sin eso el modelo no puede preguntarle al usuario qué hacer, que es justo lo que el estado le pide. Más `!esExito`. |
| `UpdateEventToolTests.test_update_event_tool_no_client_is_safe` | `== "memory unavailable"` | **Re-apuntada** a `memory_unavailable` + `esFallo`. |
| `AgentTests.test_un_exito_en_prosa_reinicia_el_presupuesto_y_un_objeto_ilegible_no` | **la propiedad contraria a la nueva** | **Reescrita, y es un cambio de propiedad declarada, no un arreglo para verdear.** Ver abajo. |

### La prueba que declaraba el parche: cambio de propiedad, razonado

`AgentTests.test_un_exito_en_prosa_reinicia_el_presupuesto_y_un_objeto_ilegible_no` →
`test_el_presupuesto_se_reinicia_con_el_contrato_y_no_con_la_prosa`.

La vieja afirmaba, en su primera mitad, que **un éxito en prosa reinicia el presupuesto**. Era
verdad y era el parche: el defecto que arreglaba era real, y el precio estaba escrito. Al quitar el
parche, esa mitad deja de ser la propiedad del sistema. **No se podía «arreglar» sin invertirla**,
así que la reescribí entera y dejé en el comentario de dónde viene y por qué cambia.

La nueva tiene **cuatro mitades en la misma función**, elegidas para que ninguna implementación
fácil pase:

- **(a)** `forget` declarando `status: success` reinicia → la ronda con cuatro fallos + `forget` +
  un fallo + `browser_fill` termina entera. **Es el caso que obligó al parche, ahora cubierto por
  la puerta buena.** El doble (`FakeForgetDelContrato`) devuelve la forma REAL de `ForgetTool`.
- **(b)** un objeto JSON sin `status` legible **no** reinicia → el presupuesto se agota y el
  `browser_fill` no corre.
- **(c)** la PROSA **tampoco** reinicia → la MISMA ronda que antes terminaba entera ahora agota el
  presupuesto. **Es exactamente el precio que se ha quitado**, medido en el bucle y no solo en la
  función pura.
- **(d)** la función pura, incluido `reiniciaElPresupuesto("memory unavailable") == false`, que es
  el fallo en prosa que antes reiniciaba.

Una implementación que reiniciara con cualquier cosa que no sea un fallo pasaría (a) y moriría en
(b) y (c); una que no reiniciara nunca moriría en (a); **y la de antes pasaría (a) y (b) y moriría
en (c)**.

Y el doble `FakeObjetoSinEstado` cambió de ejemplo, lo cual **es** el arreglo: era
`ToolJSONOutput.error("Se requiere 'name' …")`, y desde este cambio ese caso **salió** de la
categoría «objeto sin `status`» y es un fallo contado. La categoría sigue existiendo y sigue
necesitando su doble, así que ahora el doble es un objeto que de verdad llega sin `status`, con el
porqué escrito encima.

### Las que se quedaron VERDES pero vacuas (4)

Son las que no se ven, y el encargo avisaba de ellas. Para cada aserción me pregunté: *¿esto se
cumple con mi cambio deshecho?*

| prueba | por qué era vacua | decisión |
|---|---|---|
| `ReflectToolTests.test_reflect_tool_requests_light_reflection_locally` | `XCTAssertFalse(out.isEmpty)` lo cumple **cualquier** cadena. No se enteraba de que `reflect` contestaba en prosa —y la fila la pintaba en rojo— ni se enteraría de que dejara de hacerlo. Ya era vacua antes de mi cambio. | **Reforzada:** `status == "success"`. La otra mitad (que el manejador local se llame) se queda intacta. |
| `ReflectToolTests.test_reflect_tool_no_handler_is_safe` | lo mismo, y era la prueba entera | **Reforzada:** `status == "success"` **y** que `ToolLogRow.summarize` no la resuma como fallo — que es el defecto por el que esta herramienta entró en el censo. |
| `ToolLogRowTests.test_sin_estado_no_es_un_fallo` | seguía verde, y su ejemplo (`{"count":3}`) nunca fue el caso que importaba. Tal cual, **bendecía** la amnistía que dejaba pasar `{"error": …}` con tilde verde. | **Conservada y ampliada** a `test_sin_estado_no_es_un_fallo_pero_una_guarda_de_argumentos_si`. La primera mitad sigue siendo cierta y necesaria (la polaridad de la fila enumera el fallo, no el éxito); la segunda clava que la salida de una guarda de argumentos **ya no** entra en esa categoría, para que la amnistía no vuelva a cubrirla. |
| `ToolLogRowTests.test_lo_que_no_es_json_no_rompe_la_fila_ni_la_deja_en_blanco` | seguía verde con su basura (`""`, `"{roto"`, un volcado de pánico) y sigue siendo una propiedad real. Lo que había caducado era lo que **significaba**: su decisión se tomó cuando «ilegible» quería decir «basura», y durante un tiempo quiso decir también «la prosa de ocho herramientas que funcionan». | **Conservada sin cambiar aserciones**, con el porqué escrito encima: hoy lo único que llega a esa rama es lo que su nombre dice. Es la prueba que el encargo citaba como «declara la conducta vieja»; la conducta que declara sigue siendo correcta, lo que cambió es que ya no atropella a nadie. |

### Las que NO cambiaron, y por qué no hacía falta

- `SaveMemoryToolTests.test_save_permanent_flag_is_passed_in_extra`,
  `StringSpelledArgumentsTests.test_save_memory_lee_permanent_en_cadena`,
  `StringSpelledArgumentsTests.test_update_event_lee_allDay_y_force_en_cadena`: miran el **cuerpo
  de la petición HTTP**, no la salida. Siguen siendo verdad por el mismo camino.
- `AtoZTests.test_tools_conformToAgentTool`: afirma nombres y número de parámetros. Intacta — y
  deja a la vista que las tres herramientas de A to Z no tenían ninguna prueba de `run`, que es
  por lo que `AtoZToolOutput` existe.
- `AgentTests.test_un_resultado_ilegible_no_es_exito_ni_fallo`: `esFallo` y `esExito` no se
  tocaron, y el tercer estado sigue existiendo.
- `AgentTests.test_el_mensaje_de_presupuesto_agotado_dice_la_herramienta_las_veces_y_el_motivo`:
  usa la prosa de `FakeIlegible` como «resultado sin motivo legible», que sigue siendo cierto.
- `AgentTests.test_lo_que_gasta_presupuesto_sale_con_cruz_roja_en_el_chat`: recorre
  `Agent.estadosDeFallo` y `estadosDeExito` desde producción. `dry_run` entra solo en el conjunto
  ancho, así que el invariante (`estadosDeFallo ⊆ failureStatuses`) sigue en pie — **y esta prueba
  es la que lo habría cazado** si lo hubiera metido en el estrecho.
- `ToolLogRowTests.test_cada_estado_de_fallo_tiene_su_frase_fija_y_ninguna_habla_al_modelo`:
  recorre `failureStatuses` desde producción, así que **añadir `dry_run` sin frase la habría
  puesto roja**. Es el guardián que el arreglo anterior dejó puesto y funcionó.

### El quinto rojo de la base

La base declarada eran **5** fallos. Uno de ellos, `ForgetToolTests
.test_forget_calls_endpoint_and_returns_count`, estaba en mi zona de obra y **no fallaba por el
contrato**: su doble afirmaba que la PRIMERA petición de `forget` es `/v1/memory/forget`, y dejó
de serlo cuando la herramienta aprendió a buscar por nodos — hoy empieza por `GET /v1/nodes` y
solo baja al borrado por etiqueta si no encontró ninguno. El doble se quejaba de la primera
llamada y la prueba moría ahí **sin llegar a mirar nada de lo que decía medir**. Al re-apuntarla
arreglé también eso (el doble contesta a las dos rutas y la aserción del camino de borrado se
mantiene donde importa), así que la base real pasa de 5 a 4. Los otros cuatro
(`AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`,
`ContactAliasStoreTests` ×2, `ReminderCRUDToolTests.test_update_mueve_la_hora`) son ajenos y
siguen rojos sin que esta rama los haya tocado.

---

## Tabla de mutaciones

Una por propiedad afirmada, **suite ENTERA en cada una**. El guion
(`mutaciones_status_opus5.py`, con nombre único porque el scratchpad está compartido) exige que el
ancla aparezca **exactamente una vez** en el fichero antes de tocar nada, comprueba que la
mutación cambió el fichero, y al terminar restaura desde la copia y **vuelve a comprobar el MD5**
con un `assert` que aborta el guion si no coincide. «Rojos nuevos» = rojos de esa ejecución menos
los **4 de la base**.

**Catorce mutaciones. Las catorce compilaron, corrieron y murieron. Ninguna sobrevivió, ningún
agujero.**

| id | mutación | propiedad | rojos nuevos | pruebas que la matan |
|---|---|---|---|---|
| **M1** | `ToolJSONOutput.error` vuelve a `object(["error": message])` | la guarda de argumentos declara `status: error` **(punto 2)** | 2 | `HerramientasHablanStatusTests.test_la_guarda_de_argumentos_declara_error_y_ya_no_sale_en_verde`, `ToolLogRowTests.test_sin_estado_no_es_un_fallo_pero_una_guarda_de_argumentos_si` |
| **M2** | `"forgotten_count": count` → `0` | cuántos recuerdos se olvidaron viaja al modelo | 2 | `ForgetToolTests.test_forget_calls_endpoint_and_declares_how_many_it_forgot`, `HerramientasHablanStatusTests.test_forget_dice_cuantos_olvido_en_una_clave_y_no_en_una_frase` |
| **M3** | la rama `not_found` de `forget` → `status: success` | un `forget` que no encontró nada no se pinta como hecho | 1 | `HerramientasHablanStatusTests.test_forget_que_no_encuentra_nada_no_se_pinta_como_hecho` |
| **M4** | `reflect` vuelve a `return "Reflecting in the background."` | `reflect` habla el contrato | 4 | `HerramientasHablanStatusTests.test_las_ocho_que_hablaban_prosa_devuelven_json_con_status_legible`, `…test_un_exito_de_las_que_hablaban_prosa_ya_no_sale_con_cruz_roja`, `ReflectToolTests.test_reflect_tool_no_handler_is_safe`, `…test_reflect_tool_requests_light_reflection_locally` |
| **M5** | `get_current_time` vuelve a `return text` | `get_current_time` habla el contrato | 2 | `HerramientasHablanStatusTests.test_las_ocho_que_hablaban_prosa_devuelven_json_con_status_legible`, `…test_un_exito_de_las_que_hablaban_prosa_ya_no_sale_con_cruz_roja` |
| **M6** | `.dryRun` → `status: success` | una simulación de A to Z **no** es un éxito | 1 | `HerramientasHablanStatusTests.test_los_cinco_resultados_de_a_to_z_declaran_su_estado` |
| **M7** | se quita `"dry_run"` de `ToolLogRow.failureStatuses` | `dry_run` está en el censo que pinta la cruz roja | 1 | ídem |
| **M8** | se quita la frase de `dry_run` de `frasesDeFallo` (cae en «falló») | `dry_run` tiene su **propia** frase, y no la genérica | 1 | ídem |
| **M9** | el éxito de `update_event` → `status: "updated"` | el éxito se declara con el estado que el bucle reconoce, no con un verbo | 2 | `HerramientasHablanStatusTests.test_update_event_declara_sus_cuatro_resultados`, `UpdateEventToolTests.test_update_event_tool_echoes_updated_event` |
| **M10** | se quita la clave `conflicts` de `update_event` | con qué choca sigue viajando al modelo | 2 | `HerramientasHablanStatusTests.test_update_event_declara_sus_cuatro_resultados`, `UpdateEventToolTests.test_update_event_tool_conflict_asks` |
| **M11** | `reiniciaElPresupuesto` vuelve al parche entero (prosa = éxito) | **la prosa ya no reinicia el presupuesto (punto 3)** | 2 | `AgentTests.test_el_presupuesto_se_reinicia_con_el_contrato_y_no_con_la_prosa`, `HerramientasHablanStatusTests.test_el_presupuesto_ya_no_reinicia_con_prosa_porque_no_queda_ninguna_que_la_hable` |
| **M12** | se quita `merged_into` de `save_memory` | un guardado FUNDIDO lo dice | 1 | `SaveMemoryToolTests.test_save_merged_response_is_still_a_save_and_says_so` |
| **M13** | `list_available_shifts` vacío → `status: failed` | «no hay turnos» es un éxito sin nada que contar, no un fallo | 1 | `HerramientasHablanStatusTests.test_list_available_shifts_cuenta_los_turnos_y_el_vacio_no_es_un_fallo` |
| **M14** | la guarda de `save_memory` → `status: success` | una entidad basura no se pinta como guardada | 1 | `SaveMemoryToolTests.test_save_junk_entity_discarded_before_http` |

Una nota sobre **M10**, por si alguien repite la medida: el primer intento abortó por ancla no
única —`"conflicts": r.conflicts.map { ScheduleToolSupport.row($0) }` aparece **dos** veces en
`ScheduleTools.swift`, porque `create_event` tiene la misma línea— y el guion se negó a tocar
nada, que es para lo que está esa comprobación. Se repitió con el ancla de dos líneas
(`status` + `conflicts`), que sí es única, y murió.

Cómo se verificó la restauración, porque es el error que ya se cometió en este proyecto: cada
mutación guarda una copia con un nombre que lleva su id y el mío, comprueba su MD5 contra el
original **antes** de tocar nada, afirma que la mutación cambió el fichero, y al terminar restaura
y **vuelve a comprobar el MD5** con un `assert` que aborta el guion entero si no coincide. Las
catorce pasaron, y la suite se corrió una vez más al final sobre el árbol restaurado.


---

## Commits

| SHA | qué |
|---|---|
| `f68e55a` | **punto 2** — un error de argumentos ya no sale con tilde verde y un «listo» (`ToolJSONOutput` + `ToolLogRowTests`). |
| `99c6c87` | **puntos 1 y 3** — las ocho que contestaban en prosa hablan el contrato `status`, y con eso se quita el precio que el presupuesto pagaba (las ocho herramientas + `AtoZToolOutput` + la frase de `dry_run` en `ToolLogRow` + `Agent.reiniciaElPresupuesto` + las pruebas). |
| (el último) | este informe. Su propio SHA no se puede escribir aquí sin volver a cambiarlo. |

**Por qué los puntos 1 y 3 van juntos y no en dos commits.** Son un solo cambio de contrato leído
por los dos extremos: quitar el parche del reinicio **solo es correcto** si no queda ninguna
herramienta hablando prosa, y las pruebas que lo miden (`test_el_presupuesto_se_reinicia_con_el
_contrato_y_no_con_la_prosa` y `test_el_presupuesto_ya_no_reinicia_con_prosa_porque_no_queda
_ninguna_que_la_hable`) necesitan las ocho ya convertidas. Separarlos obligaría a inventar un
estado intermedio —las ocho convertidas con el parche todavía puesto— que ninguna ejecución de la
suite ha verificado. El punto 2 sí es independiente a nivel de fichero y va aparte; su coherencia
como estado propio está medida por la mutación M1, que al deshacerlo pone rojas exactamente las
dos pruebas que viajan en ese mismo commit.

**Sin push.**

