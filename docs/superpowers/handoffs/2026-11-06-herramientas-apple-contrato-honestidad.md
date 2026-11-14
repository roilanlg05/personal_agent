# Herramientas nativas de Apple: el contrato de honestidad

**Fecha:** 2026-11-06
**Repo:** `personal_agent`, rama `main`
**Alcance:** las herramientas que el agente Gemma expone al modelo — `Gemma/Gemma/NativeServices/` y `Gemma/Gemma/Memory/`
**Estado al cerrar:** 71 herramientas registradas, todas con contrato de `status`; app instalada y corriendo en el iPhone 18 Pro

---

## 1. El problema de fondo

Las herramientas de `NativeServices/` fueron generadas por Gemini y la mayoría estaban
roas de una forma concreta y peligrosa: **devolvían éxito cuando no habían hecho nada**.
No fallaban con un error; mentían con una respuesta aparentemente buena. El modelo las
creía y se lo contaba al usuario como un hecho.

Ejemplos reales que estaban en producción:

- `call_contact` devolvía `status: "calling"` cuando lo único que había pasado era que
  iOS abrió el marcador. El usuario oía «ya está llamando» y el teléfono no sonaba.
- `check_schedule` consultaba las rutinas con `try?`. Si el servicio de memoria fallaba,
  el error desaparecía y la respuesta era `"No conflicts."`. El modelo decía «tienes
  libre» cuando la verdad era «no pude comprobar tu horario».
- `load_messages` devolvía literalmente `"no messages found for chat X"` cuando se caía
  el servidor. El usuario oía que su historial no existía.
- `RoutineHelper.parseDays` devolvía lunes-a-viernes cuando no entendía los días. Decir
  «cuando pueda» guardaba en silencio una rutina de lunes a viernes que el usuario nunca
  pidió, y después generaba conflictos de agenda inventados.

## 2. El contrato

De ahí salió la regla central del proyecto, que ahora cumplen las 71 herramientas:

> **Toda herramienta devuelve un `status` que distingue el éxito verificado del éxito
> supuesto, y su `description` le dice al modelo explícitamente qué NO puede afirmar en
> cada estado.**

Reglas derivadas, todas nacidas de un defecto concreto:

1. **La salida siempre es JSON**, construido con `ToolJSONOutput.object`. Interpolar
   strings a mano producía JSON inválido en cuanto un título llevaba una comilla.
2. **«No pude saber» no es «no hay nada».** `memory_unavailable` ≠ `empty`;
   `permission_required` ≠ `not_found`.
3. **Nunca elegir a ciegas entre candidatos.** `ambiguous` + `candidates`, y no se toca
   nada.
4. **Nunca inventar un dato que falta.** `needs_time`, `needs_criteria`, `invalid_days`
   + `received` con lo que llegó, para poder diagnosticar.
5. **Un fallo parcial se reporta como parcial**, con `warnings`, y quien lo recibe tiene
   que propagarlo. Media comprobación no es una comprobación.
6. **Un recorte se declara.** `total` + `truncated`. Una lista presentada como completa
   que no lo es es una mentira silenciosa.
7. **El orden de las operaciones protege al usuario.** Se verifica contra el sistema
   antes de limpiar el estado local; se programa lo nuevo antes de borrar lo viejo. Así
   un fallo nunca deja al usuario sin alarma creyendo que la tiene.
8. **`ToolJSONOutput.object` solo quita los `nil` del primer nivel.** Las filas anidadas
   hay que limpiarlas una a una con `([...] as [String: Any?]).compactMapValues { $0 }`.

Nota de diseño importante: **el modelo que conduce a Gemma es Claude Haiku**, no el Gemma
local pequeño. Hay contexto de sobra. Las descripciones largas y explícitas del contrato
no son un coste a minimizar — son precisamente lo que el modelo sí sigue. Se descartó
agrupar herramientas hermanas para ahorrar tokens.

## 3. CRUD completo

Se auditaron las 71 herramientas contra las capacidades de los servicios y se encontró
que varias áreas solo tenían lectura y escritura. Lo que faltaba y se añadió:

