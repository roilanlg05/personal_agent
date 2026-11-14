# Tarea 2c — El JSON de salida de las herramientas tiene orden de claves estable

Rama `diag/panel-se-muere`, base `3d27a2a`. Suite:
`xcodebuild -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' test`.

Esta tarea se metió delante de las tareas 3, 4 y 5 del plan del bucle de navegación porque el
instrumento con el que se miden estaba envenenado: la línea base de «exactamente 7 fallos» y cada
tabla de mutaciones dependen de que la suite dé el mismo resultado dos veces, y una suite que no
es determinista no mide, adivina.

---

## 1. Los recuentos, que es lo más valioso

Contados siempre así, no a ojo:

```
… test 2>&1 | grep -E "^Test case" | grep "' failed" | sed 's/ on .*//' | sort -u
```

| Fase | Repetición | Fallos únicos |
|---|---|---|
| ANTES (base `3d27a2a`, sin tocar nada) | 1 | 7 |
| ANTES | 2 | 7 |
| ANTES | 3 | 7 |
| DESPUÉS (todo aplicado) | 1 | 7 |
| DESPUÉS | 2 | 7 |
| DESPUÉS | 3 | 7 |
| DESPUÉS | 4 | 7 |

Las tres repeticiones del antes dan la MISMA lista de siete nombres (`diff` vacío entre las tres),
y las cuatro del después dan esa misma lista otra vez (`diff` vacío contra la del antes). La lista
es la del encargo: `AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`,
`ContactAliasStoreTests` (×2), `ForgetToolTests.test_forget_calls_endpoint_and_returns_count`,
`ReminderCRUDToolTests.test_update_mueve_la_hora`, `ToolJSONEscapingTests` (×2).

### Lo que estos recuentos NO dicen, y hay que decirlo

**La intermitencia no se veía en la suite antes del arreglo, y no porque no existiera.** El agente
anterior ya la había esquivado: dejó la prueba de `BrowserCoreSkillTests` comparando dos trozos
estables (la cabecera de la nota y el `message` del resultado) en vez del resultado entero, y
escribió el porqué en el comentario. O sea que «7 antes, 7 después» mide que no he roto nada —que
era la mitad del encargo— pero NO prueba por sí solo que el defecto estuviera ahí. Eso se mide
aparte, en los dos apartados siguientes: la medición directa del orden (§2) y la fase roja de las
pruebas nuevas (§3), donde la suite entera pasa de 7 a 10 fallos sin el arreglo.

---

## 2. La medición directa: cómo es de inestable el orden, y por qué

Programa de nueve líneas, fuera de la app, con la implementación vieja de `ToolJSONOutput.object`
copiada tal cual y el par de claves real (`["status", "message"]`).

**(a) Entre procesos.** Seis arranques del mismo programa:

| Arranque | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| Clave primera | `message` | `message` | `status` | `status` | `message` | `status` |

Tres y tres. El orden de iteración de un `Dictionary` de Swift depende de la semilla de hash del
proceso, que es aleatoria por arranque. Consecuencia: **cualquier aserción que compare la salida de
una herramienta byte a byte es una moneda al aire por ejecución de la suite** — y con XCTest
repartiendo las clases entre varios procesos, la moneda se tira varias veces por ejecución.

**(b) Dentro de un mismo proceso.** Dos diccionarios con las MISMAS claves y distinta capacidad
(`[:]` recién creado contra `[String: Any?](minimumCapacity: 64)`) salieron en órdenes distintos en
la misma ejecución (arranque 2 de los seis: `a` y `b` dieron `message` primero, `c` dio `status`).
La posición de un elemento sale del hash Y de la capacidad de la tabla, y la capacidad depende de
cómo se construyó el diccionario.

