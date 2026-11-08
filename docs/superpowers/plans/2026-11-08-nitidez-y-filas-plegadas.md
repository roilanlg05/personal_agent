# Nitidez del panel y filas de herramienta plegadas — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el panel del navegador se vea nítido en el iPhone y que la fila de
una herramienta deje de volcar su resultado entero en la conversación.

**Architecture:** Tres entregas independientes. La configuración del contenedor
del navegador entra en el repositorio como fichero propio (hoy vive solo en el
i3, sin historial), y con ella bajo control de versiones se sube la nitidez a un
valor medido, no supuesto. En la app, `ChatLogEntry` gana los campos que ya tiene
el precedente del pensamiento plegable, y una función pura decide qué dice la
línea de una herramienta cuando está plegada.

**Tech Stack:** Docker Compose, Python + pytest (`gemma-memory/browser/`),
SwiftUI + XCTest (objetivo multiplataforma `Gemma`).

**Spec:** `docs/superpowers/specs/2026-11-08-navegador-visible-y-busqueda-design.md`

**Alcance:** este plan es el **subsistema A** de ese spec. Los otros tres —la
búsqueda por `agent-browser` (B), la visión (C) y los tres modos con el vídeo del
turno (D)— son planes aparte. Este no depende de ninguno, y los tres dependen de
él porque es el que pone la configuración del contenedor bajo control de
versiones.

## Global Constraints

- Swift 6, concurrencia estricta. Un `nonisolated async` **hereda** la isolation
  de quien llama: para salir del hilo principal hace falta `@concurrent`.
- Un solo objetivo multiplataforma (`iphoneos iphonesimulator macosx`). Nada
  nuevo detrás de `#if os(macOS)` salvo algo que solo exista en una plataforma.
- `browser/stream.py` **no se toca**. Solo deja pasar `params["url"]`, y solo bajo
  `navigate`.
- Ningún secreto por `argv`: `ps` lee el argv de cualquier proceso.
- Lista de **permitidos**, nunca de prohibidos, si hace falta un flag o
  subcomando nuevo del CLI: se añade a `FLAGS_BY_SUBCOMMAND` y
  `ALLOWED_SECOND_WORD` con su aridad y citando la fuente (`--help` del CLI y el
  sitio de llamada real).
- El servicio corre con `--no-access-log` y con la fábrica de registros que tacha
  `token=`. No se añade logging que pueda escribir una URL con query string.
- El i3 no se toca sin nombrar el servicio: nunca `docker compose down` sin
  servicio, nunca `docker system prune`, nunca un comando de compose desde
  `~/Projects/gemma-memory`.
- Nunca `git add -A` en `personal_agent`: barre las instantáneas de
  `graphify-out/`, y una pasó del límite de 100 MB de GitHub.
- Los implementadores **no ejecutan docker ni tocan el i3**. Las mediciones y el
  despliegue los hace el controlador; cada tarea dice cuál de sus pasos es suyo.

## Review Focus

1. **Un resultado de herramienta que no es JSON** (un mensaje de crash, una
   cadena vacía): la fila tiene que seguir dibujándose y no dejar una línea en
   blanco. → Tarea 3.
2. **Un resultado enorme** (`browser_get html` de una página real son cientos de
   kilobytes): abrir la fila no puede congelar la interfaz. → Tarea 3.
3. **`status` distinto de `success`**: el motivo tiene que verse **sin** abrir la
   fila. Esconder un fallo es peor que el ruido que este plan viene a quitar. →
   Tarea 3.
4. **Valores de nitidez fuera de rango** (calidad > 100, anchura mayor que la
   ventana del navegador): el servicio no puede quedarse sirviendo nada en
   silencio. → Tarea 2.
5. **El compose sin `BROWSER_BEARER_TOKEN`**: hoy falla cerrado con 401 en todo,
   y eso es correcto. La versión que entra al repositorio no puede introducir un
   valor por omisión que lo convierta en un servicio abierto. → Tarea 1.

---

### Task 1: El compose del navegador entra al repositorio

**Files:**
- Create: `gemma-memory/docker-compose.browser.yml`
- Create: `gemma-memory/browser/.env.example`
- Test: `gemma-memory/browser/test_compose.py`

