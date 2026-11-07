# Panel de streaming del navegador — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mover el navegador del agente al i3 y que el usuario vea en el chat de la app, en vivo, la página que el agente está conduciendo allí — con narración legible, sin que el panel pueda mentir, y sin que un secreto salga nunca del i3.

**Architecture:** Dos lados y un cable. En el **i3** nace un servicio nuevo en Python/FastAPI (`gemma-memory/browser/`, puerto 8083) que es dueño del demonio `agent-browser` de Linux: expone `POST /v1/browser/invoke`, que ejecuta el `argv` del CLI y devuelve su envelope tal cual, y `GET /v1/browser/stream`, un WebSocket que abre el socket local del demonio, **tira `params` antes de poner nada en el cable**, compone la narración y el resumen, decide «en vivo» y hace de relé hacia uno o varios visores. En la **app de Mac** cambian dos cosas: un `AgentBrowserInvoking` nuevo que habla HTTP con el i3 en vez de lanzar un proceso —así las nueve herramientas que ya existen conducen el navegador del i3 sin tocarlas—, y un visor que consume el relé y pinta un panel por turno dentro del chat. Toda la lógica vive en el i3; la app dibuja.

**Tech Stack:** i3: Python 3.11, FastAPI, `websockets`, `httpx`, pytest, Docker (chromium + xvfb + Node 24 + `agent-browser`). App: Swift 6, SwiftUI, `URLSessionWebSocketTask`, ImageIO, XCTest. Sin dependencias nuevas en Swift.

**Spec:** `docs/superpowers/specs/2026-11-06-panel-streaming-navegador-design.md` (revisión del 2026-11-07: secciones 3, 5.10, 6.4 y 11)

## Global Constraints

**Dos repositorios.** Las tareas 1 a 4 se comitean en `gemma-memory` (que vive en `personal_agent/gemma-memory/`, ignorado por el repo de la app, y es `github.com/roilanlg05/gemma-memory`). Las tareas 5 a 9, en `personal_agent`. Ninguna tarea toca los dos.

- **El servicio nuevo no se escribe en Swift.** Decisión del usuario, spec §5.10. Python/FastAPI junto a `voice/`, que ya está desplegado en el i3.
- **`params` no sale del proceso del relé.** Spec §5.7 y §6.3. Ni al cable, ni a un log, ni a una traza de depuración. Es la restricción que manda sobre todas las demás.
- **El cable lleva solo los seis mensajes de la spec §6.4**: `frame`, `narration`, `host`, `state`, `summary`, `closed`. Nada de `params`, acción cruda, selectores, valores ni URL completa — solo el host.
- **Los frames nunca se escriben a disco**, ni en el i3 ni en el Mac. Spec §6.2(a), ahora en dos máquinas.
- **Nunca se llama a `stream enable`.** Devuelve `success:false` cuando ya está activo, que es siempre. Spec §5.1.
- **El puerto del stream se lee de `stream status --json` cada vez.** Lo asigna el sistema operativo y cambia por demonio. Spec §5.2.
- **«En vivo» lo decide el i3**: socket al demonio abierto + el relé acusando + el último `status` con `screencasting: true`. Nunca la edad del frame. Spec §6.2(f).
- **El acuse encadena los dos saltos.** El relé acusa al demonio **cuando el visor le acusa a él**, nunca por su cuenta. Spec §6.4.
- **Autenticación `Bearer` en los dos endpoints**, con el patrón `require_bearer` que `voice/app.py` ya usa. Ni dentro de Tailscale se sirve sin token.
- **El JPEG no se decodifica en el hilo principal de la app.** Spec §6.2(b).
- **El panel se degrada, nunca rompe.** Si el i3 no responde, el panel no aparece y el turno del agente no cambia en nada. Spec §6.2(e).
- Un panel nuevo por cada turno que toque el navegador; los anteriores colapsan a etiqueta y **sueltan la imagen**. Spec §10.
- Textos de interfaz y narración **en español**. Nombres de pruebas y comentarios, en español.
- Pruebas del i3: `python3 -m pytest browser/test_app.py -v` desde la raíz de `gemma-memory`.
- Pruebas de la app: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/<Suite> 2>&1 | tail -20`
- `HarnessModelTests/test_defaultBaseURL` falla ya en `main`: fallo conocido, no lo introduce este trabajo.
- Código nuevo de la app bajo `#if os(macOS)` **solo donde use AppKit o ImageIO**. El cliente del relé y el estado del panel **no** llevan nada de Apple más que `Foundation`: son las piezas que un cliente de iOS reusará tal cual.

## Variables de entorno del demonio, verificadas en el binario

Extraídas del binario 0.41.2 y necesarias para la Tarea 1. Las tres de calidad son las de la spec §5.3; las otras cuatro son de Linux y el spec no las tenía:

| Variable | Valor | Por qué |
|---|---|---|
| `AGENT_BROWSER_EXECUTABLE_PATH` | `/usr/bin/chromium` | el Chrome de Debian; sin esto el CLI busca uno que no existe en la imagen |
| `AGENT_BROWSER_NO_XVFB` | sin poner | el CLI usa Xvfb en Linux; la imagen lo instala y se deja el comportamiento por omisión |
| `AGENT_BROWSER_IDLE_TIMEOUT_MS` | `1800000` | el demonio se apaga por inactividad; media hora cubre una conversación larga sin dejarlo vivo para siempre |
| `AGENT_BROWSER_SOCKET_DIR` | `/run/agent-browser` | el socket del demonio, en un directorio del contenedor y no en `XDG_RUNTIME_DIR` |
| `AGENT_BROWSER_STREAM_QUALITY` | `20` | spec §5.3; el servicio es dueño del demonio, así que ahora sí surte efecto en frío |
| `AGENT_BROWSER_STREAM_MAX_WIDTH` | `640` | ídem |
| `AGENT_BROWSER_STREAM_MAX_HEIGHT` | `360` | ídem |
| `AGENT_BROWSER_NO_VERSION_CHECK` | `1` | que no toque la red en cada llamada |

## Review Focus

Cinco clases de entrada que el spec implica y que ninguna tarea cubriría por sí sola. Cada línea lleva su prueba asignada a la tarea dueña del código.

1. **El demonio se apaga por inactividad a mitad de una conversación.** `AGENT_BROWSER_IDLE_TIMEOUT_MS` existe y el demonio muere solo; al volver, el puerto del stream es otro (§5.2). Esperable: la invocación siguiente lo levanta y el relé lee el puerto nuevo, sin que el agente vea un fallo. Un relé que cachea el puerto deja el panel muerto para el resto de la sesión. → Tareas 2 y 4.
2. **El i3 no responde** (servicio caído, Tailscale abajo, token mal). Esperable: las nueve herramientas devuelven `not_available` con un motivo accionable —el mismo estado que hoy cuando falta el binario— y el panel **no aparece**, sin romper el turno. → Tareas 5 y 8.
3. **Dos visores en el mismo panel** (la app de Mac ahora, la de iOS después). Esperable: los dos ven lo mismo y el lento no retrasa al rápido, porque el acuse es por cliente. Un relé que acusa al demonio con el cliente más lento convierte a ese cliente en el reloj de todos. → Tarea 4.
4. **El visor se va y vuelve** a mitad de un turno. Esperable: al volver recibe la página **actual** y el estado actual, no un backlog ni una imagen vieja. Es la contrapresión de §6.4 funcionando de punta a punta. → Tareas 4 y 6.
5. **`POST /v1/browser/invoke` recibe un `argv` que no es del vocabulario del CLI** (`["rm","-rf","/"]`, `["eval","..."]`, un flag que apunte a un fichero del contenedor). Esperable: rechazo antes de ejecutar nada. El endpoint ejecuta un binario con argumentos que llegan por red: sin lista de permitidos es ejecución remota de órdenes. → Tarea 2.

---

# Lado i3 — `gemma-memory`

### Task 1: La imagen y el esqueleto del servicio

**Files:**
- Create: `browser/Dockerfile`
- Create: `browser/requirements.txt`
- Create: `browser/app.py`
- Create: `browser/test_app.py`
- Modify: `docker-compose.yml` — servicio `browser` nuevo, después de `voice`
- Modify: `README.md` — una línea en la tabla de servicios y una en Testing

**Interfaces:**
- Consumes: nada.
- Produces:
  ```python
  app: FastAPI                      # título "Gemma Browser Gateway"
  def require_bearer(authorization: str = Header(default="")) -> None
  BROWSER_BIN: str                  # ruta del CLI, de AGENT_BROWSER_BIN o "agent-browser"
  ```
  `GET /healthz` → `{"status": "ok"}` sin autenticación, como en `voice/app.py`.