| Área | Qué faltaba | Herramienta nueva |
|---|---|---|
| Alarmas y temporizadores | **no se podían cancelar en absoluto** | `cancel_alarm` |
| Alarmas | cambiar la hora obligaba a cancelar + crear, y si la creación falla el usuario se queda sin alarma | `update_alarm` |
| Recordatorios | solo `create`, y `create` tiraba el identificador de Apple, así que nada se podía tocar después | `list_reminders`, `update_reminder`, `delete_reminder` |
| Música | solo se podía empezar a sonar | `control_music` (pausa, reanudar, siguiente, anterior, estado) |
| Atajos | `ShortcutRegistry.forget` existía sin exponer | `forget_shortcut` |
| Apodos de contactos | `forgetAlias` y `learned` existían sin exponer | `list_contact_aliases`, `forget_contact_alias` |
| Tareas | no se podían editar; completar una la borraba | `update_task` |
| Rutinas | no se podían borrar, así que una rutina vieja generaba conflictos falsos para siempre | `delete_routine` |
| Lugares | renombrar creaba un duplicado en el mismo sitio | `rename_place` |

El cambio estructural que lo hizo posible en recordatorios fue `StoredReminder.appleID`:
guardar el identificador que devuelve EventKit. Sin él, un recordatorio creado por Gemma
era inmutable.

## 4. Defectos reales encontrados

Ordenados por lo que le hacían al usuario.

### Mentiras de «tienes libre»
- `check_schedule` y `create_event` tragaban el fallo del servicio de rutinas con `try?`.
  `create_event` **además agendaba**. Ahora `partial` / `created_with_warnings`, y nunca
  `free`.
- Se pedían 50 nodos sin filtrar por kind, que es menos que los recuerdos de cualquier
  usuario real: las rutinas viejas no se comprobaban nunca.

### Fallos vendidos como ausencia
- `load_messages`, `recall_by_topic`, `list_topics`, `why`: el `catch` devolvía la misma
  frase que «no hay nada».
- `search_memory` heredaba el degradado silencioso de `MemoryClient.recall`, que se traga
  los 5xx a propósito y devuelve un paquete vacío. Servidor caído = «no recuerdo nada de
  ti». Se añadió `recallStrict`, que propaga el fallo.
- `search_contacts` devolvía un error genérico cuando faltaba el permiso de Contactos, y
  el modelo lo contaba como «no tienes ningún contacto con ese nombre».

### Datos inventados
- `create_calendar_event` descartaba `hasTime` de `ISO8601Dates.parse`: una fecha sin
  hora se convertía en medianoche, y el fin también, produciendo **un evento de cero
  minutos a las 00:00** con respuesta `created`. Tampoco validaba `end > start`.
- `query_schedule` con `to <= from` sustituía en silencio el rango por `from + 86400` y
  enumeraba una ventana que nadie pidió.
- `draft_message` caía al tono amistoso ante cualquier tono que no entendiera. Pedir un
  mensaje formal para un abogado devolvía un saludo de colegas, y el modelo creía haber
  redactado algo formal.
- `remember_contact_alias` guardaba el apodo sin comprobar que el contacto existiera, y
  contestaba «ya puedes usar ese apodo para llamar o escribir». Con un nombre que no está
  en la libreta esa promesa no se cumple, y el usuario se entera la próxima vez que pide
  llamar.

### Días que no cuadraban
- `cancel_events` parseaba el `to` sin `endOfDayIfDateOnly`. «Cancela mis citas de hoy»
  construía una ventana 00:00–00:00 y cancelaba cero. `query_schedule` lo hacía bien: dos
  herramientas con dos definiciones distintas de «día».
- **`RoutineHelper.findRoutineConflicts` solo miraba el día de la semana de la fecha de
  inicio.** Un viaje de cinco días se comprobaba contra las rutinas del día 1 y los días
  2 al 5 no se miraban nunca. Es exactamente la clase de fallo que SP1 existe para
  evitar.