**Interfaces:**
- Consumes: nada.
- Produces: `docker-compose.browser.yml`, el fichero que las Tareas 2 en adelante
  editan para cambiar la configuración del contenedor. Las claves que el servicio
  lee de verdad son `BROWSER_BEARER_TOKEN` (de `.env`),
  `BROWSER_STREAM_SESSION`, `AGENT_BROWSER_EXECUTABLE_PATH`,
  `AGENT_BROWSER_IDLE_TIMEOUT_MS`, `AGENT_BROWSER_SOCKET_DIR`,
  `AGENT_BROWSER_STREAM_QUALITY`, `AGENT_BROWSER_STREAM_MAX_WIDTH`,
  `AGENT_BROWSER_STREAM_MAX_HEIGHT`, `AGENT_BROWSER_NO_VERSION_CHECK`.

**Por qué existe esta tarea:** lo que corre en el i3 es
`~/Projects/gemma-browser/docker-compose.yml`, escrito a mano y **sin historial
en ningún repositorio**. Las Tareas 2, y los planes B, C y D, cambian valores de
ese fichero. Mientras viva fuera de git, nadie puede revisar ni revertir un
cambio de nitidez, de plazo o de grabación. El usuario eligió versionarlo como
fichero propio y seguir desplegándolo aparte, para no mover el compose que
levanta memoria y voz.

- [ ] **Step 1: Escribir la prueba que falla**

En `gemma-memory/browser/test_compose.py`. Lee el YAML con `yaml.safe_load` y
asevera la forma, no el texto:

```python
def test_el_compose_declara_las_claves_que_el_servicio_lee():
    env = _env_del_servicio("browser")          # dict {clave: valor}
    assert env["BROWSER_STREAM_SESSION"] == "gemma"
    assert env["AGENT_BROWSER_EXECUTABLE_PATH"] == "/usr/bin/chromium"
    assert env["AGENT_BROWSER_SOCKET_DIR"] == "/run/agent-browser"
    assert env["AGENT_BROWSER_IDLE_TIMEOUT_MS"] == "1800000"
    assert env["AGENT_BROWSER_NO_VERSION_CHECK"] == "1"
    assert "AGENT_BROWSER_NO_XVFB" not in env   # en Linux el CLI usa Xvfb

def test_el_token_viene_del_env_file_y_no_tiene_valor_por_omision():
    # Review Focus 5: un valor por omisión aquí convertiría el servicio en
    # abierto. Sin token, require_bearer da 401 en todo, y eso es lo correcto.
    assert ".env" in _config()["services"]["browser"]["env_file"]
    assert "BROWSER_BEARER_TOKEN" not in _env_del_servicio("browser")

def test_el_puerto_y_el_healthcheck_son_los_del_servicio_desplegado():
    svc = _config()["services"]["browser"]
    assert "8083:8083" in svc["ports"]
    assert "http://localhost:8083/healthz" in " ".join(svc["healthcheck"]["test"])
    assert svc["restart"] == "unless-stopped"

def test_el_env_example_nombra_el_token_sin_traer_un_valor():
    texto = (pathlib.Path(__file__).parent / ".env.example").read_text()
    assert "BROWSER_BEARER_TOKEN=" in texto
    assert "replace-me" not in texto   # no se hereda el placeholder de la memoria
```

- [ ] **Step 2: Correr y verificar que falla**

Run: `cd gemma-memory && python3 -m pytest browser/test_compose.py -v`
Expected: FAIL por fichero inexistente.

- [ ] **Step 3: Crear `docker-compose.browser.yml` copiando el Apéndice A de este plan**

El contenido exacto está en el Apéndice A, que es lo que corre hoy en el i3. Se
copia **literalmente**, comentarios incluidos: cada uno explica por qué existe su
línea, y el del encabezado explica por qué este fichero va aparte del compose de
`gemma-memory`. Añade al encabezado una línea nueva diciendo que este fichero es
ahora la fuente de verdad y que el del i3 se sincroniza desde aquí.

- [ ] **Step 4: Crear `browser/.env.example`**

Una sola variable, `BROWSER_BEARER_TOKEN=`, sin valor, con un comentario de dos
líneas: que se genera con `openssl rand -hex 32`, y que **no** es el
`MEMORY_BEARER_TOKEN` —el navegador conduce un Chromium real y no hereda un
secreto conocido.

- [ ] **Step 5: Correr las pruebas y verificar que pasan**

Run: `cd gemma-memory && python3 -m pytest browser/ -q`
Expected: PASS, y el total sube de 121 a 125.

- [ ] **Step 6 (controlador): validar el compose de verdad y comparar con el i3**

Esto lo hace el controlador, no el implementador. `docker compose -f
docker-compose.browser.yml config` tiene que salir con 0 y resolver el token no
vacío; y el fichero del i3 tiene que quedar idéntico a este salvo el encabezado.