- [ ] **Step 1: Escribir las pruebas que fallan**

```python
"""Pruebas del servicio de navegador. Correr con:
    python3 -m pytest browser/test_app.py -v
Usa BROWSER_FAKE_CLI=1 para no lanzar el binario de verdad."""
import os, sys
os.environ["BROWSER_FAKE_CLI"] = "1"
os.environ["BROWSER_BEARER_TOKEN"] = "test-token"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi.testclient import TestClient
import app as appmod

client = TestClient(appmod.app)
AUTH = {"Authorization": "Bearer test-token"}


def test_healthz_no_pide_token():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_invoke_sin_token_devuelve_401():
    r = client.post("/v1/browser/invoke", json={"arguments": ["stream", "status"]})
    assert r.status_code == 401


def test_invoke_con_token_malo_devuelve_401():
    r = client.post("/v1/browser/invoke",
                    json={"arguments": ["stream", "status"]},
                    headers={"Authorization": "Bearer otro"})
    assert r.status_code == 401
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd gemma-memory && python3 -m pytest browser/test_app.py -v`
Expected: FAIL, no existe `browser/app.py`.

- [ ] **Step 3: Escribir `browser/app.py` con `/healthz`, `require_bearer` y un `POST /v1/browser/invoke` que devuelva 501**

El 501 es temporal: esta tarea entrega el esqueleto autenticado, la Tarea 2 le pone el cuerpo. `require_bearer` compara con `BROWSER_BEARER_TOKEN` y lanza `HTTPException(401)`, igual que `voice/app.py`.

- [ ] **Step 4: Escribir el `Dockerfile`**

`python:3.11-slim`, y encima: `curl ca-certificates`, **Node 24** (de NodeSource, porque el paquete `agent-browser` declara `engines.node >= 24`), `npm install -g agent-browser@0.41.2`, `chromium`, `xvfb`, y las fuentes mínimas (`fonts-liberation`) para que las páginas no se rendericen en cuadros. `mkdir -p /run/agent-browser`. `EXPOSE 8083`, `CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8083"]`.

- [ ] **Step 5: Añadir el servicio al `docker-compose.yml`**

Con el patrón del servicio `voice`: `ports: ["8083:8083"]`, `BROWSER_BEARER_TOKEN=${MEMORY_BEARER_TOKEN}`, `TZ`, las ocho variables de la tabla de arriba, `healthcheck` con `curl -fsS http://localhost:8083/healthz`, `restart: unless-stopped`. **Sin `depends_on`**: el navegador no necesita la memoria.

- [ ] **Step 6: Verificar la imagen a mano y dejar la prueba escrita en el README**

```bash
cd gemma-memory && docker compose build browser
docker compose run --rm --entrypoint agent-browser browser --version   # debe imprimir 0.41.2
docker compose run --rm --entrypoint chromium browser --version        # debe imprimir una versión
```
Expected: las dos imprimen versión. Si `agent-browser --version` falla por Node, es que Node 24 no entró en la imagen.

- [ ] **Step 7: Correr las pruebas y verificar que pasan**

Run: `cd gemma-memory && python3 -m pytest browser/test_app.py -v`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
cd gemma-memory
git add browser/ docker-compose.yml README.md
git commit -m "feat(browser): servicio del navegador en el i3, con chromium y agent-browser en la imagen"
```

---

### Task 2: `POST /v1/browser/invoke` — el proxy del `argv`, con lista de permitidos

El seam que hace que las nueve herramientas de la app sigan funcionando sin tocarlas: `AgentBrowserInvoking` ya habla en `argv` y devuelve stdout, así que el endpoint recibe el `argv` y devuelve lo mismo.

**Files:**
- Modify: `browser/app.py`
- Create: `browser/cli.py`
- Modify: `browser/test_app.py`

**Interfaces:**
- Consumes: `require_bearer`, `BROWSER_BIN`.
- Produces:
  ```python
  # browser/cli.py
  ALLOWED_SUBCOMMANDS: frozenset[str]
  REJECTED_FLAG_PREFIXES: tuple[str, ...]
  def validate(arguments: list[str]) -> None          # lanza ValueError con el motivo
  async def run(arguments: list[str], timeout: float, stdin: str | None = None) -> dict
      # -> {"exitCode": int, "stdout": str, "stderr": str}
  ```
  Y el endpoint: `POST /v1/browser/invoke` con cuerpo `{"arguments": [...], "timeout": 30, "stdin": null}` → `200` con `{"exitCode", "stdout", "stderr"}`, o `400` con `{"detail": "<motivo>"}` si la validación falla.

`ALLOWED_SUBCOMMANDS` arranca con lo que las nueve herramientas y el panel usan: `open`, `read`, `click`, `fill`, `press`, `wait`, `get`, `close`, `snapshot`, `stream`, `batch`. **`eval` NO está**, porque es el comando más peligroso del CLI y la app no lo expone como herramienta.

- [ ] **Step 1: Escribir las pruebas que fallan**

```python
# --- validación (Review Focus 5) ---
def test_rechaza_un_subcomando_que_no_esta_en_la_lista():
    r = client.post("/v1/browser/invoke", json={"arguments": ["eval", "1+1"]}, headers=AUTH)
    assert r.status_code == 400
    assert "eval" in r.json()["detail"]


def test_rechaza_algo_que_no_es_del_cli():
    r = client.post("/v1/browser/invoke", json={"arguments": ["rm", "-rf", "/"]}, headers=AUTH)
    assert r.status_code == 400


def test_rechaza_argumentos_vacios():
    assert client.post("/v1/browser/invoke", json={"arguments": []}, headers=AUTH).status_code == 400


def test_rechaza_flags_que_apuntan_a_ficheros_del_contenedor():
    # --action-policy y --state leen del disco del i3: no se aceptan por red.
    for flag in ["--action-policy", "--state", "--profile", "--init-scripts", "--extensions"]:
        r = client.post("/v1/browser/invoke",
                        json={"arguments": ["open", "https://a.test", flag, "/etc/passwd"]},
                        headers=AUTH)
        assert r.status_code == 400, flag


def test_el_subcomando_se_busca_en_el_primer_positional_no_en_un_flag():
    # "--session gemma open ..." es la forma que arma AgentBrowserService.
    r = client.post("/v1/browser/invoke",
                    json={"arguments": ["--session", "gemma", "open", "https://a.test", "--json"]},
                    headers=AUTH)
    assert r.status_code == 200


# --- ejecución ---
def test_devuelve_el_envelope_del_cli_tal_cual():
    # Con BROWSER_FAKE_CLI=1 el ejecutor devuelve un envelope fijo sin lanzar nada.
    r = client.post("/v1/browser/invoke",
                    json={"arguments": ["stream", "status", "--json"]}, headers=AUTH)
    body = r.json()
    assert body["exitCode"] == 0
    assert '"success"' in body["stdout"], "el stdout del CLI se pasa sin interpretar"


def test_el_argv_llega_al_ejecutor_sin_shell(monkeypatch):
    visto = {}

    async def falso(arguments, timeout, stdin=None):
        visto["arguments"] = arguments
        return {"exitCode": 0, "stdout": "{}", "stderr": ""}

    monkeypatch.setattr(appmod.cli, "run", falso)
    client.post("/v1/browser/invoke",
                json={"arguments": ["open", "https://a.test; rm -rf /"]}, headers=AUTH)
    assert visto["arguments"] == ["open", "https://a.test; rm -rf /"], \
        "la lista llega entera a execve: nunca pasa por un shell"


