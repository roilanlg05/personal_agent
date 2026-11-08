# Tarea 2b — los tres huecos del corte de cola y del presupuesto de fallos

Rama `diag/panel-se-muere`, base `e2176c8`. Tres huecos que el autor del presupuesto de fallos
dejó señalados: un bug de verdad (una URL envenenada), un resultado del propio bucle que no
hablaba el contrato JSON y por eso no gastaba presupuesto, y un conjunto de estados de fallo
demasiado estrecho. No se toca `cortaLaCola`, ni el aviso de corte, ni `BrowserRules`, ni los
candados de cierre, ni `executedMutations`, ni la retirada de herramientas.

---

## Hueco 1 — un `browser_open` FALLIDO envenenaba la URL conocida

### El defecto, y por qué era exactamente el que el corte existe para evitar

`AgentBrowserToolOutput.resolve(_:extra:)` mezcla el `extra` **también** en el objeto de fallo
(está documentado así en su propio comentario: «`extra` se mezcla en el objeto de fallo (por
ejemplo la URL pedida)»). `BrowserOpenTool` lo llamaba con `extra: ["url": url]`, así que un
`open` que **no llegó a la página** devolvía de todas formas la URL **que se pidió**. Y el bucle
la grababa sin mirar el estado:

```swift
if let url = Self.urlDelResultado(result) { urlConocidaDelNavegador = url }
```

La cadena completa: estamos en `a.test`; falla el `open` a `b.test/x`; la URL conocida pasa a
`b.test/x`, **una página en la que nunca estuvimos**; un `click` posterior que navega **de
verdad** a `b.test/x` coincide con la URL conocida, `cortaLaCola` cae en su rama que no corta, y
las `@eN` de la cola —planificadas contra `a.test`— se disparan contra la página nueva. Es
literalmente el defecto que el corte se escribió para impedir, producido por el propio corte.

### Lo que se arregló, y son dos capas independientes

1. **En el bucle** (`Agent.swift`): la URL conocida solo se actualiza desde un resultado con
   éxito. Vive en una función pura nueva, `Agent.urlDemostrada(porResultado:)`, que exige
   `status == "success"` —el **mismo** estándar de prueba que usa `cortaLaCola`— y solo entonces
   delega en `urlDelResultado`. No se usa `esExito`, que es más ancho: `no_content` significa «la
   operación funcionó pero no hay nada que reportar», y eso no demuestra ninguna página.
2. **En el origen** (`BrowserNavigationTools.swift`): `BrowserOpenTool` ya no pasa `extra` a
   `resolve`, así que su JSON de fallo no lleva ninguna URL. Era **la única de las nueve**
   herramientas de navegador que mandaba una URL en un fallo; las demás llaman a
   `resolve(outcome)` a secas. El motivo del fallo sigue viajando en el `message`, que es lo que
   el modelo necesita, y la URL pedida la tiene en sus propios argumentos.

Las dos capas son deliberadas y no redundantes: la del bucle es la que no puede depender de que
ninguna de las nueve herramientas vuelva a meter una URL en un fallo, y la del origen es la que
evita que el modelo lea «url: …» en un resultado que no llegó a esa página.

### ¿Basta con exigir éxito? El censo de los caminos por los que una URL llega a ser «la conocida»

Esto era la pregunta del encargo, y la respuesta no es un sí limpio. Censo completo de lo que
`Agent.urlDelResultado` puede leer (la clave `url`, o `value` cuando `what == "url"`), herramienta
por herramienta, mirando los dos caminos de salida de cada una:

