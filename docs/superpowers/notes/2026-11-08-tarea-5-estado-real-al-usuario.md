# Tarea 5 — Que el usuario lea lo que la página dice, no lo que el modelo cuenta

Rama `diag/panel-se-muere`, base `6572bd3`. Última de las cinco tareas del plan del bucle de
navegación (`docs/superpowers/plans/2026-11-08-bucle-de-navegacion.md`).

## El hueco que cierra, y el que NO cierra

El hueco es compartido con browser-use: **nadie comprueba que lo que el agente dice que hizo haya
pasado de verdad**. El caso real que motiva la tarea es el usuario leyendo «te he puesto el vídeo»
cuando la pulsación había fallado. El fallo no se perdía en el camino técnico —viajaba al modelo
entero en la nota de resultado— y aun así lo único que llegaba a la pantalla era la narración del
modelo.

Su intento de tapar el hueco es un **juez LLM**, y no sirve: corre después, **no sobrescribe el
resultado**, y solo escribe `⚠️ Agent reported success but judge thinks task failed` en un registro
que nadie lee. El plan prohíbe importarlo, y la prohibición es correcta: añade una llamada al
modelo y no cambia lo que el usuario ve.

**Nuestra ventaja es que hay un humano mirando.** No hace falta un juez: hace falta que **lo
observable llegue a sus ojos sin pasar por la narración del modelo**. Eso es lo que se ha
construido.

### Lo que esto NO es, dicho también en el código

**No es verificación. Es que el dato no se pierda.** La verificación de verdad —comparar la
INTENCIÓN del usuario con el estado final de la página— no entra en este plan, no existe en
browser-use, y sigue siendo **un problema sin resolver en los dos proyectos**. Haría falta saber
qué significa «pon el vídeo» como estado de una página, y eso no sale de ningún `status`: un
`browser_press` con `status: success` sobre el botón equivocado es un éxito a ojos de esta línea y
un fracaso a ojos del usuario, y este canal no lo distingue.

Lo ÚNICO que la línea afirma es un hecho que ya teníamos medido y estábamos tirando: **la última
acción sobre la página declaró que no la hizo.** Esa frase está escrita en el doc comment de
`Agent.lineaDeEstadoDelNavegador`, para que nadie la lea como más de lo que es.

## Dónde vive la línea, y por qué ahí

| Pieza | Fichero | Qué es |
| --- | --- | --- |
| `Agent.lineaDeEstadoDelNavegador(herramienta:resultado:)` | `Gemma/Gemma/Agent/Agent.swift` | la decisión y el texto, pura y estática; `nil` = nada que decir |
| `ultimaDelNavegador` (variable de turno) | `Agent.run(prompt:options:)` | la última acción de navegador del turno y su resultado |
| `entregaLaRespuesta(_:)` (función local de `run`) | `Agent.run(prompt:options:)` | el único sitio por el que sale la respuesta del modelo, y donde se le pega la línea |

**En `Agent.swift`, no en `BrowserRules.swift`.** `BrowserRules` es la fuente única de nuestras
reglas del navegador, pero esas reglas son **instrucciones al modelo**: se renderizan en el prompt
del sistema y dentro del bloque de la guía, y su razón de existir es que las dos renderizaciones no
divergan. **Un texto que lee una persona no es una de ellas.** Poner esta línea ahí mezclaría dos
públicos en la misma constante, que es exactamente la clase de confusión que costó una rama.

El vecino correcto es `Agent.mensajeDePresupuestoAgotado`: el otro texto de la app que va al
usuario, en español, sin JSON, y que el modelo no redacta. Las dos viven ahora juntas.

**En `Agent.swift`, no en `HarnessModel.swift`.** `consumeAgentEvents` ve todos los
`.toolCallFinished` en un solo sitio, lo que es una ventaja, pero el `Agent` es quien **construye**
el `.completed`, que es lo que se persiste en la transcripción (`finalAssistantText`). Desde
`HarnessModel` habría que mutar el texto después de recibirlo y además duplicar la lógica en los
dos `catch` de cancelación. El cableado va donde nace el dato.

**Y la escribe la app, no el modelo.** No se le pide al modelo que la escriba y no se le ofrece la
posibilidad: la línea se compone del `status` que devolvió la herramienta. Si el modelo pudiera
redactarla no habría arreglado nada, porque el defecto es justo que su narración no coincide con
los hechos.

### El texto

> Aviso de la app, no del modelo: la última acción sobre la página, `browser_press`, devolvió
> `error` y no se llegó a hacer. Si la respuesta de arriba la da por hecha, no te fíes de esa
> parte; abre la fila de `browser_press` en este turno para ver qué contestó el navegador.