def test_stdin_se_pasa_al_proceso_y_no_al_argv(monkeypatch):
    # El sub-proyecto de secretos necesita el modo stdin de `batch`: el valor NO
    # puede ir en argv porque `ps` lo lee. Esta prueba fija el camino desde ya.
    visto = {}

    async def falso(arguments, timeout, stdin=None):
        visto.update(arguments=arguments, stdin=stdin)
        return {"exitCode": 0, "stdout": "{}", "stderr": ""}

    monkeypatch.setattr(appmod.cli, "run", falso)
    client.post("/v1/browser/invoke",
                json={"arguments": ["batch", "--json"], "stdin": '{"secreto":"x"}'}, headers=AUTH)
    assert visto["stdin"] == '{"secreto":"x"}'
    assert "x" not in " ".join(visto["arguments"])
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd gemma-memory && python3 -m pytest browser/test_app.py -v`
Expected: FAIL, el endpoint devuelve 501.

- [ ] **Step 3: Implementar `browser/cli.py`: `validate` y `run`**

`validate` busca el primer argumento que no empiece por `-` y que no sea el valor de un flag conocido con valor (`--session`), comprueba que está en `ALLOWED_SUBCOMMANDS`, y rechaza cualquier argumento que empiece por uno de `REJECTED_FLAG_PREFIXES`. `run` usa `asyncio.create_subprocess_exec` —**nunca** `create_subprocess_shell`— con el entorno del proceso, escribe `stdin` si lo hay, y mata el proceso al vencer el plazo. Con `BROWSER_FAKE_CLI=1` devuelve un envelope fijo sin lanzar nada, igual que `VOICE_FAKE_ENGINES` en el servicio de voz.

- [ ] **Step 4: Cambiar el 501 del endpoint por la llamada real**

Con un modelo de Pydantic para el cuerpo. `ValueError` de `validate` → `HTTPException(400)` con el motivo.

- [ ] **Step 5: Correr y verificar que pasan**

Expected: PASS.

- [ ] **Step 6: Verificación en vivo contra el CLI del contenedor**

```bash
cd gemma-memory && docker compose up -d browser
curl -sS -X POST localhost:8083/v1/browser/invoke -H "Authorization: Bearer $MEMORY_BEARER_TOKEN" \
  -H 'content-type: application/json' -d '{"arguments":["open","https://example.com","--json"],"timeout":60}'
```
Expected: un envelope con `"success":true`. Esto es también la prueba de que chromium y Xvfb funcionan dentro del contenedor.

- [ ] **Step 7: Commit**

```bash
cd gemma-memory
git add browser/
git commit -m "feat(browser): proxy del argv del CLI con lista de permitidos y stdin fuera de argv"
```

---

### Task 3: El lector del stream — donde `params` muere

El corazón de seguridad del diseño, y puro: entra texto del socket, sale un mensaje del cable o nada.

**Files:**
- Create: `browser/stream.py`
- Create: `browser/test_stream.py`

**Interfaces:**
- Consumes: nada.
- Produces:
  ```python
  # browser/stream.py
  def decode(text: str) -> dict | None
      # -> {"kind": "frame"|"bad_frame"|"status"|"command"|"other",
      #     "seq": int|None, "jpeg_b64": str|None, "captured_at": float|None,
      #     "screencasting": bool|None, "action": str|None, "url": str|None}
  def phrase(action: str, url: str | None) -> str
  def host_of(url: str | None) -> str | None
  def wire_messages(decoded: dict) -> list[dict]
      # los mensajes de la spec §6.4 listos para el cable, o []
  def ack_seq(decoded: dict) -> int | None
  def summary(host: str | None, action_count: int) -> str
  ```
  `decode` devuelve `url` **solo** cuando `action == "navigate"`, y nunca ninguna otra clave de `params`.

Tabla de frases, de la spec §6.3 (las tres últimas son decisión de este plan, revocables):
`navigate` → `navegando a <host>` (o `navegando`), `click` → `haciendo clic`, `fill`/`type` → `rellenando un campo`, `snapshot` → `leyendo la página`, `wait` → `esperando`, `close` → `cerrando la pestaña`, cualquier otra → el `action` a secas.

- [ ] **Step 1: Escribir las pruebas que fallan**

```python
import base64, json
from stream import decode, phrase, host_of, wire_messages, ack_seq, summary

JPEG = bytes([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])


def test_frame_trae_seq_jpeg_y_fecha():
    d = decode(json.dumps({"type": "frame", "seq": 41,
                           "data": base64.b64encode(JPEG).decode(),
                           "metadata": {"timestamp": 1793996915607}}))
    assert d["kind"] == "frame" and d["seq"] == 41
    assert abs(d["captured_at"] - 1793996915.607) < 0.001


def test_frame_que_no_es_jpeg_es_bad_frame_pero_se_acusa():
    d = decode(json.dumps({"type": "frame", "seq": 7,
                           "data": base64.b64encode(b"hola").decode(),
                           "metadata": {"timestamp": 1}}))
    assert d["kind"] == "bad_frame"
    assert ack_seq(d) == 7, "un frame ilegible se acusa igual: si no, el ritmo se atasca"
    assert wire_messages(d) == [], "y no se manda nada al visor"


def test_frame_con_base64_roto_es_bad_frame():
    d = decode(json.dumps({"type": "frame", "seq": 8, "data": "%%%", "metadata": {"timestamp": 1}}))
    assert d["kind"] == "bad_frame"


# LA PRUEBA QUE IMPORTA, dos veces: en el decodificador y en el cable.
def test_el_valor_de_un_fill_no_sale_del_decodificador():
    d = decode(json.dumps({"type": "command", "action": "fill", "id": "r1",
                           "params": {"selector": "#card", "value": "4111111111111111",
                                      "url": "https://x.test"}}))
    assert d["action"] == "fill"
    assert d["url"] is None, "fill no es navegación: ni la url"
    assert "4111111111111111" not in json.dumps(d)
    assert "#card" not in json.dumps(d)


def test_el_valor_de_un_fill_no_sale_al_cable():
    d = decode(json.dumps({"type": "command", "action": "fill",
                           "params": {"selector": "#card", "value": "4111111111111111"}}))
    cable = json.dumps(wire_messages(d))
    assert "4111111111111111" not in cable and "#card" not in cable
    assert "fill" not in cable, "ni la acción cruda: solo la frase"
    assert "rellenando un campo" in cable


def test_navigate_manda_narracion_y_host_pero_no_la_url_completa():
    d = decode(json.dumps({"type": "command", "action": "navigate",
                           "params": {"url": "https://www.amazon.es/dp/B0?ref=secreto"}}))
    msgs = wire_messages(d)
    kinds = [m["type"] for m in msgs]
    assert kinds == ["narration", "host"]
    cable = json.dumps(msgs)
    assert "secreto" not in cable and "/dp/B0" not in cable
    assert msgs[0]["text"] == "navegando a www.amazon.es"
    assert msgs[1]["host"] == "www.amazon.es"


def test_una_accion_desconocida_sale_como_su_nombre_y_sin_params():
    d = decode(json.dumps({"type": "command", "action": "teletransportar",
                           "params": {"secreto": "abc"}}))
    msgs = wire_messages(d)
    assert msgs[0]["text"] == "teletransportar"
    assert "abc" not in json.dumps(msgs)


def test_result_y_tipos_desconocidos_no_mandan_nada():
    assert wire_messages(decode(json.dumps({"type": "result", "action": "navigate"}))) == []
    assert wire_messages(decode(json.dumps({"type": "tabs", "tabs": []}))) == []


def test_status_trae_screencasting():
    assert decode(json.dumps({"type": "status", "screencasting": True}))["screencasting"] is True
    assert decode(json.dumps({"type": "status"}))["screencasting"] is False


def test_texto_que_no_es_objeto_con_type_devuelve_none():
    assert decode("no soy json") is None
    assert decode("[]") is None
    assert decode('{"sin":"tipo"}') is None


def test_host_of_y_summary():
    assert host_of("https://a.test/x") == "a.test"
    assert host_of("no es url") is None
    assert summary("amazon.es", 1) == "navegó en amazon.es · 1 acción"
    assert summary("amazon.es", 7) == "navegó en amazon.es · 7 acciones"
    assert summary(None, 1) == "navegó en la web · 1 acción"
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd gemma-memory && python3 -m pytest browser/test_stream.py -v`
Expected: FAIL, no existe `browser/stream.py`.

- [ ] **Step 3: Implementar `browser/stream.py`**

La detección de JPEG es olfateo de los tres primeros bytes (`FF D8 FF`) y no una suposición: el spec §5.4 advierte de que el formato puede cambiar por debajo. `metadata.timestamp` es epoch en milisegundos.

- [ ] **Step 4: Correr y verificar que pasan**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd gemma-memory
git add browser/stream.py browser/test_stream.py
git commit -m "feat(browser): lector del stream que no puede transportar params al cable"
```

---

### Task 4: `GET /v1/browser/stream` — el relé

**Files:**
- Modify: `browser/app.py`
- Create: `browser/relay.py`
- Modify: `browser/requirements.txt` — `websockets`
- Modify: `browser/test_app.py`

