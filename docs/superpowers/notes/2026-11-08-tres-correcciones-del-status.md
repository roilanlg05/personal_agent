# Tres correcciones del `status` — rama del bucle de navegación

**Rama:** `diag/panel-se-muere`, sobre `ab648ca`.
**Encargo:** tres correcciones pequeñas sobre el trabajo que acaba de aterrizar
(`2026-11-08-las-herramientas-hablan-status.md`): dos comentarios que afirman algo falso, el
éxito de `create_event`/`cancel_events` que no reiniciaba el presupuesto de fallos, y
`get_current_time` pintando «listo» en vez de la hora.

**Pruebas:** base **4 rojos** → después **4 rojos**. Los cuatro son preexistentes y ajenos a esta
rama (`AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`,
`ContactAliasStoreTests` ×2, `ReminderCRUDToolTests.test_update_mueve_la_hora`).

**Lo que más importa de este informe** está en dos sitios: el **censo de estados de éxito
huérfanos** (abajo, **31 estados huérfanos, 22 de ellos éxitos**, sobre las 80 herramientas del
registro) y el **hallazgo que
cambió el arreglo del punto 2**: `cancelled` significa cosas opuestas en dos familias de
herramientas, así que meterlo en `Agent.estadosDeExito` habría hecho que **un mensaje que el
usuario descartó reiniciara el presupuesto de fallos del turno**.

---

## 1 — Los dos comentarios falsos (eran cuatro sitios)

El trabajo anterior justificó el estado `dry_run` diciendo que el modo simulado de A to Z viene
**activado** de fábrica. Es falso en los dos únicos sitios que fijan el valor por omisión:

| sitio | lo que dice el código |
|---|---|
| `Gemma/Gemma/AtoZ/AtoZConfig.swift:48` | `dryRun: d.object(forKey: AtoZSettingsKeys.dryRun) as? Bool ?? false` |
| `Gemma/Gemma/Settings/SettingsView.swift:102` | `@AppStorage(AtoZSettingsKeys.dryRun) private var atozDryRun = false` |

Los dos por omisión **`false`**: el modo simulado viene **DESACTIVADO**, es **opt-in**, y por
omisión los turnos **sí** se envían a Amazon. El estado `dry_run` se queda, y el valor por
omisión no se ha tocado — es una decisión de producto sobre una herramienta que actúa en la
cuenta de trabajo del usuario.

### El censo de la frase: la afirmación falsa estaba copiada en CUATRO sitios, no dos

El encargo nombraba dos y pedía buscar más. Hay dos más, y uno de ellos es **el origen de la
copia**:

| # | sitio | qué decía | qué dice ahora |
|---|---|---|---|
| 1 | `Gemma/Gemma/Harness/ToolLogRow.swift:136` | «El modo simulado viene ACTIVADO de fábrica (`AtoZConfig`), así que este es el camino NORMAL de una aceptación de turno» | «EL MODO SIMULADO ES OPT-IN: viene DESACTIVADO de fábrica —`AtoZSettings.load` lo lee como `?? false` y `SettingsView` lo declara `= false`—, así que el camino normal de una aceptación de turno es el REAL y la petición sí llega a Amazon. Este estado es el camino del usuario que ENCENDIÓ la simulación en Ajustes» |
| 2 | `Gemma/Gemma/AtoZ/AtoZToolOutput.swift:60` | «Es el camino NORMAL —`AtoZConfig` trae el modo simulado activado de fábrica—» | «El modo simulado es OPT-IN: viene DESACTIVADO de fábrica (…). Este es el camino del usuario que ENCENDIÓ la simulación, y entonces pintar «listo» sería mentirle sobre la herramienta que le coge turnos de trabajo» |
| 3 | **`Gemma/Gemma/AtoZ/AtoZConfig.swift:29`** (nuevo) | `/// Bool. When true (default) add_shift runs every gate but never sends the mutation.` — **el «(default)» es el origen de la copia: está pegado a la propia declaración de la clave, dos líneas encima de la línea que lee `?? false`** | «`When true, add_shift runs every gate but never sends the mutation. Default FALSE: the simulated mode is opt-in…`», con la nota de dónde se copió la afirmación falsa |
| 4 | **`Gemma/GemmaTests/HerramientasHablanStatusTests.swift:173`** (nuevo) | «`AtoZConfig` trae el modo simulado ACTIVADO por omisión, así que `.dryRun` es el camino normal» | la versión correcta, apuntando a la prueba nueva que clava la premisa |