**Matiz sobre el diagnóstico heredado, porque cambia qué hay que creerse.** El encargo decía que el
orden «no es estable ni entre dos llamadas del mismo proceso». Medido: dos llamadas con el MISMO
diccionario (mismas claves, misma forma de construirlo) sí dan el mismo orden dentro de un proceso
—es determinista dado el proceso—. Lo que no es estable es (a) entre procesos y (b) entre
diccionarios de distinta capacidad en un mismo proceso. La conclusión práctica del encargo es
correcta y el arreglo es el mismo; lo que no se sostiene es el mecanismo exacto que se le atribuyó
a aquella prueba roja 1 de cada 3. Queda dicho para que nadie reconstruya el razonamiento sobre una
premisa que no se cumple.

---

## 3. El arreglo de la serialización

`Gemma/Gemma/NativeServices/ToolJSONOutput.swift`: `.sortedKeys` añadido a las opciones de
`JSONSerialization.data`, más el comentario que deja escrito el porqué y las dos mediciones.

```swift
let data = try? JSONSerialization.data(withJSONObject: cleaned,
                                       options: [.sortedKeys, .withoutEscapingSlashes])
```

**Es el único serializador de salida de herramienta que hay.** Comprobado, no supuesto:

- 309 usos de `ToolJSONOutput` en 58 ficheros de producción; todas las herramientas del registro
  construyen su salida por aquí, incluidas las nueve del navegador vía
  `AgentBrowserToolOutput.resolve` / `noContent` / `invalidArguments`.
- `grep JSONSerialization.data` en producción da nueve sitios: éste, dos cuerpos de petición HTTP
  (`ServerRuntime`), `HTTPServerHealth`, `AtoZGraphQL`, `AtoZConfig`, `LlamaCppRuntime` (parámetros
  del servidor), `GemmaToolCallParser` (que YA pedía `.sortedKeys`, y es el precedente de esto) y
  `AgentBrowserService` (ver el hallazgo de §6).
- `grep 'return "{'` en producción: un solo sitio, el objeto de error de `ToolJSONOutput` mismo,
  que tiene una sola clave.
- `JSONEncoder` con `outputFormatting`: un sitio, `PlaceStore`, y es `.prettyPrinted` sobre un
  `Codable` (orden de declaración, determinista). `ReminderService.record` también usa `JSONEncoder`
  sobre un `Codable`: determinista, y además no es salida de herramienta.

**Ningún consumidor depende del orden, comprobado en el código y no por el «debería».** Todo lo que
lee un resultado de herramienta lo parsea: `Agent.estadoDelResultado`, `Agent.motivoDelResultado`,
`Agent.urlDelResultado`, `ToolLogRow.summarize`, `AgentBrowserService.fields`, y los tests, todos
vía `JSONSerialization.jsonObject`. No hay ni un `hasPrefix("{\"`, ni un `range(of: "\"status\"")`,
ni un `dropFirst` sobre un resultado. El único sitio que toca el TEXTO del resultado es
`ToolLogRow.detail`, que lo recorta a `detailLimit` para enseñarlo al abrir la fila del chat: es
cosmético, y con el orden fijo además es reproducible, que es mejor que antes.

### Las pruebas nuevas, y su fase roja sobre la suite entera

Fichero nuevo `Gemma/GemmaTests/ToolJSONOutputOrderTests.swift`, cuatro pruebas. **Escritas antes
del arreglo y corridas antes del arreglo**: la suite entera pasó de **7 a 10 fallos**.

| Prueba | Qué afirma | Fase roja |
|---|---|---|
| `test_las_claves_salen_en_orden_alfabetico` | ocho claves cuyo orden alfabético no es ni el de inserción ni el inverso salen en orden alfabético | roja, determinista |
| `test_la_capacidad_de_la_tabla_no_cambia_la_salida` | mismo contenido, dos capacidades, misma cadena | roja |
| `test_la_forma_real_del_resultado_de_herramienta_inexistente` | `Agent.resultadoDeHerramientaInexistente` empieza por `{"message":` | roja en las 2 ejecuciones observadas, pero ver nota |
| `test_las_barras_siguen_sin_escaparse` | `.withoutEscapingSlashes` sigue puesto | VERDE en la fase roja |