- [ ] **Step 7: Commit**

```bash
git add docker-compose.browser.yml browser/.env.example browser/test_compose.py
git commit -m "chore(navegador): el compose del servicio entra al repositorio"
```

---

### Task 2: La nitidez, medida y no supuesta

**Files:**
- Modify: `gemma-memory/docker-compose.browser.yml` (las tres claves de stream)
- Modify: `gemma-memory/browser/relay.py:99,101` (`DAEMON_MAX_FPS`, `DEFAULT_VIEWER_MAX_FPS`)
- Modify: `gemma-memory/browser/test_compose.py` (candado de los valores elegidos)
- Create: `docs/superpowers/notes/2026-11-08-medicion-nitidez-panel.md` (en `personal_agent`)

**Interfaces:**
- Consumes: `docker-compose.browser.yml` de la Tarea 1.
- Produces: los valores de `AGENT_BROWSER_STREAM_QUALITY`,
  `AGENT_BROWSER_STREAM_MAX_WIDTH`, `AGENT_BROWSER_STREAM_MAX_HEIGHT` y
  `DEFAULT_VIEWER_MAX_FPS` que el plan D hereda.

**El dato de partida:** hoy son 640×360 a calidad 20. El usuario, textual: «la
resolución es como la de 600 algo. O sea, se ve bien borroso». El tope de 10
fotogramas por segundo (`DAEMON_MAX_FPS`, `DEFAULT_VIEWER_MAX_FPS`) se fijó
cuando el único cliente era un Mac por cable; ahora hay un iPhone con datos
móviles.

- [ ] **Step 1 (controlador): medir el peso del fotograma a cuatro calidades**

Esto lo hace el controlador, porque toca el i3 y docker. Con el navegador en una
página real y densa (una página de resultados de Amazon, que es el caso del
usuario), se levanta el servicio con cada combinación y se mide el **tamaño medio
del JPEG en bytes** sobre al menos 20 fotogramas:

| anchura × altura | calidad |
|---|---|
| 640 × 360 | 20 (lo de hoy, la línea base) |
| 900 × 506 | 45 |
| 1080 × 608 | 45 |
| 1080 × 608 | 60 |

Lo que se busca no es «el más bonito»: es el más grande cuyo caudal
(bytes medios × fotogramas por segundo) quepa en un enlace móvil con holgura.
**Presupuesto: 400 kB/s como tope.** Por encima de eso, el panel se queda atrás
en cuanto el usuario sale de la wifi.

- [ ] **Step 2 (controlador): elegir los valores y escribir la medición**

Crear `docs/superpowers/notes/2026-11-08-medicion-nitidez-panel.md` en
`personal_agent` con la tabla real medida, los valores elegidos, el caudal que
sale de ellos y el tope que se aplicó. Si la medición dice que a 10 fotogramas
por segundo no cabe ninguna mejora de nitidez, **la respuesta correcta es bajar
los fotogramas**, no renunciar a la nitidez: una página de compras se mira, no se
anima.

- [ ] **Step 3: Escribir la prueba que falla, con los valores elegidos**

En `test_compose.py`, con los números del Step 2 escritos a mano (es un candado
de regresión: si alguien los cambia sin medir, esta prueba se pone roja y le
obliga a leer la nota):

```python
def test_la_nitidez_es_la_medida_no_la_heredada():
    env = _env_del_servicio("browser")
    assert env["AGENT_BROWSER_STREAM_MAX_WIDTH"] == "<elegido>"
    assert env["AGENT_BROWSER_STREAM_MAX_HEIGHT"] == "<elegido>"
    assert env["AGENT_BROWSER_STREAM_QUALITY"] == "<elegido>"
    # Review Focus 4: valores fuera de rango no pueden llegar al daemon.
    assert 1 <= int(env["AGENT_BROWSER_STREAM_QUALITY"]) <= 100
```

Y en `browser/test_app.py`, para el caudal:

```python
def test_el_caudal_del_panel_cabe_en_un_enlace_movil():
    # bytes medios medidos × fps = caudal. El tope son 400 kB/s.
    assert relay.DEFAULT_VIEWER_MAX_FPS * <bytes_medios_medidos> <= 400_000
```

- [ ] **Step 4: Correr y verificar que falla**

Run: `cd gemma-memory && python3 -m pytest browser/test_compose.py browser/test_app.py -v`
Expected: FAIL, porque el compose sigue con 640/360/20.