| herramienta | en el ÉXITO | en el FALLO | ¿filtra lo que no es una página? |
|---|---|---|---|
| `browser_open` | la URL de aterrizaje del CLI, o la pedida si el CLI no la trae | **ya no manda URL** (antes: la pedida) | **sí, ahora** (`isAllowedWebURL`) |
| `browser_snapshot` | `url` del CLI | no manda URL | sí (ya lo hacía) |
| `browser_click` / `_fill` / `_press` | `InteractionSupport.urlPosterior` (la del CLI o un `get url`) | no mandan URL | sí (`urlSiEsUnaPagina`) |
| `browser_get` con `what=url` | `value` = lo que diga el CLI | no manda URL | **no** |
| `browser_close` / `browser_wait` | nunca mandan URL | no mandan URL | — |
| `read_webpage` | — | — | irrelevante: no está en `browserToolNames`, el bucle no le lee URLs |

De ahí salen **tres hallazgos** además del bug encargado:

**(a) `browser_open` era la única que no filtraba la URL del éxito.** `browser_snapshot` lo
filtra y lo dice con estas palabras: «un valor que no sea una página web (`isAllowedWebURL`) no se
reporta, para que una URL ilegible no pueda fabricar un cambio de página que no hubo»; las tres
de interacción hacen lo mismo con `InteractionSupport.urlSiEsUnaPagina`. `open` pasaba al bucle
lo que dijera el CLI, así que un `about:blank` o un `chrome-error://chromewebdata/` podía
convertirse en «donde estamos». **Arreglado**: ahora filtra igual que sus ocho hermanas.

**(b) El camino que QUEDA abierto, y se queda abierto a propósito: la estimación del éxito.** En
el éxito, si el CLI no trae la URL de aterrizaje, `open` reporta **la pedida** (`?? url`). Con una
redirección que el CLI no cuente, esa es una URL en la que no estamos. Es un camino real por el
que una URL no visitada puede ser la conocida, y **se ha dejado**, porque medido contra el corte
la alternativa es peor:

- Con la estimación (base `a.test`, estamos de verdad en `c.test`): un clic que no navega
  reporta `c.test ≠ a.test` → corte de más (cuesta una ronda, el modelo vuelve a mirar: dirección
  segura). Un clic que navega a cualquier sitio distinto de `a.test` → **corta, y acierta**. Solo
  se escapa el clic que navegue precisamente a la URL pedida al principio.
- **Sin** la estimación (omitir la clave cuando el CLI calla): no hay línea base, y
  `cortaLaCola` exige `urlConocida` para comparar, así que **ninguna** navegación posterior se
  detecta hasta que otra herramienta fije una URL.

O sea: omitirla es más «honesto» por la regla de «la duda no inventa», pero detecta
estrictamente menos navegación que estimar. Se queda la estimación, con el razonamiento escrito
en el código.

**(c) `browser_get` con `what=url` es la única URL que sigue sin filtrar.** No es un
envenenamiento: ese valor es una **lectura del estado real** del navegador (si el CLI dice
`about:blank`, es que estamos en `about:blank`), no una estimación, y el modelo lo recibe como lo
que es, una lectura. Además `url` no está en `BrowserInspectionTools.clippedWhat`, así que no
puede llegar recortada. Se deja como está y queda anotado.

### La prueba

`AgentTests.test_un_open_fallido_no_envenena_la_url_conocida_y_el_clic_posterior_si_corta`
recorre el camino entero hasta el corte, que era la condición del encargo: ronda 1 un
`browser_snapshot` con éxito deja establecido que estamos en `a.test` (leer no corta nunca);
ronda 2 un `browser_open` que **falla** trayendo `url: https://b.test/x`, un `browser_click` que
navega de verdad a `https://b.test/x`, y un `browser_fill` detrás con un `@e9` de la página
vieja. Lo que se exige es que el **fill no se ejecute** y que el aviso de corte —derivado de
`BrowserRules.queueCutNote`, no escrito a mano— llegue al prompt vivo.

**Y esta prueba pasó por el motivo equivocado en su primera versión.** El `open` fallido traía
`https://b.test/` y el clic aterrizaba en `https://b.test/x`: con el bug intacto la URL conocida
pasaba a `b.test/` y el corte **se disparaba igualmente** porque `b.test/x ≠ b.test/`. Verde con
el defecto dentro. Las dos URL tienen que coincidir **al carácter** para que la prueba mida lo
que dice medir, y el caso así es además el realista: el modelo intenta ir directo, no puede, y
acaba llegando pulsando un enlace. Queda escrito en el comentario de la prueba para que nadie lo
«simplifique» otra vez.