Dos de esas filas son información, no ruido, y las declaro:

- **`test_la_forma_real_…` es una moneda al aire en la fase roja**, por construcción: tiene dos
  claves, así que sin `.sortedKeys` acierta el orden alfabético la mitad de las veces. La observé
  roja en las dos ejecuciones sin arreglo (la fase roja y la mutación M1), pero no se puede
  prometer. Después del arreglo es determinista. La prueba que sostiene la propiedad sin azar es la
  de las ocho claves: que un orden de hash coincida por casualidad con el alfabético son 1 entre
  8! = 40320.
- **`test_las_barras_siguen_sin_escaparse` verdeó en la fase roja**, y eso es correcto: no es la
  prueba del arreglo, es el candado de que el arreglo no se lleve por delante
  `.withoutEscapingSlashes` (una clave sola no tiene orden que equivocar). Que una prueba verdee
  antes de implementar es información: aquí la información es «esta no mide lo nuevo», y por eso
  tiene su propia mutación (M2) que demuestra que mide ALGO.

### Pruebas tocadas, y por qué

| Prueba | Qué le hice | Por qué |
|---|---|---|
| `ToolJSONOutputOrderTests` (4, nuevas) | escritas | afirmar el orden estable, que no tenía quién lo sostuviera |
| `BrowserCoreSkillTests.test_el_primer_browser_del_turno_lleva_la_guia_exactamente_una_vez` | el resultado se comprueba ENTERO en vez de por su `message`, y el comentario del orden se reescribió | es la prueba que se ponía intermitente; con el orden fijo y con el registro de dobles (§4) la comparación fuerte ya es legítima |
| `BrowserCoreSkillTests` (resto, §4) | registro de dobles | trampa latente del presupuesto de fallos |

**Ninguna prueba de la base afirmaba un prefijo JSON de una salida de herramienta**, así que
`.sortedKeys` no puso roja a ninguna por el cambio de `{"status":` a `{"message":`. Buscado:
`XCTAssertEqual(out…)`, `XCTAssertEqual(result…)`, `contains("{\"`, `hasPrefix("{`. Los literales
JSON que hay en los tests (`AgentTests`, `ToolLogRowTests`, `GemmaToolCallParserTests`,
`BrowserRelayClientTests`) son todos ENTRADAS escritas a mano, no salidas comparadas.

### Qué pasó con los dos `ToolJSONEscapingTests`

**No cambiaron, ni en un sentido ni en otro, y no son de lo mío.** Texto de fallo extraído del
`.xcresult`, byte a byte igual antes y después:

| Prueba | Antes (`18-40-15`, base limpia) | Después (`18-44-46`, con `.sortedKeys`) |
|---|---|---|
| `test_search_contacts_output_is_valid_json` | `XCTAssertEqual failed: ("Optional("found")") is not equal to ("Optional("ok")")` | idéntico |
| `test_search_contacts_error_output_is_valid_json` | `XCTAssertEqual failed: ("nil") is not equal to ("Optional("Permiso \"denegado\"\npara contactos")")` | idéntico |

Y era previsible por la forma de la prueba: las dieciséis pruebas de ese fichero **parsean** la
salida (`JSONSerialization.jsonObject`) y comparan valores por clave, nunca la cadena. Un parser
descarta precisamente lo que `.sortedKeys` cambia. Las otras catorce del fichero pasan, antes y
después.

Lo que esos dos fallos sí son: **deriva entre la prueba y el contrato de la herramienta**, y es un
hallazgo de fuera de mi tarea (§6).

---

## 4. La trampa latente de `BrowserCoreSkillTests`

### El defecto