Y un quinto, que no es código: el informe anterior
(`2026-11-08-las-herramientas-hablan-status.md:152`) repite la afirmación. No se reescribe un
informe fechado, así que lleva una **errata** encima del párrafo.

### La razón escrita de nuevo, que es la que importa

El estado se queda **no** porque la simulación sea el camino normal —no lo es— sino porque
**cuando el usuario la enciende, el único texto honesto es «no se hizo de verdad»**: la
herramienta le coge **turnos de trabajo**, y pintar «listo» sobre un turno que nunca se pidió a
Amazon es exactamente la queja del usuario.

### Un comentario no se puede ejecutar, así que se clava su premisa

`TresCorreccionesDelStatusTests.test_el_modo_simulado_de_a_to_z_viene_desactivado_de_fabrica`
afirma el valor por omisión sobre un `UserDefaults` limpio, que es de lo que los cuatro
comentarios dependen. Si alguien cambia el valor por omisión, la prueba se pone roja y los
comentarios se revisan. Lo prueba la mutación **M7**.

---

## 2 — El éxito de `create_event` y `cancel_events`

### El defecto, medido en el bucle

`Agent.estadosDeExito` era `["success", "no_content"]`, y las dos mutaciones de agenda declaraban
su éxito con un verbo: `created`, `created_with_warnings`, `cancelled`. Ninguno estaba en el
conjunto, así que **un evento creado correctamente no borraba la cuenta de fallos anteriores**:
cuatro fallos + el evento creado + un fallo mataban el turno, con la agenda del usuario ya
escrita, y el `browser_fill` del final no llegaba a correr. Es el mismo defecto que el trabajo
anterior quitó por la puerta de la prosa, entrando por la puerta del verbo.

Lo mide en el bucle `AgentTests.test_un_evento_creado_reinicia_el_presupuesto_como_cualquier
_otro_exito`, con el doble `FakeCreateEventDelContrato` (la forma REAL de `CreateEventTool`).

### 🔴 EL HALLAZGO QUE CAMBIÓ EL ARREGLO: `cancelled` está sobrecargado

El encargo daba dos caminos (los estados entran en `estadosDeExito`, o pasan a `success`) y pedía
mirar **qué lee cada estado antes de moverlo**. Mirándolo, los dos caminos **no valen para los
dos estados**, y la medida decide cada uno.

`Agent.estadosDeExito` se indexa por **nombre de estado**, no por herramienta —y eso es
deliberado: `esFallo`/`esExito` no miran el nombre de la herramienta, porque el presupuesto no es
una regla del navegador—. Y `cancelled` significa **cosas opuestas** en dos familias:

| herramienta | fichero:línea | qué significa `cancelled` |
|---|---|---|
| `cancel_events` | `Gemma/Gemma/Memory/ScheduleTools.swift:604` | se canceló lo que se pidió cancelar — **éxito** |
| `cancel_alarm` | `Gemma/Gemma/NativeServices/CancelAlarmTool.swift:109` y `:163` | la alarma se quitó de verdad — **éxito** |
| **`run_shortcut`** | `Gemma/Gemma/NativeServices/RunShortcutTool.swift:93` (vía `ShortcutRunOutcome.cancelled`) | **el USUARIO lo descartó desde la app Atajos y el atajo NO corrió** |
| **`send_message`** | `Gemma/Gemma/NativeServices/SendMessageTool.swift:115` (el mismo enum) | **el USUARIO lo descartó y el mensaje NO se envió** |

