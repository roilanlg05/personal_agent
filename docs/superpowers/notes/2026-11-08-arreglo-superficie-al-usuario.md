# Arreglo de la superficie al usuario — rama del bucle de navegación

**Rama:** `diag/panel-se-muere`, sobre `782c079`.
**Encargo:** dar la vuelta al veredicto de `2026-11-08-revision-de-rama-navegacion.md`, que fue
**NO** y no por el bucle: «Bucle bien. Superficie al usuario, mal. Dos textos de la app mienten
en turno normal.»
**Alcance:** nada de lo que hay aquí toca el bucle ni sus cinco frenos (`cortaLaCola`,
`urlDemostrada`, `esFallo`/`maxConsecutiveFailures` —salvo el REINICIO—, `pareceAtascado`,
`recortaElHistorial`, `browserGuideFits`, `executedMutations`, `activeTools = []`, ni los candados
`BrowserCloseIntent`/`BrowserCloseTool`). Lo que cambia es lo que el usuario **lee**: dos textos
de la app que afirmaban cosas falsas, el resumen de la fila plegada, el reinicio del presupuesto,
lo que entra en el transcripto, el orden de lectura del prompt y una línea de diagnóstico en
pantalla.

**Pruebas:** base **5 fallos / 1.196 verdes** → después **5 fallos / 1.206 verdes** (+10 pruebas
nuevas). Los cinco fallos son los mismos cinco de la base declarada en el plan y ninguno es de
esta rama.

Un aviso sobre el recuento, para quien repita la medida: el comando del encargo
(`grep -E "^Test case" | grep "' failed"`) cuenta bien los ROJOS, pero el recuento de verdes por
`grep -c "' passed"` es ±1 entre ejecuciones porque las pruebas corren en paralelo y a veces dos
procesos se parten una línea del log (en la ejecución final se perdió así la línea de
`BrowserNavigationToolsTests.test_snapshot_reports_the_full_url_when_the_cli_gives_it`, que pasó).
Los rojos nunca se vieron afectados.

---

## Las frases fijas por estado, y por qué cada una

Esto es el corazón del arreglo, porque es lo que el usuario va a leer en su teléfono. La fila
plegada de una herramienta que falla ya no pinta el `message` de la herramienta —que está
redactado para el MODELO: segunda persona, con instrucciones— sino una frase de la APP, fija por
estado, en español y sin dirigirse a nadie. El motivo íntegro **no se pierde**: sigue en el
detalle que se abre tocando la fila (`ToolLogRow.detail`, 4.000 caracteres) y sigue viajando
entero al modelo en la nota de resultado. Hoy el usuario tiene el motivo pero escrito para otro;
con esto tiene un motivo escrito para él y el original a un toque.

