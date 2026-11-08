# Tarea 1 — Cortar la cola de acciones cuando la página cambia

Rama `diag/panel-se-muere`, base `6c0f8ff`. Ficheros tocados:
`Gemma/Gemma/Agent/Agent.swift`, `Gemma/Gemma/Agent/BrowserRules.swift`,
`Gemma/GemmaTests/AgentTests.swift`.

## El defecto, y qué se hizo

El prompt del sistema le dice al modelo, con estas palabras, que «the `@eN` references change
after every action, so NEVER reuse an old one» (`BrowserRules.text`). El bucle de
`Agent.run(prompt:options:)` ejecutaba la ronda entera en fila sin comprobarlo: si el modelo
pedía `browser_click @e5` y `browser_fill @e9` y el clic navegaba, el `@e9` se disparaba contra
la página nueva, donde esa referencia es otro elemento o ninguno — acertaba a otra cosa, o
fallaba sin decir por qué. **La regla estaba escrita y nadie la hacía cumplir.**

Ahora la hace cumplir el bucle. Tras ejecutar cada herramienta de navegador se pregunta a
`Agent.cortaLaCola(trasHerramienta:resultado:urlConocida:)` —pura y estática— si esa acción pudo
invalidar las referencias; si pudo y detrás quedaba cola, la cola se descarta y el modelo recibe
en la nota de resultados un aviso que dice cuántas acciones quedaron sin ejecutar, cuáles y por
qué, para que las vuelva a pedir con la página nueva delante.

## Los tres puntos de criterio

### 1. De dónde sale la URL con la que se compara

Medido contra las herramientas reales antes de suponer la forma del JSON
(`Gemma/Gemma/NativeServices/Browser*Tools.swift`):

| Herramienta | Qué devuelve su éxito | ¿URL utilizable? |
| --- | --- | --- |
| `browser_open` (`BrowserNavigationTools.swift:49-55`) | `status`, `title`, `url`, `content_is_untrusted` | **Sí**, la de aterrizaje (puede no ser la pedida si hubo redirección) |
| `browser_get` con `what=url` (`BrowserInspectionTools.swift:154`) | `status`, `what`, `value` | **Sí**, en `value`, identificada por `what == "url"` |
| `browser_snapshot` (`BrowserNavigationTools.swift:118-128`) | `status`, `snapshot`, `element_count`, `origin`, … | No: `origin` es esquema+host y no distingue dos páginas del mismo sitio |
| `browser_click` (`BrowserInteractionTools.swift:44`) | `status`, `message` | **No** |
| `browser_fill` (`BrowserInteractionTools.swift:95`) | `status`, `message` | **No** |
| `browser_press` (`BrowserInteractionTools.swift:133`) | `status`, `message` | **No** |
| `browser_wait` (`BrowserInspectionTools.swift:74`) | `status`, `message` | **No** |
| `browser_close` (`BrowserNavigationTools.swift:177`) | `status`, `message` | **No** (y no hace falta: mata la sesión) |

Decisión: `Agent.urlDelResultado(_:)` lee `url`, y en su defecto `value` cuando `what == "url"`.
Nada más — en particular NO se usa `origin`, que daría falsos negativos dentro de un mismo sitio
y es la clase de dato «casi bueno» que produce un corte que no se puede explicar.

La comparación vive en el bucle, no en la función pura: `urlConocidaDelNavegador` se declara al
lado de `executedMutations` (o sea, con vida de turno, no de ronda) y se le pasa a `cortaLaCola`
como `urlConocida`. Es deliberado que cruce rondas: el `browser_open` de una ronda es lo que le
da a la siguiente con qué comparar. Se actualiza **después** de decidir el corte, para que la
comparación sea siempre contra la página en la que el modelo planificó la ronda.

Y la regla de la dirección segura, escrita en el comentario de la función: un resultado ilegible,
sin `status`, fallido, o sin URL cuando la URL es lo único que demostraría el cambio, **no corta**.
Cortar de más tampoco es gratis (cuesta una ronda del presupuesto del turno y manda al modelo a
mirar otra vez una página que no se había movido), así que un valor que no se supo leer nunca se
convierte en un corte.