El repositorio lo tiene escrito en el **nombre** de sus pruebas:
`Gemma/GemmaTests/RunShortcutToolTests.swift:60`
→ `test_run_cancelled_isReportedAsCancelledNotSuccess`, y
`Gemma/GemmaTests/SendMessageToolTests.swift:174` → `test_cancelled_isNotReportedAsSent`.

**Lo que habría pasado si hubiera metido `cancelled` en el conjunto:** un mensaje que el usuario
descartó habría **reiniciado el presupuesto de fallos**, o sea que un modelo alternando fallo y
envío descartado nunca agotaría el turno — justo el freno que el presupuesto es. Y **las dos
pruebas de arriba habrían seguido verdes**, porque afirman la cadena del estado y no el
presupuesto: el agujero no se vería. Es el patrón de la prueba vacua que el encargo avisaba.

### Lo que se hizo, con la razón de cada mitad

| estado | camino | por qué ese |
|---|---|---|
| `created` | **entra en `estadosDeExito`** | lo emiten **seis** herramientas (`create_event`, `create_calendar_event`, `create_alarm`, `create_note`, `create_reminder`, `add_task`) y las seis con el **mismo** significado: lo que se pidió crear quedó creado. Ampliar el conjunto arregla a las seis de una vez. Y está leído por el modelo en la descripción («Lee 'status': 'created' = creado y comprobado, ya se lo puedes confirmar») y afirmado literalmente en una decena de pruebas (`ScheduleToolsContractTests`, `DateParsingTests`, `PendingDefectsTests`, `HybridReminderTests`, `ToolJSONEscapingTests`, `NotesServiceTests`). |
| `created_with_warnings` | **entra en `estadosDeExito`** | es la OTRA rama de éxito de `create_event`: el evento **se creó**, lo que quedó a medias es la comprobación de choques. Dejarla fuera arreglaría el defecto solo cuando la comprobación de rutinas funciona. Y **no se puede fundir con `created`**: su descripción le dice al modelo «mira 'warnings' … nunca [digas] que no choca con nada», que es justo la pieza que le impide afirmar que la agenda está limpia. |
| `cancelled` | **NO entra; `cancel_events` pasa a declarar `success`** | el nombre es ambiguo (tabla de arriba). Se retira de la herramienta de agenda en vez de enseñárselo al conjunto. No se pierde nada: `cancelled_count` ya dice cuántos, y el cero sigue siendo `nothing_to_cancel`. Se reescribió la descripción (que ahora enseña `'success'`) y se re-apuntaron las dos pruebas que la afirmaban. |
| `nothing_to_cancel` | **sigue fuera de los dos conjuntos** | «contesté, y no había nada que hacer» es el tercer estado, la misma categoría que `not_found`, que `estadosDeFallo` deja fuera a propósito. Ante la duda, fuera: es la dirección segura escrita en ese conjunto. |

`cancel_alarm` sigue emitiendo `cancelled` y por tanto su éxito sigue sin reiniciar el
presupuesto. Es preexistente, está en el censo de abajo y **no se tocó**: no es de este encargo,
y arreglarlo pide la misma decisión por herramienta que `cancel_events` acaba de tomar.

### Las pruebas del lado viejo, repasadas por «¿esto se cumple con mi cambio deshecho?»

