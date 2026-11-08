# Tarea 2 — Presupuesto de fallos consecutivos, contado POR ACCIÓN

Rama `diag/panel-se-muere`, base `046df5e`. Ficheros tocados:

- `Gemma/Gemma/Agent/Agent.swift` — el presupuesto, los predicados puros y la salida del turno.
- `Gemma/GemmaTests/AgentTests.swift` — once pruebas nuevas.
- `Gemma/GemmaTests/AgentBrowserRegistrationTests.swift` — la propina (la lista de nueve
  nombres escrita a mano).
- `Gemma/GemmaTests/BrowserCrossPlatformTests.swift` — el mismo defecto de la propina en un
  cuarto sitio, que lo destapó la campaña de mutación (ver M13).

## Qué se añadió

El bucle de `Agent.run(prompt:options:)` no tenía presupuesto de fallos ninguno: una
herramienta podía devolver `error` una vez y otra hasta agotar las rondas del turno (diez, en
un turno que haya tocado el navegador), y lo que el usuario veía era el agente dando vueltas
sin avanzar y terminando con un `tool loop did not converge` que no le dice nada a nadie.

Interfaz nueva, toda en `Agent`:

| Nombre | Qué es |
|---|---|
| `maxConsecutiveFailures = 5` | el tope, con su motivo escrito al lado |
| `estadosDeFallo` | `error`, `refused`, `not_available` — los que gastan presupuesto |
| `estadosDeExito` | `success`, `no_content` — los que lo reinician |
| `esFallo(resultado:) -> Bool` | pura; `false` para todo lo que no se supo leer |
| `esExito(resultado:) -> Bool` | pura; la contraria NO es la negación de la anterior |
| `mensajeDePresupuestoAgotado(herramienta:fallos:resultado:)` | el texto con el que el turno termina |
| `motivoDelResultado(_:)` | el `message` que un resultado declara, o `nil` |

El contador vive **fuera del bucle de rondas** y sube **por acción ejecutada**. Eso es la
mitad del arreglo: en browser-use (`_post_process`) el contador solo sube si el paso tuvo
*exactamente una* acción, así que un paso con cinco acciones todas fallidas cuenta cero. Su
tope acota el caso bueno —un paso, una acción— y deja libre el malo. Aquí el peor caso es
justo el que queda acotado, y la prueba que su implementación no pasaría es
`test_cinco_acciones_fallidas_en_una_sola_ronda_agotan_el_presupuesto`.

Dos cosas que el encargo fijaba y que están comprobadas, no asumidas:

- **El error vuelve al modelo entero.** `toolResultNote` ya interpolaba el `result` completo;
  lo que faltaba era que nadie lo pudiera "optimizar" sin que se enterase una prueba. Lo
  clava `test_el_error_vuelve_al_modelo_entero_y_sin_recortar` con un motivo de 446
  caracteres, y el porqué está escrito en el comentario de `toolResultNote` (el `message` de
  nuestras herramientas lleva el motivo, las instrucciones de instalación o el valor que el
  CLI rechazó, y todo eso vive justo en el medio que browser-use corta).
- **Al agotarse, el turno termina con un mensaje para el usuario.** `.token` + `.completed`,
  no `.failed` y no una excepción: el usuario tiene derecho a que se le diga que se ha parado
  y por qué, no a una fila roja con el nombre de un tipo de Swift.

## Las dos decisiones difíciles

### (2) Una acción que falla **y además** cambia la página

**Gasta presupuesto y NO corta la cola.** Son dos hechos independientes sobre la misma
acción, luego la respuesta de salón es «las dos cosas pasan» — y es la que yo también daba
antes de mirar. Contra el código real solo pasa una, y no por descuido: `cortaLaCola` exige
`status == "success"` porque **una acción que falló no actuó, y lo que no actuó no pudo
invalidar ninguna `@eN`**. La cola de detrás sigue siendo tan buena (o tan mala) como era.

