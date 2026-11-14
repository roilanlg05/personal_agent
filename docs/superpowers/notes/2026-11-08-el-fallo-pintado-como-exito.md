# El fallo pintado como éxito — `play_music` y `get_device_status`

**Rama:** `diag/panel-se-muere`, sobre `a1c487d`.
**Encargo:** las dos mentiras de la peor clase que destapó el censo de las ochenta herramientas
(`2026-11-08-tres-correcciones-del-status.md`): el `app_unavailable` de `play_music` saliendo con
tilde verde, y `get_device_status` sin declarar ningún `status`.

**Pruebas:** base **4 rojos** → después **4 rojos**. Los cuatro son preexistentes y ajenos a esta
rama (`AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`,
`ContactAliasStoreTests` ×2, `ReminderCRUDToolTests.test_update_mueve_la_hora`).

**Lo que más importa de este informe** es la sección de **los estados de `play_music` leídos a
mano**: son estados que **ningún censo automático de literales puede ver**, y el censo completo
del enum —los seis que la herramienta puede emitir, con cuál leía cada conjunto y cuál no— no
estaba escrito en ningún sitio hasta ahora.

De las dos direcciones en las que la fila del chat puede mentir, las dos correcciones de hoy son
de la **peor**: un fallo (o un «a medias») con **tilde verde**. Esa es la que le hace creer al
usuario que algo pasó, y es su queja número uno.

---

## EL CENSO DE `play_music`, LEÍDO A MANO — lo que ningún censo automático ve

`PlayMusicTool.swift:53` no escribe su estado como literal:

```swift
"status": result.outcome.rawValue,
```

Sale del `rawValue` de `MusicPlaybackOutcome` (`MusicService.swift:124-135`). Por eso **las tres
medidas que se han usado en esta rama se quedan ciegas aquí**, y el agente anterior lo dejó
medido: el recorrido por el cuerpo de `run` no ve el estado (no hay literal), el grep plano de
`"status": "…"` tampoco (no hay literal), y la tercera —el grep ancho que sí pilla los estados
construidos en código, el documentado encima de `ToolLogRow.failureStatuses`— falla por otro
motivo: busca `(status|"status")[ :=]+"[a-z_]+"`, o sea un estado **entre comillas**, y aquí el
valor es una expresión.

Así que se leyó el enum a mano. **Son cinco casos, más el `error` de la guarda de argumentos: seis
estados en total.** La tabla es el inventario completo de lo que `play_music` puede devolver hoy,
con lo que cada conjunto decía de él ANTES de este cambio:

| estado | de dónde sale | qué significa | fila ANTES | presupuesto ANTES | qué se hizo |
|---|---|---|---|---|---|
| `error` | `ToolJSONOutput.error` (guarda: falta `query`) | la llamada venía mal | **cruz roja** ✓ | gasta ✓ | nada: ya era correcto |
| `failed` | `MusicPlaybackOutcome.failed` | la consulta no valía o la apertura falló | **cruz roja** ✓ | gasta ✓ | nada: ya era correcto |
| `app_unavailable` | `MusicPlaybackOutcome.appUnavailable` | la app de música **no está instalada** | 🔴 **«listo» + tilde verde** | ni gasta ni reinicia | **ARREGLADO**: entra en `failureStatuses` con frase propia |
| `search_opened` | `MusicPlaybackOutcome.searchOpened` | solo se abrió el **buscador**: el usuario tiene que elegir y **nada suena** | 🔴 **«listo»** | ni gasta ni reinicia | **ARREGLADO**: frase «se abrió el buscador: no está sonando» |
| `launching` | `MusicPlaybackOutcome.launching` | la app aceptó el enlace y **no se pudo verificar** que suene | 🔴 **«listo»** | ni gasta ni reinicia | **ARREGLADO**: frase «se abrió en la app: no está sonando aún» |
| `playing` | `MusicPlaybackOutcome.playing` | reproducción **verificada** leyendo el estado del reproductor | «listo» | ni gasta ni **reinicia** | **NO SE TOCA**: ver abajo |