| `status` | frase | por qué |
|---|---|---|
| `refused` | «el navegador no lo hizo» | Censado: `refused` lo construyen solo el navegador (`AgentBrowserToolOutput.resolve`) y el candado de `BrowserCloseTool`, así que nombrar el navegador es cierto siempre. Dice el hecho —no se hizo— sin llamarlo avería. |
| `not_available` | «no está disponible» | **Me desvié de la frase que traía el encargo** («no está instalado»), y a propósito: el estado NO es solo del navegador. `ShortcutRunOutcome.notAvailable` lo emiten también `run_shortcut`, `play_music` y `send_message` cuando la app Atajos no está disponible en el dispositivo. «No está instalado» sería mentira en tres herramientas para acertar en nueve; «no está disponible» es cierto en las doce. Y la regla del encargo es precisamente que un texto de la app no mienta. |
| `error` | «falló» | Es el estado genérico del contrato. No se puede decir más sin interpretar, y en este proyecto contar es honesto e interpretar no. |
| `failed` | «no se pudo hacer» | Distinto de `error` a propósito: `failed` lo devuelven herramientas de sistema cuando la acción no se completó, no cuando el mecanismo se rompió. |
| `timeout` | «tardó demasiado» | Dice la causa sin prometer que reintentar vaya a funcionar. |
| `unavailable` | «el servicio no respondió» | El de fuera: red o servicio caído. |
| `memory_unavailable` | «la memoria no respondió» | El caso cotidiano del i3 al otro lado de Tailscale. «La memoria» es la palabra que usa el usuario. |
| `permission_denied` | «sin permiso» | Lo más corto que sigue siendo accionable: el permiso lo da él, en Ajustes. |
| `rejected` | «no se aceptó» | El de fuera dijo no; no fue un fallo nuestro. |
| `not_found` | «no se encontró» | |
| `contact_not_found` | «ese contacto no está» | Más concreto que «no se encontró», que a secas no dice QUÉ no se encontró. |
| `place_not_found` | «ese sitio no está» | Igual, para los de mapas. |
| `not_in_catalog` | «no está en el catálogo» | Música: no es un fallo de la app, es que la canción no existe ahí. |
| `unknown_topic` | «ese tema no está» | Memoria por temas. |
| `unsupported` | «eso no se puede hacer» | |
| `unsupported_kind` | «ese tipo no se puede» | |
| `limit_reached` | «se llegó al límite» | |
| `missing_fields` | «faltan datos» | El único que insinúa qué hacer, y sin dirigirse a nadie. |
| `name_taken` | «ese nombre ya existe» | |
| `no_phone_number` | «no hay número de teléfono» | El caso real: llamar a un contacto que no tiene número. |
| `period_in_past` | «esa fecha ya pasó» | |
| `invalid_*` (familia abierta) | «los datos no valían» | `invalid_` es un prefijo, no un censo: la rama por prefijo ya existía y aquí lleva su frase. |
| cualquier otro | «falló» | Un estado nuevo nunca deja la fila muda. Y hay una prueba que recorre el censo ENTERO desde producción (`ToolLogRow.failureStatuses`, que por eso dejó de ser `private`): añadir un estado de fallo sin frase propia la pone roja. |

Y un **par (herramienta, estado)** con su propia salida, que no es de fallo:

| caso | lo que se pinta | por qué |
|---|---|---|
| `browser_close` + `refused` | «la página sigue abierta», sin cruz roja | El candado rechaza todo cierre que el usuario no haya pedido en el turno, y eso es la conducta correcta: muchas veces la página abierta ES el entregable. Una cruz roja ahí le dice que algo se rompió cuando lo que pasó es que la app le protegió la página. La excepción es del PAR, no del estado: un `browser_open` rechazado sigue siendo fallo (el usuario no vio la página que pidió) y un `browser_close` con `error` también. |

Dos textos más de la app que se reescribieron, por la misma regla:

- **El mensaje de presupuesto agotado.** Antes: «He llamado a `read_webpage` **5 veces seguidas**
  y las 5 han fallado, así que me paro aquí en lugar de seguir intentando lo mismo. Lo último que
  devolvió fue: …». Ahora: «**Me paro aquí: 5 acciones seguidas han fallado, así que no sigo
  intentándolo. La última fue `read_webpage` y devolvió: …**». La cuenta es de **acciones**, que
  es lo que el bucle cuenta; la herramienta se nombra como lo que es, **la última**, no como la
  culpable de las cinco.
- **La línea de estado del navegador** no cambia de texto: cambia de **cuándo** aparece (ya no la
  dispara un `browser_close`) y de **dónde acaba** (ya no entra en el transcripto).

---

## Qué se hizo con cada hallazgo

### A — `browser_close` rechazado ya no ensucia un turno perfecto

`Agent.swift`: conjunto nuevo `browserToolNamesThatDoNotTouchThePage = ["browser_close"]` y
predicado `actuaSobreLaPagina(_:)`, que es el que ahora gobierna los **dos** sitios donde el bucle
apunta «la última acción de navegador» (el del bucle de acciones y el de la rama
`.toolCallFinished`).

**La exclusión vive al APUNTAR la acción, no al redactar la línea**, y esa es la única decisión de
diseño que tomé distinta de lo que proponía la revisión. Si viviera dentro de
`lineaDeEstadoDelNavegador`, un `close` posterior seguiría **tapando** un fallo de verdad anterior.
No es teórico: está medido en la fase roja de la prueba, donde el turno `press`(falla) → `close`
(rechazado) entregaba «Hecho.\n\n … `browser_close` devolvió `refused` …» — o sea que el aviso
cierto (el `press` falló) se había perdido y en su lugar había uno falso. Con la exclusión al
apuntar, la última acción sobre la página sigue siendo el `press` y lo que el usuario lee es
verdad.

