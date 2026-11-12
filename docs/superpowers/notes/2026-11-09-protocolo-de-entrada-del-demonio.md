# El protocolo de entrada del demonio, medido

> **RETIRADO el 2026-11-12** por `docs/superpowers/plans/2026-11-12-quitar-el-mando.md`. El usuario: «elimina ese control manual de raíz, solo necesito streaming del navegador abierto en mi mac hacia la app, sin controlarlo». Se conserva como historia; nada de lo que describe sobre la entrada del usuario existe ya en el código. Lo rescatado del servidor está en `feat/chrome-de-verdad` (3f814b5) y lo demás en la etiqueta `archivo/mando-subsistema-a` del repo gemma-memory.

Fecha: 2026-11-09. Tarea 1 del subsistema B del mando compartido.

## Por qué hay que medirlo y no deducirlo

El relé (`gemma-memory/browser/relay.py`) reenvía al demonio el mensaje del visor
**verbatim** y valida **solo el `type`**. Está así a propósito. Lo dice su propio
comentario, en la rama del subsistema A
(`/Users/hashdown/Projects/personal_agent/gemma-memory/.worktrees/mando-subsistema-a`,
commit `1e338b8`):

```
browser/relay.py:678-684
    if isinstance(tipo, str) and tipo in _ENTRADAS_REENVIABLES:
        # Se valida el `type` y NO el resto de los campos, a propósito: el relé
        # pasaría a depender del protocolo de entrada del demonio, y quien manda
        # esto es el portador del mando, un usuario autenticado, no un extraño. El
        # `type` no se puede colar por una clave duplicada: `json.loads` se queda
        # con la última, y esa es la que se valida y la que se reenvía.
        return ("input", message)
```

Consecuencia para el cliente: **nadie valida los campos**. Un campo mal nombrado
llega al demonio, el demonio no lo encuentra, y el síntoma que ve el usuario es
«toco y no pasa nada», indistinguible de media docena de fallos distintos. De ahí
que esta tarea empiece midiendo.

## Qué es «el demonio», exactamente

El relé abre un WebSocket contra el servidor de streaming del CLI `agent-browser`:

```
browser/relay.py:1169
    f"ws://127.0.0.1:{port}/?pacing=ack&maxFps={DAEMON_MAX_FPS}",
```

y el puerto lo lee de `agent-browser --session <s> stream status --json`
(`browser/relay.py:737`). Es decir: **el demonio es el servidor de stream de
`agent-browser`**, y su protocolo de cliente es el documentado en la guía de
streaming que el propio CLI trae.

La versión instalada aquí y la de la guía coinciden:

| Dato | Valor | Fuente |
| --- | --- | --- |
| Versión del CLI | 0.41.2 | `agent-browser --version` |
| Versión del paquete | 0.41.2 | `package.json:3` del paquete npm |
| Ruta del binario | `/opt/homebrew/Cellar/agent-browser/0.41.2/libexec/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64` | `readlink -f $(which agent-browser)` |
| Ruta de las referencias | `/opt/homebrew/Cellar/agent-browser/0.41.2/libexec/lib/node_modules/agent-browser/skill-data/core` | `agent-browser skills path core` |

Confirmado además que **no está en la guía vendorizada**:
`grep -c "input_mouse\|input_keyboard\|input_touch" docs/agent-browser/core-skill-0.41.2.md`
→ `0`. La guía vendorizada es el `SKILL.md` del núcleo; el protocolo de entrada
vive en una *referencia* (`references/streaming.md`), que no se vendorizó.

## La fuente autoritativa

`skill-data/core/references/streaming.md`, sección «Messages from the client»
(línea 72), bloque JSON de las líneas 74-80. Se obtiene igual con un comando:
`agent-browser skills get core --ref streaming`. Las tres líneas que nos importan:

```
streaming.md:75  {"type": "input_mouse", "eventType": "mousePressed", "x": 40, "y": 40, "button": "left", "clickCount": 1}
streaming.md:76  {"type": "input_keyboard", "eventType": "keyDown", "key": "a", "text": "a"}
streaming.md:77  {"type": "input_touch", "eventType": "touchStart", "touchPoints": []}
```