La duda que había que resolver antes de darle la razón a nadie era la que el encargo plantea:
un `browser_click` que navega y devuelve error puede ser un clic que **sí funcionó** y cuyo
acuse se perdió al cambiar la página; si eso fuera frecuente, gastar presupuesto castigaría
al modelo por acertar. **Está medido y no es así.** En `BrowserInteractionTools.swift` (clic:
líneas ~98-107) la herramienta devuelve `error` solo cuando el propio comando `click` del CLI
falló, es decir cuando `AgentBrowserToolOutput.resolve` devolvió `.failure`; y el caso del
«acuse perdido» —la acción funcionó pero el `get url` que viene detrás no— devuelve
`success` **sin** la clave `url`, no `error` (ver `InteractionSupport.urlPosterior`, que
devuelve `nil` y entonces la clave se omite). O sea que el fallo que gasta presupuesto es un
fallo de verdad.

Queda un único hueco honesto: `.malformed` (el CLI devolvió algo ilegible y la acción pudo
haber ocurrido) se mapea a `status: error`. Es raro y ya era indistinguible antes de esto.

Consecuencia agradable y verificada: **las dos salidas son disjuntas por construcción.** Un
fallo nunca corta la cola, y un éxito reinicia el contador, así que la acción que corta la
cola no puede ser nunca la que agota el presupuesto. Lo recorre
`test_una_accion_que_falla_con_url_nueva_gasta_presupuesto_pero_no_corta_la_cola`, que además
lo comprueba por la vía larga: el clic falla con una URL distinta y el `browser_fill` de
detrás **sí** se ejecuta.

No se tocó `cortaLaCola`.

### (3) El tope alcanzado en la misma ronda en que se agotan las iteraciones

**Gana el presupuesto, y sale un mensaje: ni dos ni ninguno.** La salida por presupuesto está
antes en el cuerpo de la ronda y termina con `break loop`, así que la rama de la no
convergencia (`iteration == maxIterations - 1`) no se llega a ejecutar.

Gana **por una razón y no por el orden en que se escribió**: dice algo cierto y concreto
—esta herramienta ha fallado cinco veces seguidas y esto fue lo que devolvió— mientras que la
otra solo sabe decir «tool loop did not converge», que no es información para nadie.

La prueba (`test_el_presupuesto_gana_a_la_salida_por_iteraciones_y_el_usuario_recibe_un_mensaje`)
construye la colisión **sin depender de que los dos números coincidan**: todas las rondas
menos la última tienen éxito, y la última trae de golpe las `maxConsecutiveFailures` acciones
fallidas. Así sigue colisionando si mañana cambia `maxIterations` o el tope. Afirma las tres
cosas: `fallados == []` (no sale el `.failed`), `completados.count == 1` (un mensaje) y que
ese mensaje es el del presupuesto.

Hay una tercera decisión, menor, que también se tomó aquí: **la acción pendiente de la ronda
no se ejecuta, pero su `.toolCallFinished` ya salió** antes del corte, así que la fila de la
herramienta se cierra en el registro del chat y no se queda abierta para siempre.

## Lo que el presupuesto NO cuenta, y por qué

`esFallo` devuelve `false` para todo lo que no se supo leer: un resultado que no es un objeto
JSON, uno sin `status`, o uno con un `status` que no está en ninguno de los dos conjuntos. Es
la dirección segura fija del proyecto aplicada aquí, y aquí tiene un filo particular: **la
acción que este valor desencadena es matar el turno del usuario**, así que un valor que no se
supo leer nunca se convierte en esa acción.

`esFallo` y `esExito` **no son complementarios**, y eso es deliberado: hay un tercer estado
—no se pudo leer— que ni gasta presupuesto ni lo reinicia. Escribir uno como la negación del
otro metería ese tercer estado en el lado equivocado, y los dos lados son malos: negar
`esExito` mataría turnos por resultados ilegibles, y negar `esFallo` reiniciaría el contador
con ellos y volvería el presupuesto inoperante justo contra el fallo repetido que no sabemos
leer.