**Interfaces:**
- Consumes: `stream.decode/wire_messages/ack_seq/summary/phrase`, `cli.run`.
- Produces:
  ```python
  # browser/relay.py
  class PanelState:
      def __init__(self, screencasting: bool) -> None
      live: bool                      # socket_open and acking and screencasting and not collapsed
      action_count: int
      host: str | None
      collapsed: bool
      def apply(self, decoded: dict) -> None
      def freeze(self) -> None
      def snapshot_messages(self) -> list[dict]   # state + summary + host, para un visor que acaba de entrar

  class Relay:
      def __init__(self, read_port: Callable[[], Awaitable[int | None]]) -> None
      async def add_viewer(self, ws, max_fps: int) -> None
      async def on_viewer_ack(self, viewer, seq: int) -> None
  ```
  Y el endpoint `GET /v1/browser/stream?maxFps=N` (WebSocket, `Bearer` en la cabecera o en el parámetro `token`).

- [ ] **Step 1: Escribir las pruebas que fallan**

```python
from relay import PanelState

# --- el predicado de «en vivo» ---
def test_nace_en_vivo_si_el_cli_dijo_screencasting_sin_haber_visto_ningun_status():
    # §5.9: el canal de status no es durable. Si el predicado exigiera haberlo visto,
    # un panel que pinta frames nuevos se marcaría congelado.
    assert PanelState(screencasting=True).live is True


def test_nace_no_vivo_si_el_cli_dijo_que_no():
    assert PanelState(screencasting=False).live is False


def test_pagina_quieta_sigue_en_vivo():
    s = PanelState(screencasting=True)
    s.apply({"kind": "frame", "seq": 1, "captured_at": 0, "jpeg_b64": "x"})
    assert s.live is True, "los frames se emiten por cambio, no por reloj: la edad no decide nada"


def test_un_status_con_screencasting_false_quita_el_en_vivo():
    s = PanelState(screencasting=True)
    s.apply({"kind": "status", "screencasting": False})
    assert s.live is False


def test_freeze_colapsa_y_deja_de_estar_vivo():
    s = PanelState(screencasting=True)
    s.freeze()
    assert s.collapsed is True and s.live is False


def test_cuenta_acciones_y_recuerda_el_host():
    s = PanelState(screencasting=True)
    s.apply({"kind": "command", "action": "navigate", "url": "https://amazon.es/x"})
    s.apply({"kind": "command", "action": "click", "url": None})
    assert s.action_count == 2 and s.host == "amazon.es"


# Review Focus 4: un visor que entra a mitad recibe el estado actual.
def test_un_visor_que_entra_a_mitad_recibe_estado_resumen_y_host():
    s = PanelState(screencasting=True)
    s.apply({"kind": "command", "action": "navigate", "url": "https://amazon.es/x"})
    kinds = [m["type"] for m in s.snapshot_messages()]
    assert "state" in kinds and "summary" in kinds and "host" in kinds


# --- el endpoint ---
def test_el_stream_sin_token_se_rechaza():
    with pytest.raises(Exception):
        with client.websocket_connect("/v1/browser/stream"):
            pass


def test_el_stream_manda_state_al_conectar():
    with client.websocket_connect(f"/v1/browser/stream?token=test-token") as ws:
        first = ws.receive_json()
        assert first["type"] == "state"
        assert set(first) >= {"type", "live", "collapsed"}


def test_el_cable_no_lleva_params_nunca(monkeypatch):
    # Se inyecta un mensaje de `fill` como si viniera del demonio y se lee el cable.
    ...  # el doble del socket del demonio lo provee la suite; ver Step 3
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `cd gemma-memory && python3 -m pytest browser/test_app.py -v`
Expected: FAIL, no existe `relay`.

- [ ] **Step 3: Implementar `PanelState`**

Con las cuatro propiedades privadas del predicado (`socket_open`, `acking`, `screencasting`, `collapsed`). `apply` ignora todo lo que pinte o narre cuando `collapsed`.

- [ ] **Step 4: Implementar `Relay` y el endpoint**

El relé, por sesión:
1. Llama a `read_port()`, que hace `cli.run(["--session","gemma","stream","status","--json"])` y lee `data.port`. **Cada vez que (re)conecta**, nunca cacheado (Review Focus 1).
2. Abre `ws://127.0.0.1:<port>/?pacing=ack&maxFps=10` con `websockets`.
3. Por cada texto: `decode`, luego **anota el `ack_seq` como pendiente** y reparte `wire_messages` a los visores. El `ack` al demonio se manda **solo cuando todos los visores con el frame en vuelo han acusado** — o cuando no queda ningún visor, para que el estado del panel siga vivo sin nadie mirando.
4. Mantiene un `PanelState` y manda `state` cuando cambia, `summary` al colapsar, `closed` al caerse el socket.
5. Fan-out por cliente, con el tope de `maxFps` de cada visor aplicado al **descarte**, no a la cola: si a un visor le toca saltarse un frame, se le salta, no se le encola (Review Focus 3).
6. Nunca escribe un frame a disco ni registra un cuerpo de mensaje.

- [ ] **Step 5: Correr y verificar que pasan**

Expected: PASS.

- [ ] **Step 6: Verificación en vivo en el contenedor**

```bash
cd gemma-memory && docker compose up -d browser
curl -sS -X POST localhost:8083/v1/browser/invoke -H "Authorization: Bearer $MEMORY_BEARER_TOKEN" \
  -H 'content-type: application/json' -d '{"arguments":["open","https://example.com","--json"],"timeout":60}' >/dev/null
python3 - <<'PY'
import asyncio, json, os, websockets
async def main():
    url = f"ws://localhost:8083/v1/browser/stream?token={os.environ['MEMORY_BEARER_TOKEN']}"
    async with websockets.connect(url) as ws:
        for _ in range(5):
            m = json.loads(await ws.recv())
            print(m["type"], {k: v for k, v in m.items() if k != "jpeg"})
            if m["type"] == "frame":
                await ws.send(json.dumps({"type": "ack", "seq": m["seq"]}))
asyncio.run(main())
PY
```
Expected: un `state` y después `frame`/`narration`. Si solo llega el primer `frame` y nada más, el encadenado del acuse está mal: es la verificación por el efecto que pide la spec §5.8.

- [ ] **Step 7: Commit**

```bash
cd gemma-memory
git add browser/
git commit -m "feat(browser): rele del stream con acuse encadenado y estado decidido en el i3"
```

---

# Lado app — `personal_agent`

### Task 5: Las nueve herramientas pasan a hablar con el i3

Sin esto el panel muestra un navegador que el agente no conduce: el agente lanzaría un demonio local en el Mac y el panel mostraría el del i3, en blanco para siempre. Es un requisito, no una mejora.