Y la lista de tipos, en la otra referencia:

```
commands.md:411  … They send `input_mouse`, `input_keyboard`, and `input_touch` to drive the page, …
```

## Campo por campo

Leyenda de la columna «fuente»:
- **DOC** = aparece literalmente en `streaming.md:75-77`. Es medición.
- **BIN** = el literal está en el binario instalado; corrobora un valor posible.
- **CDP** = **inferencia**, no medición: se deduce de que el demonio llama a
  `Input.dispatch*Event` de Chrome DevTools Protocol (los tres literales están en
  el binario, ver abajo) y de la especificación de esos métodos. **No está
  verificado contra el demonio.**

### `input_mouse`

| Campo | Tipo | Valor | Fuente |
| --- | --- | --- | --- |
| `type` | string | `"input_mouse"` | DOC `streaming.md:75`, `commands.md:411`, `relay.py:633` |
| `eventType` | string | `"mousePressed"` | DOC `streaming.md:75` |
| `eventType` | string | `"mouseReleased"`, `"mouseMoved"` | BIN, offset 10422504 (ver «literales del binario») + CDP |
| `x` | número | `40` (entero en el ejemplo) | DOC `streaming.md:75` |
| `y` | número | `40` (entero en el ejemplo) | DOC `streaming.md:75` |
| `button` | string | `"left"` | DOC `streaming.md:75` |
| `button` | string | `"right"`, `"middle"` | BIN, offset 10422504 |
| `clickCount` | número | `1` | DOC `streaming.md:75` |

### `input_keyboard`

| Campo | Tipo | Valor | Fuente |
| --- | --- | --- | --- |
| `type` | string | `"input_keyboard"` | DOC `streaming.md:76`, `commands.md:411`, `relay.py:633` |
| `eventType` | string | `"keyDown"` | DOC `streaming.md:76`, BIN offset 10423612 |
| `eventType` | string | `"keyUp"` | CDP. **El literal NO está en el binario** — ver la advertencia metodológica |
| `key` | string | `"a"` | DOC `streaming.md:76` |
| `text` | string | `"a"` | DOC `streaming.md:76` |

### `input_touch`

| Campo | Tipo | Valor | Fuente |
| --- | --- | --- | --- |
| `type` | string | `"input_touch"` | DOC `streaming.md:77`, `commands.md:411`, `relay.py:633` |
| `eventType` | string | `"touchStart"` | DOC `streaming.md:77`, BIN offset 10424531 |
| `eventType` | string | `"touchMove"`, `"touchEnd"` | CDP |
| `touchPoints` | lista | `[]` en el ejemplo | DOC `streaming.md:77` |
| `touchPoints[].x` / `.y` | número | — | **CDP, no DOC**: el ejemplo de la guía manda la lista VACÍA, así que la forma de un punto no está documentada en ninguna parte que se pueda leer sin hablar con el demonio |

## Lo que NO se pudo medir, dicho como tal

1. **La forma de un elemento de `touchPoints`.** El único ejemplo publicado manda
   `[]`. `{"x": …, "y": …}` sale de la especificación de `Input.dispatchTouchEvent`
   (el tipo `Input.TouchPoint`, cuyos únicos campos obligatorios son `x` e `y`), y
   de que el demonio llama a ese método. Es inferencia.
2. **Qué campos son obligatorios y cuáles tienen valor por omisión.** No hay
   esquema publicado y el binario no se deja leer (siguiente punto). El código de
   esta tarea resuelve esto **emitiendo siempre los cinco/cuatro campos del
   ejemplo**, sin depender de ningún valor por omisión del demonio.
3. **Si `eventType` se valida contra una lista cerrada o se pasa a CDP tal cual.**
   No se puede decidir desde fuera. Por eso el código solo permite construir los
   valores de las tablas de arriba, con un `enum`: si el demonio valida, estos son
   los que pasan; si no valida, estos son los que CDP acepta.