| prueba | qué pasaba | decisión |
|---|---|---|
| `ScheduleToolsContractTests.test_cancel_events_toma_una_fecha_suelta_como_el_dia_entero:263` | se puso **ROJA**: afirmaba `status == "cancelled"` | **Re-apuntada** a `success` y **reforzada** con `Agent.reiniciaElPresupuesto(resultado: out)`, que es la propiedad nueva. Su propiedad original (una fecha suelta como fin es el final del día) sigue intacta. |
| `ScheduleToolsContractTests.test_cancel_events_distingue_que_no_habia_nada_que_cancelar:273` | se quedó **VERDE pero VACUA**: su `XCTAssertNotEqual(status, "cancelled")` lo cumple sola desde que ninguna rama emite `cancelled` | **Re-apuntada** a `!= "success"` y reforzada con `XCTAssertFalse(Agent.reiniciaElPresupuesto(...))`: lo que protege es que cancelar cero eventos no se cuente como haber cancelado, y ahora lo mide por donde de verdad cambia. |
| `RunShortcutToolTests.test_run_cancelled_isReportedAsCancelledNotSuccess` · `SendMessageToolTests.test_cancelled_isNotReportedAsSent` | **habrían sido las vacuas del camino que NO se tomó** | Intactas. Quedan citadas en el comentario de `estadosDeExito` para que el nombre ambiguo no vuelva a entrar, y la propiedad que ellas no pueden ver la afirma ahora `TresCorreccionesDelStatusTests` (`cancelled` no reinicia el presupuesto). |
| `AgentTests.test_los_estados_de_fallo_y_de_exito_son_el_contrato_real_y_son_disjuntos` · `test_lo_que_gasta_presupuesto_sale_con_cruz_roja_en_el_chat` | verdes y **no** vacuas | Intactas. Recorren `estadosDeExito` desde producción, así que son las que habrían cazado una ampliación que rompiera la disyunción con `estadosDeFallo` o que metiera un estado que la fila pinta en rojo. Los dos invariantes se vuelven a afirmar en la prueba nueva, mitad (d). |

---

## 3 — La hora se ve

`get_current_time` ya hablaba `status` (lo arregló el trabajo anterior: antes devolvía la fecha a
pelo y la fila la pintaba con **cruz roja**), pero `ToolLogRow.table` no tenía entrada para ella,
así que caía en `case nil` y se resumía «listo». El usuario preguntaba qué hora es y leía
«listo».

Añadida por el camino que ya usa el fichero: un `Kind` nuevo, `.localTime`, y la entrada
`"get_current_time": .localTime`. Pinta `local_time` —el dato, formateado por `DateFormatter`
con el idioma y el formato del sistema— y **nunca** el `message` («Ahora son las …»), que está
escrito para el modelo. Sin el dato se cae a `.ok`, que dice menos pero no inventa ninguna hora.

La regla que decide quién entra en esa tabla está ahora escrita encima de ella, porque la tabla
ya costó una rama en este proyecto: **entra el dato que el usuario pidió y sobre cuyo significado
no cabe duda; no entra ningún texto redactado para el modelo.** Lo clava la mutación **M6**, que
hace que la fila lea `message` en vez de `local_time` y muere.

### Las que siguen escondiendo su respuesta detrás de «listo» — NO ARREGLADAS, como pidió el encargo

Censo hecho con un guion sobre **las 80 herramientas** que conforman `AgentTool`: para cada una
se aísla el cuerpo de su `func run(argsJSON:)` por emparejamiento de llaves, se leen las claves
que devuelve y se cruza con las seis entradas de `ToolLogRow.table`. `ToolLogRow.table` cubre
hoy: `browser_open`, `browser_snapshot`, `browser_get`, `read_webpage`, `web_search` y —desde
este cambio— `get_current_time`.

**A) El valor devuelto ES la respuesta que el usuario pidió, y la fila dice «listo»:**

| herramienta | el dato que se esconde | la pregunta del usuario |
|---|---|---|
| `get_weather` | `temperature_celsius` (+`location`) | «¿qué temperatura hace?» |
| `get_forecast` | `min_temperature_celsius` / `max_temperature_celsius` | «¿va a llover esta tarde?» |
| **`get_device_status`** | `battery_percent` | «¿cuánta batería me queda?» — **y además es la única del registro cuyo `run` no emite NINGÚN `status`**: ver el aviso de abajo |
| `get_current_activity` | `activity` | «¿estoy conduciendo?» |
| `get_current_location` | `place` / `city` / `address` | «¿dónde estoy?» |
| `control_music` (`command=status`) | `title` + `artist` | «¿qué está sonando?» |
| `play_music` | `now_playing` + `artist` | — (es mutación, pero el dato es lo que el usuario quería oír) |
| `read_note` | `title` (el `content` es largo; el título es el dato de un vistazo) | «léeme la nota de X» |
| `check_schedule` | **el propio estado**: `free` / `partial` | «¿estoy libre a las 3?» → «listo», cuando la respuesta es «libre» |
| `open_navigation` | `place` | — |