Dos cosas cortan sin comparar nada, y no son una duda:
`browser_open` (carga otro documento, o recarga el mismo, que destruye las `@eN` igualmente) y
`browser_close` (termina la sesión; su propia descripción ya le dice al modelo que «las
referencias '@eN' dejan de valer»). Las dos solo cortan con `status == "success"`: el `refused`
del candado de cierre deja la página abierta, y cortar ahí sería mentirle al modelo sobre lo que
acaba de pasar.

**El precio honesto de esto, y es el hallazgo principal de la tarea:** mientras
`BrowserClickTool`, `BrowserFillTool` y `BrowserPressTool` devuelvan solo `status` + `message`,
un clic que navegue **no se detecta por la vía de la URL**, porque su propio resultado no la
dice. El corte que hoy se dispara de verdad es el de `browser_open` / `browser_close`, que ya
cubre el caso muy común de «abrir y, en la misma ronda, actuar sobre una `@eN` de la página
anterior». La rama de comparación de URL está implementada y probada, y se activará sola el día
que las herramientas de interacción devuelvan la URL posterior a la acción — que el CLI conoce y
esas herramientas tiran (`BrowserInteractionTools.swift:43-44` resuelve el `outcome` y descarta
todo su JSON salvo el fallo). Eso es trabajo de las herramientas, no de este bucle, y queda
anotado abajo como trabajo suelto.

### 2. Qué ve el modelo cuando se corta

`BrowserRules.queueCutNote(tras:pendientes:)`. Vive en `BrowserRules` porque es una regla del
navegador —es la misma regla de caducidad de las `@eN` que ya está en `BrowserRules.text`, dicha
en el momento en que muerde— y esa constante es la única fuente de nuestras reglas. En inglés,
como el resto del prompt vivo.

Lleva, por exigencia del encargo: que se cortó, **cuántas** acciones quedaron sin ejecutar,
**cuáles** (por nombre, para que volver a pedirlas sea mecánico) y **por qué**.

Está redactado para que no se lea como un fallo del modelo, porque no lo es, y porque si suena a
error el modelo se pone a disculparse o a reintentar en vez de volver a pedir la acción. De ahí
que empiece por «Nothing failed, and nothing is wrong with what you asked for», que lo llame «the
normal rhythm of driving a page, not a mistake of yours and not a failure to report», que diga el
paso de recuperación exacto (`browser_snapshot`, y volver a pedir las acciones con las
referencias nuevas) y que cierre con «do not apologise and do not start the task over; you have
lost one round, nothing else».

Detalle que conviene no perder: el paso de recuperación que el aviso pide (`browser_snapshot`) es
justo la acción que un corte detrás de `browser_open` suele estar descartando, porque
`open` + `snapshot` en la misma ronda es el par más frecuente. O sea que el coste real del corte
en ese caso es **una ronda**, no información: el modelo vuelve a pedir el snapshot y sigue. Se
consideró dejar correr las acciones de la cola que no usan referencias (solo `browser_snapshot`
lo cumple: `browser_get` acepta un `@eN` en `selector`) y se descartó: reintroduce la ejecución
parcial contra una página que el modelo no planificó, a cambio de ahorrar una ronda de nueve.

### 3. Si cortar choca con los frenos que ya hay

No choca, y se comprobó en el código y con una prueba, no por suposición.

- **`executedMutations`** (la negativa a repetir una llamada idéntica) solo se consulta para
  `mutationToolNames`, que es `add_shift`, `drop_shift`, `create_event`, `cancel_event`,
  `update_event`, `create_task`, `complete_task` (`Agent.swift`, dentro de `run`). **Ninguna
  herramienta de navegador está ahí**, así que una acción cortada que el modelo vuelve a pedir no
  puede bloquearse por «duplicada». Era el riesgo real de esta tarea —cambiar un defecto por otro
  peor: una acción que ya nadie puede ejecutar en el turno— y está clavado por
  `test_la_accion_cortada_se_puede_volver_a_pedir`, que afirma que el clic re-pedido se ejecuta
  de verdad y que la nota NO contiene `DUPLICATE_CALL_IGNORED`.
