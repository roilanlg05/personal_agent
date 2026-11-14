# Tarea 4 — Detectar vueltas en vacío en las acciones que NO mutan

Rama `diag/panel-se-muere`, base `d168cd7`.

## Qué se ha añadido

Tres piezas, dos ficheros de producción:

| Pieza | Fichero | Qué es |
| --- | --- | --- |
| `Agent.AccionEjecutada` (+ `huella`) | `Gemma/Gemma/Agent/Agent.swift` | el par `(nombre, argumentos)` de una llamada que la ronda procesó, con su identidad normalizada |
| `Agent.vueltasEnVacioParaAvisar` = 3 | `Gemma/Gemma/Agent/Agent.swift` | el umbral |
| `Agent.pareceAtascado(historial:)` + `Agent.repeticionesDeLecturaAlFinal(_:)` | `Gemma/Gemma/Agent/Agent.swift` | la decisión, pura y estática |
| `BrowserRules.spinningWheelsNote(herramienta:veces:)` | `Gemma/Gemma/Agent/BrowserRules.swift` | el texto que el modelo lee |
| acumulador `accionesDelTurno` + el aviso al cierre de la ronda | `Agent.run(prompt:options:)` | el cableado |

## El criterio, y por qué ese y no otro

> **Gira en vacío el turno cuya COLA de acciones es la MISMA lectura de la página —mismo nombre
> y mismos argumentos— repetida tres veces seguidas sin nada en medio.**

Cuatro decisiones, y cada una tiene su alternativa descartada.

### (1) Solo las LECTURAS. Esa es la línea, no una timidez

El conjunto que se mira es `Agent.browserReadOnlyToolNames` = `browser_snapshot`,
`browser_get`, `browser_wait`.

El argumento no es «las acciones ya las cubre otro freno» (que además sería falso a medias, ver
los hallazgos). El argumento es que **una lectura repetida no puede ser otra cosa que una vuelta
en vacío, y una acción repetida sí**:

- `browser_snapshot` con los mismos argumentos, sobre una página que nadie ha tocado entre
  medias, devuelve lo mismo. Por definición de leer. No hay una historia inocente que contar.
- Tres `browser_click` idénticos sobre el mismo `@eN` **sí** tienen historia inocente, y es
  frecuente: «dale tres veces al `+` de la cantidad», «pulsa "ver más" hasta que salgan todos».
  Marcar eso sería acusar en falso al modelo por hacer exactamente la tarea.

Esa asimetría es la que decide el conjunto, y es la que hace que el detector y
`executedMutations` no se solapen: la negativa dura se queda para lo que cambia el mundo, la
detección blanda para lo que no puede haberlo cambiado.

El conjunto está escrito **en positivo** (las que leen), igual que ya lo estaba para el corte de
cola, y aquí eso vuelve a caer del lado barato: una herramienta de navegador nueva que nadie
añada a la lista se trata como si actuara, luego nunca se la acusa de girar en vacío.

### (2) La MISMA llamada = mismo nombre Y mismos argumentos

Tres `browser_get` de tres selectores distintos son tres preguntas distintas y avanzan. Tres del
mismo selector son la misma pregunta tres veces. Sin los argumentos no se puede distinguir una
cosa de la otra, y el detector degeneraría en «el modelo ha leído tres veces», que es
comportamiento normal.

Esto hay que decirlo con cuidado por lo que aterrizó en la tarea 3: **el historial que el modelo
lee ya no lleva el JSON de sus propias llamadas** (`Agent.modelProseNote`: ve su prosa y los
resultados). Lo comprobé antes de escribir nada, y lo que la tarea 3 quitó es el viaje al prompt,
no el dato: el bucle sigue teniendo `tc.args` en la mano en `pendingToolCalls`. Son **dos
historiales distintos** — el del modelo y el del bucle — y `pareceAtascado` trabaja sobre el
segundo. El acumulador `accionesDelTurno` no añade ni un byte al prompt.