Las pruebas de ese fichero conducían el bucle de `Agent` con un registro de herramientas VACÍO.
Vivían de que el resultado de «no existe esa herramienta» fuera ilegible para el presupuesto de
fallos. Desde `3d27a2a` ya no lo es: `Agent.resultadoDeHerramientaInexistente` habla el contrato
JSON con `status: error`, así que **cada llamada de un guion gasta una unidad del presupuesto**. Con
`Agent.maxConsecutiveFailures == 5`, el quinto fallo seguido mata el turno con `break loop` ANTES de
volver a llamar al modelo, y el síntoma no es un error: es un último prompt vivo corto y una prueba
en verde por el motivo equivocado.

Ninguna de las pruebas pasaba de tres llamadas, así que la trampa estaba armada y no había
disparado. Son **nueve** pruebas las que conducían el bucle con el registro vacío, no ocho: las
ocho que pasan por el ayudante `lastLivePrompt` más
`test_la_guia_llega_cuando_aparece_el_navegador_aunque_el_turno_empiece_sin_el`, que monta el
`ScriptedRoundsRuntime` a mano. Una décima,
`test_las_reglas_estan_desde_el_primer_token_no_solo_en_la_guia`, pasaba un registro vacío pero su
runtime no pide ninguna herramienta, así que nunca estuvo en riesgo.

### El arreglo, de raíz

Lo que las hacía frágiles era conducir el bucle con un registro vacío, no el número 3. Así que
ahora hay registro:

- **`DobleDeHerramienta`** (privado, arriba del fichero): un doble por cada nombre que los guiones
  llaman (`web_search`, `get_current_time`, `browser_open`, `browser_snapshot`, `browser_click`;
  hacen falta cinco tipos porque `AgentTool.name` es estática). Ninguno guarda estado — un contador
  en un atributo de clase sobrevive entre pruebas y en este proyecto ya ha hecho sobrevivir una
  mutación que debía morir. Todos devuelven el mismo resultado, **construido con
  `ToolJSONOutput.object`** y no escrito a mano.
- **`no_content` y no `success`**, a propósito. Las dos reinician el presupuesto
  (`Agent.estadosDeExito` contiene las dos), que es lo que hace falta; pero `success` haría además
  que `Agent.cortaLaCola` cortase la cola detrás de `browser_open` —está en
  `browserToolNamesThatResetThePage`, así que un `open` con éxito corta siempre— y las pruebas que
  cuentan tres notas en una ronda contarían una. `no_content` es además la verdad de un doble: «la
  operación funcionó pero no hay nada que reportar».
- **`registroDelGuion(_:)` afirma su propia premisa**: para cada nombre del guion exige
  `registry.tool(named:) != nil`. Si mañana alguien escribe un guion con `browser_fill` y no añade
  su doble, la prueba lo dice en vez de volver a medir el presupuesto de fallos en silencio.
- **`lastLivePrompt` comprueba que el turno no se murió por el camino**: recoge los
  `.toolCallFinished`, exige que haya tantos como acciones tiene el guion, y que ninguno sea un
  fallo a ojos de `Agent.esFallo`. Sin esta guarda la única señal de la trampa sería un prompt más
  corto de lo esperado.

### La prueba que la delata, con su fase roja

`test_cinco_acciones_de_navegador_en_una_ronda_no_matan_el_turno`: cinco acciones de navegador en
una ronda y una ronda más detrás, que es un turno de conducción de verdad. Afirma la guía una sola
vez, las SEIS notas presentes, y que el turno no terminó con el mensaje de presupuesto agotado.

Es la prueba que no se puede escribir sobre un registro vacío, y se midió: **escrita sobre el
registro vacío, la suite entera dio 8 fallos (7 + ésta)**. Con el registro de dobles, 7.

---

## 5. Tabla de mutaciones (suite ENTERA cada vez, base = 7)