**El hallazgo que el encargo no nombraba y la lectura a mano sí da:** el único de los cinco que el
encargo no mencionaba, `playing`, **sí** es un defecto, pero **del otro censo**: es un éxito de
pleno derecho que **no reinicia el presupuesto de fallos**, o sea uno de los veintidós éxitos
huérfanos que este encargo prohíbe tocar explícitamente. Está en la lista del informe anterior
atribuido a `control_music` —que lo emite como literal (`MusicPlaybackControl.swift:284`)—, y la
lectura a mano añade que **`play_music` lo emite también**, por el enum. No se ha tocado, y la
razón es la misma que el encargo da: `playing` necesita una decisión por par (herramienta,
estado), no por nombre.

### Y la frontera que hubo que medir antes de tocar nada

`play_music` **no** es la única herramienta que construye su `status` desde el `rawValue` de un
enum: `RunShortcutTool.swift:93` y `SendMessageTool.swift:115` hacen lo mismo con
**`ShortcutRunOutcome`**, que es otro enum. Si los tres estados nuevos estuvieran también ahí,
una tabla por nombre de estado los habría pintado mal en dos herramientas más. Medido:

| enum | casos | solapa con los tres de hoy |
|---|---|---|
| `MusicPlaybackOutcome` (`MusicService.swift:124`) | `playing`, `launching`, `search_opened`, `app_unavailable`, `failed` | — |
| `ShortcutRunOutcome` (`ShortcutRunner.swift:4`) | `ok`, `cancelled`, `failed`, `timeout`, `not_available` | **ninguno** |
| `control_music` (literales, `MusicPlaybackControl.swift`) | `playing`, `done`, `not_playing`, `failed`, `unsupported`, `invalid_action` | **ninguno** |

`grep -rn "appUnavailable\|app_unavailable\|searchOpened\|search_opened\|launching"` sobre todo el
árbol confirma que los tres son **exclusivos de `play_music`**. Eso es lo que permite que la frase
de `app_unavailable` **nombre la app de música**, al contrario que `not_available` —que lo emiten
doce herramientas y por eso dice solo «no está disponible», como su propio comentario explica—.

---

## 1 — `app_unavailable` es un fallo y sale con cruz roja

`ToolLogRow.failureStatuses` tenía `not_available` y **no** `app_unavailable`. Son dos estados
distintos, de dos familias distintas y de herramientas distintas, y la similitud del nombre es
justo por lo que se colaba: «la app de música no está instalada» caía en `case nil` y la fila
decía **«listo» con tilde verde**. Nada sonó y el usuario leía que sí.

| sitio | cambio |
|---|---|
| `Gemma/Gemma/Harness/ToolLogRow.swift` (`failureStatuses`) | entra `"app_unavailable"`, con el comentario de por qué ningún censo de literales lo veía |
| `Gemma/Gemma/Harness/ToolLogRow.swift` (`frasesDeFallo`) | `"app_unavailable": "la app de música no está instalada"` |

**Por qué la frase nombra la app y no dice «no está disponible»:** porque se puede. El estado es
exclusivo de `play_music` (medido arriba), así que no se miente en ninguna otra herramienta; y lo
que el usuario necesita saber es que **le falta la app**, porque eso es lo único que él puede
arreglar. «No está disponible» sería cierto e inútil.

**Lo que NO se tocó, y es una decisión, no un olvido:** `app_unavailable` **no** entra en
`Agent.estadosDeFallo` —el conjunto estrecho, el que gasta presupuesto y puede **matar el
turno**—. El encargo autorizaba `failureStatuses` y `estadosDeExito`, no ese. Encaja en el
criterio escrito de ese conjunto («no pude, y repetirlo no lo va a arreglar»: reintentarlo no
instala la app, exactamente como `not_available`), así que **queda anotado como candidato**, pero
ese conjunto es el que decide una muerte y se amplía con su propia autorización.

---

## 2 — «Se abrió, pero no está sonando»: el tercer texto de la fila

`search_opened` y `launching` decían **«listo»**. Y la descripción de la propia herramienta se lo
dice al modelo con estas palabras (`PlayMusicTool.swift:15`):

> `Informa al usuario exactamente lo que dice 'status': no afirmes que la música suena si es 'search_opened'.`

O sea: **el modelo estaba advertido y el usuario no.** Es el defecto en su forma más clara, porque
la prohibición ya estaba escrita en el repositorio, solo que en el sitio al que el usuario no
mira.