4. **El nombre que el demonio usa internamente para `eventType`** (CDP lo llama
   `type`, así que el demonio renombra). Irrelevante para el cliente, pero prueba
   que el demonio **sí parsea** los campos uno a uno en vez de reenviar el objeto
   entero: un campo mal nombrado se pierde ahí.
5. **Nada de esto se verificó contra un demonio en marcha.** No se abrió ninguna
   sesión del CLI: contra el servidor doméstico está prohibido (el navegador
   comparte un solo perfil de Chrome; una sesión paralela se queda el
   `SingletonLock` y la sesión del agente deja de abrir páginas en silencio, con
   todos los indicadores de salud en verde), y levantar un demonio local en el Mac
   habría metido un Chrome y un perfil nuevos en la máquina del usuario para
   contestar preguntas que la guía version-matched ya contesta. **La verificación
   en vivo queda pendiente y le toca a la tarea que mande la primera tecla de
   verdad.**

## Advertencia metodológica: la ausencia de un literal no prueba nada

Busqué los tipos en el binario instalado, byte a byte, y **no están**:

```
count de b"input_mouse"    → 0
count de b"input_keyboard" → 0
count de b"input_touch"    → 0
count de b"input_"         → 1, y es `group_input_len`, un assert de dav1d (offset 11861729)
```

La tentación es concluir que el demonio no tiene una lista cerrada de tipos. **Esa
conclusión es falsa**, y se demuestra con un contraejemplo medido en el mismo
binario: `keyUp` tampoco está (`count` = 0), y el CLI **tiene** un comando
`agent-browser keyup <key>` (su ayuda lo documenta) que no puede hacer su trabajo
sin mandarle a CDP el tipo de evento `keyUp`. Es decir: hay cadenas que el binario
provablemente necesita y que una búsqueda de bytes no encuentra. Por tanto, en
este binario:

- **encontrar** un literal es evidencia de que ese valor existe en algún camino;
- **no encontrarlo** no es evidencia de nada.

Ninguna decisión de esta tarea cuelga de una ausencia.

### Literales que sí se encontraron (`agent-browser-darwin-arm64`)

| Offset | Cadenas contiguas |
| --- | --- |
| 10422504 | `mouseMoved` `right` `middle` `mousePressed` `mouseReleased` |
| 10423594 | `Input.dispatchMouseEvent` `keyDown` `Input.dispatchKeyEvent` |
| 10424531 | `touchStart` `touchPoints` `Input.dispatchTouchEvent` |
| 10393893 | la tabla de nombres de parámetro de CDP: `… button` `buttons` `clickCount` `deltaX` `deltaY` `modifiers` `unmodifiedText` `windowsVirtualKeyCode` … |

Reproducible con una búsqueda de subcadenas sobre el fichero
(`python3 -c` leyendo el binario y haciendo `bytes.find`); los tres
`Input.dispatch*Event` son lo que fundamenta la columna CDP de las tablas.

## El tope del mensaje: la medición contradice al plan

El plan (y el encargo de esta tarea) dicen «el tope de **4096 bytes** del relé».
**El relé no cuenta bytes: cuenta caracteres.**

```
browser/relay.py:641   MAX_MENSAJE_VISOR = 4096
browser/relay.py:655   if not isinstance(text, str) or len(text) > MAX_MENSAJE_VISOR:
```

`text` es el `str` ya decodificado que entrega el WebSocket, y `len()` de un `str`
de Python cuenta **puntos de código**, no bytes UTF-8. La frontera es inclusiva, y
su prueba del servidor lo clava:

```
browser/test_app.py:1981-1990
    for n, pasa in ((4095, True), (4096, True), (4097, False)):
        texto = con_longitud(n)
        assert len(texto) == n
```

Esa prueba usa solo ASCII, donde caracteres y bytes coinciden, así que no distingue
los dos criterios. Con contenido no-ASCII sí se separan: un mensaje de 4096 puntos
de código con acentos o emoji pasa de 4096 bytes UTF-8 y el relé **lo acepta**.