La identidad (`AccionEjecutada.huella`) normaliza **solo** el espacio en blanco de los bordes, y
de menos a propósito: normalizar de menos pierde una detección y el turno sigue exactamente como
seguía antes de que esto existiera; normalizar de más declara iguales dos llamadas que no lo eran
y le dice al modelo que se repite cuando no se repetía. Un salto de línea de sobra nunca es una
diferencia semántica en un JSON de argumentos; cualquier cosa más lista que eso sí podría serlo.

### (3) Tres, no dos

Dos lecturas idénticas seguidas tienen explicación inocente de sobra: la página todavía estaba
pintando y el modelo vuelve a mirar. Avisar ahí sería regañarle por tener paciencia. A la tercera
ya no queda explicación: entre medias no se ejecutó nada, luego la página no se ha movido, luego
la tercera lectura devolvió lo mismo que la primera y la cuarta devolverá lo mismo otra vez.

No es un tope: no corta el turno, no retira herramientas y no gasta presupuesto de fallos. Los
topes de este bucle son otros tres y están en otro sitio (`maxConsecutiveFailures`,
`maxIterations`, `maxBrowserIterations`).

### (4) La COLA del historial, no cualquier parte de él

La racha se cuenta desde la última acción hacia atrás. Dos consecuencias buscadas:

- un turno que se atascó al principio y salió solo no tiene por qué oír hablar de ello;
- un turno que acaba de **actuar** no está mirando en vacío, por muchas lecturas que llevara
  detrás (`repeticionesDeLecturaAlFinal` devuelve 0 si la última acción no es una lectura).

El aviso tiene que describir el presente o no sirve de nada.

## Cómo se evita marcar el ciclo correcto — el corazón de la tarea

`BrowserRules.text` le **enseña** al modelo este ciclo: `browser_open` → `browser_snapshot` →
actuar sobre un `@eN` → `browser_snapshot` otra vez, «because the `@eN` references change after
every action». Y `cortaLaCola` lo hace cumplir a la fuerza. Marcar ese ciclo como bucle sería
decirle que se equivoca justo cuando hace lo correcto, y eso es estrictamente peor que no mirar
nada: el modelo que recibe un aviso al hacer lo que se le pidió se disculpa y se para.

La protección no es un caso especial ni una lista de excepciones. **Es estructural**: el ciclo
que el prompt enseña tiene SIEMPRE una acción entre dos miradas, así que la racha de lecturas
idénticas se rompe en cada vuelta y no llega nunca a tres. `snapshot → click → snapshot` tiene
racha 1. `snapshot, snapshot, click, snapshot` tiene racha 1. `snapshot, snapshot, snapshot,
click` tiene racha 0 (la última no es lectura). Solo la racha ininterrumpida cuenta, y en el
ciclo enseñado nunca hay racha.

Y está clavado como prueba, no como comentario:
`test_el_ciclo_que_el_prompt_ensena_no_gira_en_vacio` afirma los tres `false` **y** el `true` que
sale de quitar la acción de en medio, en la misma prueba. Eso es deliberado: un `false` solo se
cumple con la característica borrada (es el valor por omisión de un `Bool`), así que las dos
mitades tienen que compartir mutación o la prueba no prueba nada. Lo mismo en las otras tres
pruebas puras: cada una lleva su mitad `true`.

## Lo que el aviso dice, y lo que NO hace

El texto vive en `BrowserRules.spinningWheelsNote`, que es la única fuente de nuestras reglas del
navegador. Dice tres cosas:

1. **Qué lleva repitiendo**: la herramienta por su nombre y las veces (las de verdad — si el
   modelo pidió cinco lecturas idénticas en una ronda, lee «cinco», no «tres»).
2. **Por qué no avanza**: leer una página que nadie ha tocado devuelve lo mismo, así que la
   llamada siguiente le dirá lo que ya le dijo la primera.
3. **Las dos salidas que existen de verdad**: actuar sobre un `@eN` del snapshot que ya tiene
   (con `browser_click`, `browser_fill`, `browser_press` — lista DERIVADA de los conjuntos de
   `Agent`, no escrita a mano, por el mismo motivo que `toolInventoryNote`), o decir que lo que
   el usuario pidió no está en esta página y contestarle con lo que ya sabe.