El precio de esa elección está en «Hallazgos», punto 1.

## Tabla de mutaciones

Trece mutaciones, una a la vez, suite **entera** en cada una, restaurando después. El ancla
de cada mutación se comprobó presente **exactamente una vez** antes de aplicarla (una
mutación cuyo ancla es prefijo de la línea nueva produce código equivalente y *parece*
sobrevivir sin haber mutado nada; aquí no pasó, pero el guion lo habría dicho).

Los rojos de la tabla son los **nuevos**, descontados los 7 preexistentes.

| # | Mutación (línea de producción neutralizada) | Rojos nuevos |
|---|---|---|
| M1 | `fallosConsecutivos += 1` → `+= 0` (el contador no sube) | `cinco_acciones_fallidas_en_una_sola_ronda`, `el_presupuesto_gana_a_la_salida_por_iteraciones`, `un_resultado_ilegible_no_reinicia` |
| M2 | `if presupuestoAgotado != nil { break }` → sin `break` (la ronda sigue ejecutando acciones) | `cinco_acciones_fallidas_en_una_sola_ronda` |
| M3 | `fallosConsecutivos = 0` → `+= 0` (el éxito no reinicia) | `un_exito_reinicia_la_cuenta_de_fallos` |
| M4 | `esFallo`: el `guard … else { return false }` → `return true` (lo ilegible gasta) | `un_resultado_ilegible_no_es_exito_ni_fallo`, `un_resultado_ilegible_no_reinicia`, `a_turn_that_touches_the_browser_gets_a_bigger_iteration_budget` |
| M5 | `esExito`: el `guard … else { return false }` → `return true` (lo ilegible reinicia) | `un_resultado_ilegible_no_es_exito_ni_fallo`, `un_resultado_ilegible_no_reinicia` |
| M6 | la salida por presupuesto: `break loop` → `()` (el turno no termina y cae a la salida por iteraciones) | `cinco_acciones_fallidas_en_una_sola_ronda`, `el_presupuesto_gana_a_la_salida_por_iteraciones`, `un_resultado_ilegible_no_reinicia` |
| M7 | `mensajeDePresupuestoAgotado`: la rama `if let motivo` nunca entra | `el_mensaje_de_presupuesto_agotado_dice_la_herramienta_las_veces_y_el_motivo` |
| M8 | `toolResultNote`: `\(result)` → `\(String(result.prefix(100)))` (el recorte de browser-use) | `el_error_vuelve_al_modelo_entero_y_sin_recortar` |
| M9 | `estadosDeFallo` → `[]` (ningún estado gasta presupuesto) | `cinco_acciones_fallidas_en_una_sola_ronda`, `el_presupuesto_gana_a_la_salida_por_iteraciones`, `los_estados_de_fallo_y_de_exito_son_el_contrato_real`, `un_resultado_ilegible_no_reinicia`, `una_accion_que_falla_con_url_nueva` |
| M10 | `var resultsNote = currentPrompt` → `+ "\n\n[fallos: 0]"` (el prompt vivo paga un token nuevo) | `un_turno_limpio_sin_navegador_no_paga_un_solo_token_nuevo` |
| M11 | `estadosDeExito` += `timeout` (un estado que el chat pinta en rojo reinicia el presupuesto) | `lo_que_gasta_presupuesto_sale_con_cruz_roja_en_el_chat` |
| M12 | `cortaLaCola`: el `guard … == "success"` → siempre pasa (un fallo corta la cola) | `una_accion_que_falla_con_url_nueva`, `cortaLaCola_la_duda_no_corta`, `BrowserCoreSkillTests.tres_llamadas_de_navegador_en_una_ronda_siguen_llevando_la_guia_una_vez` |
| M13 | `registerBrowserTools`: se borra el registro de `BrowserCloseTool` | `AgentBrowserRegistrationTests.the_browser_tools_are_registered`, `…adds_the_browser_tools`, `AgentTests.browser_tool_note_lets_the_model_keep_driving_the_page`, `BrowserCrossPlatformTests.las_herramientas_de_navegador_se_registran_en_cualquier_plataforma` |