### Qué hace el cliente con esto

`BrowserInputEvents.cabeEnElTope(_:)` comprueba **bytes UTF-8 ≤ 4096**, que es
*más estricto* que el relé. Razones:

1. **Es correcto en la dirección que importa.** En UTF-8, `bytes ≥ puntos de
   código` siempre. Así que `bytes ≤ 4096` ⟹ `len(str) ≤ 4096`: si `cabeEnElTope`
   dice que sí, el relé **no** lo va a descartar. La promesa del nombre se cumple.
2. **La dirección contraria no se puede prometer.** `len(str) ≤ 4096` no implica
   nada sobre los bytes, y lo que haya aguas abajo (el socket del demonio, su
   propio límite de trama, que no se puede medir desde aquí) cuenta bytes, no
   caracteres.
3. **El hueco entre los dos criterios es inalcanzable en la práctica.** Un evento
   de entrada legítimo son decenas de bytes. Para caer en el hueco haría falta un
   `text` de miles de caracteres no-ASCII en un solo `input_keyboard`, que es
   justamente el pegado largo que el relé manda partir
   (`relay.py:636-640`: «Un visor que quiera pegar un texto largo tiene que
   partirlo en varios `input_keyboard`»).
4. **Comprobar las dos cosas sería redundante.** `bytes ≤ 4096 && escalares ≤ 4096`
   es exactamente `bytes ≤ 4096`, porque el primero implica el segundo. Una
   conjunción así deja una cláusula que ninguna prueba puede matar por separado, y
   este proyecto ya tiene bastantes mutaciones supervivientes por motivos
   equivalentes. Una sola cláusula.

Y el aviso para quien escriba el lado Swift de esto más adelante: **`String.count`
de Swift cuenta grafemas, no puntos de código ni bytes.** `"é"` compuesta es 1
grafema, 2 escalares y 3 bytes. Para hablar del tope hay que usar `.utf8.count`.
`cabeEnElTope` lo usa.

## Un hallazgo que cambia una suposición del plan: el formato no viaja

El relé **no** reenvía nuestro texto; reenvía el objeto reserializado:

```
browser/relay.py:915
    await connection.send(json.dumps(message))
```

Así que al demonio le llega el JSON de Python (`json.dumps` por omisión: separadores
`", "` y `": "`, claves en orden de inserción). Consecuencias:

- **El orden de las claves y los espacios de nuestro JSON son irrelevantes para el
  demonio.** Lo único que importa es el conjunto de claves y sus valores.
- Por tanto, serializar con `ToolJSONOutput` (que ordena las claves desde `dd9059c`)
  **no es un riesgo de protocolo**, y sí es lo que hace que las pruebas de esta
  tarea puedan comparar byte a byte sin ser intermitentes. Se usa ese serializador,
  como pide el plan.
- El tope de 4096 se mide sobre **nuestro** texto (`relay.py:655` corre antes de
  `json.dumps`), no sobre el reserializado. `cabeEnElTope` recibe nuestro JSON, que
  es el correcto.

## Decisiones de la implementación que salen de todo lo anterior

1. **Tres funciones, un `type` cada una, sin vía genérica.** No hay forma de
   construir un mensaje con otro `type`: no existe un parámetro de tipo. Es la
   restricción «no se toca la lista de permitidos del relé» hecha estructura.
2. **`enum` para `eventType` y para `button`.** Un `String` libre permitiría un
   `"mousePress"` que el demonio tira sin decir nada.
3. **Se emiten siempre todos los campos del ejemplo publicado.** Cero dependencia
   de valores por omisión del demonio, que no se pudieron medir.
4. **`touchPoints` lleva un punto para `touchStart`/`touchMove` y va vacía para
   `touchEnd`.** Es lo que pide `Input.dispatchTouchEvent` (en `touchEnd` los
   puntos que siguen activos son ninguno), y es la única rama de este fichero donde
   el `eventType` cambia la forma del mensaje. Marcado como inferencia CDP.