`laRondaTocoElNavegador` sigue poniéndose con `browser_close` (la guía y el presupuesto de rondas
no cambian): lo único que el cierre ya no hace es escribir la línea.

**Prueba:** `AgentTests.test_un_close_rechazado_no_ensucia_el_turno_y_no_tapa_un_fallo_de_verdad`,
con cuatro mitades en la misma función: (a) el turno limpio, (b) un fallo **sobre la página** que
SÍ produce la línea, (c) el cierre que no tapa el fallo anterior, (d) la función pura. La premisa
se afirma dentro: `esFallo("refused")` sigue siendo `true`, así que la prueba no puede verdear
porque `refused` haya dejado de contar como fallo.

### B — el mensaje del presupuesto ya no miente con un número

`Agent.mensajeDePresupuestoAgotado` reescrito (texto arriba). El contador sigue siendo global al
turno y por acción ejecutada: no se tocó nada del conteo, solo la frase que lo cuenta.

**Prueba:** `AgentTests.test_el_mensaje_de_presupuesto_no_le_cuelga_los_cinco_fallos_a_una_sola_herramienta`,
que construye el caso medido por la revisión (tres `read_webpage` + dos `browser_press`), afirma
las cuentas reales de cada doble, y exige a la vez lo que el mensaje **sí** dice y la afirmación
falsa que **ya no puede** decir.

### C — la fila plegada ya no pinta texto escrito para el modelo

`ToolLogRow.summarize`, rama de fallo: `clip(message)` → `fraseDeFallo(status:)`. Más la excepción
del par `browser_close` + `refused`. El recorte a 120 caracteres del `message` desapareció con él:
un texto para el modelo cortado por la mitad es una instrucción a medias, que es peor que la
entera.

**Pruebas:** `test_un_fallo_se_resume_con_la_frase_de_la_app_y_no_con_el_texto_del_modelo` (usa el
caso real: `Agent.resultadoDeHerramientaInexistente`, el error más común del modelo, y comprueba
que el motivo íntegro sigue en el detalle), `test_cada_estado_de_fallo_tiene_su_frase_fija_y_ninguna_habla_al_modelo`
(recorre el censo de producción), `test_un_cierre_rechazado_por_el_candado_no_se_pinta_como_fallo`
(con sus dos mitades: el `open` rechazado y el `close` con `error` siguen siendo fallo),
`test_un_motivo_largo_escrito_para_el_modelo_no_llega_a_la_fila`.

Y el invariante `AgentTests.test_lo_que_gasta_presupuesto_sale_con_cruz_roja_en_el_chat` lleva
ahora **declarada su única excepción**, con su coste escrito: un `browser_close` + `refused` sigue
gastando presupuesto —el bucle no mira el nombre de la herramienta, y no debería— pero no se pinta
como fallo. Si un modelo se empeñara en cerrar, gastaría presupuesto sin cruz roja. No se ha
observado (el candado le dice «NO vuelvas a intentarlo» en el `message`) y queda anotado.

### D — el presupuesto ya no mata turnos en los que hubo éxitos de verdad

`Agent.reiniciaElPresupuesto(resultado:)`, usada por el bucle donde antes estaba `esExito`. La
línea que traza es **mecánica**, no una corazonada sobre el texto:

| resultado | ¿reinicia? | por qué |
|---|---|---|
| `status` de `estadosDeExito` | sí | el contrato, como antes |
| **no es un objeto JSON** (prosa: «Forgot 3 item(s)…») | **sí, es lo nuevo** | una herramienta de fuera del contrato contestando en su prosa. Son seis registradas: `ForgetTool`, `SaveMemoryTool`, `ReflectTool`, `add_shift`, `drop_shift`, `get_shifts` (dos de ellas mutaciones) |
| `esFallo` | no | |
| objeto JSON con `status` ilegible o sin `status` | **no** | aquí vive `ToolJSONOutput.error(_:)` → `{"error": …}`, la salida de las guardas de argumentos de media app. Es un fallo de verdad y es alcanzable (el modelo llamando con los argumentos mal): si reiniciara, el presupuesto se quedaría sin dientes justo contra el bucle de fallos que no sabemos leer, que es lo que el comentario de `esFallo` avisa de no hacer |
| `DUPLICATE_CALL_IGNORED` | no | no es una herramienta contestando, es el bucle atajando una repetición |