A nivel de herramienta: `BrowserNavigationToolsTests.test_un_open_fallido_no_reporta_la_url_que_se_pidio`
(el JSON de fallo no trae `url`, y `Agent.urlDelResultado` no puede sacar ninguna de ahí) y
`test_open_no_reporta_como_pagina_una_url_absurda_del_cli` (un `about:blank` del CLI no se
convierte en la URL conocida).

---

## Hueco 2 — un error que no hablaba JSON no gastaba presupuesto

El bucle contestaba a una herramienta inexistente con la cadena `error: no tool named X`, que no
es un objeto JSON. `esFallo` no le podía leer el `status`, el resultado caía por la dirección
segura —no gasta presupuesto— y un modelo empeñado en una herramienta que no existe seguía dando
vueltas **hasta el tope de rondas del turno**, que es justo el caso para el que el presupuesto se
escribió.

Ahora ese resultado sale de `Agent.resultadoDeHerramientaInexistente(nombre:)` y habla el
contrato: `status: error` más un `message` que nombra la herramienta que no existe y le dice al
modelo que no la vuelva a llamar. No sugiere ninguna herramienta parecida a propósito: mandar al
modelo a una que no es la que quería es peor que decirle que esa no está, y el inventario completo
ya le viaja en la lista de herramientas de la petición. Efecto secundario bueno: `error` está en
`ToolLogRow.failureStatuses`, así que esa llamada ahora sale con cruz roja en la fila del chat,
que es lo que el usuario debería ver.

Prueba: `AgentTests.test_insistir_en_una_herramienta_que_no_existe_agota_el_presupuesto` —cinco
llamadas a una herramienta que no está en el registro paran el turno, la sexta acción de la ronda
no se ejecuta, y el usuario recibe **un** mensaje que la nombra.

### La trampa que el autor avisó, y cómo se resolvió

Ese resultado era el ejemplo canónico de «no es JSON válido» en tres pruebas. Ninguna se ha
borrado ni debilitado; las tres tienen ahora un ejemplo **de verdad** ilegible:

- `test_cortaLaCola_la_duda_no_corta` (la propiedad que es una restricción global del plan: una
  duda no corta la cola) usa ahora `"Clic ejecutado; la página quedó en https://b.test/x"`:
  prosa, y prosa que **nombra una URL distinta de la conocida**. Es un ejemplo mejor que el que
  tenía, porque además de no ser JSON clava que lo que decide el corte es el contrato JSON y
  nunca una URL leída de un texto suelto.
- `test_un_resultado_ilegible_no_es_exito_ni_fallo` y
  `test_un_resultado_ilegible_no_reinicia_el_presupuesto_ni_revienta_el_bucle` usan un doble
  nuevo, `FakeIlegible`, que devuelve prosa. No es un caso de laboratorio: `ForgetTool`
  (`forget`) contesta de verdad «Forgot 3 item(s) matching 'x'.», y el propio bucle produce otro
  resultado que tampoco es JSON (`DUPLICATE_CALL_IGNORED`). La vía larga sigue midiendo lo que
  medía —que un resultado ilegible **no reinicia** la cuenta— y se le ha añadido una aserción de
  que la herramienta ilegible se ejecutó de verdad.
- `test_el_mensaje_de_presupuesto_agotado_…` usa el mismo doble para su caso «sin motivo
  legible».

---

## Hueco 3 — el conjunto de estados que cuentan como fallo era demasiado estrecho