Y termina diciéndole explícitamente que **no le han quitado nada**. Eso no es relleno: el encargo
fija que al detectarlo NO se retiran las herramientas, y un aviso que suena a castigo produce
justo el comportamiento que el proyecto ya tiene documentado como fallo (el modelo se disculpa y
abandona). La retirada ya existe por mutación ejecutada y por cercanía al tope de rondas;
adelantarla aquí le quitaría el navegador a mitad de una tarea legítima pero **lenta**, y lenta es
lo normal en un navegador remoto sobre una conexión doméstica.

## Dónde entra en el bucle, y los tres encajes con lo que ya había

El aviso se añade **una vez y al final de la ronda**, justo antes de cerrar el historial:

- *al final* porque la ronda es lo último que el modelo lee antes de decidir el paso siguiente;
- *una sola vez* porque dentro del bucle de acciones se repetiría tantas veces como lecturas
  trajera la ronda, y tres copias del mismo aviso son ruido.

El acumulador apunta **toda** llamada que la ronda procesa, incluida la que no se llegó a
ejecutar (una mutación repetida que el bucle atajó con `DUPLICATE_CALL_IGNORED`, o una
herramienta que no existe). Lo que la detección necesita saber es si entre dos lecturas pasó
algo, y una llamada atajada también pasó: apuntar solo lo ejecutado haría que dos lecturas con un
`DUPLICATE_CALL_IGNORED` en medio parecieran seguidas.

Tres encajes, todos comprobados:

- **No se estorba con el corte de cola.** El corte solo ocurre detrás de una acción con `success`
  que movió la página; entonces la última acción del turno no es una lectura, luego la racha es
  0. Disjuntos por construcción.
- **No se estorba con el presupuesto de fallos.** El aviso no se emite si el presupuesto se agotó
  en esta ronda (`presupuestoAgotado == nil` en la guarda): ese camino cierra el turno con su
  propio mensaje al usuario, y un segundo aviso no lo leería nadie. El caso existe: cinco lecturas
  idénticas que devuelven `error` agotan el presupuesto *y* hacen racha.
- **No cambia el orden del prompt vivo, y eso se verificó ANTES.**
  `BrowserCoreSkillTests.swift:322` afirma `indiceNota < indiceGuia`. El aviso se añade a
  `ronda.texto`, y `RondaDelTurno.render` es `texto + "\n\n" + guia`, así que la guía sigue
  DETRÁS. El orden queda nota de resultado → aviso → guía oficial. Esa prueba no se tocó y sigue
  verde.

## Las pruebas

Cinco, en `Gemma/GemmaTests/AgentTests.swift`. Cuatro puras (sin bucle, sin red, sin modelo) y
una por el bucle entero.

| Prueba | Qué afirma |
| --- | --- |
| `test_tres_lecturas_identicas_seguidas_giran_en_vacio_y_dos_no` | el umbral: `true` con tres, `false` con dos, con una y con ninguna |
| `test_el_ciclo_que_el_prompt_ensena_no_gira_en_vacio` | `snapshot → click → snapshot` NO está atascado; la acción rompe la racha esté donde esté; y el `true` que sale de quitarla |
| `test_lo_que_cambia_algo_no_entra_por_la_deteccion_de_vueltas_en_vacio` | cinco `create_event` idénticos y cinco clics idénticos NO entran; cinco lecturas sí; y las TRES lecturas del contrato cuentan, no solo el snapshot |
| `test_argumentos_distintos_son_lecturas_distintas` | tres selectores distintos avanzan; el mismo tres veces no; el espacio en blanco de los bordes no hace una llamada distinta |
| `test_la_tercera_lectura_identica_trae_el_aviso_y_no_retira_las_herramientas` | por el bucle: la ronda 3 NO lleva aviso, la 4 sí, nombra la herramienta y las veces, y en la ronda del aviso las herramientas de navegador SIGUEN ahí |