- La misma función inventaba duración: `endMins <= startMins → startMins + 60`. Dos
  víctimas: un evento que cruza medianoche (20:00 → 06:00) se recortaba a 20:00–21:00 y
  una rutina de las 22:00 quedaba invisible; y «llámame a las 10:00» ocupaba hasta las
  11:00, produciendo choques falsos.

### Recortes silenciosos
- `recall_by_topic` promete en su descripción devolver TODO lo que se recuerda de un tema
  y cortaba a 4000 caracteres sin decirlo. Igual `list_topics` (2000), `load_messages`
  (4000) y `search_memory` (`.prefix(4)` de turnos).

### Contrato roto
- `create_calendar_event` y `delete_calendar_event` devolvían los errores de argumentos
  por `ToolJSONOutput.error()`, o sea `{"error": ...}` **sin `status`**, contradiciendo
  sus propias descripciones.
- `why` confundía tres casos distintos: no encontré la creencia / la tengo pero sin
  fuentes / no pude mirar. Ahora `not_found` / `no_sources` / `failed`, y el mensaje de
  `no_sources` prohíbe explícitamente inventar una justificación.

## 5. Arreglos de diseño, no solo de contrato

**`RoutineHelper.dayWindows`** (nuevo). Reparte un evento en los tramos que ocupa de cada
día natural: el primer día desde su hora hasta medianoche, los de en medio completos, el
último desde medianoche hasta su hora. `findRoutineConflicts` recorre todos. Tope de 400
días: una rutina es semanal, así que con una semana ya se vieron los siete días y un
evento mal fechado de cinco años no hace iterar 1.800 veces.

El solape de un evento sin duración se comprueba como punto, no como hora inventada:
las 10:00 no choca con 10:30–11:00, pero las 10:45 sí.

El aviso ahora dice **qué día** choca («Choca el jueves 12 de noviembre»). Con un viaje de
cinco días saber que hay conflicto no sirve de nada: la decisión del usuario («muevo el
vuelo» o «pido el día libre») depende del día. Y una rutina que choca cuatro días del
viaje es un aviso, no cuatro.

**`scanRoutines`** pasó de una barrida de 500 nodos sin filtrar a tres consultas
filtradas por kind (`routine`, `fact`, `place`) lanzadas en paralelo con `async let`.
Consecuencia práctica: el aviso de `partial` solo salta cuando de verdad falta algo de
*ese* kind por mirar, no en cada llamada por el simple hecho de tener muchos recuerdos.
Un usuario con miles de recuerdos tiene un puñado de rutinas.

Hallazgo que ahorró trabajo en el server: **`GET /v1/nodes?kind=<kind>&limit=&offset=` ya
existe, está desplegado en el i3, filtra por kind exacto y devuelve el `total` real**
(`MemoryStore+List.swift:17-45`). `list_routines` ya lo usaba así. No hacía falta ningún
endpoint nuevo en `gemma-memory`.

**`tel:` en vez de `tel://`.** `tel:` es la forma canónica documentada por Apple;
`tel://` funcionaba solo por tolerancia.

**La línea que faltaba en el prompt** (`Agent.swift`): «`check_schedule` status 'partial'
is NOT free». Sin ella el modelo podía leer `partial` y contarlo como hueco libre, lo que
anulaba todo el trabajo de propagar avisos.

## 6. Lo que se verificó sobre llamadas automáticas

Pregunta del usuario: ¿puede `call_contact` marcar sola?

**No, y no hay forma documentada.** Desde iOS 10.3, abrir una URL `tel:` desde una app de
terceros muestra una alerta del sistema; `UIApplication.open` devuelve `true` cuando el
sistema acepta *mostrar esa alerta*, no cuando empieza la llamada. CallKit
(`CXStartCallAction`) es solo para VoIP, nunca para la red celular.

Queda una pregunta abierta que solo se puede responder a mano: **¿la acción «Llamar» de
la app Atajos marca sin pulsar?** No está documentado en ninguna parte. Prueba de 30
segundos: Atajos → nuevo atajo → acción «Llamar» → un contacto → ejecutarlo. Si marca
directo, hay camino viable vía Atajos (y encaja con la regla del proyecto: API directa
cuando se pueda, atajos cuando no). Si pregunta, el tema está cerrado.