`Agent.estadosDeFallo` tenía 3 estados; `ToolLogRow.failureStatuses` tiene 21. Se han añadido los
**cinco** que significan «no pude»: `timeout`, `unavailable`, `memory_unavailable`,
`permission_denied`, `failed`. Los cinco existen de verdad en la app (`CurrentLocationTool`,
`SendMessageTool`/`ShareTool`, todas las de memoria, y las de tareas/`LoadMessagesTool`), y los
cinco están en `ToolLogRow.failureStatuses`, así que la coherencia con la cruz roja del chat se
mantiene sola.

**El criterio queda escrito en el comentario de `estadosDeFallo`**, que era la mitad del encargo:
entra el estado que significa «**NO PUDE**» —la herramienta no hizo el trabajo y repetirla no va
a cambiarlo—; se queda fuera el que significa «**CONTESTÉ, Y LA RESPUESTA ES NO**» —la
herramienta sí hizo el trabajo, lo que devuelve es información, y un turno en el que el modelo
consulta cinco cosas que no existen está trabajando, no dando vueltas—. Por eso siguen fuera
`not_found`, `contact_not_found`, `place_not_found`, `not_in_catalog`, `unknown_topic`,
`unsupported`, `unsupported_kind`, `limit_reached`, `missing_fields`, `name_taken`,
`no_phone_number`, `period_in_past` y `rejected`. Y queda dicha la razón de que los dos conjuntos
no se unifiquen nunca: pintar una cruz roja no le cuesta nada al usuario y **matarle el turno
sí**, así que el conjunto que decide una muerte es más corto por construcción, y es un
subconjunto estricto del otro.

Pruebas: `test_los_estados_de_no_pude_gastan_presupuesto_y_los_de_conteste_que_no_siguen_fuera`
(los cinco gastan; los trece del límite no), `test_cinco_timeouts_seguidos_paran_el_turno` (la vía
larga, con un estado de **fuera** del contrato del navegador: el presupuesto no es una regla del
navegador sino del bucle), y las dos propiedades que ya estaban y siguen clavadas:
`test_los_estados_de_fallo_y_de_exito_son_el_contrato_real_y_son_disjuntos` (ampliado a los ocho
estados) y `test_lo_que_gasta_presupuesto_sale_con_cruz_roja_en_el_chat` (que no hubo que tocar).

---

## Mutación por propiedad afirmada

Cada mutación neutraliza **una** línea de producción (M7, dos: ver su nota), corre la suite
**entera** y se restaura. Los rojos son de la suite entera, contados con
`… test 2>&1 | grep -E "^Test case" | grep "' failed" | sed 's/ on .*//' | sort -u`, y la columna
«rojos nuevos» es sobre los 7 fallos preexistentes.

| mutación | línea de producción neutralizada | rojos nuevos sobre la suite entera |
|---|---|---|
| **M1** | `urlDemostrada(porResultado:)` deja de exigir `status == "success"` (queda idéntica a `urlDelResultado`) | 1 — `AgentTests.test_un_open_fallido_no_envenena_la_url_conocida_y_el_clic_posterior_si_corta` |
| **M2** | `BrowserOpenTool` vuelve a pasar `extra: ["url": url]` a `resolve` | 1 — `BrowserNavigationToolsTests.test_un_open_fallido_no_reporta_la_url_que_se_pidio` (+1 intermitente, ver abajo) |
| **M3** | la URL del éxito de `open` vuelve a pasar sin filtrar por `isAllowedWebURL` | 1 — `BrowserNavigationToolsTests.test_open_no_reporta_como_pagina_una_url_absurda_del_cli` |
| **M4** | la herramienta inexistente vuelve a contestar `error: no tool named X` | 2 — `AgentTests.test_insistir_en_una_herramienta_que_no_existe_agota_el_presupuesto` y `BrowserCoreSkillTests.test_el_primer_browser_del_turno_lleva_la_guia_exactamente_una_vez` |
| **M5** | los cinco estados de «no pude» salen de `estadosDeFallo` | 3 — `test_los_estados_de_no_pude_gastan_presupuesto_y_los_de_conteste_que_no_siguen_fuera`, `test_los_estados_de_fallo_y_de_exito_son_el_contrato_real_y_son_disjuntos`, `test_cinco_timeouts_seguidos_paran_el_turno` |
| **M6** | `esFallo` devuelve `true` cuando no sabe leer el `status` (se acaba el tercer estado) | 2 — `test_un_resultado_ilegible_no_es_exito_ni_fallo`, `test_un_resultado_ilegible_no_reinicia_el_presupuesto_ni_revienta_el_bucle` |
| **M7** (dos líneas) | `estadoDelResultado` da `"success"` a lo ilegible **y** `urlDelResultado` saca la URL de la prosa | 3 — `test_cortaLaCola_la_duda_no_corta`, `test_un_resultado_ilegible_no_es_exito_ni_fallo`, `test_un_resultado_ilegible_no_reinicia_el_presupuesto_ni_revienta_el_bucle` |