Dice tres cosas y ninguna más: **quién lo dice** (la app), **qué acción** y **con qué estado**, y
**dónde está el detalle** (la fila de la herramienta, que el usuario abre si quiere).

### Las dos salidas que la llevan, y la que no

`Agent.run` entrega la respuesta del modelo en tres sitios. La línea va en dos:

| Salida | ¿Lleva la línea? | Por qué |
| --- | --- | --- |
| El turno termina solo (`isFinal`) | **Sí** | es el camino normal, y el del caso real |
| El turno se queda sin rondas (`iteration == maxIterations - 1`) | **Sí** | si solo la llevara el primero, el defecto volvería por aquí justo en los turnos largos, que son los de navegador |
| El presupuesto de fallos se agotó | **No** | ese camino ya cierra el turno con una línea de la app que nombra la herramienta y las veces que falló (`mensajeDePresupuestoAgotado`): el hecho ya está delante del usuario y repetirlo sería ruido |

La salida por `.failed` no lleva nada: no hay narración del modelo con la que contrastar.

## Cómo se garantiza que el `message` no llega a la pantalla

**Esto es el corazón de la tarea.** Los `message` de las herramientas están redactados para el
MODELO —segunda persona, con instrucciones— y llevar sus instrucciones a la pantalla del usuario
costó su propia rama (ver `ToolSyntaxStreamGate`, y la nota de `toolResultNote` sobre por qué los
argumentos de la llamada ya no vuelven al prompt).

La garantía es **estructural, no una revisión de redacción**: `lineaDeEstadoDelNavegador` solo lee
el resultado a través de `esFallo(resultado:)` y `estadoDelResultado(_:)`. **Nunca llama a
`motivoDelResultado(_:)`**, que es el único accesor del `message` en todo el fichero. El `message`
no está disponible dentro de la función que escribe la línea, así que no puede filtrarse por
descuido de redacción; haría falta añadir una llamada nueva.

Es la misma regla que ya cumple el resumen de la fila de herramienta, y se imitó de ahí: un estado
que pide algo al usuario se resume con una **frase fija de la app** (`ToolLogRow.needsYouText`,
cuyo comentario dice literalmente «Nunca el `message` de la herramienta: esos mensajes están
redactados para el modelo […] y no deben pintarse en la cara del usuario»), y una herramienta sin
dato propio se resume con «listo», no con su `message`.

**El motivo no se pierde para quien lo quiera**: viaja entero al modelo en la nota de resultado
(que es lo que `test_el_error_vuelve_al_modelo_entero_y_sin_recortar` ya clava) y vive en el
`toolDetail` de la fila de la herramienta, que el usuario despliega si quiere leerlo. La línea
nombra esa fila precisamente por eso.

### Cómo se mide, y por qué la medida no es trivial

La prueba del `message` es la más fácil de escribir mal de las tres, porque una afirmación en
negativo verdea de tres maneras sin que nada funcione: **con la línea vacía**, **con un `message`
vacío**, o **con una respuesta que no se construyó**. Por eso
`test_la_linea_de_estado_nunca_imprime_el_message_de_la_herramienta` mide **los dos canales a la
vez sobre el MISMO dato**:

- el motivo (400+ caracteres, el de `FakeBrowserAlwaysFails.motivo`) tiene que estar **entero** en
  el prompt vivo que recibe el modelo en la ronda siguiente;
- y **no** tiene que estar en el texto que el turno entrega al usuario;
- y la respuesta tiene que decir algo **más** que la narración del modelo
  (`XCTAssertNotEqual(respuesta, "Ya te he puesto el video.")`), más la línea no vacía y con el
  nombre de la herramienta dentro.

Se añade una guarda extra: la línea no puede contener `"You "`. No protege de nada hoy, pero
delata al próximo que copie una frase de las notas del prompt vivo a este canal.

## Las tres pruebas, y por qué comparten mutación

Las dos pruebas centrales son **una afirmación y su negación**, que es la trampa de esta tarea:
*«con todo en éxito NO lleva la línea»* verdea trivialmente si el código **nunca** la añade. Las
tres están construidas para morir juntas con la característica borrada:

| Prueba | Qué fija |
| --- | --- |
| `test_la_ultima_accion_fallida_del_navegador_llega_al_usuario_en_la_respuesta` | el CABLEADO: lo que la función produce llega **entero** a la respuesta del usuario (igualdad completa, derivada de producción, **no un ancla de prefijo**) |
| `test_un_turno_de_navegador_en_exito_no_lleva_la_linea_de_estado` | que a lo que funciona no se le pone ruido (igualdad byte a byte con la prosa del modelo) **y** que la función SÍ es capaz de producir línea ante un fallo |
| `test_la_linea_de_estado_nunca_imprime_el_message_de_la_herramienta` | el CONTENIDO: nombra la acción y el estado, nunca el `message`, por los dos canales |

Por qué el reparto cableado/contenido: en la primera prueba **los dos lados de la igualdad salen de
la misma función**, así que una mutación del TEXTO no la pondría roja. La que cubre el texto es la
tercera. Y la de prefijo se evitó a propósito: un ancla de prefijo deja pasar cualquier mutación de
la cola de la frase (ya pasó en esta base de código).

## Tabla de mutaciones → rojos sobre la suite ENTERA

Cada mutación: se neutraliza la línea de producción, se corre la suite completa, se listan los
fallos, se restaura y **se verifica la restauración por `sha256`** contra una copia de seguridad
hecha antes de empezar (el guion aborta si el fichero no está en su estado base, si la mutación no
cambió nada, o si la restauración no restauró; eso cierra las tres maneras en que una mutación ha
mentido en este proyecto esta semana).

| # | Mutación | Rojos **nuevos** sobre la base de 5 |
| --- | --- | --- |
| M2 | `lineaDeEstadoDelNavegador` devuelve siempre `nil` y no hay cableado (= característica borrada; fue la fase ROJA) | **las 3**: `…llega_al_usuario_en_la_respuesta`, `…no_lleva_la_linea_de_estado`, `…nunca_imprime_el_message…` |
| M1 | la línea se calcula pero no se entrega (`entregaLaRespuesta` emite el `.completed` sin tocar) | `…llega_al_usuario_en_la_respuesta`, `…nunca_imprime_el_message…`, `test_un_exito_reinicia_la_cuenta_de_fallos` |
| M3 | la línea **sí** imprime el `message` (`+ motivoDelResultado(resultado)`) | `…nunca_imprime_el_message…` |
| M4 | se cae la guarda `esFallo`: la línea se añade siempre | `…no_lleva_la_linea_de_estado` |
| M5 | `browserGuideFits` mide el prompt vivo **sin** la ronda que se cierra (`rondas: historial`) | **ninguno — sobreviviente, y es equivalente**; ver abajo |

M2 es la mutación que las tres comparten, que es lo que la tarea exigía. M4 es la que hace que la
prueba en negativo no sea gratis.

### M5 sobrevivió, y sobrevivir es lo correcto

No es un agujero: es una **mutación equivalente**, y conviene que quede con los números.

`browserGuideFits` solo cambia de respuesta si el `livePrompt` es pivotal, y hoy no lo es en ningún
camino:

- **Servidor** (el único que corre hoy): `contextTokenBudget == nil` → «cabe» siempre, sin mirar el
  `livePrompt`.
- **On-device**: medido el 2026-11-08 (y afirmado en `test_las_ventanas_reales_del_camino_on_device`),
  prompt del sistema 17.471 B ≈ 5.824 tokens, bloque de la guía 18.002 B ≈ 6.001 tokens → 11.825
  tokens solo entre los dos. Presupuesto de prompt con ventana de 4096 = 3.584; con 8192 = 7.680.
  **No cabe con `livePrompt` vacío**, así que tampoco cabe con uno más grande.

O sea que el valor del `livePrompt` no decide nada en las dos ventanas reales, y montar la prueba
que lo pinchara exigiría un runtime de prueba con una ventana artificial del orden de 13.000 tokens
—un número elegido para que la prueba funcione, no medido de ningún sitio—. No se monta.

## Las tres cosas heredadas de la Tarea 4

### (1) `AgentTests.swift:201` conducía el bucle con un registro VACÍO — **arreglado**

`test_the_browser_note_reaches_the_live_prompt_through_the_loop` pasaba
`registry: ToolRegistry()`. Cada `browser_snapshot` del guion caía en
`Agent.resultadoDeHerramientaInexistente`, que desde que habla el contrato JSON lleva
`status: error`, así que **gastaba presupuesto de fallos** y el turno moría en la quinta ronda. No
mentía, porque la prueba solo lee `prompts[1]`, pero es exactamente la fragilidad que
`BrowserCoreSkillTests` ya diagnosticó y arregló para sí misma con dobles de herramienta: **quien
la extendiera más allá de tres rondas mediría el presupuesto creyendo medir la nota**, y el síntoma
sería un prompt corto, no un error.