**B) La respuesta es un recuento, y `ToolLogRow` ya tiene el `Kind` para eso (`.count`), usado
hoy solo por `web_search`:** `get_calendar_events`, `query_schedule`, `search_contacts`,
`search_notes`, `list_places`, `list_shortcuts`, `list_installable_shortcuts`,
`list_music_playlists`, `list_topics`, `recall_by_topic`, `why`, `load_messages` (todas con clave
`count`), y `list_tasks` / `list_reminders` / `list_alarms` con el recuento bajo otro nombre
(`pending_count`, `done_count`).

**Ninguna se ha tocado.** El encargo pedía la lista, no el arreglo. El grupo B es un cambio de
una línea por herramienta y casi mecánico; el grupo A pide decidir, herramienta por herramienta,
qué clave es «el dato» y comprobar que no es texto para el modelo (`summary` de `get_weather` y
`get_forecast`, por ejemplo, está documentado como «una frase lista para decir», o sea redactado
para el modelo: **no** puede ser lo que se pinte).

### ⚠️ Aviso suelto que salió del censo: `get_device_status` no declara `status`

`Gemma/Gemma/NativeServices/GetDeviceStatusTool.swift:22` devuelve `device`,
`battery_level_known`, `battery_percent`, `is_charging`, `is_low_power_mode`,
`low_battery_warning` y `summary` — **y ningún `status`**. Consecuencias, las dos del mismo
defecto que esta rama persigue: la fila cae en `case nil` y dice «listo» (no es mentira, pero
esconde el dato), y su éxito **nunca reinicia el presupuesto de fallos**, porque
`reiniciaElPresupuesto` exige un `status` de `estadosDeExito`. Es la única de las 80 en ese
estado; las otras cuatro que el guion marcó sin `status` literal son falsos positivos (las tres
de A to Z pasan por `AtoZToolOutput` y `play_music` lo construye desde
`MusicPlaybackOutcome.rawValue`). **No se ha tocado**: no es de este encargo.

---

## EL CENSO DE ESTADOS DE ÉXITO HUÉRFANOS

Lo que el encargo llamó «lo más valioso». Hecho con el mismo guion
(`censo_estados_opus5.py`, en el scratchpad) sobre **las 80 herramientas** del registro, no sobre
una lista heredada: recorre cada declaración que conforma `AgentTool`, aísla el cuerpo de su
`run` por emparejamiento de llaves, y extrae los `status` que emite —incluidos los que salen de
un **ternario**, que un grep ingenuo parte por la mitad y por los que se perderían `navigating`,
`navigating_search`, `opened`, `nothing_to_cancel` y `created_with_warnings`—. Luego cruza cada
estado con los **cuatro** conjuntos que lo leen:

- `Agent.estadosDeExito` — reinicia el presupuesto de fallos;
- `Agent.estadosDeFallo` — lo gasta;
- `ToolLogRow.failureStatuses` (+ el prefijo `invalid_`) — cruz roja en la fila;
- `ToolLogRow.needsYouStatuses` — icono «te pide algo».

**Lo que no está en ninguno es el TERCER ESTADO: ni gasta, ni reinicia, ni se pinta en rojo.** Y
ahí viven los éxitos huérfanos. Son **31 estados huérfanos**, repartidos por **51 herramientas**,
y **22 de los 31 son éxitos de pleno derecho**.

Se midió **dos veces por dos caminos distintos**, porque un solo guion no es una medida:
(1) el recorrido por cuerpo de `run` de arriba, y (2) un grep plano de todos los `"status": "…"`
del árbol, incluidos los ternarios, cruzado con los mismos cuatro conjuntos. Los dos coinciden
salvo en dos entradas, y las dos discrepancias se resolvieron a mano:

- **`install_presented`** (`ShortcutInstallTool.swift:147`) lo ve el grep plano y **no** el
  recorrido por `run`: el emparejamiento de llaves de ese cuerpo se corta antes, porque la
  descripción de la herramienta lleva llaves dentro de una cadena. Es real y está en el censo.
  Anotado para quien repita la medida: **el recorrido por `run` puede quedarse corto; el grep
  plano puede sobrar. Hay que correr los dos.**
- **`pending`** lo ven los dos y es un **FALSO POSITIVO**: no es el `status` de ninguna
  herramienta. `TaskTools.swift:99` y `ReminderService.swift:397` lo escriben dentro del `extra`
  de un NODO de memoria (`extra: #"{"status":"pending"}"#`), que es otro contrato. Fuera del
  censo.

### Éxitos de pleno derecho que NO reinician el presupuesto (22 estados)

| estado | herramientas | lectura |
|---|---|---|
| `ok` | `get_calendar_events`, `get_current_activity`, `get_forecast`, `get_weather`, `list_alarms`, `list_contact_aliases`, `list_installable_shortcuts`, `list_music_playlists`, `list_places`, `list_reminders`, `list_routines`, `list_shortcuts`, `list_tasks`, `list_topics`, `load_messages`, `query_schedule`, `read_note`, `recall_by_topic`, `search_memory`, `search_notes`, `why` (**21**) | el más gordo del censo. `ToolLogRowTests.test_el_estado_ok_no_es_un_fallo` ya declara que no es un fallo; nadie declaró que sea un éxito |
| `deleted` | `delete_calendar_event`, `delete_note`, `delete_place`, `delete_reminder`, `delete_routine`, `delete_task` (**6**) | seis MUTACIONES que borran de verdad y no cuentan como acierto |
| `updated` | `save_place`, `update_alarm`, `update_calendar_event`, `update_note`, `update_reminder`, `update_task` (**6**) | ídem, seis mutaciones |
| `cancelled` | `cancel_alarm` (**1**; `cancel_events` salió de aquí en este cambio) | **ambiguo: ver el hallazgo del punto 2.** No se puede meter por nombre |
| `remembered` | `remember_contact_alias`, `remember_shortcut` | |
| `forgotten` | `forget_contact_alias`, `forget_shortcut` | |
| `saved` | `save_place`, `set_routine` | |
| `found` | `search_contacts` | |
| `renamed` | `rename_place` | |
| `shared` | `share` | |
| `started` | `create_timer` | |
| `drafted` | `draft_message` | el borrador se escribió |
| `opened` | `open_app` | |
| `done` | `control_music` | la orden se dio y el reproductor obedeció |
| `playing` | `control_music` | |
| `navigating`, `navigating_search` | `open_navigation` (**2**) | los construye un ternario: un grep ingenuo no los ve |
| `certain` | `get_current_location` | se supo dónde está, y con un lugar guardado |
| `free` | `check_schedule` | el hueco está libre: la consulta funcionó |
| `no_results` | `web_search` | «funcionó y no hay nada»: es un `no_content` con otro nombre |
| `empty` | `list_alarms`, `list_contact_aliases`, `list_reminders`, `list_routines`, `list_tasks`, `list_topics`, `load_messages`, `query_schedule`, `recall_by_topic`, `search_memory` (**10**) | ídem: la lista está vacía, la consulta funcionó |
| `no_sources` | `why` | ídem |

Y los que **NO** son éxitos y por tanto están bien fuera, anotados para que el siguiente no los
meta de arrastre: `nothing_to_cancel` (`cancel_events`), `nothing_to_change` (`update_alarm`,
`update_reminder`, `update_task`), `unchanged` (`rename_place`), `was_not_scheduled`
(`cancel_alarm`), `not_playing` (`control_music`), `partial` (`check_schedule`, `cancel_alarm`),
`remembered_unverified` y `remembered_ambiguous` (`remember_contact_alias`),
`install_presented` (`install_shortcut`: se abrió la ficha y el atajo **NO** quedó instalado).
Son **9 estados**, todos «contesté, y la respuesta es que no» o «a medias», que es la categoría
que el proyecto deja fuera a propósito. (`calling`, de `make_phone_call`, no cuenta: hoy solo
existe dentro de un comentario que explica por qué se retiró.)