**Files:**
- Create: `Gemma/Gemma/NativeServices/HTTPAgentBrowserInvoker.swift`
- Modify: `Gemma/Gemma/Settings/SettingsKeys.swift` — `browserBaseURL`, `browserBearerToken`
- Modify: `Gemma/Gemma/Settings/SettingsView.swift` — los dos campos
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift` — `registerBrowserTools` construye el `AgentBrowserService` con el invocador HTTP cuando hay URL configurada
- Test: `Gemma/GemmaTests/HTTPAgentBrowserInvokerTests.swift`

**Interfaces:**
- Consumes: `AgentBrowserInvoking`, `AgentBrowserInvocation`, `AgentBrowserInvocationFailure`.
- Produces:
  ```swift
  public struct HTTPAgentBrowserInvoker: AgentBrowserInvoking, Sendable {
      public init(baseURL: URL, bearerToken: String, session: URLSession = .shared)
      public func invoke(arguments: [String], timeout: TimeInterval) async
          -> Result<AgentBrowserInvocation, AgentBrowserInvocationFailure>
  }
  ```
  Mismo protocolo que `ProcessAgentBrowserInvoker`, así que `AgentBrowserService` y las nueve herramientas **no cambian**.

- [ ] **Step 1: Escribir las pruebas que fallan**

```swift
func test_manda_el_argv_y_el_plazo_en_el_cuerpo() async throws {
    let (invoker, stub) = Self.invoker(responding: #"{"exitCode":0,"stdout":"{}","stderr":""}"#)
    _ = await invoker.invoke(arguments: ["--session", "gemma", "open", "https://a.test", "--json"],
                             timeout: 60)
    let body = try XCTUnwrap(stub.lastBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["arguments"] as? [String],
                   ["--session", "gemma", "open", "https://a.test", "--json"])
    XCTAssertEqual(json["timeout"] as? Double, 60)
}

func test_manda_el_bearer_y_pega_la_ruta_al_base() async {
    let (invoker, stub) = Self.invoker(responding: #"{"exitCode":0,"stdout":"{}","stderr":""}"#)
    _ = await invoker.invoke(arguments: ["stream", "status"], timeout: 10)
    XCTAssertEqual(stub.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer t0k3n")
    XCTAssertEqual(stub.lastRequest?.url?.path, "/v1/browser/invoke")
}

func test_devuelve_el_stdout_del_cli_sin_interpretarlo() async throws {
    let envelope = #"{\"success\":true,\"data\":{\"title\":\"T\"},\"error\":null}"#
    let (invoker, _) = Self.invoker(responding: #"{"exitCode":0,"stdout":"\#(envelope)","stderr":""}"#)
    guard case .success(let run) = await invoker.invoke(arguments: ["get", "title"], timeout: 10)
    else { return XCTFail("esperaba .success") }
    XCTAssertTrue(run.standardOutput.contains("\"success\":true"),
                  "el invocador no interpreta el envelope: eso es de AgentBrowserService")
}

/// Review Focus 2: el i3 caído tiene que dar el mismo estado accionable que un binario ausente.
func test_un_error_de_red_es_launchFailed_con_motivo() async {
    let (invoker, _) = Self.invoker(failingWith: URLError(.cannotConnectToHost))
    guard case .failure(.launchFailed(let detail)) = await invoker.invoke(arguments: ["open", "https://a.test"], timeout: 10)
    else { return XCTFail("esperaba .launchFailed") }
    XCTAssertFalse(detail.isEmpty, "el motivo llega al usuario: 'no pude hablar con el i3'")
}

func test_un_401_dice_que_el_token_esta_mal_y_no_se_confunde_con_un_rechazo_del_cli() async {
    let (invoker, _) = Self.invoker(status: 401, responding: #"{"detail":"unauthorized"}"#)
    guard case .failure(.launchFailed(let detail)) = await invoker.invoke(arguments: ["open", "https://a.test"], timeout: 10)
    else { return XCTFail("esperaba .launchFailed") }
    XCTAssertTrue(detail.contains("401"))
}

func test_un_400_del_servicio_tambien_es_fallo_de_invocacion_no_un_envelope() async {
    let (invoker, _) = Self.invoker(status: 400, responding: #"{"detail":"subcomando no permitido: eval"}"#)
    guard case .failure = await invoker.invoke(arguments: ["eval", "1+1"], timeout: 10)
    else { return XCTFail("esperaba .failure") }
}

func test_el_plazo_de_la_peticion_deja_margen_sobre_el_del_cli() async {
    let (invoker, stub) = Self.invoker(responding: #"{"exitCode":0,"stdout":"{}","stderr":""}"#)
    _ = await invoker.invoke(arguments: ["open", "https://a.test"], timeout: 60)
    let interval = try! XCTUnwrap(stub.lastRequest?.timeoutInterval)
    XCTAssertGreaterThan(interval, 60, "el viaje de red se suma al plazo del CLI, no se le resta")
}
```

`Self.invoker(...)` monta un `URLSession` con un `URLProtocol` de prueba que registra la petición y devuelve lo pedido. Si el repo ya tiene ese ayudante para `MemoryClient`, se reusa.

- [ ] **Step 2: Correr y verificar que fallan**

Run: `xcodebuild test … -only-testing:GemmaTests/HTTPAgentBrowserInvokerTests 2>&1 | tail -20`
Expected: FAIL, no existe `HTTPAgentBrowserInvoker`.

- [ ] **Step 3: Implementar `HTTPAgentBrowserInvoker`**

`POST <base>/v1/browser/invoke` con `{"arguments": [...], "timeout": <s>}`, `Authorization: Bearer`, `timeoutInterval` = `timeout` + margen. Respuesta 2xx → decodificar `{exitCode, stdout, stderr}` a `AgentBrowserInvocation`. Cualquier otra cosa o error de transporte → `.launchFailed` con un motivo legible que nombre el i3.

- [ ] **Step 4: Añadir los dos ajustes y cablear `registerBrowserTools`**

`browserBaseURL` y `browserBearerToken` en `SettingsKeys` y en `SettingsView`, con el patrón que ya usan `memoryBaseURL` y su token. En `registerBrowserTools`: si hay URL configurada, el servicio se construye con `HTTPAgentBrowserInvoker`; si no, con `ProcessAgentBrowserInvoker`, que es el comportamiento de hoy. Así la app sigue funcionando sin el i3 y el cambio es reversible desde Settings.

- [ ] **Step 5: Correr la suite completa y verificar que pasa**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' 2>&1 | tail -30`
Expected: PASS salvo el fallo conocido. **Las pruebas de las nueve herramientas no se tocan y tienen que seguir verdes**: son la prueba de que el seam funcionó.

- [ ] **Step 6: Commit**

```bash
git add Gemma/Gemma/NativeServices/HTTPAgentBrowserInvoker.swift Gemma/Gemma/Settings/ Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/HTTPAgentBrowserInvokerTests.swift
git commit -m "feat(panel): las nueve herramientas conducen el navegador del i3 por HTTP"
```

---

### Task 6: El cliente del relé, sin nada de Apple más que Foundation

**Files:**
- Create: `Gemma/Gemma/NativeServices/BrowserRelayClient.swift`
- Test: `Gemma/GemmaTests/BrowserRelayClientTests.swift`

**Interfaces:**
- Consumes: nada del proyecto.
- Produces:
  ```swift
  public enum BrowserRelayEvent: Equatable, Sendable {
      case frame(seq: Int, jpeg: Data, capturedAt: Date)
      case narration(String)
      case host(String)
      case state(live: Bool, collapsed: Bool)
      case summary(String)
      case closed(reason: String)
  }

  public actor BrowserRelayClient {
      public init(baseURL: URL, bearerToken: String, maxFps: Int = 10, session: URLSession = .shared)
      public static func socketURL(baseURL: URL, maxFps: Int) -> URL?
      public static func decode(_ text: String) -> BrowserRelayEvent?
      public static func ackPayload(seq: Int) -> String
      public func events() -> AsyncStream<BrowserRelayEvent>
      public func stop()
  }
  ```
  `decode` es puro y es lo que se prueba aquí; el bucle del socket lo verifica la Tarea 9.

- [ ] **Step 1: Escribir las pruebas que fallan**

```swift
func test_la_url_del_socket_sale_del_base_http_con_esquema_ws() {
    let url = BrowserRelayClient.socketURL(baseURL: URL(string: "http://100.91.174.81:8083")!, maxFps: 10)
    XCTAssertEqual(url?.absoluteString, "ws://100.91.174.81:8083/v1/browser/stream?maxFps=10")
}

func test_un_base_https_da_wss() {
    let url = BrowserRelayClient.socketURL(baseURL: URL(string: "https://i3.test")!, maxFps: 10)
    XCTAssertEqual(url?.scheme, "wss")
}

func test_decodifica_frame_con_el_jpeg_en_bytes() throws {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
    let text = #"{"type":"frame","seq":41,"jpeg":"\#(jpeg.base64EncodedString())","captured_at":1793996915.607}"#
    guard case .frame(let seq, let bytes, let at) = try XCTUnwrap(BrowserRelayClient.decode(text))
    else { return XCTFail("esperaba .frame") }
    XCTAssertEqual(seq, 41)
    XCTAssertEqual(bytes, jpeg)
    XCTAssertEqual(at.timeIntervalSince1970, 1793996915.607, accuracy: 0.001)
}

func test_decodifica_los_otros_cinco_mensajes() throws {
    XCTAssertEqual(try XCTUnwrap(BrowserRelayClient.decode(#"{"type":"narration","text":"haciendo clic"}"#)),
                   .narration("haciendo clic"))
    XCTAssertEqual(try XCTUnwrap(BrowserRelayClient.decode(#"{"type":"host","host":"amazon.es"}"#)),
                   .host("amazon.es"))
    XCTAssertEqual(try XCTUnwrap(BrowserRelayClient.decode(#"{"type":"state","live":true,"collapsed":false}"#)),
                   .state(live: true, collapsed: false))
    XCTAssertEqual(try XCTUnwrap(BrowserRelayClient.decode(#"{"type":"summary","text":"navegó en amazon.es · 7 acciones"}"#)),
                   .summary("navegó en amazon.es · 7 acciones"))
    XCTAssertEqual(try XCTUnwrap(BrowserRelayClient.decode(#"{"type":"closed","reason":"socket caído"}"#)),
                   .closed(reason: "socket caído"))
}

func test_un_mensaje_desconocido_se_ignora_sin_romper() {
    XCTAssertNil(BrowserRelayClient.decode(#"{"type":"loquesea"}"#))
    XCTAssertNil(BrowserRelayClient.decode("no soy json"))
}

/// El cable no debería traer params nunca, pero si un relé viejo lo trajera,
/// el cliente no tiene ningún caso donde meterlo. Esta prueba fija esa garantía.
func test_un_frame_con_campos_de_mas_no_los_transporta() throws {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
    let text = #"{"type":"frame","seq":1,"jpeg":"\#(jpeg.base64EncodedString())","captured_at":1,"params":{"value":"SECRETO"}}"#
    guard case .frame(_, let bytes, _) = try XCTUnwrap(BrowserRelayClient.decode(text))
    else { return XCTFail("esperaba .frame") }
    XCTAssertEqual(bytes, jpeg, "el enum no tiene dónde guardar params")
}

func test_el_acuse_tiene_la_forma_exacta() throws {
    let json = try XCTUnwrap(JSONSerialization.jsonObject(
        with: Data(BrowserRelayClient.ackPayload(seq: 41).utf8)) as? [String: Any])
    XCTAssertEqual(json["type"] as? String, "ack")
    XCTAssertEqual(json["seq"] as? Int, 41)
}
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: `xcodebuild test … -only-testing:GemmaTests/BrowserRelayClientTests 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Implementar las tres estáticas y el bucle del actor**

El bucle abre el socket con el `Bearer` en la cabecera, recibe, decodifica, **acusa cada `frame`** y emite el evento. Error de recepción → `.closed(reason:)` y fin del `AsyncStream`. `onTermination` cierra el socket, para que cancelar el consumidor lo cierre todo. El actor no es el hilo principal; **no decodifica JPEG**, lo pasa en bytes.

- [ ] **Step 4: Correr y verificar que pasan**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/NativeServices/BrowserRelayClient.swift Gemma/GemmaTests/BrowserRelayClientTests.swift
git commit -m "feat(panel): cliente del rele del i3, portable y sin decodificar imagen"
```

---

### Task 7: El estado del panel y el coordinador — un panel por turno

**Files:**
- Create: `Gemma/Gemma/Harness/BrowserPanelState.swift`
- Create: `Gemma/Gemma/Harness/BrowserPanelCoordinator.swift`
- Test: `Gemma/GemmaTests/BrowserPanelStateTests.swift`
- Test: `Gemma/GemmaTests/BrowserPanelCoordinatorTests.swift`

**Interfaces:**
- Consumes: `BrowserRelayEvent`, `Agent.browserToolNames`.
- Produces:
  ```swift
  @Observable @MainActor
  public final class BrowserPanelState {
      public private(set) var jpeg: Data?
      public private(set) var phrase: String
      public private(set) var summary: String
      public private(set) var lastFrameAt: Date?
      public private(set) var isLive: Bool
      public private(set) var isCollapsed: Bool
      public init()
      public func apply(_ event: BrowserRelayEvent)
      public func freeze()
  }

  @MainActor
  public final class BrowserPanelCoordinator {
      public typealias StreamFactory = @MainActor () -> AsyncStream<BrowserRelayEvent>?
      public private(set) var panels: [String: BrowserPanelState]
      public private(set) var activeID: String?
      public init(stream: @escaping StreamFactory)
      public func openIfNeeded(toolName: String) -> String?
      public func endTurn()
      public nonisolated static func isBrowserTool(_ name: String) -> Bool
  }
  ```
  `isLive` y `summary` **se reciben**, no se calculan: los decide el i3 (spec §5.10). El estado arranca con `isLive = false` y lo pone a `true` el primer `state` del relé, que el relé manda al conectar.

- [ ] **Step 1: Escribir las pruebas que fallan**

```swift
// BrowserPanelStateTests
@MainActor func test_el_en_vivo_llega_del_i3_no_se_calcula() {
    let s = BrowserPanelState()
    XCTAssertFalse(s.isLive)
    s.apply(.state(live: true, collapsed: false))
    XCTAssertTrue(s.isLive, "la app no decide si está vivo: lo recibe")
}

@MainActor func test_pagina_quieta_sigue_en_vivo_porque_la_edad_no_decide() {
    let s = BrowserPanelState()
    s.apply(.state(live: true, collapsed: false))
    s.apply(.frame(seq: 1, jpeg: Data([0xFF, 0xD8, 0xFF]), capturedAt: Date(timeIntervalSinceNow: -30)))
    XCTAssertTrue(s.isLive)
    XCTAssertNotNil(s.lastFrameAt, "la edad se muestra, pero no decide")
}

@MainActor func test_solo_guarda_el_frame_mas_nuevo() {
    let s = BrowserPanelState()
    s.apply(.frame(seq: 1, jpeg: Data([0x01]), capturedAt: .now))
    s.apply(.frame(seq: 2, jpeg: Data([0x02]), capturedAt: .now))
    XCTAssertEqual(s.jpeg, Data([0x02]), "un frame a la vez: el anterior se suelta")
}

@MainActor func test_closed_colapsa_y_suelta_la_imagen() {
    let s = BrowserPanelState()
    s.apply(.state(live: true, collapsed: false))
    s.apply(.frame(seq: 1, jpeg: Data([0x01]), capturedAt: .now))
    s.apply(.closed(reason: "fin del turno"))
    XCTAssertTrue(s.isCollapsed)
    XCTAssertFalse(s.isLive)
    XCTAssertNil(s.jpeg, "§6.2(g): un panel congelado no deja imagen en el historial")
}

/// Un frame que llega después de congelar no puede reabrir el secreto en reposo.
@MainActor func test_un_frame_despues_de_congelar_no_repinta() {
    let s = BrowserPanelState()
    s.freeze()
    s.apply(.frame(seq: 9, jpeg: Data([0x01]), capturedAt: .now))
    XCTAssertNil(s.jpeg)
}

@MainActor func test_la_narracion_y_el_resumen_se_guardan_tal_como_llegan() {
    let s = BrowserPanelState()
    s.apply(.narration("haciendo clic"))
    s.apply(.summary("navegó en amazon.es · 7 acciones"))
    XCTAssertEqual(s.phrase, "haciendo clic")
    XCTAssertEqual(s.summary, "navegó en amazon.es · 7 acciones")
}

// BrowserPanelCoordinatorTests
@MainActor func test_una_herramienta_que_no_es_de_navegador_no_abre_panel() {
    let c = Self.coordinator()
    XCTAssertNil(c.openIfNeeded(toolName: "save_memory"))
    XCTAssertTrue(c.panels.isEmpty)
}

@MainActor func test_la_primera_herramienta_de_navegador_abre_un_panel() {
    let c = Self.coordinator()
    let id = c.openIfNeeded(toolName: "browser_open")
    XCTAssertNotNil(id)
    XCTAssertEqual(c.activeID, id)
}

@MainActor func test_un_turno_con_varias_acciones_tiene_un_solo_panel() {
    let c = Self.coordinator()
    let first = c.openIfNeeded(toolName: "browser_open")
    XCTAssertNil(c.openIfNeeded(toolName: "browser_click"))
    XCTAssertNil(c.openIfNeeded(toolName: "browser_snapshot"))
    XCTAssertEqual(c.panels.count, 1)
    XCTAssertEqual(c.activeID, first)
}

@MainActor func test_el_turno_siguiente_abre_otro_panel_y_el_viejo_queda_colapsado() {
    let c = Self.coordinator()
    let first = try! XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
    c.endTurn()
    let second = try! XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
    XCTAssertNotEqual(second, first)
    XCTAssertTrue(c.panels[first]!.isCollapsed)
    XCTAssertFalse(c.panels[second]!.isCollapsed)
    XCTAssertEqual(c.panels.count, 2, "los dos siguen en el historial; solo uno conectado")
}

@MainActor func test_abrir_sin_cerrar_antes_congela_el_anterior_igual() {
    let c = Self.coordinator()
    let first = try! XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))
    let second = try! XCTUnwrap(c.openIfNeeded(toolName: "browser_open"))  // sin endTurn
    XCTAssertEqual(second, first, "dentro del mismo turno no hay segundo panel")
    c.endTurn()
    XCTAssertTrue(c.panels[first]!.isCollapsed)
}

/// Review Focus 2: sin i3 configurado, la fábrica devuelve nil y no aparece panel.
@MainActor func test_sin_rele_no_aparece_panel() {
    let c = BrowserPanelCoordinator(stream: { nil })
    XCTAssertNil(c.openIfNeeded(toolName: "browser_open"))
    XCTAssertTrue(c.panels.isEmpty)
}

func test_isBrowserTool_cubre_las_nueve_mas_read_webpage() {
    for name in Agent.browserToolNames { XCTAssertTrue(BrowserPanelCoordinator.isBrowserTool(name), name) }
    XCTAssertTrue(BrowserPanelCoordinator.isBrowserTool("read_webpage"))
    XCTAssertFalse(BrowserPanelCoordinator.isBrowserTool("web_search"))
}
```

- [ ] **Step 2: Correr y verificar que fallan**

Run: las dos suites nuevas.
Expected: FAIL.

- [ ] **Step 3: Implementar `BrowserPanelState`**

`apply` ignora todo lo que pinte o narre cuando `isCollapsed`. `phrase` arranca en `"abriendo el navegador"`; `summary` en `""`.

- [ ] **Step 4: Implementar `BrowserPanelCoordinator`**

`openIfNeeded` devuelve `nil` si la herramienta no es de navegador, si ya hay panel activo, o si la fábrica devuelve `nil`. Al crear uno, congela el activo anterior **antes** de pedir el flujo nuevo. Cada panel arranca una tarea que consume el `AsyncStream` y llama a `apply`; al terminar el flujo, `freeze()`. `endTurn()` congela el activo y pone `activeID` a `nil`.

- [ ] **Step 5: Correr y verificar que pasan**

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Gemma/Gemma/Harness/BrowserPanelState.swift Gemma/Gemma/Harness/BrowserPanelCoordinator.swift Gemma/GemmaTests/BrowserPanelStateTests.swift Gemma/GemmaTests/BrowserPanelCoordinatorTests.swift
git commit -m "feat(panel): estado y coordinador del panel, con el en-vivo recibido del i3"
```

---

### Task 8: Pintarlo en el chat

**Files:**
- Create: `Gemma/Gemma/Harness/BrowserPanelView.swift`
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift` — `ChatLogEntry` (líneas 7-21), `.toolCallStarted` (línea 595), el final del turno y `stopAgentTurn`
- Modify: `Gemma/Gemma/Harness/AgentChatView.swift` — el `ForEach` (líneas 346-356) y `ChatLogRow` (línea 569)
- Test: `Gemma/GemmaTests/BrowserPanelWiringTests.swift`

**Interfaces:**
- Consumes: `BrowserPanelCoordinator`, `BrowserPanelState`, `BrowserRelayClient`.
- Produces:
  ```swift
  public var panelID: String?                 // campo nuevo de ChatLogEntry, con valor por omisión
  @ObservationIgnored public private(set) var browserPanels: BrowserPanelCoordinator   // en HarnessModel
  struct BrowserPanelView: View { let state: BrowserPanelState }
  ```

- [ ] **Step 1: Escribir las pruebas que fallan**

```swift
func test_chatLogEntry_sin_panelID_se_construye_igual_que_antes() {
    XCTAssertNil(ChatLogEntry(role: "tool", text: "🔧 x").panelID)
}

func test_una_entrada_de_panel_lleva_rol_propio_y_su_id() {
    let entry = ChatLogEntry(role: "browserPanel", text: "", panelID: "p1")
    XCTAssertEqual(entry.role, "browserPanel")
    XCTAssertEqual(entry.panelID, "p1")
    XCTAssertTrue(entry.text.isEmpty, "el panel no lleva texto: lo pinta la vista desde el estado")
}

/// Detener la generación congela el panel: si no, la pantalla del pago queda viva.
@MainActor func test_detener_el_turno_congela_el_panel_activo() {
    let model = Self.makeModel()
    let id = try! XCTUnwrap(model.browserPanels.openIfNeeded(toolName: "browser_open"))
    model.stopAgentTurn()
    XCTAssertTrue(model.browserPanels.panels[id]!.isCollapsed)
    XCTAssertNil(model.browserPanels.activeID)
}

/// La decodificación del JPEG no puede ocurrir en el hilo principal.
@MainActor func test_la_vista_decodifica_fuera_del_hilo_principal() async {
    let state = BrowserPanelState()
    state.apply(.frame(seq: 1, jpeg: Self.realJPEG(), capturedAt: .now))
    let image = await BrowserPanelView.decodeOffMain(state.jpeg!)
    XCTAssertNotNil(image)
}
```

Si `HarnessModel` no tiene un constructor usable en pruebas, `Self.makeModel()` usa el mismo camino que `HarnessModelTests`; si no existe ninguno, esta prueba se escribe sobre el coordinador (`endTurn()` tras `openIfNeeded`) y el informe anota que el camino de `stopAgentTurn` lo cubre la Tarea 9.

- [ ] **Step 2: Correr y verificar que fallan**

Run: `xcodebuild test … -only-testing:GemmaTests/BrowserPanelWiringTests 2>&1 | tail -20`
Expected: FAIL, no existe `panelID`.

- [ ] **Step 3: Añadir `panelID` y el coordinador a `HarnessModel`**

El coordinador se construye con una fábrica que devuelve `nil` cuando no hay `browserBaseURL` configurada, y si la hay, `BrowserRelayClient(baseURL:bearerToken:).events()`. Todo bajo `#if os(macOS)`.

- [ ] **Step 4: Disparar y cerrar el panel en el bucle del turno**

En `.toolCallStarted(let n, _)`, tras la entrada `role: "tool"` que ya se añade:
`if let id = browserPanels.openIfNeeded(toolName: n) { agentLog.append(ChatLogEntry(role: "browserPanel", text: "", panelID: id)) }`.
`browserPanels.endTurn()` al salir del bucle, en `catch is CancellationError`, en `catch`, y en `stopAgentTurn()`.

- [ ] **Step 5: Implementar `BrowserPanelView`**

`static func decodeOffMain(_ jpeg: Data) async -> CGImage?` hace el trabajo de ImageIO en una tarea de fondo y es lo que la vista llama con `.task(id: state.jpeg)`. Dos estados: **en vivo**, la imagen al ancho de la burbuja con alto máximo fijo, la frase arriba en monoespaciada pequeña, «en vivo» con punto verde abajo a la derecha, y la edad del último frame en gris solo si pasa de dos segundos —presentación y nada más, spec §8(2)—; **colapsado**, una línea con `state.summary` y sin imagen.

`ChatLogRow` gana `case "browserPanel"` y un parámetro `let panel: BrowserPanelState?`; `AgentChatView` lo pasa con `entry.panelID.flatMap { model.browserPanels.panels[$0] }`. Con `nil`, la fila no pinta nada.

- [ ] **Step 6: Correr la suite completa**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' 2>&1 | tail -30`
Expected: PASS salvo el fallo conocido.

- [ ] **Step 7: Commit**

```bash
git add Gemma/Gemma/Harness/ Gemma/GemmaTests/BrowserPanelWiringTests.swift
git commit -m "feat(panel): el panel aparece en el chat por turno y colapsa al acabar"
```

---

### Task 9: De punta a punta, contra el i3 de verdad

**Files:**
- Modify: `Gemma/GemmaTests/AgentBrowserLiveTests.swift`

**Interfaces:**
- Consumes: todo lo anterior.
- Produces: nada.

Guardián nuevo, junto al que el fichero ya tiene: `GEMMA_LIVE_I3=1` más `GEMMA_I3_BROWSER_URL` y `GEMMA_I3_BROWSER_TOKEN`. Sin ellos, se omiten.

- [ ] **Step 1: Escribir las pruebas en vivo**

```swift
func test_en_vivo_una_herramienta_conduce_el_navegador_del_i3() async throws {
    try requireLiveI3()
    let service = AgentBrowserService(invoker: Self.i3Invoker(), sessionName: Self.liveSession)
    let out = await BrowserNavigateTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#)
    XCTAssertEqual(try parse(out)["status"] as? String, "success", "got: \(out)")
}

/// La prueba del acuse POR EL EFECTO, de punta a punta: si el encadenado
/// visor→relé→demonio estuviera mal, el flujo se pararía en el primer frame.
func test_en_vivo_llegan_dos_o_mas_frames_del_rele() async throws {
    try requireLiveI3()
    let client = BrowserRelayClient(baseURL: Self.i3URL(), bearerToken: Self.i3Token())
    var frames = 0
    let deadline = Date(timeIntervalSinceNow: 25)
    for await event in client.events() {
        if case .frame = event { frames += 1 }
        if frames >= 2 || Date() > deadline { break }
    }
    await client.stop()
    XCTAssertGreaterThanOrEqual(frames, 2)
}

/// EL ANTI OBJETIVO PRINCIPAL, de punta a punta.
@MainActor
func test_en_vivo_pagina_quieta_treinta_segundos_sigue_diciendo_en_vivo() async throws {
    try requireLiveI3()
    let service = AgentBrowserService(invoker: Self.i3Invoker(), sessionName: Self.liveSession)
    _ = await BrowserNavigateTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#)
    let state = BrowserPanelState()
    let client = BrowserRelayClient(baseURL: Self.i3URL(), bearerToken: Self.i3Token())
    let pump = Task { @MainActor in for await e in client.events() { state.apply(e) } }
    try await Task.sleep(for: .seconds(30))
    XCTAssertTrue(state.isLive, "página quieta: no llega ni un frame en 30 s y sigue viva")
    pump.cancel(); await client.stop()
}

/// LA PRUEBA DE SEGURIDAD, sobre el cable real.
func test_en_vivo_un_fill_no_manda_su_valor_por_el_cable() async throws {
    try requireLiveI3()
    let service = AgentBrowserService(invoker: Self.i3Invoker(), sessionName: Self.liveSession)
    _ = await BrowserNavigateTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#)
    let client = BrowserRelayClient(baseURL: Self.i3URL(), bearerToken: Self.i3Token())
    var narrations: [String] = []
    let collector = Task { for await e in client.events() { if case .narration(let t) = e { narrations.append(t) } } }
    _ = await BrowserFillTool(service: service).run(argsJSON: #"{"selector":"body","text":"SECRETO123"}"#)
    try await Task.sleep(for: .seconds(3))
    collector.cancel(); await client.stop()
    XCTAssertFalse(narrations.contains { $0.contains("SECRETO123") })
    XCTAssertFalse(narrations.contains { $0.contains("body") })
}

/// Review Focus 2, en vivo: con el i3 inalcanzable, el estado es accionable.
func test_en_vivo_un_i3_inalcanzable_da_not_available_y_no_rompe() async throws {
    try requireLiveI3()
    let invoker = HTTPAgentBrowserInvoker(baseURL: URL(string: "http://127.0.0.1:1")!, bearerToken: "x")
    let out = await BrowserNavigateTool(service: AgentBrowserService(invoker: invoker, sessionName: "x"))
        .run(argsJSON: #"{"url":"https://example.com"}"#)
    XCTAssertEqual(try parse(out)["status"] as? String, "not_available", "got: \(out)")
}

func test_en_vivo_cierra_la_sesion_de_prueba() async throws {
    try requireLiveI3()
    _ = await BrowserCloseTool(service: AgentBrowserService(invoker: Self.i3Invoker(), sessionName: Self.liveSession))
        .run(argsJSON: "{}")
}
```

Los nombres de las herramientas se toman de los que el fichero ya usa; si difieren, se usan los reales sin cambiar la intención.

- [ ] **Step 2: Correr la suite en vivo contra el i3**

Run:
```
TEST_RUNNER_GEMMA_LIVE_I3=1 \
TEST_RUNNER_GEMMA_I3_BROWSER_URL=http://100.91.174.81:8083 \
TEST_RUNNER_GEMMA_I3_BROWSER_TOKEN=$MEMORY_BEARER_TOKEN \
xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/AgentBrowserLiveTests 2>&1 | tail -30
```
Expected: PASS. (`100.91.174.81` es `homelab` en Tailscale.)

- [ ] **Step 3: Correr la suite normal y confirmar que las nuevas se omiten**

Expected: PASS; las pruebas en vivo omitidas y sin tocar la red.

- [ ] **Step 4: Commit**

```bash
git add Gemma/GemmaTests/AgentBrowserLiveTests.swift
git commit -m "test(panel): de punta a punta contra el i3, con la prueba del valor que no viaja"
```

---

## Autorrevisión

**1. Cobertura del spec.** §5.1 no llamar a `enable` → T4 (el relé solo hace `stream status`) y T2 (`enable` no está en la lista de permitidos). §5.2 leer el puerto cada vez → T4. §5.3 y §6.2(b) variables y tragar el peor frame → T1 (las ocho variables) y T8 (la vista reduce). §5.4 olfatear el JPEG → T3. §5.5 y §6.2(c) `pacing=ack&maxFps=10` → T4. §5.6 ack → T4 y T9. §5.7 narración desde `command` → T3. §5.8 probar el acuse por el efecto → T4 Step 6 y T9. §5.9 no derivar estado de los mensajes de canal → T4 (`PanelState` nace sembrado del CLI). §5.10 el reparto i3/app → T1 a T8; el servicio en Python, T1. §6.1 panel en el chat por turno → T7, T8. §6.2(a) frames nunca a disco → restricción global; ninguna tarea escribe ficheros. §6.2(e) las cinco degradaciones → T2 y T4 (sin puerto), T6 (`closed`), T7 (congelado), T3 (frame ilegible acusado y no enviado), T5 (i3 caído). §6.2(f) el predicado → T4. §6.2(g) suelta la imagen → T7. §6.3 la regla del filtrado → T3, dos veces: en el decodificador y en el cable. §6.4 los seis mensajes y el acuse encadenado → T4 y T6. §7 nada de control remoto: ninguna tarea manda `input_*`, y el relé no acepta mensajes del visor que no sean `ack`. §8(1) forma del relé → T4. §8(2) presentación de la edad → T8. §8(3) disparo y cierre → T7, T8. §8(4) variables del demonio → T1. §8(5) tope de fps por cliente → T4. §8(6) el acuse y su prueba → T4, T9. §8(7) dos sesiones → T7: un solo panel activo. §8(8) autenticación del visor → T1, T6. §10 ciclo de vida → T7. §11(1) las herramientas por red → T5. §11(2) ancho de banda → T4 (tope por cliente). §11(3) Chrome en el i3 → T1. Las catorce clases de entrada del spec quedan repartidas entre T2, T3, T4, T5, T6, T7 y T9. Sin huecos.

**2. Pasos.** Cada paso de código lleva firma exacta y fichero; los cuerpos solo aparecen donde la firma y las pruebas no determinan el algoritmo (el bucle del relé en T4, el del actor en T6, los dos estados de la vista en T8). Ningún paso dice «manejar casos límite».

**3. Consistencia de tipos.** `cli.run(arguments, timeout, stdin)` (T2) lo usa `read_port` del relé (T4). `stream.decode` → `wire_messages`/`ack_seq` (T3) los usa el bucle de T4. Los seis mensajes de `wire_messages` (T3) son exactamente los seis casos de `BrowserRelayEvent` (T6). `BrowserRelayEvent` lo aplica `BrowserPanelState.apply` (T7). `BrowserPanelState` lo guarda el coordinador (T7) y lo pinta la vista (T8). `endTurn()` se define en T7 y se llama en T8. `HTTPAgentBrowserInvoker` (T5) y el endpoint de T2 comparten el cuerpo `{arguments, timeout, stdin}`. Un solo nombre por cosa.

**4. Review Focus.** Las cinco líneas tienen prueba: 1 → `read_port` se llama en cada reconexión (T4) y la verificación en vivo de T2 Step 6 levanta el demonio en frío; 2 → `test_un_error_de_red_es_launchFailed_con_motivo` (T5), `test_sin_rele_no_aparece_panel` (T7) y `test_en_vivo_un_i3_inalcanzable_da_not_available_y_no_rompe` (T9); 3 → el fan-out con descarte por cliente y el acuse por cliente (T4); 4 → `test_un_visor_que_entra_a_mitad_recibe_estado_resumen_y_host` (T4); 5 → los cuatro tests de validación de T2.

**5. Proporción.** El spec son 773 líneas; este plan, 1204, es decir 1,56 veces. Revisado con ese número delante: la mayor parte son aserciones de prueba con los valores exactos del spec y las firmas exactas, que es lo que el implementador no puede inventar, y no hay ningún cuerpo de función transcrito. Lo que justifica el exceso sobre el spec es que este plan cruza **dos lenguajes y dos repositorios**: cada pieza del cable aparece dos veces, una en Python y otra en Swift, y las dos necesitan sus valores exactos para que los seis mensajes de la §6.4 coincidan. Si una tarea quedara larga al ejecutarla, la candidata es la 4, que es la única con cuerpo descrito en seis pasos.

---

## Orden y por qué

Las tareas 1 a 4 entregan un navegador conducible por red con su panel, verificable con `curl` y un script de cinco líneas, **antes de tocar la app**. La 5 es la que hace que el panel tenga sentido: sin ella el agente conduciría un navegador en el Mac y el panel mostraría otro, en blanco, en el i3. Las 6 a 8 son el visor. La 9 ata los dos lados.

Si hubiera que parar a mitad, el punto limpio es **después de la 5**: el navegador vive en el i3, las nueve herramientas funcionan contra él, y el panel simplemente no aparece todavía.