Arreglada igual que allí: corre contra `registroDeNavegadorFalsoConSnapshot()` y **la premisa se
afirma en vez de suponerse** —se recogen los resultados de los `.toolCallFinished` y se exige que
ninguno sea `Agent.esFallo`, más que el turno llegó a `Agent.maxBrowserIterations` rondas—. Ahora
el turno recorre las diez rondas de un turno de navegador en lugar de morir en la quinta.

### (2) `browserGuideFits` decidía DENTRO del bucle de acciones — **arreglado**

La decisión vivía dentro del bucle de acciones, contra una ronda a medio construir, así que medía
un prompt **más pequeño que el que de verdad se envía**. Y el hueco era más grande que el que la
Tarea 4 había visto:

- las **notas de cierre** de la ronda, que se añaden después: el aviso de corte de cola (≈ 650 B) o
  el de vueltas en vacío (≈ 690 B). Nunca los dos, porque son disjuntos por construcción;
- y, sobre todo, las **notas de las acciones que vienen DETRÁS** de la primera de navegador en la
  misma ronda. Una ronda de `open` + `snapshot` + `click` metía dos notas más que la medida no veía,
  y una nota con snapshot pesa hasta `BrowserSnapshotTool.snapshotLimit` (8.000 caracteres) + 820 B
  fijos ≈ 8,8 KB. Ahí la subestimación no son 300 tokens: son **~3.000 por cada snapshot de más**.

Arreglado como la Tarea 4 proponía: **se mide una vez, al cerrar la ronda**, con la ronda completa.
Se cierra el mismo agujero para las dos notas de cierre y para las acciones de la cola de una sola
vez. El bucle de acciones ya solo apunta un `laRondaTocoElNavegador = true`.

**Lo que NO cambia, y se comprobó antes de tocar nada:** la posición de la guía en el prompt. No la
decide esta condición, la decide `RondaDelTurno.render`, que pone `guia` **detrás** del texto de la
ronda —o sea detrás de la nota de la herramienta que la pagó—. `BrowserCoreSkillTests.swift:322`
(`indiceNota < indiceGuia`) sigue verde, igual que las cuatro pruebas de «una sola guía por turno» y
las dos de las ventanas.

**No hay fuga medida** en el camino que corre hoy (servidor = sin ventana declarada, más la
estimación de 3 B/token que sobreestima los tokens a propósito), y eso está dicho en el comentario.
Se cambia igualmente: **una medida que se sabe falsa no se deja escrita**, y el día que un runtime
declare una ventana intermedia sí decidiría.

### (3) Por qué `executedMutations` NO se puede extender al navegador — **documentado**

Es documentación, no código, y está **junto a `mutationToolNames`**, que es donde iría a mirar quien
pensara que extenderlo es la mejora obvia.

La razón: una llamada de navegador «idéntica» **no es la misma operación dos veces**. La clave de
`executedMutations` es `nombre + argumentos`, y lo que hace fiable ese freno en `create_event` es
que los mismos argumentos describen el mismo evento siempre. En el navegador no: las referencias
`@eN` **caducan** con cada acción —lo dice `BrowserRules.text` y lo hace cumplir `cortaLaCola`—, así
que `browser_click @e5` en dos rondas apunta **por diseño** a elementos distintos. Negar la segunda
sería negarle al modelo el paso siguiente de la tarea por una igualdad de bytes que aquí no
significa nada; y al contrario, dos clics sobre el MISMO elemento con dos `@eN` distintas pasarían
el freno sin que se notara.

Un freno de repetición para el navegador tendría que ser por igualdad de **elemento**, y el bucle
hoy no la conoce: lo único que recibe de vuelta es el `status`, el `message` y a veces la `url`,
nunca una identidad estable del elemento sobre el que actuó. Mientras eso no exista, lo que cubre al
navegador es `pareceAtascado` (Tarea 4), que no niega nada y solo mira las LECTURAS, donde la
igualdad de argumentos sí es concluyente.

## Un detalle de cableado que no era obvio

`HarnessModel.consumeAgentEvents` se queda con el `text` del `.completed` **cuando no está vacío** y
con los tokens acumulados cuando sí lo está:

```swift
let chosen = !res.text.isEmpty ? res.text : answer
```

Así que la línea tiene que viajar por **los dos canales** (`.token` y `.completed`) o se cae por el
hueco según el runtime. Y cuando el `text` viene vacío **no se rellena con la línea sola**: eso
convertiría un `text` vacío en uno con contenido, la interfaz dejaría de mirar los tokens, y la
respuesta visible del modelo se perdería dejando solo el aviso. Es el tipo de fallo que habría
aparecido en producción y no en los tests, porque `ScriptedRuntime` siempre devuelve `text`.