**No son un fallo.** La herramienta hizo lo que podía: `search_opened` abrió el buscador de la app
con el término dentro (el usuario tiene que elegir), y `launching` abrió el recurso y **no pudo
verificar** la reproducción (en macOS hay verificación por Apple Events y entonces el estado es
`playing`; en iOS no existe equivalente). Pintarlos en rojo le diría que algo se rompió. Y «listo»
afirma que la cosa ocurrió, y no ocurrió. Hace falta el **tercer texto**.

La fila ya tenía ese hueco abierto para un caso: `cierreRechazadoText`, el candado de
`browser_close` + `refused`, que devuelve un `.value` con una frase de la app. Este cambio lo
convierte en tabla:

```swift
private nonisolated static let frasesDeEstadoAMedias: [String: [String: String]] = [
    PlayMusicTool.name: [
        "search_opened": "se abrió el buscador: no está sonando",
        "launching": "se abrió en la app: no está sonando aún",
    ],
]
```

con `fraseDeEstadoAMedias(toolName:status:)` y una rama en `summarize` que va **después** de los
dos censos globales (`failureStatuses` y `needsYouStatuses` siguen teniendo prioridad: un par que
alguien metiera aquí y que además fuera un fallo censado se seguiría pintando en rojo, que es la
dirección segura).

### Se indexa por el PAR (herramienta, estado), y eso es la lección de `cancelled`

Una tabla por **nombre de estado** funcionaría hoy —los tres estados son exclusivos de
`play_music`, medido—. Se escribe por par de todos modos, y la razón es la medida del informe
anterior: **el nombre de un estado no basta para decidir qué significa.** `cancelled` es un éxito
en `cancel_events` y `cancel_alarm` y significa «el usuario lo descartó y NO se ejecutó» en
`run_shortcut` y `send_message`. Una tabla por nombre sería una trampa armada para el día en que
otra herramienta estrene un `launching` que signifique otra cosa. Lo clava la mutación **M6**, que
hace que la búsqueda ignore el nombre de la herramienta y muere.

### Por qué `search_opened` no se metió en `needsYouStatuses`, que era la otra forma

`search_opened` encaja casi en la definición de ese conjunto («la herramienta no pudo seguir y
espera algo del usuario»: tiene que elegir un resultado). Pero su texto es fijo y único
—`needsYouText` = «necesita algo de ti»— y **pierde justo la mitad que importa**: que no está
sonando. El encargo pedía que la frase diga eso, y además `needsYouStatuses` no estaba entre los
conjuntos autorizados. Se queda fuera.

---

## 3 — `get_device_status` habla el contrato, y la batería se ve

Era **la única de las ochenta** herramientas del registro cuyo `run` no emitía ningún `status`
(`GetDeviceStatusTool.swift:22`, antes del cambio). Dos defectos del mismo tamaño:

1. **La fila mentía por omisión.** Sin `status` caía en `case nil` y decía «listo». No era falso,
   pero escondía el dato que el usuario había pedido.
2. **Su éxito nunca reiniciaba el presupuesto de fallos.** `Agent.reiniciaElPresupuesto` exige un
   `status` de `Agent.estadosDeExito`, así que **preguntar por la batería no borraba los fallos
   anteriores** y acercaba el turno a morir. Ésta es la peor de las dos porque no se ve en ninguna
   pantalla.

| sitio | cambio |
|---|---|
| `Gemma/Gemma/NativeServices/GetDeviceStatusTool.swift` | emite `"status": "success"` como primera clave; las siete que ya emitía siguen intactas |
| `Gemma/Gemma/Harness/ToolLogRow.swift` | `Kind` nuevo `.battery` + entrada `"get_device_status": .battery`, que pinta `battery_percent` como `73%` |

**Declara `success` y no un verbo propio como `ok`, y eso no es pereza.** `ok` es hoy un éxito
**huérfano** en veintiuna herramientas del registro: está fuera de `Agent.estadosDeExito`. Si la
herramienta dijera `ok`, para que su éxito reiniciara el presupuesto habría que meter `ok` en el
conjunto — que es exactamente el cambio por nombre que este encargo prohíbe y que el hallazgo de
`cancelled` demostró peligroso. `success` ya está en el conjunto y significa esto mismo en el
resto del registro.

**La batería entra en `ToolLogRow.table` y el `summary` no.** La regla escrita encima de esa tabla
—la que costó una rama en este proyecto— es: entra el dato que el usuario pidió y sobre cuyo
significado no cabe duda; **no entra ningún texto redactado para el modelo**. Un porcentaje de
batería cumple los dos lados. El `summary` («Tu iPhone tiene 73% de batería (sin cargar). Carga
baja, te recomiendo conectar tu iPhone pronto.») es texto para el modelo y **no** se pinta: lo
clava la mutación **M9**, que hace que la fila lea `summary` y muere.