**El precio, declarado en el código:** un **fallo** en prosa («memory unavailable», que es lo que
`forget` contesta cuando el servicio no está) ahora reinicia. No se puede distinguir de su éxito
sin tocar las seis herramientas, y entre matar turnos buenos y dejar un turno malo en manos del
tope de rondas, lo segundo es lo que no le cuesta nada al usuario. El arreglo de raíz —que esas
seis hablen el contrato `status`— está anotado en el código y arreglaría además los dos hallazgos
nuevos de más abajo.

**Prueba:** `test_un_exito_en_prosa_reinicia_el_presupuesto_y_un_objeto_ilegible_no` sustituye a
`test_un_resultado_ilegible_no_reinicia_el_presupuesto_ni_revienta_el_bucle`, que afirmaba
exactamente la propiedad contraria. **Eso es un cambio de propiedad declarada, no un arreglo de
prueba:** la vieja decía «lo ilegible no reinicia» y era la mitad del defecto. La nueva tiene las
dos mitades en la misma función (prosa reinicia / objeto ilegible no) más la función pura, así que
ni «reiniciar con todo» ni «no reiniciar nunca» la pasan.
`test_un_resultado_ilegible_no_es_exito_ni_fallo` sigue como estaba: `esFallo` y `esExito` no se
tocaron.

### E — la línea de la app ya no se guarda como voz del asistente

Tres piezas:

1. `GenerationResult.appNotice: String?` (nuevo, por omisión `nil`): **declara** que ese sufijo
   exacto de `text` lo escribió la app. No es un segundo canal de texto, es una declaración sobre
   el que ya hay.
2. `Agent.entregaLaRespuesta` lo rellena con la línea de estado.
3. `HarnessModel.sinElAvisoDeLaApp(_:aviso:)` lo quita **solo del valor que se archiva**
   (`finalAssistantText`, que es literalmente lo que `runAgentTurn` persiste con
   `appendTranscript`). Lo que se pinta no se toca.

Es un **sufijo declarado, no una búsqueda**: si el aviso no está al final, no se quita nada; el
texto del modelo no se recorta nunca «por si acaso».

**Pruebas:** `AgentTests.test_la_linea_de_estado_viaja_declarada_como_aviso_de_la_app` (el bucle
declara el aviso en un turno con fallo y NO declara ninguno en un turno en éxito, y la última
afirmación ata las dos piezas de producción sobre el mismo dato) y
`AvisoDeLaAppEnElTranscriptoTests`, tres pruebas que pasan por `consumeAgentEvents` —el mismo bucle
que usa `runAgentTurn`— y miden a la vez que el aviso **no** está en lo archivado y **sí** está en
lo pintado.

**Nota honesta sobre la fase roja:** la mitad de E que vive en `Agent` y la función pura las
escribí en la misma tanda que las pruebas, así que
`test_la_linea_de_estado_viaja_declarada_como_aviso_de_la_app` **verdeó ya en la fase roja**. Eso
es información, no alivio: lo que de verdad estaba roto —el arnés archivando el aviso— lo midió en
rojo `test_el_aviso_de_la_app_no_se_archiva_y_si_se_muestra`, y la propiedad entera la cubre la
mutación N5.

### F — la guía oficial ya no es la cola del prompt

`RondaDelTurno.render`: la guía pasa a ir **delante** del texto de su ronda, así que la nota de
resultado vuelve a ser lo último que el modelo lee. Con eso, las dos afirmaciones de producción que
se contradecían (`toolResultNote`, «es lo ÚLTIMO que el modelo lee … gana sobre cualquier
instrucción», y `browserGuideBlock()`) vuelven a ser ciertas; las tres las reescribí para que digan
lo que el código hace. `promptVivo` no cambió: la guía **rescatada** ya era cabecera, delante de las
rondas.

Lo que esto cierra, medido por la revisión: la cola del prompt era «Working safely … **Never echo
or paste secrets**», exactamente la lectura a secas que `browserGuidePreamble` dedica un párrafo a
desactivar (una dirección de correo no es un secreto; es una queja literal del usuario) y que la
otra lectura peligrosa —«run `agent-browser close` when you're done»— ya se había cobrado el
hallazgo A.