- **`activeTools = []`** (la retirada de herramientas) se dispara con `anyMutationExecuted` —que
  tampoco lo arman las herramientas de navegador— o con `iteration >= maxIterations - 2`. Un
  turno que toca el navegador tiene `maxBrowserIterations == 10`, o sea nueve rondas que pueden
  llamar herramientas. Un corte gasta una. Es el único coste medible del cambio.
- El **acuse conversacional de la ronda 0** se emite antes de ejecutar nada y no se ha tocado.
- Los **candados de cierre** (`BrowserCloseIntent` + `BrowserCloseTool`) no se han tocado; el
  corte respeta su `refused` no cortando.

## Mutación → pruebas rojas nuevas

Cada mutación: neutralizar una línea de producción, correr la suite entera, comprobar el rojo,
restaurar. «Nuevas rojas» = fallos que no están en la base de 7.

| Mutación (línea neutralizada) | Pruebas rojas nuevas |
| --- | --- |
| **M1** `guard browserToolNames.contains(nombre)` → `guard !nombre.isEmpty` (cualquier herramienta puede cortar) | `test_cortaLaCola_la_duda_no_corta` |
| **M2** `guard estadoDelResultado(resultado) == "success"` → `guard !resultado.isEmpty` (una acción fallida también corta) | `test_cortaLaCola_la_duda_no_corta`, `BrowserCoreSkillTests.test_tres_llamadas_de_navegador_en_una_ronda_siguen_llevando_la_guia_una_vez` |
| **M3** `guard !browserReadOnlyToolNames.contains(nombre)` → `guard !browserReadOnlyToolNames.isEmpty` (leer la página también corta) | `test_cortaLaCola_leer_la_pagina_no_corta_nunca` |
| **M4** `browserToolNamesThatResetThePage.contains(nombre)` → `.contains("jamas")` (abrir/cerrar deja de cortar por sí solo) | `test_cortaLaCola_navegar_invalida_las_referencias`, `test_la_cola_se_corta_cuando_la_pagina_cambia_y_el_modelo_se_entera`, `test_la_accion_cortada_se_puede_volver_a_pedir` |
| **M5** `return urlNueva != urlConocida` → `==` (comparación invertida) | `test_cortaLaCola_una_accion_corta_solo_si_la_pagina_cambio`, `test_la_url_conocida_cruza_las_rondas_y_el_fill_no_se_ejecuta` |
| **M6** se quita el `break` del corte (la cola sigue ejecutándose) | `test_la_cola_se_corta_cuando_la_pagina_cambia_y_el_modelo_se_entera`, `test_la_accion_cortada_se_puede_volver_a_pedir`, `test_la_url_conocida_cruza_las_rondas_y_el_fill_no_se_ejecuta` |
| **M7** se quita el `resultsNote += queueCutNote(...)` (corte en silencio, sin aviso) | `test_la_cola_se_corta_cuando_la_pagina_cambia_y_el_modelo_se_entera`, `test_la_url_conocida_cruza_las_rondas_y_el_fill_no_se_ejecuta` |
| **M8** `if corta, !pendientes.isEmpty` → `if corta` (avisa aunque no quedara cola) | `test_una_ronda_de_una_sola_accion_no_cambia` |
| **M9** se quita la actualización de `urlConocidaDelNavegador` (sin memoria de la URL entre rondas) | `test_la_url_conocida_cruza_las_rondas_y_el_fill_no_se_ejecuta` |

**Nueve mutaciones, nueve muertas, cero supervivientes.** Las nueve compilaron sin errores (se
comprobó: `error:` = 0 en los nueve logs), así que ninguna es de las que mienten quedando en
código equivalente o en un fallo de compilación disfrazado de rojo. Logs en
`scratchpad/t1-M*.log`, resumen en `scratchpad/mut-report.txt`.

Dos cosas que la tabla enseña y que merecen leerse:

- **M2 se llevó por delante una prueba ajena**:
  `BrowserCoreSkillTests.test_tres_llamadas_de_navegador_en_una_ronda_siguen_llevando_la_guia_una_vez`
  pone tres herramientas de navegador en UNA ronda, que es justo lo que el corte gobierna. Con el
  código bueno sigue verde (sus resultados no son JSON legible → no se corta), pero es de facto
  un segundo guardián de que el corte no se dispara por las buenas. Vale saberlo antes de tocar
  esa prueba.