Trece de trece se pusieron rojas; ninguna sobrevivió, así que no hubo que ir a mirar si la
mutación había mentido. Dos cosas que la campaña enseñó de propina:

- **M4 enrojece `test_a_turn_that_touches_the_browser_gets_a_bigger_iteration_budget`**, que
  no es mío. Tiene sentido y confirma el hueco del punto 1 de «Hallazgos»: ese test usa
  `RepeatingToolRuntime` con el registro vacío, así que todos sus resultados son el
  `error: no tool named …` ilegible. Con la implementación correcta no gastan presupuesto (y
  el test pasa); si lo ilegible gastara, el turno moriría en la ronda 5 en vez de llegar a
  las diez. O sea que la decisión de no contar lo ilegible es justo la que mantiene ese
  test verde — y es la misma decisión que deja el hueco.
- **M13 descubrió un cuarto sitio con el mismo defecto de la propina:**
  `BrowserCrossPlatformTests.swift:98` afirmaba `tools.count == 9` con el `9` escrito a mano.
  Arreglado igual, derivándolo de `Agent.browserToolNames.count + 1` (el nombre del test
  también decía «nueve»).

## Recuento antes / después

| | Fallos únicos |
|---|---|
| Base (`046df5e`, antes de tocar nada) | **7** |
| Después | **7** |

Los mismos siete, uno por uno:
`AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`,
`ContactAliasStoreTests` (×2), `ForgetToolTests.test_forget_calls_endpoint_and_returns_count`,
`ReminderCRUDToolTests.test_update_mueve_la_hora`, `ToolJSONEscapingTests` (×2).

Contados con el `grep` del encargo, no a ojo.

## La propina: `AgentBrowserRegistrationTests`

La lista de nueve nombres escrita a mano (`:14`) ya no existe. Lo que el test afirma ahora es
la propiedad que importa, y respeta la diferencia que la lista escondía en vez de borrarla:

```swift
private var esperadas: Set<String> { Agent.browserToolNames.union(["read_webpage"]) }
```

Nueve registradas, ocho de navegador. `read_webpage` se registra por este mismo camino
(comparte el `AgentBrowserService`) sin ser una de las que conducen una página: es de una sola
llamada y el bucle la trata como cualquier otra herramienta del registro. Si mañana aparece
una novena herramienta de navegador, entra sola en cuanto se añada a `browserToolNames`; y si
alguien la registra **sin** añadirla ahí, el fallo dice exactamente qué nombre sobra o falta,
en vez del «9 != 10» que no nombra nada. Los dos nombres de test que decían «nine» se
renombraron.

Y había un cuarto sitio con el mismo defecto, que yo no habría encontrado leyendo:
`BrowserCrossPlatformTests.swift:98` afirmaba `HarnessModel.browserToolRegistry().tools.count
== 9` con el `9` a mano (y el nombre del test decía «las nueve herramientas»). Lo destapó la
mutación M13 al borrar un registro: tres tests dijeron qué nombre faltaba y ese dijo
«9 != 8». Ahora deriva de `Agent.browserToolNames.count + 1` igual que los otros.

## Hallazgos fuera de la tarea

### 1. El resultado que el propio bucle fabrica no es JSON, y por eso no gasta presupuesto

`Agent.swift:654` — cuando el modelo llama a una herramienta que no existe, el bucle devuelve
`error: no tool named <nombre>`, que no es JSON. Por la dirección segura, `esFallo` lo deja
pasar: **un modelo que insiste en llamar a una herramienta inexistente sigue pudiendo dar
vueltas hasta el tope de rondas.** Es un hueco real del presupuesto y está anotado en el
comentario de `esFallo`.