**La prueba que ya no significaba lo que decía** (`BrowserCoreSkillTests
.test_el_primer_browser_del_turno_lleva_la_guia_exactamente_una_vez`, `indiceNota < indiceGuia`)
ahora afirma el orden **fuerte**: la guía **acaba** antes de que la nota empiece
(`rangoGuia.upperBound < indiceNota`), no solo que empiece antes, así que una guía que envolviera
la nota tampoco pasaría. Y de paso afirma que la frase de precedencia sigue pegada por delante.

**Y el agujero M6 de la revisión queda tapado**: `test_el_recorte_rescata_la_guia_de_la_ronda_que_se_cae`
exige ahora que la guía **rescatada** vaya delante de las rondas que sobreviven (mutación N8), que
es la propiedad que `recortaElHistorial` declaraba en su comentario y que no guardaba nadie.

### G — los contadores de diagnóstico, solo cuando informan

`BrowserPanelView.muestraLaCuenta(fotogramas:descartados:hayJpeg:)`, nueva y declarada, y la vista
la llama. **Los contadores no se borran** —el misterio que diagnostican, «mensajes 6 · fotogramas
0», sigue sin explicación— pero dejan de aparecer sobre un panel que funcionó.

Qué cambia de verdad, porque el encargo se escribió creyendo que era peor de lo que era: la línea
**ya estaba** dentro del hueco sin imagen, así que un panel que está pintando no la veía nunca. El
caso que sobraba es el otro: el hueco **normal**, el que queda cuando el panel suelta la imagen al
cerrarse después de cuarenta fotogramas sin un problema. Ahí dos números monoespaciados no
diagnostican nada. Ahora se pintan solo si el panel **no consiguió pintar**: `fotogramas == 0` (el
misterio), `descartados > 0` (llegaron y se tiraron) o `hayJpeg` (llegó uno y no decodificó).

**Prueba:** `BrowserPanelCuentasTests.test_la_cuenta_solo_se_pinta_cuando_el_panel_no_consiguio_pintar`,
con las dos mitades en la misma función. **Honestidad sobre el alcance:** la prueba cubre la
REGLA, no el cableado de la vista — el cuerpo de una `View` de SwiftUI no es observable desde una
prueba unitaria, igual que ya ocurre con `textoSinImagen` y `esperandoLaPrimera` en este mismo
fichero. El cableado se leyó y es una sola `if` alrededor del `Text`.

---

## Tabla de mutaciones

Nueve mutaciones, una por propiedad afirmada, **suite ENTERA en cada una**. El guion
(`mutar.py`, en el scratchpad) exige que el ancla aparezca **exactamente una vez** antes de
tocar nada, comprueba que la mutación cambió el fichero, y restaura desde una copia **verificando
el MD5 después de restaurar** (un `assert` que aborta si no coincide: es el error que ya dejó
correr tres mutaciones encadenadas sobre un fichero ya mutado en una ronda anterior).

Cada mutación compiló (si no compilara, el rojo no mediría nada) y **las nueve murieron**.
«Rojos nuevos» = rojos de esa ejecución menos los **5 de la base**.