## 7. Instalación en el dispositivo

El iPhone 18 Pro (`00008160-0009349A36C0000A`) aparecía como `unavailable` en
`devicectl` y no se podía instalar. Diagnóstico completo:

- `devicectl` solo instala en dispositivos que **CoreDevice ha descubierto**. Rechaza
  direcciones sueltas: ni el nombre de nodo de Tailscale (`iphone192`) ni su IP
  (`100.127.126.117`) resuelven a un dispositivo.
- El descubrimiento va por mDNS. **Tailscale no sirve**: es capa 3 y no lleva multicast,
  así que el anuncio `_remotepairing._tcp` nunca llega.
- Lo que sí funciona: **RoamRun** (`RoamRun.app`, corriendo en el Mac). Publica el
  registro `_remotepairing._tcp` del teléfono en el dominio local del Mac, como host
  `rr-<id>.roamrun.local:49152` sobre su propio túnel (`utun0`). CoreDevice lo resuelve,
  empareja, y monta su túnel propio (`utun9`, mtu 16000, `fdad:5ee4:9565::2`). El
  transporte se reporta como `localNetwork` porque para CoreDevice el descubrimiento fue
  de red local: RoamRun lo hace indistinguible.

**Consecuencia operativa: no hace falta cable ni estar en la Wi-Fi de casa.** Con RoamRun
levantado en el Mac y en el teléfono, la instalación funciona desde cualquier sitio. El
teléfono tarda unos 45 segundos en pasar de `unavailable` → `connecting` → `connected`.

Hay un script de espera en el scratchpad de la sesión que vigila el estado y lanza la
instalación en cuanto el dispositivo queda alcanzable. **Importante:** el estado hay que
leerlo de `properties.connection.state` del JSON de `devicectl list devices`. Parsear las
columnas de la tabla por posición da falsos positivos, y lanzar la instalación durante el
`connecting` falla con `CoreDeviceError 4016` («not able to fulfill the requested usage
assertion requirements»).

## 8. Cómo se trabajó

**TDD, y sirvió.** Cuatro defectos se encontraron porque una prueba falló por una razón
distinta de la esperada, no porque nadie los estuviera buscando: el rechazo al editar un
recordatorio ya pasado, el alias de fábrica que reaparece al olvidar el aprendido, la
fabricación de lunes-a-viernes en `parseDays`, y la mentira de `status: "calling"`.

**Una prueba existente que se rompe puede significar que la prueba estaba mal.** Pasó
tres veces. El caso claro: una prueba afirmaba `status == "calling"` — exactamente la
mentira que se estaba quitando. Se invirtió con un comentario explicando que la premisa
era falsa, en vez de borrarla.

**Delegación.** Las 11 herramientas sin ninguna prueba se encargaron a un subagente en un
worktree aislado. Dos aprendizajes:

1. Un worktree aislado parte del último commit, así que **no contiene el trabajo sin
  commitear** del checkout principal. El subagente se bloqueó al no encontrar los
  ficheros del encargo. Se resolvió con un commit de baseline en su worktree y
  **devolución por patch** (`git diff <baseline> <trabajo>`), no por copia de ficheros
  enteros: así los cambios se aplican aunque el árbol principal se haya movido mientras.
2. El subagente reportó como «decisión del dueño» que el servicio de memoria necesitaba
  un endpoint de rutinas. **Era falso**: el endpoint ya existía. Conviene verificar los
  bloqueos que reporta un subagente antes de encargar trabajo a partir de ellos.

## 9. Cifras

| | |
|---|---|
| Herramientas registradas | 71 |
| Con contrato de `status` | 71 |
| Pruebas al empezar la sesión | 587 |
| Pruebas al cerrar | ver nota |
| Fallos preexistentes ajenos | 4 |
| Compilación iOS | `BUILD SUCCEEDED` |
| Instalación en iPhone 18 Pro | hecha, `com.roilan.gemma` |