### Y tres huérfanos que son FALLOS o avisos y no salen con cruz roja

**Estos tres NO los ve ninguno de los dos censos automáticos**, y por eso quedan aparte: no son
literales. `play_music` construye su `status` desde `result.outcome.rawValue`
(`PlayMusicTool.swift:53`), o sea desde `MusicPlaybackOutcome`
(`MusicService.swift:124`). Se encontraron leyendo a mano las cinco herramientas que el guion
marcó «sin `status` literal en `run`»:

- **`app_unavailable`** — `MusicPlaybackOutcome.appUnavailable`. `ToolLogRow.failureStatuses`
  tiene `not_available`, **no** `app_unavailable`, así que «la app de música no está instalada»
  sale con **tilde verde y «listo»** y además no gasta presupuesto.
- **`search_opened`** y **`launching`** — la descripción de la propia herramienta le dice al
  modelo «no afirmes que la música suena si es 'search_opened'», y la fila del usuario dice
  «listo» en los dos casos.

Y por el mismo camino, un éxito huérfano más que los censos de literales no ven:
**`ok`** desde `ShortcutRunOutcome.ok` (`ShortcutRunner.swift:6`), emitido por `run_shortcut`
(`RunShortcutTool.swift:93`) y `send_message` (`SendMessageTool.swift:115`) — el atajo corrió o
el mensaje se envió, y no reinicia el presupuesto.

**No se ha tocado nada de esto**: no es de este encargo. Quedan dichos porque son exactamente la
mentira que esta serie de arreglos persigue, y el censo los encontró de paso.

### Cómo se repite el censo

`python3 -I censo_estados_opus5.py` (en el scratchpad de la sesión). Lee los cuatro conjuntos
**del fuente**, no de una copia, así que no caduca cuando alguien los cambia. Y las tres
limitaciones medidas, para que el siguiente no se fíe de un número: el recorrido por cuerpo de
`run` **se queda corto** cuando una descripción lleva llaves dentro de una cadena
(`install_presented`); el grep plano **sobra** cuando un `"status"` pertenece a otro contrato
(`pending`, que es el `extra` de un nodo de memoria); y **ninguno de los dos** ve los estados
que se construyen desde el `rawValue` de un enum (`play_music`, `run_shortcut`, `send_message`),
que hay que leer a mano partiendo de las herramientas sin `status` literal.

---

## Tabla de mutaciones

Una por propiedad afirmada, **suite ENTERA en cada una**. El guion
(`mutaciones_tres_correcciones_opus5.py`, con nombre único porque el scratchpad está compartido)
exige que el ancla aparezca **exactamente una vez** en el fichero antes de tocar nada, guarda una
copia con nombre único, comprueba su MD5 contra el original, afirma que la mutación cambió el
fichero, y al terminar restaura y **vuelve a comprobar el MD5** con un `assert` que aborta el
guion si no coincide. «Rojos nuevos» = rojos de esa ejecución menos los **4 de la base**.

**Siete mutaciones. Las siete compilaron, corrieron y murieron. Ninguna sobrevivió.**