| id | mutación | propiedad | rojos nuevos | pruebas que la matan |
|---|---|---|---|---|
| **N1** | `browserToolNamesThatDoNotTouchThePage = []` (resucita el defecto) | **A**: un `close` rechazado no ensucia la respuesta | 1 | `AgentTests.test_un_close_rechazado_no_ensucia_el_turno_y_no_tapa_un_fallo_de_verdad` |
| **N2** | `mensajeDePresupuestoAgotado` vuelve a «He llamado a `X` N veces seguidas» | **B**: la cuenta es de acciones, no de llamadas a esa herramienta | 1 | `AgentTests.test_el_mensaje_de_presupuesto_no_le_cuelga_los_cinco_fallos_a_una_sola_herramienta` |
| **N3** | la rama de fallo de `summarize` vuelve a `clip(message)` | **C**: la fila no pinta el texto escrito para el modelo | 3 | `ToolLogRowTests.test_un_fallo_se_resume_con_la_frase_de_la_app_y_no_con_el_texto_del_modelo`, `…test_un_motivo_largo_escrito_para_el_modelo_no_llega_a_la_fila`, `…test_browser_open_rechazado_es_fallo_y_no_enseña_el_host` |
| **N4** | `reiniciaElPresupuesto` vuelve a ser solo `esExito` | **D**: un éxito en prosa reinicia el presupuesto | 1 | `AgentTests.test_un_exito_en_prosa_reinicia_el_presupuesto_y_un_objeto_ilegible_no` |
| **N5** | el arnés archiva `stripped` sin filtrar el aviso | **E**: el aviso de la app no entra en el transcripto | 1 | `AvisoDeLaAppEnElTranscriptoTests.test_el_aviso_de_la_app_no_se_archiva_y_si_se_muestra` |
| **N6** | `RondaDelTurno.render` vuelve a poner la guía DETRÁS del texto | **F**: la nota de resultado es lo último que el modelo lee | 2 | `BrowserCoreSkillTests.test_el_primer_browser_del_turno_lleva_la_guia_exactamente_una_vez`, `AgentTests.test_el_recorte_rescata_la_guia_de_la_ronda_que_se_cae` |
| **N7** | `muestraLaCuenta` → `true` (lo de antes) | **G**: la cuenta solo se pinta cuando informa | 1 | `BrowserPanelCuentasTests.test_la_cuenta_solo_se_pinta_cuando_el_panel_no_consiguio_pintar` |
| **N8** | `promptVivo` pone la guía rescatada DETRÁS de las rondas (es la M6 de la revisión, que sobrevivía) | **F/M6**: la guía rescatada vive como cabecera | 1 | `AgentTests.test_el_recorte_rescata_la_guia_de_la_ronda_que_se_cae` |
| **N9** | se quita la excepción `browser_close` + `refused` de `summarize` | **C**: un cierre rechazado no se pinta como fallo | 2 | `ToolLogRowTests.test_un_cierre_rechazado_por_el_candado_no_se_pinta_como_fallo`, `AgentTests.test_lo_que_gasta_presupuesto_sale_con_cruz_roja_en_el_chat` |

**Ninguna equivalente, ningún agujero.** Y el agujero M6 que la revisión dejó abierto está cerrado
(N8).

Cómo se verificó la restauración, porque es el error que ya se cometió antes: cada mutación guarda
una copia, comprueba su MD5 contra el original **antes** de tocar nada, afirma que la mutación
cambió el fichero, y al terminar restaura y **vuelve a comprobar el MD5** con un `assert` que
aborta el guion entero si no coincide. Las nueve pasaron. Después, los cuatro ficheros de
producción se compararon por MD5 contra las copias y la suite se corrió una última vez.

---

## Lo que descubrí fuera de la tarea

### Dos textos MÁS de la app que mienten en la pantalla del usuario, los dos en `ToolLogRow.summarize`

No los arreglé —no están en A-G y los dos necesitan una decisión de producto— pero son de la misma
familia que el veredicto y los dos son alcanzables en un turno normal:

1. **Un éxito en prosa sale con CRUZ ROJA.** `summarize`, rama del `guard` de arriba
   (`ToolLogRow.swift`, el `return .failure(clip(t …))` del resultado que no es JSON): `forget`
   contesta «Forgot 3 item(s) matching 'x'.» y la fila lo pinta como **fallo**, con su cruz roja y
   su texto en rojo. Lo mismo las otras cinco herramientas del censo de prosa (`save_memory`,
   `reflect`, `add_shift`, `drop_shift`, `get_shifts`). O sea: el usuario pide un turno en A-to-Z,
   se lo apunta correctamente, y la fila le dice que falló. Hay una prueba que **declara** esa
   conducta (`test_lo_que_no_es_json_no_rompe_la_fila_ni_la_deja_en_blanco`, «un resultado ilegible
   es un fallo, no un éxito»), así que es una decisión vieja, no un descuido — pero se tomó cuando
   «ilegible» quería decir «basura», y hoy quiere decir también «prosa de seis herramientas que
   funcionan».
2. **Un error de argumentos sale con TILDE VERDE y «listo».** `ToolJSONOutput.error(_:)` produce
   `{"error": "Se requiere 'name' …"}`: un objeto JSON **sin** `status`, así que no entra en la
   rama de fallo, cae en `case nil` y se resume como «listo». Es el camino de las guardas de
   argumentos de media app, y lo dispara el modelo llamando con los argumentos mal. También hay una
   prueba que lo declara (`test_sin_estado_no_es_un_fallo`), con un ejemplo (`{"count":3}`) que no
   es este caso.