El `.token` es seguro frente a `GemmaToolCallParser.strip`: la línea no contiene ninguno de los
marcadores que esa función recorta. Es otra razón para que esta línea **no** vaya envuelta en
`[...]`, que es la convención de las notas del prompt vivo.

## Recuento de pruebas

| | Fallos |
| --- | --- |
| Base (`6572bd3`) | **5** |
| Fase roja (stub) | 8 = 5 + mis 3 |
| **Después** | **5** — las mismas cinco de siempre |

Las cinco de siempre: `AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`,
`ContactAliasStoreTests` (×2), `ForgetToolTests.test_forget_calls_endpoint_and_returns_count`,
`ReminderCRUDToolTests.test_update_mueve_la_hora`.

Contados con el censo del encargo, no a ojo:

```
xcodebuild -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' test 2>&1 \
  | grep -E "^Test case" | grep "' failed" | sed 's/ on .*//' | sort -u
```

### El sexto, que era mío

`test_un_exito_reinicia_la_cuenta_de_fallos` afirmaba `visto.completados == ["listo"]`. En ese
guion la **última** acción de navegador del turno es una pulsación fallida, así que la respuesta
ahora lleva la línea. No es un daño colateral: es **exactamente el caso para el que la línea
existe** —el modelo dice «listo» después de que la última acción sobre la página fallara—. La
aserción se actualizó a `["listo\n\n" + linea]`, con la línea derivada de producción, y la intención
original de la prueba (el éxito del medio reinicia el contador, el turno no muere por el
presupuesto) se conserva intacta. Sirve además como tercer punto de cableado: M1 la pone roja.

## Lo que se descubre fuera de esta tarea

1. **`ToolLogRow.summarize` SÍ pinta el `message` en la fila plegada cuando el estado es de fallo.**
   La rama es `return .failure(clip(message.isEmpty ? status : message))`, con `clip` a 120
   caracteres. O sea que la regla «el `message` está escrito para el modelo y no se pinta en la cara
   del usuario» —que el propio fichero enuncia dos veces, en `needsYouText` y en la rama
   `case nil`— **no se cumple justo en el caso del fallo, que es el que más se ve**. No se toca
   aquí: es la fila de herramienta, no es la línea de esta tarea, y cambiarlo dejaría al usuario sin
   ninguna pista de qué falló en la fila. Pero la incoherencia conviene resolverla a propósito, en
   un sentido o en el otro, y no por omisión.

2. **El `message` también viaja al usuario en `mensajeDePresupuestoAgotado`**, que incluye
   `motivoDelResultado(resultado)` con el texto íntegro del `message`. Es deliberado y está
   razonado ahí («dice QUÉ pasó y, cuando el resultado lo declara, POR QUÉ»), pero significa que la
   regla de esta tarea es **de esta línea**, no del proyecto. Si se quiere que sea del proyecto,
   `mensajeDePresupuestoAgotado` es el otro sitio que hay que revisar.

3. **La línea no distingue un `refused` del candado de cierre de un fallo de verdad.**
   `Agent.estadosDeFallo` incluye `refused` a propósito (un modelo que insiste contra el candado es
   el que da vueltas), así que un turno cuya última acción de navegador fuera un `browser_close`
   rechazado le diría al usuario que «no se llegó a hacer» — lo cual es **cierto** pero puede leerse
   como un error cuando es la conducta correcta de la app. No se arregla aquí porque el caso es raro
   (el prompt le dice al modelo que no cierre, y el candado existe para cuando lo intenta de todas
   formas) y porque la alternativa —sacar `refused` del conjunto solo para esta línea— metería un
   segundo criterio de fallo en el fichero. Queda anotado.

4. **Desviación del plan, declarada:** el plan pedía las pruebas en
   `Gemma/GemmaTests/AgentSystemPromptTests.swift`. Están en `Gemma/GemmaTests/AgentTests.swift`,
   porque toda la infraestructura que estas pruebas necesitan vive allí y es `private`
   (`ScriptedRuntime` con su `prosa`, los dobles de navegador, `registroConLaQueFalla()`, el
   ayudante `ejecuta`). Replicarla en el otro fichero habría duplicado ~120 líneas de dobles para
   medir lo mismo. `AgentSystemPromptTests` mide el prompt del sistema; esto no es prompt, es la
   respuesta al usuario, así que `AgentTests` —donde ya se mide la conducta del bucle— es además el
   sitio con más sentido.