**Y sin medición no se inventa nada.** Cuando el sistema no reporta el nivel, `run` **omite** la
clave a propósito (es el defecto 9 que `DeviceStatusHonestyTests` protege: «la batería desconocida
no se convierte en 100%»), y entonces la fila cae a «listo», que dice menos pero no inventa un
porcentaje. Esa mitad va en la misma prueba.

---

## Lo que NO se hizo, y por qué — los 22 éxitos huérfanos

El encargo lo prohibía y la prohibición se sostiene al mirarla, así que no hay nada que rechazar
aquí. Pero este trabajo ha **tropezado** con la lista dos veces, y las dos veces la prohibición
cambió la forma del arreglo en vez de solo frenarlo:

- **`playing` de `play_music`** es un éxito huérfano que la lectura a mano del enum destapó (el
  informe anterior solo lo atribuía a `control_music`). No se tocó.
- **`get_device_status`** se arregló declarando `success` precisamente **para no** tener que meter
  `ok` en `Agent.estadosDeExito`.

Hay además un candado nuevo que escribe la prohibición en el código, para que el siguiente que lo
mire tenga que leer la razón antes de cambiarla:
`ElFalloPintadoComoExitoTests.test_los_exitos_huerfanos_del_censo_siguen_fuera_del_presupuesto`
recorre ocho de los huérfanos (`ok`, `empty`, `deleted`, `updated`, `cancelled`, `playing`,
`done`, `found`), fija `Agent.estadosDeExito` al conjunto exacto que esta rama dejó, y vuelve a
afirmar los dos invariantes del par de conjuntos (disyunción con `estadosDeFallo`, y
`estadosDeFallo ⊆ failureStatuses`).

Lo demás del encargo se respetó entero: `cortaLaCola`, `urlDemostrada`, `esFallo`,
`maxConsecutiveFailures`, `pareceAtascado`, `recortaElHistorial`, `browserGuideFits`,
`executedMutations`, `activeTools = []`, `BrowserCloseIntent` y `BrowserCloseTool` siguen
intactos. De los dos conjuntos autorizados **solo `failureStatuses` cambió** (un estado:
`app_unavailable`); **`Agent.estadosDeExito` no se tocó en absoluto** — el arreglo del presupuesto
de `get_device_status` se consiguió desde la herramienta, no desde el conjunto.

---

## Tabla de mutaciones

Una por propiedad afirmada, **suite ENTERA en cada una**. El guion
(`mutaciones_fallo_pintado_opus5.py`, con marca propia `opus5_fpe` porque el scratchpad es
compartido y hoy a un agente le pisaron el suyo) exige que el ancla aparezca **exactamente una
vez** antes de tocar nada, guarda la copia con nombre único, compara su MD5 con el original,
afirma que la mutación cambió el fichero en disco, y al restaurar **vuelve a comprobar el MD5** con
un `assert` que aborta el guion si no coincide. «Rojos nuevos» = rojos de esa ejecución menos los
**4 de la base**.

**Nueve mutaciones. Las nueve compilaron, corrieron y murieron. Ninguna sobrevivió. Ningún ancla
abortó por no ser única.**