La última necesitó una adición al doble que ya había: `ScriptedRuntime` ahora apunta
`herramientasPorRonda` (los nombres de las herramientas que el bucle le ofreció en cada ronda).
Es la única manera de comprobar desde fuera que una ronda NO perdió el navegador, y era
imprescindible: la mitad del encargo es «no se retiran las herramientas», y eso no se puede
afirmar mirando solo el prompt.

## Mutación → rojos, sobre la suite ENTERA

Seis mutaciones, una por línea de producción de la que depende alguna aserción. Cada una:
neutralizar, correr `xcodebuild … test` completo, contar, restaurar. Ninguna sobrevivió.

| # | Mutación (línea de producción neutralizada) | Rojas NUEVAS (además de las 5 de base) |
| --- | --- | --- |
| M1 | `pareceAtascado` → `false` siempre | **5**: `…giran_en_vacio_y_dos_no`, `…el_ciclo_que_el_prompt_ensena…`, `…lo_que_cambia_algo…`, `…argumentos_distintos…`, `…la_tercera_lectura_identica…` |
| M2 | `vueltasEnVacioParaAvisar` 3 → 2 | **2**: `…giran_en_vacio_y_dos_no`, `…la_tercera_lectura_identica…` |
| M3 | fuera la guarda `browserReadOnlyToolNames.contains(ultima.nombre)` | **1**: `…lo_que_cambia_algo_no_entra…` |
| M4 | `huella` → solo `nombre` (sin los argumentos) | **1**: `…argumentos_distintos_son_lecturas_distintas` |
| M5 | `huella` → sin el `trimmingCharacters` | **1**: `…argumentos_distintos_son_lecturas_distintas` |
| M6 | el `anade(BrowserRules.spinningWheelsNote(…))` del bucle, desactivado | **1**: `…la_tercera_lectura_identica_trae_el_aviso…` |

Dos lecturas de esta tabla que valen más que el «no sobrevivió ninguna»:

**M1 es la que de verdad importa.** Las cuatro pruebas puras afirman `false` en algún sitio, y
`false` es el valor por omisión de un `Bool`: una `pareceAtascado` que no detectara nada pasaría
esas mitades sin enterarse. M1 las mata **todas**, o sea que ninguna de las cuatro vive solo de
sus `false`. Esto era el riesgo que el encargo señaló por su nombre y es el que la tabla descarta.

**M2 no mata `…el_ciclo_que_el_prompt_ensena…`, y eso es información, no un agujero.** Con el
umbral en 2 el ciclo `snapshot → click → snapshot` sigue sin marcarse, porque su racha de
lecturas idénticas es **1**, no 2. Es decir: la protección del ciclo correcto **no depende del
umbral** — es estructural (siempre hay una acción entre dos miradas), y seguiría en pie con
cualquier umbral ≥ 2. La prueba del umbral y la del ciclo miden cosas distintas a propósito, y
esta mutación lo demuestra en vez de suponerlo.

## Recuento

| | Fallos |
| --- | --- |
| Base (`d168cd7`, medido, no a ojo) | **5** |
| Fase ROJA (producción con los cuerpos en `false`/`0`, sin cableado) | 10 = 5 + mis 5 |
| Después | **5** |

Las 5 de base son las de siempre: `AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`,
`ContactAliasStoreTests` (×2), `ForgetToolTests.test_forget_calls_endpoint_and_returns_count`,
`ReminderCRUDToolTests.test_update_mueve_la_hora`. Ni un sexto.

Contado así, las tres veces:

```
xcodebuild -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' test 2>&1 \
  | grep -E "^Test case" | grep "' failed" | sed 's/ on .*//' | sort -u
```

La fase roja se hizo con los símbolos ya presentes y los **cuerpos** neutralizados
(`pareceAtascado` → `false`, `repeticionesDeLecturaAlFinal` → `0`, sin cableado en el bucle), no
con un error de compilación: así el rojo es informativo —exactamente mis cinco pruebas y nada
más— en vez de «no compila».