| id | mutación | propiedad | rojos nuevos | pruebas que la matan |
|---|---|---|---|---|
| **M1** | se quita `"created"` de `Agent.estadosDeExito` | un evento creado reinicia el presupuesto **(punto 2)** | 2 | `AgentTests.test_un_evento_creado_reinicia_el_presupuesto_como_cualquier_otro_exito`, `TresCorreccionesDelStatusTests.test_los_exitos_de_create_event_y_cancel_events_reinician_el_presupuesto` |
| **M2** | se quita `"created_with_warnings"` de `Agent.estadosDeExito` | la rama de aviso de `create_event` también reinicia: el evento SÍ se creó | 2 | las mismas dos |
| **M3** | `cancel_events` vuelve a `status: "cancelled"` | el éxito de `cancel_events` se declara con un estado que el bucle reconoce | 2 | `ScheduleToolsContractTests.test_cancel_events_toma_una_fecha_suelta_como_el_dia_entero`, `TresCorreccionesDelStatusTests.test_los_exitos_…` |
| **M4** | se AÑADE `"cancelled"` a `Agent.estadosDeExito` | **`cancelled` no es un éxito**: en `run_shortcut` y `send_message` significa que el usuario lo descartó | 2 | `AgentTests.test_un_evento_creado_…`, `TresCorreccionesDelStatusTests.test_los_exitos_…` |
| **M5** | se quita la entrada `"get_current_time": .localTime` de `ToolLogRow.table` | la hora se ve en la fila **(punto 3)** | 1 | `TresCorreccionesDelStatusTests.test_la_hora_se_ve_en_la_fila_y_no_un_listo` |
| **M6** | `.localTime` lee `obj["message"]` en vez de `obj["local_time"]` | la fila pinta el DATO y **no** el texto escrito para el modelo | 1 | ídem |
| **M7** | `AtoZSettings.load` vuelve a `?? true` para `dryRun` | el modo simulado viene DESACTIVADO de fábrica **(la premisa del punto 1)** | 1 | `TresCorreccionesDelStatusTests.test_el_modo_simulado_de_a_to_z_viene_desactivado_de_fabrica` |

**M1 y M2 comparten el ancla** (`        "created", "created_with_warnings",`, única en
`Agent.swift`) y la mutan de dos formas distintas: cada una deja el otro estado en su sitio, así
que la que muere es la del estado quitado y no «el par». Ninguna ancla abortó por no ser única,
y la lección del agente anterior se tuvo en cuenta: las líneas de `create_event` se parecen a
las de sus hermanas, así que ninguna mutación de este lote usa una línea del cuerpo de
`create_event`.

Las siete restauraciones verificadas por MD5 (`a298ff2f…` para `Agent.swift`, `352231f1…` para
`ScheduleTools.swift`, `2a013bbe…` para `ToolLogRow.swift`, `0e0af925…` para `AtoZConfig.swift`),
y la suite se corrió una vez más al final sobre el árbol restaurado: **4 rojos**, los de la base.

---

## Pruebas nuevas

`Gemma/GemmaTests/TresCorreccionesDelStatusTests.swift` (tres):

- `test_el_modo_simulado_de_a_to_z_viene_desactivado_de_fabrica` — la premisa de los cuatro
  comentarios, más la mitad que justifica que `dry_run` se quede.
- `test_los_exitos_de_create_event_y_cancel_events_reinician_el_presupuesto` — cuatro mitades:
  (a) la función pura, con el guardia de que `cancelled` sigue **fuera**; (b) las dos
  herramientas de verdad por su camino bueno, incluida la rama `created_with_warnings`; (c) lo
  que sigue fuera (`nothing_to_cancel`); (d) los dos invariantes del conjunto tras la ampliación.
- `test_la_hora_se_ve_en_la_fila_y_no_un_listo` — la hora se pinta, el `message` no, y sin el
  dato se cae a «listo» sin inventar ninguna hora.

`Gemma/GemmaTests/AgentTests.swift`:
`test_un_evento_creado_reinicia_el_presupuesto_como_cualquier_otro_exito`, con el doble nuevo
`FakeCreateEventDelContrato`. Mide el defecto **en el bucle** —la ronda que moría— y no solo en
la función pura.

## Lo que NO se tocó

El encargo lo enumeraba y se respetó entero: `cortaLaCola`, `urlDemostrada`, `esFallo`,
`maxConsecutiveFailures`, `pareceAtascado`, `recortaElHistorial`, `browserGuideFits`,
`executedMutations`, `activeTools = []`, `BrowserCloseIntent` y `BrowserCloseTool`. La única
excepción autorizada era `estadosDeExito`, y es lo único del bucle que cambió. `urlDemostrada`
merece una nota: exige el literal `"success"` y **no** `esExito`, así que ampliar el conjunto no
le ha cambiado nada — lo dice su propio comentario, y sigue siendo cierto.

Tampoco se cambió el valor por omisión de `dryRun`, como pedía el encargo.

**Sin push.**