| # | Mutación | Fichero | Rojos | Nuevos rojos |
|---|---|---|---|---|
| M1 | quitar `.sortedKeys` de `ToolJSONOutput.object` | `NativeServices/ToolJSONOutput.swift` | 10 | `ToolJSONOutputOrderTests` ×3 (`las_claves_salen_en_orden_alfabetico`, `la_capacidad_de_la_tabla_no_cambia_la_salida`, `la_forma_real_del_resultado_de_herramienta_inexistente`) |
| M2 | quitar `.withoutEscapingSlashes` (dejando `.sortedKeys`) | `NativeServices/ToolJSONOutput.swift` | 8 | `ToolJSONOutputOrderTests.test_las_barras_siguen_sin_escaparse` |
| M3 | quitar el candado `!browserGuideInjected` de la inyección de la guía | `Agent/Agent.swift` | 10 | `BrowserCoreSkillTests`: `cinco_acciones…`, `tres_llamadas…`, `tres_rondas…` |
| M4 | volver al registro vacío en `lastLivePrompt` | `GemmaTests/BrowserCoreSkillTests.swift` | 16 | las NUEVE pruebas que conducen el bucle, incluida `un_turno_sin_navegador…` (por la guarda de `esFallo`) |
| M5 | quitar `BrowserClick()` de `DobleDeHerramienta.todos` | `GemmaTests/BrowserCoreSkillTests.swift` | 10 | `cinco_acciones…`, `tres_llamadas…`, `tres_rondas…` (la guarda de premisa de `registroDelGuion` dispara) |

Todas restauradas y verificadas: la ejecución final da 7 fallos, lista idéntica a la base.

M4 es la que mide el arreglo de la §4 por el lado que importa: las nueve pruebas que antes
dependían de un resultado de error ahora **lo dicen a gritos** si alguien les quita el registro, en
vez de medir el presupuesto con el prompt corto.

M3 y M5 están para que el ancla no mienta: M3 confirma que la prueba nueva mide la inyección de la
guía (propiedad de producción) y no solo que el turno sobreviva; M5 confirma que la guarda de
premisa dispara de verdad.

---

## 6. Lo que descubrí fuera de la tarea

1. **Los dos `ToolJSONEscapingTests` son deriva prueba-contrato, no orden.** `SearchContactsTool`
   devuelve hoy `status: "found"` y la prueba sigue exigiendo `"ok"`; y su camino de error ya no
   emite una clave `error` de primer nivel, que es lo que la otra prueba busca. Son dos pruebas que
   afirman un contrato que la herramienta ya no tiene. No las he tocado: están en la línea base del
   encargo y arreglarlas es decidir cuál de los dos lados tiene razón, que no es mi tarea.
2. **`AgentBrowserService` reempaqueta el `data` del navegador sin `.sortedKeys`** (línea ~82,
   después de quitarle la clave `lifecycle`). Hoy es inofensivo: ese `Data` nunca sale como
   resultado de herramienta, se vuelve a parsear con `AgentBrowserService.fields` y las nueve
   herramientas reconstruyen su salida con `ToolJSONOutput.object`. Lo dejo anotado porque es el
   único otro sitio donde un diccionario de claves de contrato se serializa, y si algún día alguien
   emite ese `Data` tal cual, el problema vuelve.
3. **El diagnóstico heredado del mecanismo no se sostiene** (detalle en §2): dos llamadas con el
   mismo diccionario en el mismo proceso dan el mismo orden. La inestabilidad es entre procesos y
   entre capacidades. La conclusión y el arreglo no cambian.
4. **`GemmaToolCallParser` ya pedía `.sortedKeys`** para el eco de los argumentos de una llamada
   (línea 143). O sea que el proyecto ya había tomado esta decisión una vez, en el camino de
   entrada; esto la termina en el camino de salida.
5. **Basura sin seguir en la raíz del repo**, ajena a esta tarea: `.build/`, `__pycache__/`,
   `default.profraw`, `claude-fix.patch`.