Las siete aplican con un ancla única (verificado antes de correr nada) y restauran el fichero
byte a byte; el `git diff --stat` al final del lote es idéntico al de antes de empezar.

**Por qué M7 son dos líneas y no una, dicho sin maquillaje.** La propiedad «una duda no corta la
cola» está guardada **dos veces**: `cortaLaCola` exige `status == "success"` y además exige una
URL legible. Con una sola de las dos neutralizada, un resultado en prosa sigue sin cortar —si le
regalas el `success`, la URL sigue siendo `nil`; si le regalas la URL, el `status` sigue sin ser
`success`—, así que **ninguna mutación de una línea pone roja esa aserción**. Eso no es una
prueba vacía, es una propiedad con doble cinturón; para demostrar que la aserción no es
decorativa hay que quitar los dos, y con los dos quitados se pone roja. Queda dicho aquí en vez
de dejar la casilla en blanco o fingir un rojo.

**Y el M1/M2 que no se duplica.** El arreglo del hueco 1 está en dos sitios (el guard del bucle y
el `extra` de la herramienta), pero no hacen falta dos mutaciones de la misma propiedad: si el
sitio de llamada no usara `urlDemostrada`, la prueba del hueco 1 estaría roja **ahora**, y está
verde. M1 ya demuestra que la prueba discrimina y que el bucle pasa por ahí.

---

## Recuento de la suite

| momento | fallos |
|---|---|
| base `e2176c8` (preexistentes) | 7 |
| con las pruebas nuevas, antes de implementar | 13 (7 + 6 nuevas, rojas) |
| después de implementar | 9 (7 + 2 pruebas viejas que el hueco 2 rompió) |
| tras arreglar esas dos | 7, con una intermitente (el orden de claves JSON) |
| final | **7** (exactamente los preexistentes) |

Pruebas nuevas: 6 (`AgentTests` ×4, `BrowserNavigationToolsTests` ×2). Pruebas viejas tocadas: 6
(dos reparadas porque el hueco 2 cambió su suelo, tres porque su ejemplo de «no es JSON» dejó de
serlo, una ampliada con los cinco estados nuevos). Ninguna borrada ni debilitada.

Los 7 preexistentes, sin cambios:
`AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`,
`ContactAliasStoreTests` (×2), `ForgetToolTests.test_forget_calls_endpoint_and_returns_count`,
`ReminderCRUDToolTests.test_update_mueve_la_hora`, `ToolJSONEscapingTests` (×2).

---

## Lo que apareció fuera de la tarea

**1. Dos pruebas viejas conducían el bucle con un registro VACÍO y dependían de que el resultado
de «esa herramienta no existe» fuera ilegible.** El hueco 2 las puso rojas, y las dos eran
legítimas de romper:

- `AgentTests.test_a_turn_that_touches_the_browser_gets_a_bigger_iteration_budget` medía el tope
  de **rondas** con un registro vacío: cada ronda llamaba a una herramienta inexistente, y desde
  el arreglo eso gasta presupuesto y mata el turno en la quinta ronda, así que nunca llegaba a
  las diez. Arreglada registrando dobles que **tienen éxito** (`FakeOkSearch`, el registro de
  navegador falso), que es lo que la prueba quería decir: el turno no puede morir por otra razón
  que el tope de rondas.