Los 4 fallos preexistentes que no se tocaron:
`ServerRuntimeStreamingTests.test_streaming_yields_incremental_tokens_then_completed`,
`ForgetToolTests.test_forget_calls_endpoint_and_returns_count`,
`AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`,
`ReminderCRUDToolTests.test_update_mueve_la_hora` (este último huele a dependencia del
reloj; falla también en un árbol limpio sin los cambios).

## 10. Lo que queda

**Decisiones del dueño:**

1. **`recall_by_topic` emite `unknown_topic` cuando el servidor devuelve `tag: ""`.**
   Verificado contra el código desplegado: el comentario del handler dice literalmente
   que `tag: ""` es el centinela de «no resuelto» (`MemoryHandlers.swift:235`). Correcto
   tal como está.
2. **Topes elegidos a ojo** por el subagente: 200 temas, 150 recuerdos, 200 mensajes, 60
   hechos, 20 resúmenes, 12 turnos. Como el modelo es Haiku, se pueden subir.
3. **`update_event`** sigue en prosa sin `status`. No estaba en el encargo.
4. **`SaveMemoryTool` y `ForgetTool`** siguen devolviendo `"memory unavailable"` en
   prosa. Fuera del encargo.
5. 🔐 **El token del servicio de memoria del i3 sigue siendo el placeholder**
   `replace-me-with-a-long-random-string`. Rotarlo en el compose/.env del i3 y en los
   Ajustes de la app.

**Sin verificar:**

- Nada se probó contra el i3 en vivo. Todo es stub HTTP (`StubURLProtocol`) y dobles
  (`StubCalendarManager`, `MockContactsManager`).
- EventKit real: las herramientas de calendario y recordatorios se probaron contra
  dobles, nunca contra el calendario del usuario.
- `share`, `open_app`, `open_navigation`, `play_music`, `install_shortcut` dependen de
  permisos y de apps instaladas. La app ya está en el teléfono: esto toca probarlo a
  mano.
- Dos pruebas llevan `XCTSkipIf` por la hora del reloj y se saltan a ciertas horas.

**Qué probar primero en el teléfono**, porque es donde el contrato tiene que verse:

1. Denegar el permiso de Contactos y preguntar por un contacto. Tiene que decir que no
   pudo mirar, no que no tienes a nadie.
2. «Mi jefe es Fulano Inexistente». Tiene que negarse a guardar el apodo y pedir el
   nombre exacto de la libreta.
3. Agendar algo del martes al sábado encima de una rutina de los jueves. Tiene que cazar
   el conflicto y nombrar el día.
4. «Llama a mi hermano». Abre el marcador y pide pulsar. Nunca debe decir que ya está
   llamando.

## 11. Convenciones confirmadas

- **Nunca `git add -A` en este repo.** Barre los snapshots de `graphify-out/<fecha>/`
  (uno de 2026-06-04 pesa 119 MB, por encima del límite de 100 MB de GitHub) y el push
  se rechaza. Rutas explícitas siempre.
- `Gemma.xcodeproj` usa `PBXFileSystemSynchronizedRootGroup`: los ficheros nuevos en
  `Gemma/Gemma/` o `Gemma/GemmaTests/` entran solos en el target. **No hay que editar el
  `.pbxproj`.**
- `xcodebuild` **no imprime el texto de las aserciones** en stdout. Para sacarlo:
  `xcrun xcresulttool get test-results tests --path <bundle> --format json` y recorrer
  `testNodes` buscando `nodeType == 'Failure Message'`.
- `ToolRegistry` se reconstruye **en cada turno** de conversación, así que cualquier
  almacén compartido tiene que ser `static let shared`. Una instancia por herramienta
  hace que lo que el usuario acaba de enseñar no exista para la herramienta siguiente.
- Texto de usuario y comentarios en español con acentos; identificadores en inglés;
  nombres de prueba descriptivos en español.
- Los diagnósticos de SourceKit sobre ficheros de los worktrees aislados están rancios y
  reportan tipos inexistentes. Verificar con `xcodebuild`, no con ellos.