**Los dos los arregla el mismo cambio**, que es además el arreglo de raíz de D: que esas seis
herramientas hablen el contrato `status` y que `ToolJSONOutput.error` ponga `"status": "error"`.
Con eso, prosa y `{"error":…}` dejan de existir como categorías y las tres cosas se caen solas.
Precedente en esta misma rama: `3d27a2a` hizo exactamente eso con el resultado de la herramienta
inexistente. **Es el siguiente trabajo que yo haría aquí.**

### Lo que no se tocó, con su línea (hallazgos 6, 7, 9, 10 y 12 de la revisión)

- **Hallazgo 6 — el invariante de la entrega sin guardián** (`Agent.swift`, `entregaLaRespuesta`,
  `text: res.text.isEmpty ? res.text : res.text + …`). Sigue sin prueba propia, pero ahora hay algo
  que no había: `appNotice` lleva la línea **declarada aparte**, así que un futuro «simplificar el
  ternario» ya no puede además contaminar el transcripto. La mitad grave del hallazgo (el usuario
  deja de ver la respuesta y solo ve el aviso) sigue sin guardián.
- **Hallazgo 7 — `.toolCallFinished` es código muerto y el comentario dice lo contrario**
  (`Agent.swift`, rama `.toolCallFinished` del `for try await event in stream`). **Salió gratis a
  medias:** la rama ahora comparte el predicado `actuaSobreLaPagina` con el camino vivo (así el
  defecto de A no reaparece por ahí el día que un runtime ejecute sus propias herramientas) y el
  comentario lleva añadido que hoy **ningún runtime de producción** la recorre. No la borré: eso es
  una decisión de arquitectura, no de superficie.
- **Hallazgo 9 — el aviso de vueltas en vacío se acumula con dos cuentas distintas**
  (`Agent.swift`, el `if presupuestoAgotado == nil, Self.pareceAtascado(…)` al cerrar la ronda).
  Intacto. El arreglo propuesto —un `avisoDeVueltasEmitido` como el `browserGuideInjected`— toca el
  bucle, y el bucle no se abre en esta ronda.
- **Hallazgo 10 — `queueCutNote` da consejo de `@eN` por una herramienta que no es del navegador**
  (`BrowserRules.queueCutNote`, llamado desde el bucle con `pendientes` sin filtrar). Intacto, por
  lo mismo: el arreglo es filtrar `pendientes` o ejecutar el resto, y las dos cosas son el bucle.
- **Hallazgo 12 — el comentario caducado de `AgentTests.swift`**
  (`test_cortaLaCola_la_duda_no_corta`, «Lo que `BrowserClickTool` devuelve hoy: ni una URL»,
  falso desde la Tarea 1b). Intacto: no toqué esa prueba y no quise mezclar un cambio de comentario
  ajeno en los commits de este arreglo.
- **`BrowserOpenTool` puede fijar una URL que no es la página real** y la **carrera de
  `urlPosterior`**: intactos, son del bucle.

---

## Commits

| SHA | qué |
|---|---|
| `151dd71` | **C** — la fila de una herramienta que falla dice una frase de la app, no el texto escrito para el modelo (`ToolLogRow` + sus pruebas). Incluye la excepción del cierre rechazado. |
| `4453b7c` | **A, B, D, E, F** — los cinco textos del bucle que llegaban al usuario diciendo cosas que no eran (`Agent.swift`, `ModelRuntime.swift`, `HarnessModel.swift` + pruebas). |
| `c3722f9` | **G** — los contadores del panel solo se pintan cuando el panel no consiguió pintar. |
| (el último) | este informe. Su propio SHA no se puede escribir aquí sin volver a cambiarlo. |

Van en cuatro commits y no en siete porque A, B, D, E y F viven en **hunks solapados** de
`Agent.swift` y `AgentTests.swift`: separarlos obligaría a inventar estados intermedios que
ninguna ejecución de la suite ha verificado. C y G sí son independientes a nivel de fichero, y van
aparte. **Sin push.**