- `BrowserCoreSkillTests.test_el_primer_browser_del_turno_lleva_la_guia_exactamente_una_vez`
  **escribía a mano** `"error: no tool named browser_open"` para reconstruir la nota de resultado
  y localizarla en el prompt. Arreglada derivando el resultado de
  `Agent.resultadoDeHerramientaInexistente(nombre:)`, que es la única fuente.

**2. 🔴 El hallazgo gordo: `ToolJSONOutput.object` no promete el orden de las claves, y NO es
estable ni entre dos llamadas del mismo proceso.** Serializa con
`JSONSerialization.data(withJSONObject:)` **sin** `.sortedKeys`, así que el mismo diccionario
literal sale una vez como `{"status":…,"message":…}` y otra como `{"message":…,"status":…}`.
Medido, no deducido: al derivar la nota esperada de
`Agent.resultadoDeHerramientaInexistente(nombre:)`, la prueba de la guía se puso roja **1 de cada
3 veces** con la suite entera (0 de 10 corriendo sola, 1 de 5 corriendo su clase), y el volcado
de la aserción enseña las dos cadenas lado a lado, la esperada con `status` primero y la del
prompt con `message` primero, **en el mismo proceso**.

Consecuencias, por orden de importancia:

- **Cualquier prueba que compare la salida JSON de una herramienta byte a byte es
  intermitente**, en toda la app, no solo aquí. Setenta y tantas herramientas construyen su
  salida con `ToolJSONOutput.object`. Quien escriba `XCTAssertEqual(out, #"{"status":"ok",…}"#)`
  tiene una prueba que pasa o falla según el día; lo correcto es parsear y comparar campos, que
  es lo que hacen las pruebas que ya existen (todas usan un `parse(_:)` y leen claves).
- La prueba de esta tarea se arregló **sin tocar producción**: localiza la nota por su cabecera
  —derivada de `toolResultNote` con un resultado centinela— y comprueba el resultado por su
  motivo (`Agent.motivoDelResultado`, una sola cadena). Verificado 6 de 6 corridas limpias de la
  clase, y la mutación M4 la sigue poniendo roja, así que no se ha debilitado: lo que se quitó
  fue la dependencia del orden, no la aserción.
- **Lo que NO se ha hecho, y es una decisión**: añadir `.sortedKeys` a `ToolJSONOutput.object`
  arreglaría el orden para siempre y haría diffeable la salida de las setenta y tantas
  herramientas, pero cambia la salida de todas a la vez y esto es una tarea de tres huecos
  concretos. Queda propuesto, con la nota de que es un cambio de una línea y de que el modelo no
  nota la diferencia.

**3. Y la fragilidad latente que eso descubre.** `BrowserCoreSkillTests.lastLivePrompt` conduce
`Agent.run` con un registro vacío **a propósito** («ninguna herramienta real corre, pero el bucle
construye igual la nota de resultado»). Desde el hueco 2, **cada** llamada de ese fichero gasta
una unidad del presupuesto de fallos. Hoy ninguna de sus ocho pruebas pasa de tres llamadas por
turno, así que todas siguen verdes; la primera que meta cinco morirá en el presupuesto en lugar
de medir la guía, y el síntoma será un prompt vivo más corto de lo esperado, no un error que lo
explique. Si alguien amplía ese fichero, lo barato es registrar dobles que tengan éxito, como se
ha hecho en `test_a_turn_that_touches_the_browser_gets_a_bigger_iteration_budget`.

**4. La medida de la semana que se confirmó otra vez**: la prueba del hueco 1 pasó en verde con
el defecto intacto porque dos URL que debían coincidir no coincidían (`b.test/` contra
`b.test/x`). Se detectó porque la suite de la fase roja la reportó **pasando** cuando tenía que
fallar, no por releerla. Correr la fase roja y **leer qué pasó** vale lo que cuesta.