- [ ] **Step 5: Poner los valores en el compose y, si la medición lo pide, en `relay.py`**

Las tres claves de stream en `docker-compose.browser.yml`. Si el Step 2 decidió
bajar los fotogramas, `DAEMON_MAX_FPS` y `DEFAULT_VIEWER_MAX_FPS` en
`relay.py:99,101`, **con un comentario que diga de dónde sale el número y que
cite la nota de la medición**: una constante sin procedencia es la que el yo del
futuro cambia a ojo.

- [ ] **Step 6: Correr las pruebas y verificar que pasan**

Run: `cd gemma-memory && python3 -m pytest browser/ -q`
Expected: PASS.

- [ ] **Step 7 (controlador): desplegar y mirarlo en el teléfono**

Sincronizar al i3, reconstruir el servicio nombrado, y que el usuario confirme
que ya no lo ve borroso. Esto es lo único que de verdad cierra la tarea: el
número lo da la medición, pero el veredicto lo da su ojo.

- [ ] **Step 8: Commit**

```bash
git add docker-compose.browser.yml browser/relay.py browser/test_compose.py browser/test_app.py
git commit -m "fix(panel): la nitidez sale de una medicion, no de un valor heredado"
```

---

### Task 3: La fila de herramienta se pliega

**Files:**
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift:7-24` (`ChatLogEntry`), `:692`, `:701`
- Create: `Gemma/Gemma/Harness/ToolLogRow.swift`
- Modify: `Gemma/Gemma/Harness/AgentChatView.swift:589-599` (`case "tool"`)
- Test: `Gemma/GemmaTests/ToolLogRowTests.swift`

**Interfaces:**
- Consumes: nada de las tareas anteriores.
- Produces:
  - `ChatLogEntry` gana tres campos: `toolName: String?`, `toolDetail: String?`,
    `isToolExpanded: Bool = false`. `text` deja de llevar el resultado.
  - `enum ToolRowSummary: Equatable { case ok, value(String), count(Int, String), failure(String) }`
  - `static func ToolLogRow.summarize(toolName: String, resultJSON: String) -> ToolRowSummary`
  - `static func ToolLogRow.detail(resultJSON: String) -> String` — el texto que se
    ve al abrir la fila, recortado a `detailLimit` y terminado en `…` cuando se
    recortó.
  - `static let ToolLogRow.detailLimit: Int` — el tope de caracteres que se
    pintan, con su por qué escrito al lado.
  - `struct ToolLogRow: View { @Binding var entry: ChatLogEntry }`

**El defecto exacto:** `HarnessModel.swift:701` hace
`ChatLogEntry(role: "tool", text: "🔧 \(n) ✓ \(r)")` donde `r` es el resultado
**completo**, y `AgentChatView.swift:589` lo pinta con un `Text` sin límite de
líneas. Un `browser_snapshot` vuelca cientos de líneas de referencias `@eN`.

**La regla que pidió el usuario, textual:** «no pongas ningún resumen, pon 32
objetos o lo que sea… a menos que sea un tool que tenga una respuesta concreta».
Es decir: contar es honesto, interpretar no; y cuando la herramienta devuelve
**un dato**, ese dato sí se ve.

**El precedente a seguir:** `isThoughtExpanded` ya existe y
`AgentChatView.swift:632-650` ya lo pinta con su chevron. La fila nueva imita ese
patrón; no se inventa otro.

- [ ] **Step 1: Escribir las pruebas que fallan**

En `Gemma/GemmaTests/ToolLogRowTests.swift`. Las formas de JSON son las reales de
`AgentBrowserToolOutput`:

```swift
func test_snapshot_cuenta_los_objetos_y_no_los_enseña() {
    let json = #"{"status":"success","snapshot":"- generic [ref=e1]\n- link [ref=e2]\n- text [ref=e3]"}"#
    XCTAssertEqual(ToolLogRow.summarize(toolName: "browser_snapshot", resultJSON: json),
                   .count(3, "objetos"))
}

func test_get_enseña_el_dato_porque_es_la_respuesta() {
    let json = #"{"status":"success","value":"59,99 €"}"#
    XCTAssertEqual(ToolLogRow.summarize(toolName: "browser_get", resultJSON: json),
                   .value("59,99 €"))
}

func test_open_enseña_el_host_no_la_url_entera() {
    let json = #"{"status":"success","url":"https://www.amazon.es/s?k=raquetas+ping+pong"}"#
    XCTAssertEqual(ToolLogRow.summarize(toolName: "browser_open", resultJSON: json),
                   .value("www.amazon.es"))
}