No lo arreglé porque arreglarlo bien significa que ese resultado hable el mismo contrato que
los demás (`{"status":"error","message":"no tool named …"}`), y eso cambia un literal del que
cuelgan pruebas de otra tarea de esta rama (`test_cortaLaCola_la_duda_no_corta` lo usa como su
ejemplo canónico de resultado ilegible). Es un cambio de una línea más el ajuste de esas
pruebas; decide quien lleve el plan.

### 2. `Agent.estadosDeFallo` (3 estados) vs `ToolLogRow.failureStatuses` (21)

`ToolLogRow.swift:68` tiene un censo de veintiún estados de fallo, hecho con un grep sobre
toda la app, que es el que decide si la fila del chat sale con cruz roja. **No lo reutilicé, a
propósito:** la mitad de los suyos significan «la herramienta contestó, y la respuesta es que
no» (`not_found`, `contact_not_found`, `unknown_topic`, `not_in_catalog`), y un turno en el
que el modelo consulta cinco cosas que no existen está trabajando, no dando vueltas. Matarlo
sería peor que el defecto que esto arregla.

Pero la frontera no está donde a mí me gustaría del todo: hay estados de infraestructura de
otras herramientas —`timeout`, `unavailable`, `memory_unavailable`, `permission_denied`,
`failed`— que sí significan «no pude hacerlo» y que **hoy no gastan presupuesto**. Dejarlos
fuera es la dirección segura (el presupuesto mata turnos), pero es una decisión revisable de
una línea. Si se amplía, el criterio a aplicar está escrito en el comentario de
`estadosDeFallo`: entra lo que significa «la herramienta NO PUDO hacerlo», no lo que significa
«la herramienta contestó que no».

Lo que sí quedó clavado es que los dos conjuntos no se contradigan:
`test_lo_que_gasta_presupuesto_sale_con_cruz_roja_en_el_chat` exige que todo lo que gasta
presupuesto se pinte como fallo en la fila, y que nada de `estadosDeExito` se pinte como
fallo. Un turno que muere por un estado que el chat pintaba en verde sería inexplicable para
quien lo está mirando.

### 3. Un `browser_open` FALLIDO reescribe la URL conocida con una página que nunca se abrió

Esto es un bug latente del corte de cola, no mío, y conviene arreglarlo antes de que muerda.

`BrowserNavigationTools.swift:41` — el camino de fallo de `browser_open` es
`AgentBrowserToolOutput.resolve(outcome, extra: ["url": url])`, donde `url` es la **pedida**.
O sea que un `open` que falla devuelve `{"status":"error","url":"https://b.test/","message":…}`.

Y `Agent.swift:710` hace esto **sin mirar el estado**:

```swift
if let url = Self.urlDelResultado(result) { urlConocidaDelNavegador = url }
```

El comentario de `urlDelResultado` dice que devuelve «la URL que un resultado de herramienta
de navegador DEMUESTRA», y en este camino no demuestra nada: demuestra lo contrario.
Consecuencia concreta: si estamos en `a.test` y un `open https://b.test` falla,
`urlConocidaDelNavegador` pasa a valer `b.test`. Si después un `browser_click` navega de
verdad de `a.test` a `b.test`, su `url` posterior coincide con la "conocida" y **el corte no
se dispara**: la cola de detrás se ejecuta contra la página nueva con las `@eN` viejas, que es
exactamente el defecto que el corte existe para evitar.

Arreglo propuesto, una línea y dentro de la filosofía ya escrita en `cortaLaCola` («la duda no
corta», «un valor que no se supo leer nunca se convierte en un corte»): actualizar la URL
conocida **solo** cuando el resultado fue un éxito.

```swift
if Self.esExito(resultado: result), let url = Self.urlDelResultado(result) {
    urlConocidaDelNavegador = url
}
```

No lo apliqué porque el encargo dice explícitamente que el corte de cola no se toca, y esta
línea es suya. Pero `esExito` ya existe ahora, así que el arreglo es literalmente la condición
de arriba más una prueba.