| id | mutación | propiedad | rojos nuevos | prueba que la mata |
|---|---|---|---|---|
| **M1** | se quita `"app_unavailable"` de `ToolLogRow.failureStatuses` | la app de música ausente sale con **cruz roja** y no con «listo» | 1 | `test_la_app_de_musica_que_no_esta_sale_con_cruz_roja_y_no_con_un_listo` |
| **M2** | se quita la frase de `app_unavailable` de `frasesDeFallo` | y con un motivo concreto, no con el genérico «falló» | 1 | la misma |
| **M3** | se quita la frase de `search_opened` de `frasesDeEstadoAMedias` | «se abrió el buscador» no dice «listo» | 1 | `test_la_musica_que_se_abrio_pero_no_suena_no_dice_ni_listo_ni_que_fallo` |
| **M4** | se quita la frase de `launching` | «se abrió en la app» no dice «listo» | **2** | la de arriba **y** `test_la_frase_es_del_par_y_no_del_nombre_del_estado_suelto` |
| **M5** | `summarize` deja de consultar la tabla de estados a medias | la fila de verdad usa la tabla, no solo la tabla existe | 1 | `test_la_musica_que_se_abrio_pero_no_suena_no_dice_ni_listo_ni_que_fallo` |
| **M6** | la búsqueda pasa a `frasesDeEstadoAMedias.values.first?[status]`, o sea **ignora la herramienta** | la frase es del **par**, no del nombre del estado suelto — la trampa de `cancelled` | 1 | `test_la_frase_es_del_par_y_no_del_nombre_del_estado_suelto` |
| **M7** | `get_device_status` deja de emitir `"status": "success"` | su éxito **reinicia el presupuesto de fallos** | 1 | `test_get_device_status_declara_su_exito_y_reinicia_el_presupuesto` |
| **M8** | se quita la entrada `"get_device_status": .battery` de `ToolLogRow.table` | la batería **se ve** en la fila | 1 | `test_la_bateria_se_ve_en_la_fila_y_no_un_listo` |
| **M9** | `.battery` lee `obj["summary"]` en vez de `obj["battery_percent"]` | se pinta el **dato** y no el texto escrito para el modelo | 1 | la misma |

**M4 mata dos pruebas y eso es deliberado**, no un descuido del diseño: la segunda
(`…del_par_y_no_del_nombre…`) empieza por `XCTAssertNotNil(fraseDeEstadoAMedias(play_music,
"launching"))`, o sea exige que el par exista antes de comprobar que otro no lo hereda. Sin esa
mitad, la prueba del par se cumpliría sola en un mundo donde la tabla estuviera vacía — que es la
forma exacta de la prueba vacua que el encargo avisaba (`XCTAssertNil` de todo es trivialmente
cierto si nada existe).

Las nueve restauraciones verificadas por MD5: `c1907008…` para `ToolLogRow.swift` (ocho
mutaciones) y `48a44b0a…` para `GetDeviceStatusTool.swift` (M7). La suite se corrió una vez más
al final sobre el árbol restaurado: **4 rojos**, los de la base.

---

## Pruebas nuevas

`Gemma/GemmaTests/ElFalloPintadoComoExitoTests.swift` (seis). Las tres de `play_music` llegan a su
estado por el **camino real de la herramienta** —con `MockAppURLOpener` y `MusicService`, no
fabricando el JSON a mano—, así que miden la cadena entera y no la forma de una cadena:

- `test_la_app_de_musica_que_no_esta_sale_con_cruz_roja_y_no_con_un_listo` — tres mitades: la
  herramienta declara `app_unavailable`; la fila lo pinta como fallo; y lo que pinta es la frase
  de la app, **no** el `message` (que está escrito para el modelo) ni el estado en crudo. Y
  comprueba el censo desde producción, para que añadirlo solo en esta llamada no cuente.
- `test_la_musica_que_se_abrio_pero_no_suena_no_dice_ni_listo_ni_que_fallo` — los dos estados, con
  las cuatro mitades cada uno: no es fallo, **no es `.ok`**, la frase dice «no está sonando», y no
  es el `message` del modelo.
- `test_la_frase_es_del_par_y_no_del_nombre_del_estado_suelto` — el candado de la lección de
  `cancelled`: el par existe, otra herramienta con el mismo nombre de estado **no** lo hereda, y
  `playing` no es un estado a medias.
- `test_get_device_status_declara_su_exito_y_reinicia_el_presupuesto` — `success`, `esExito`,
  `reiniciaElPresupuesto`, `!esFallo`, y las dos claves que ya emitía intactas.
- `test_la_bateria_se_ve_en_la_fila_y_no_un_listo` — tres mitades: se pinta `73%`; **no** se pinta
  el `summary`; y sin medición se cae a «listo» sin inventar cifra.
- `test_los_exitos_huerfanos_del_censo_siguen_fuera_del_presupuesto` — el candado de lo que el
  encargo prohibía. No prueba un arreglo: fija una decisión medida.

### El repaso de «¿esto se cumple con mi cambio deshecho?»

Por cada prueba del lado viejo que este cambio de contrato podía volver **vacua** (que es lo que
no se ve, al contrario que una roja):