5. **Ni un registro, de ninguna clase.** Ni `PanelLog`, ni `print`, ni `Logger`, ni
   `os_log`, ni `NSLog`, ni una descripción de excepción. El fichero no tiene
   caminos de error: `ToolJSONOutput.object` no puede fallar con `Int` y `String`, y
   su literal de reserva es constante y no reproduce ningún valor de entrada. La
   ausencia de registro la afirma una prueba que **lee el fuente**, igual que
   `AgentBrowserRegistrationTests.test_run_agent_turn_calls_registerBrowserTools`
   clava su llamada. Es frágil ante renombrados a propósito.

## Lo que me encontré fuera de mi tarea

- **La suite no compila en un worktree recién creado.** `Gemma/Gemma/Frameworks/`
  (el `llama.xcframework`, 259 MB) está excluido en `.git/info/exclude:8`, así que
  no viaja a los worktrees, y sin él el build muere con
  `error: Unable to resolve module dependency: 'llama' (in target 'Gemma')` antes de
  correr una sola prueba — la primera corrida de la base dio **0 rojos y 2
  failures**, que no es una base limpia sino un build roto. Se arregla con un enlace
  simbólico al del checkout principal:

  ```
  ln -s /Users/hashdown/Projects/personal_agent/Gemma/Gemma/Frameworks \
        <worktree>/Gemma/Gemma/Frameworks
  ```

  Queda ignorado por la misma entrada de `.git/info/exclude` (que es del directorio
  común de git y la comparten todos los worktrees), así que no se commitea. **Vale
  la pena ponerlo en el plan de cualquier tarea futura que se ejecute en un
  worktree de este repo**, porque el síntoma («0 rojos») se confunde con éxito.
- **`ForgetToolTests.test_forget_calls_endpoint_and_returns_count`**, que el encargo
  del subsistema B lista como el quinto rojo preexistente, **ya no falla** en
  `c7f0fcb`. La base de esta rama son 4 rojos, como decía el encargo de la tarea.
- El cliente de hoy (`Gemma/Gemma/NativeServices/BrowserRelayClient.swift`) solo
  sabe mandar `ack`, y lo hace con una interpolación a mano
  (`ackPayload`, línea 111). Es coherente con lo que midió la revisión de rama: la
  app no tiene con qué mandar una tecla. Este fichero es la primera pieza.

## Recuento de la suite

| Fase | Rojos | Pasadas | Qué era |
| --- | --- | --- | --- |
| Antes (base de la rama, `c7f0fcb`) | **4** | 1227 | `AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`, `ContactAliasStoreTests` (×2), `ReminderCRUDToolTests.test_update_mueve_la_hora` |
| Fase ROJA (esqueleto que no implementa nada) | 13 | — | los 4 de la base + 9 de los 10 nuevos |
| Después (verde) | **4** | 1236 | los mismos 4 de la base; los 10 nuevos pasan |

Lo que cuenta es la columna de **rojos**: 4 antes y 4 después, los mismos cuatro.
Las pasadas varían ±1 entre corridas porque la suite va en paralelo y el log se
parte (1227 + 10 daría 1237 y se contaron 1236), así que no son un instrumento de
medida; los nombres de los rojos sí.

El décimo, `test_ninguna_funcion_del_fichero_registra_nada`, **verdeó en la fase
roja**, y eso es información y no un alivio: afirma una AUSENCIA, y el esqueleto
tampoco registraba nada, así que la propiedad se cumplía de verdad. Una prueba de
ausencia no puede ponerse roja contra una implementación que no existe; lo único
que demuestra que puede ponerse roja es la mutación M3, y se corrió.

## Tabla de mutaciones

Cada mutación neutraliza una línea de producción, corre la suite **entera**, y se
restaura comparando el hash del fichero (`shasum -a 256`) antes y después. El
arnés es `t1-mutar.sh` en el scratchpad (nombres prefijados `t1-` a propósito: el
scratchpad es compartido y hoy a un agente le pisaron sus ficheros temporales), y
tiene tres guardas contra las tres formas en que una mutación ha mentido en este
proyecto:

- **exige que el ancla aparezca exactamente una vez**, y aborta sin tocar nada si
  no (contra el ancla-prefijo que muta otra cosa);
- **comprueba que el fichero está en su estado original ANTES de mutar**,
  comparándolo con la copia de restauración (contra las mutaciones encadenadas
  sobre un fichero ya mutado);
- **comprueba que la copia de restauración existe** antes de empezar (contra la
  copia a una ruta inexistente, que ya hizo correr tres mutaciones sobre el
  fichero mutado).

Hash del fichero original: `f0b021abbb2892fcd03d5bbee69041fcd03615988f073f38e547200cad27ad0a`.
Las seis restauraciones volvieron a ese hash exacto.

| # | Mutación | Rojos | ¿Mata? | Prueba que lo ve |
| --- | --- | --- | --- | --- |
| M1 | `cabeEnElTope` devuelve `true` constante | 7 (4+3) | sí | `..._una_tecla_normal_cabe_y_un_texto_largo_no`, `..._la_frontera_del_tope_esta_en_4096_bytes_inclusive`, `..._el_tope_cuenta_bytes_y_no_grafemas` |
| M2 | se borra la rama de `touchEnd`: `touchPoints` lleva siempre un punto | 5 (4+1) | sí | `..._el_fin_del_toque_no_lleva_ningun_punto` |
| M3 | se añade `PanelLog.note("tecla \(tecla)")` dentro de `keyboard` | 5 (4+1) | sí | `..._ninguna_funcion_del_fichero_registra_nada` |
| M4 | el `type` del ratón pasa a `"input_raton"` | 7 (4+3) | sí | `..._el_raton_produce_el_json_que_documenta_la_medicion`, `..._los_tres_tipos_son_los_tres_permitidos_por_el_rele`, `..._el_fichero_no_menciona_ningun_otro_tipo_de_entrada` |
| M5 | la frontera del tope deja de ser inclusiva (`<=` → `<`) | 5 (4+1) | sí | `..._la_frontera_del_tope_esta_en_4096_bytes_inclusive` |
| M6 | el tope cuenta grafemas (`.utf8.count` → `.count`) | 5 (4+1) | sí | `..._el_tope_cuenta_bytes_y_no_grafemas` |

Ninguna sobrevivió, y ninguna es equivalente: las seis cambian comportamiento
observable. Cada una mata exactamente las pruebas que afirman su propiedad y
ninguna más, que es la otra mitad de la comprobación: una mutación que pone roja
media suite no dice qué prueba sirve.

### El primer intento de M4 se abortó solo, y eso fue el arnés funcionando

La primera versión de M4 usaba el ancla `type": "input_mouse"`, que aparece **dos
veces** en el fichero: en el código y en la línea de `streaming.md:75` citada en el
comentario de cabecera. El arnés abortó sin escribir nada
(`FATAL: el ancla aparece 2 veces, no 1`) y la mutación se repitió con el ancla
indentada del código, que es única. Sin esa guarda, la mutación habría cambiado
también la cita de la documentación y el rojo de
`..._el_fichero_no_menciona_ningun_otro_tipo_de_entrada` habría salido del
comentario y no del código: una mutación que miente con los dos resultados en
verde aparente.

## Lo que queda por hacer, y de quién es

- **La verificación en vivo contra un demonio de verdad.** Nada de esto se probó
  contra un `agent-browser` en marcha (ver «Lo que NO se pudo medir», punto 5). La
  primera tarea que mande una tecla de verdad desde la app tiene que mirar que la
  página la reciba, y si no, el sospechoso número uno es la forma de un punto de
  `touchPoints`, que es la única inferencia pura de este fichero.
- **El `graphify update .`** que pide `CLAUDE.md` no se corrió: el grafo vive en el
  checkout principal y esta tarea trabaja en un worktree aislado.