## Lo que descubrí fuera de mi tarea

### 1. La negativa de `executedMutations` no se puede extender al navegador, y el motivo es bueno

`mutationToolNames` son **siete** nombres (`add_shift`, `drop_shift`, `create_event`,
`cancel_event`, `update_event`, `create_task`, `complete_task`): ninguna herramienta de navegador
está dentro. Así que un `browser_fill` idéntico repetido —el mismo valor en el mismo `@eN`— no lo
para nadie: ni la negativa (no está en la lista) ni esta detección (no es una lectura, y eso es
deliberado).

A primera vista parece un hueco que alguien debería tapar. **No lo es, y conviene que quede
escrito antes de que a alguien le parezca una mejora obvia:** una llamada de navegador
«idéntica» no es la misma operación dos veces. Las `@eN` caducan con cada acción —es lo que dice
el prompt y lo que `cortaLaCola` hace cumplir—, así que `browser_click @e5` en dos rondas
distintas apunta, por diseño, a elementos distintos. La igualdad de bytes que hace de
`executedMutations` un freno fiable para `create_event` (donde los argumentos SON la operación)
es justamente lo que no significa nada en el navegador. Si alguien quiere un freno de repetición
para las acciones del navegador, no puede ser por igualdad de la llamada: tendría que ser por
igualdad del *elemento*, y eso el bucle hoy no lo sabe.

### 2. `AgentTests.swift:201` conduce el bucle con el registro VACÍO

`test_the_browser_note_reaches_the_live_prompt_through_the_loop` usa
`RepeatingToolRuntime(toolName: "browser_snapshot")` contra `ToolRegistry()`, o sea un registro
sin herramientas: cada llamada se contesta con `Agent.resultadoDeHerramientaInexistente`
(`status: error`), gasta presupuesto de fallos, y el turno se muere en la quinta. La prueba sigue
midiendo lo que dice medir porque solo lee `runtime.prompts[1]` —la ronda 0 llega intacta—, pero
es **exactamente** la fragilidad que `BrowserCoreSkillTests` diagnosticó para sí misma y arregló
usando un registro real (ver el comentario de
`test_cinco_acciones_de_navegador_en_una_ronda_no_matan_el_turno`). Quien extienda esa prueba más
allá de tres rondas va a medir el presupuesto creyendo que mide la nota, con el síntoma venenoso
de siempre: verde por el motivo equivocado. No la toqué porque no es mi tarea y hoy no miente.

### 3. `browserGuideFits` mide un prompt vivo al que todavía le faltan las notas de cierre de ronda

La decisión de inyectar la guía se toma **dentro** del bucle de acciones, contra
`promptVivo(… rondas: historial + [ronda])`. En ese momento la ronda aún no lleva las notas que
se añaden al cerrarla: ni el aviso de corte de cola (`queueCutNote`, que ya era así) ni este
aviso nuevo (~900 bytes ≈ 300 tokens con el `estimateBytesPerToken` de 3). O sea que el encaje se
decide sobre un prompt algo más corto que el que se envía. No lo cambié: la subestimación es de
~300 tokens contra un estimador que ya **sobre**estima los tokens a propósito (3 bytes/token
frente a los ~4 reales), que es el colchón que absorbe esto; y el caso en que coinciden es
estrecho —la guía se inyecta con la primera herramienta de navegador del turno, y para que el
aviso caiga en esa misma ronda el modelo tiene que pedir tres lecturas idénticas en la ronda 0—.
Pero el hueco existe y es el mismo para las dos notas, así que si alguna vez se quiere cerrar, se
cierra una vez para las dos: midiendo el encaje al cerrar la ronda, no al ejecutar la acción.

### 4. El encargo lleva la línea base vieja

`tarea-4-encargo.md` dice «EXACTAMENTE 7 fallos» y nombra `ToolJSONEscapingTests` (×2). Esas dos
se arreglaron hoy en `4751d74`, así que la base son **5**. Lo medí antes de empezar y lo digo
porque el documento sigue afirmando 7 y la siguiente tarea lo va a leer.