| prueba | ¿queda vacua? | por qué |
|---|---|---|
| `MusicServiceTests.test_tool_appNotInstalled_statusIsAppUnavailable` | **no** | afirma `status == "app_unavailable"` y que el `message` no diga «reproduciendo». El contrato de la herramienta no cambió: lo que cambió es cómo lo LEE la fila. Intacta. |
| `MusicServiceTests.test_tool_returnsValidJSON_evenWithQuotesInQuery` (`search_opened`) | **no** | ídem: afirma el estado y el escapado de la consulta. Intacta. |
| `DeviceStatusHonestyTests` (×3) | **no** | afirman `battery_percent`, `battery_level_known` y `low_battery_warning`. El `status` se **añadió**, no sustituyó nada, así que las tres siguen midiendo lo suyo. Intactas. |
| `ToolJSONEscapingTests.test_get_device_status_output_is_valid_json` | **no** | afirma JSON válido con contenido hostil. Intacta. |
| `ToolLogRowTests.test_cada_estado_de_fallo_tiene_su_frase_fija_y_ninguna_habla_al_modelo` | **no, y se refuerza** | recorre `failureStatuses` **desde producción**, así que `app_unavailable` entró en su barrido: una frase vacía, demasiado larga, con el estado repetido o hablándole al modelo la habría puesto roja. |
| `AgentTests.test_lo_que_gasta_presupuesto_sale_con_cruz_roja_en_el_chat` | **no** | recorre los dos conjuntos desde producción; ampliar `failureStatuses` no rompe la inclusión que exige, y el final la vuelve a verificar. Intacta. |
| `ToolLogRowTests.test_una_accion_sin_dato_solo_dice_que_salio_bien` | **no** | sus cinco herramientas no están en la tabla ni en la de pares, así que siguen cayendo en `case nil`. Intacta. |

**Ninguna prueba existente se modificó**: este cambio **añade** estados a conjuntos y claves a
salidas, y no reescribe ningún contrato que una prueba viva afirmara. Eso es por qué no hubo
ninguna roja del lado viejo y por qué el repaso de vacuidad sale limpio — que es lo que había que
comprobar, no asumir.

**Sin push.**

---

## Autorización del controlador sobre la preocupación 1 (añadida después del informe)

**`app_unavailable` entra en `Agent.estadosDeFallo`. Autorizado.**

El implementador lo dejó fuera porque ese conjunto **mata turnos** y no estaba en
su encargo, lo cual fue correcto. La autorización:

Encaja en el criterio que ese conjunto ya lleva escrito —«no pude, y repetirlo no
lo arregla»— y encaja **exactamente igual que `not_available`, que ya está
dentro**. Reintentar no instala la aplicación de música. Un turno que insiste
contra una app que no existe no puede terminar bien, y el presupuesto existe para
pararlo antes de gastar las cinco rondas.

**Coste si me equivoco**: si algún día `app_unavailable` pasa a significar algo
transitorio (la app está instalada pero no responde todavía), contarlo como fallo
pararía un turno que habría funcionado al segundo intento. Se nota como «el agente
se rinde demasiado pronto con la música» y se quita de una línea.

**No se hace en su propio ciclo de pruebas**: viaja con el siguiente cambio que
toque `Agent.swift`, y su prueba es la que ya recorre el conjunto desde
producción. Queda escrito aquí para que no se pierda entre dos tareas, que es
exactamente cómo `pide_el_agente` y `vencio()` se quedaron sin llamante en el otro
repositorio.

## Lo que sigue abierto, con su número, para quien venga

- **22 estados de éxito huérfanos** que no reinician el presupuesto (`ok` en 21
  herramientas, más `empty`, `deleted`, `updated`, `playing`…). **El arreglo no es
  mecánico**: `estadosDeExito` se indexa por nombre y `cancelled` demostró que un
  nombre significa cosas opuestas en herramientas distintas. El diseño correcto es
  decidir por **(herramienta, estado)**, como hace ya `frasesDeEstadoAMedias` de
  este commit. Hay un candado que fija el conjunto malo conocido, así que un
  arreglo mecánico se pone rojo.
- **Diez herramientas esconden su respuesta detrás de «listo»** (la temperatura, la
  ubicación, la actividad, lo que suena, el título de la nota), más quince cuyo
  resultado es un recuento y para las que el tipo de fila ya existe (`Kind .count`,
  hoy solo lo usa `web_search`). `get_current_time` y `get_device_status` ya están
  arregladas y son el patrón a seguir.