func test_una_accion_sin_dato_solo_dice_que_salio_bien() {
    for tool in ["browser_click", "browser_fill", "browser_press", "browser_wait", "browser_close"] {
        XCTAssertEqual(ToolLogRow.summarize(toolName: tool, resultJSON: #"{"status":"success"}"#),
                       .ok, "\(tool) no devuelve ningún dato que merezca una línea")
    }
}

func test_un_fallo_enseña_su_motivo_sin_tener_que_abrir_la_fila() {
    // Review Focus 3: esconder un fallo es peor que el ruido que esto viene a quitar.
    let json = #"{"status":"error","message":"No se pudo lanzar el navegador: timeout"}"#
    XCTAssertEqual(ToolLogRow.summarize(toolName: "browser_open", resultJSON: json),
                   .failure("No se pudo lanzar el navegador: timeout"))
}

func test_lo_que_no_es_json_no_rompe_la_fila_ni_la_deja_en_blanco() {
    // Review Focus 1.
    for basura in ["", "Fatal error: índice fuera de rango", "{roto"] {
        let r = ToolLogRow.summarize(toolName: "browser_get", resultJSON: basura)
        if case .failure(let motivo) = r { XCTAssertFalse(motivo.isEmpty) }
        else { XCTFail("un resultado ilegible es un fallo, no un éxito: \(r)") }
    }
}

func test_el_detalle_se_recorta_para_que_abrir_la_fila_no_cuelgue_la_interfaz() {
    // Review Focus 2: `browser_get html` de una página real son cientos de kB.
    let enorme = String(repeating: "x", count: 500_000)
    XCTAssertLessThanOrEqual(ToolLogRow.detail(resultJSON: enorme).count, ToolLogRow.detailLimit)
    XCTAssertTrue(ToolLogRow.detail(resultJSON: enorme).hasSuffix("…"))
}

func test_web_search_cuenta_resultados() {
    let json = #"{"status":"success","count":3,"results":[]}"#
    XCTAssertEqual(ToolLogRow.summarize(toolName: "web_search", resultJSON: json),
                   .count(3, "resultados"))
}
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd Gemma && xcodebuild test -scheme Gemma -destination 'platform=macOS,arch=arm64' -only-testing:GemmaTests/ToolLogRowTests`
Expected: FAIL por `ToolLogRow` inexistente.

- [ ] **Step 3: Implementar `ToolLogRow.summarize`, `.detail` y `.detailLimit` en `Gemma/Gemma/Harness/ToolLogRow.swift`**

`summarize` parsea el JSON una vez con `JSONSerialization`. Si no parsea, o si
`status` no es `"success"`, es `.failure` con el `message` cuando lo haya y un
texto propio cuando no. Con éxito, una tabla por herramienta decide entre
`.value`, `.count` y `.ok`; la tabla es el único sitio donde se dice qué
herramienta devuelve un dato, y las que no están en ella son `.ok`.
`detailLimit` es una constante con su por qué escrito al lado.

Las nueve herramientas y su veredicto, que es la decisión que el implementador no
puede tomar solo:

| herramienta | resumen |
|---|---|
| `browser_open` | `.value` con el host de `url` |
| `browser_snapshot` | `.count` de líneas de `snapshot`, «objetos» |
| `browser_get` | `.value` con `value`, o `.count` cuando el campo es `count` |
| `read_webpage` | `.count` de caracteres de `content`, «caracteres» |
| `web_search` | `.count` de `count`, «resultados» |
| `browser_click`, `browser_fill`, `browser_press`, `browser_wait`, `browser_close` | `.ok` |

- [ ] **Step 4: Implementar `ToolLogRow` (la vista) y cablearla**

Plegada: una fila con el estado, el nombre de la herramienta en monoespaciado, el
resumen, y un chevron cuando hay detalle. Abierta: el detalle recortado, en
monoespaciado y con `textSelection(.enabled)`. Un `.failure` muestra su motivo
**plegado**, no escondido. Tocar alterna `entry.isToolExpanded`, igual que
`AgentChatView.swift:632` hace con el pensamiento.

- [ ] **Step 5: Añadir los tres campos a `ChatLogEntry` y dejar de concatenar**

`toolName`, `toolDetail`, `isToolExpanded` en `HarnessModel.swift:7-24`, con el
`init` manteniendo valores por omisión para no romper a los demás llamantes.
`:692` pasa a `ChatLogEntry(role: "tool", text: "", toolName: n)` y `:701` a
`ChatLogEntry(role: "tool", text: "", toolName: n, toolDetail: r)`. El `case
"tool"` de `AgentChatView.swift:589-599` se reemplaza por `ToolLogRow(entry: $entry)`.

- [ ] **Step 6: Correr la suite completa y comparar con la línea base**

Run: `cd Gemma && xcodebuild test -scheme Gemma -destination 'platform=macOS,arch=arm64'`
Expected: las nuevas en verde, y **exactamente los ocho fallos preexistentes de
`main`**, ni uno más: `AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`,
`ServerRuntimeStreamingTests.test_streaming_yields_incremental_tokens_then_completed`,
`ToolJSONEscapingTests.test_search_contacts_output_is_valid_json`,
`ToolJSONEscapingTests.test_search_contacts_error_output_is_valid_json`,
`ReminderCRUDToolTests.test_update_mueve_la_hora`,
`ContactAliasStoreTests.test_herramientaExigeAmbosArgumentos`,
`ContactAliasStoreTests.test_herramientaParaEnsenarAlias`,
`ForgetToolTests.test_forget_calls_endpoint_and_returns_count`.

- [ ] **Step 7: Verificar que compila para el iPhone**

Run: `cd Gemma && xcodebuild build -scheme Gemma -destination 'generic/platform=iOS'`
Expected: `** BUILD SUCCEEDED **`. La fila se mira sobre todo en el teléfono.

- [ ] **Step 8: Commit**

```bash
git add Gemma/Gemma/Harness/ToolLogRow.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/Gemma/Harness/AgentChatView.swift Gemma/GemmaTests/ToolLogRowTests.swift
git commit -m "fix(chat): la fila de una herramienta se pliega y deja de volcar su resultado"
```

---

## Apéndice A — el compose tal y como corre hoy en el i3

Copia literal de `~/Projects/gemma-browser/docker-compose.yml`. La Tarea 1 lo
reproduce con los comentarios intactos; la Tarea 2 cambia solo las tres claves de
stream.

```yaml
# Despliegue independiente del servicio del navegador en el i3.
#
# Va aparte del compose de gemma-memory a propósito: el checkout del i3 está en
# `main` con diez ficheros modificados sin commitear, así que cambiarle la rama
# para traer la rama del navegador habría puesto en riesgo ese trabajo local.
# Este directorio es puramente aditivo y no toca nada de lo que ya corre.
#
# Diferencia deliberada respecto al compose de gemma-memory: allí el servicio
# leía `BROWSER_BEARER_TOKEN=${MEMORY_BEARER_TOKEN}`, reusando el token de la
# memoria, que hoy sigue siendo el placeholder débil. Aquí el navegador tiene su
# propio token largo y aleatorio: es un servicio nuevo expuesto en la red de
# Tailscale que puede conducir un Chromium real, y no debe heredar un secreto
# conocido.
services:
  browser:
    build:
      context: ./browser
    ports:
      - "8083:8083"
    env_file:
      - .env
    environment:
      - TZ=America/Havana
      # Sesión del CLI que sigue el relé del panel. TIENE QUE COINCIDIR con el
      # AGENT_BROWSER_SESSION de la app (valor por omisión `gemma`). Si divergen,
      # el navegador sigue funcionando y el panel se queda en blanco; el relé lo
      # compara con la sesión que declara el visor y cierra nombrando las dos.
      # Se escribe con su valor a la vista: una variable que solo existe dentro
      # de un `os.environ.get` es una trampa para el yo del futuro.
      - BROWSER_STREAM_SESSION=gemma
      # Chrome de Debian; sin esto el CLI busca uno que no existe en la imagen.
      - AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium
      # AGENT_BROWSER_NO_XVFB queda SIN declarar a propósito: en Linux el CLI usa
      # Xvfb (la imagen lo instala). No añadirla.
      # El demonio se apaga por inactividad; media hora cubre una conversación larga.
      - AGENT_BROWSER_IDLE_TIMEOUT_MS=1800000
      - AGENT_BROWSER_SOCKET_DIR=/run/agent-browser
      # Calidad y tamaño máximo del JPEG del streaming.
      - AGENT_BROWSER_STREAM_QUALITY=20
      - AGENT_BROWSER_STREAM_MAX_WIDTH=640
      - AGENT_BROWSER_STREAM_MAX_HEIGHT=360
      # Que no toque la red en cada llamada.
      - AGENT_BROWSER_NO_VERSION_CHECK=1
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8083/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
    restart: unless-stopped
```