- **M9 solo la mata una prueba**, y esa prueba se escribió precisamente porque al planear las
  mutaciones se vio que sin ella la línea de la memoria de la URL se podía borrar sin que nada se
  pusiera rojo. Es el caso literal del encargo (clic que navega + fill con `@eN` vieja) y es la
  única prueba que recorre la rama de comparación de URL de punta a punta.


## Recuento de fallos

| Momento | Fallos |
| --- | --- |
| Base (`6c0f8ff`, antes de tocar nada) | **7**, todos preexistentes: `AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`, `ContactAliasStoreTests` (×2), `ForgetToolTests.test_forget_calls_endpoint_and_returns_count`, `ReminderCRUDToolTests.test_update_mueve_la_hora`, `ToolJSONEscapingTests` (×2) |
| Rojo del paso 2 (pruebas escritas, `cortaLaCola` devolviendo `false` y el bucle sin tocar) | **11** = 7 + 4 nuevas (`navegar_invalida_las_referencias`, `una_accion_corta_solo_si_la_pagina_cambio`, `la_cola_se_corta_…`, `la_accion_cortada_se_puede_volver_a_pedir`) |
| Después (implementado) | **7**, los mismos de la base. Ningún octavo |

Contados con el `grep` del encargo, no a ojo. Las diez pruebas nuevas pasan (`passed` explícito
en `scratchpad/final-t1.log`); la suite devuelve `rc=65` por los 7 preexistentes y 0 errores de
compilación.

## Trabajo suelto que apareció y no es de esta tarea

1. **🔴 El hueco que queda, y es el importante.** `BrowserClickTool`, `BrowserFillTool` y
   `BrowserPressTool` resuelven el `outcome` del CLI y **tiran su JSON entero** salvo el fallo
   (`BrowserInteractionTools.swift:43-44`, `:94`, `:132`): devuelven un `{"status":"success",
   "message":"…"}` escrito a mano. El CLI sí sabe en qué página quedó la acción. Mientras eso no
   se arregle, **un clic que navegue no se puede detectar** y el corte por URL no se dispara
   detrás de una acción. El arreglo es pequeño y está fuera de esta tarea: que esas tres
   herramientas propaguen la URL posterior a la acción (el campo `url` de los `fields` del CLI,
   como ya hace `BrowserOpenTool`). En cuanto lo hagan, la rama que `cortaLaCola` ya tiene
   implementada y probada se activa sola, sin tocar el bucle. Sugerencia de orden: hacerlo antes
   de las tareas 2-5, porque es lo que convierte esta tarea de media en entera.
2. **`BrowserSnapshotTool` devuelve `origin` y no la URL** (`BrowserNavigationTools.swift:124`).
   `origin` es esquema+host: no distingue `…/carrito` de `…/pago`. Si el snapshot devolviera la
   URL completa, el bucle tendría una segunda fuente para `urlConocidaDelNavegador` justo en el
   paso que el modelo da más a menudo. Barato y útil.
3. **`AgentTests.test_browser_tool_note_lets_the_model_keep_driving_the_page` afirma
   `XCTAssertEqual(Agent.browserToolNames.count, 8)`**, o sea el número escrito a mano. Es
   exactamente lo que `BrowserRules.toolInventoryNote` dejó de hacer en `e423b1f` (deriva el
   número de la constante). Esa línea se pondrá roja el día que aparezca una novena herramienta,
   y será un rojo sin información. No la toqué por no entrar en la prueba de otro.
4. **El `maxIterations` de un turno de navegador se gasta un poco más rápido.** Un corte cuesta
   una ronda de las nueve que pueden llamar herramientas. Hoy solo se dispara detrás de
   `browser_open`/`browser_close`, y el par `open` + `snapshot` en la misma ronda es frecuente, así
   que algún turno largo de conducción podría notarlo. Si alguna vez se nota de verdad, la salida
   NO es dejar de cortar: es subir `maxBrowserIterations`, que es un número y no una regla.
5. **El árbol estaba sucio antes de empezar** (no es mío): `graphify-out/` entero,
   `docs/superpowers/plans/2026-11-08-mando-subsistema-a.md`, los `xcuserstate` y un montón de
   notas sin commitear. El commit de esta tarea toca solo sus tres ficheros más esta nota.

