# Chrome real en el i3 — Spec + Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el navegador del agente en el i3 sea un Google Chrome REAL (con ventana bajo Xvfb, perfil persistente, sin banderas de automatización, conducido por `agent-browser --cdp`, el mismo patrón que la Mac), para que Google y compañía dejen iniciar sesión; y que el usuario pueda iniciar esa sesión SIN mando, pidiéndoselo al agente: `present_form` (campo `secret`) → `browser_fill_secret`, que hoy solo funciona con el `agent-browser` local de la Mac.

**Architecture:** En el servidor (`gemma-memory/browser/`), un módulo nuevo `chrome.py` posee el Chrome del contenedor igual que `ChromeRealDeLaMac` posee el de la Mac: lo abre antes del `open`, lo cierra tras el `close`, y además lo cierra por inactividad. Xvfb lo arranca el `entrypoint.sh`; `AGENT_BROWSER_CDP=9222` hace que TODA invocación del CLI (incluidas las del relé del panel) se conecte a ese Chrome. Un endpoint nuevo `POST /v1/browser/fill_secret` recibe el valor en el CUERPO, comprueba en el servidor que el host de la página actual casa con el origen al que está atado el secreto, y teclea por la entrada estándar de `agent-browser batch`. En la app, `HTTPAgentBrowserInvoker` se declara capaz de teclear secretos mediante un protocolo hermano nuevo (no mediante `AgentBrowserInvokingConStdin`, cuyo contrato es «stdin de un proceso local»), y el rechazo de `present_form`/`browser_fill_secret` se levanta SOLO para ese invocador autenticado y sobre transporte cifrado.

**Tech Stack:** Python 3.11 / FastAPI 0.115.6 / pytest 8.3.4 / Google Chrome stable 157 (.deb amd64) / Xvfb / agent-browser 0.41.2 / Docker 29.5.2 + Compose v5.1.4 en el i3; Swift 6 / XCTest en la app (`Gemma/Gemma.xcodeproj`, grupos sincronizados con el sistema de ficheros).

**Spec:** este mismo documento, sección «Diseño» (abajo). Sustituye al enfoque «el usuario inicia sesión con el mando» de `docs/superpowers/specs/2026-11-08-mando-compartido-del-navegador-design.md`, retirado por `docs/superpowers/plans/2026-11-12-quitar-el-mando.md`.

## Global Constraints

- **Dos repos, dos ramas nuevas.**
  - Servidor: repo `/Users/hashdown/Projects/personal_agent/gemma-memory`. Rama nueva `feat/chrome-real-i3` creada **desde `feat/chrome-de-verdad` (`a2b9d18`)** en un worktree nuevo `/Users/hashdown/Projects/personal_agent/gemma-memory/.worktrees/chrome-real-i3`. NUNCA desde `feat/mando-subsistema-a` (el mando se retira) ni sobre el checkout principal (tiene cambios sin commitear en `memory-service/` que no son de este plan).
  - App: repo `/Users/hashdown/Projects/personal_agent`. Rama nueva `feat/chrome-real-i3` desde `main` (si `feat/mando-subsistema-b` —quitar el mando— ya está fusionada, desde ese `main`; las tareas de app de este plan no tocan ningún fichero de aquel plan: aquel toca Harness/BrowserRelay/BrowserPanel/Settings y este toca `NativeServices/{HTTPAgentBrowserInvoker,AgentBrowserInvoker,AgentBrowserService}.swift` y `Forms/{BrowserFillSecretTool,FormTools}.swift`).
- `git add` por ruta, NUNCA `git add -A` (en `personal_agent` barre `graphify-out/<fecha>/graph.json` >100 MB y GitHub rechaza el push; en `gemma-memory` barrería el trabajo ajeno sin commitear).
- Pruebas del servidor: `cd <worktree>/browser && python3 -m pytest -q` (las que existen hoy pasan todas antes de empezar: paso 1 de la Tarea 1 lo fija como línea base).
- Pruebas de la app: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS'` con el MISMO conjunto de fallos que la línea base de la Tarea 7, y `xcodebuild build` verde también para iOS Simulator (`-destination 'platform=iOS Simulator,name=iPhone 17'`): el cliente real del usuario es el iPhone.
- **La línea que no se cruza** (memoria `cola-de-trabajo-navegador`): sí a configurar un navegador de verdad (Chrome real, perfil, idioma, zona horaria, con ventana); NO al plugin `stealth`, a parchear `navigator.webdriver`, ni a scripts que mientan sobre automatización. Nada de este plan lo hace: el `webdriver == false` sale de no pasar `--enable-automation`, que es lo que hace un Chrome abierto por una persona.
- El valor de un secreto NUNCA aparece en: argv de ningún proceso, URL, query string, log del servicio, cuerpo de un error (incluido el 422 de FastAPI), disco del i3. Cada una de esas vías tiene una prueba.
- Despliegue al i3: SOLO descrito (Tarea 11). No se despliega sin OK explícito del usuario.
- Commits con los pies de atribución que fije la sesión que ejecute.

## Review Focus

1. **Fuga del secreto por el 422 de FastAPI.** `RequestValidationError` devuelve por defecto el campo `input` con el cuerpo recibido: un cuerpo de `fill_secret` mal formado devolvería la contraseña en la respuesta. Tarea 5 instala un manejador que no ecoa nada en esa ruta, y su prueba manda un cuerpo inválido con un valor centinela y busca el centinela en la respuesta.
2. **El `close` deja el Chrome vivo.** `agent-browser close` NO cierra un navegador conectado por `--cdp` («externally connected browsers are not owned», `agent-browser --help`, 0.41.2): por eso la Mac lo cierra ella (`ChromeRealDeLaMac.cierra`). Si el servidor no lo hace, un vídeo de YouTube sigue reproduciéndose silenciado en el i3 para siempre. Tarea 4 lo fija.
3. **El relé del panel con un Chrome externo.** El relé lee el puerto con `stream status --json` y se conecta al servidor de streaming del DEMONIO; no lanza Chrome. Con `AGENT_BROWSER_CDP` en el entorno del contenedor, `stream status` se conecta al Chrome externo. Está deducido del código, NO medido: la Tarea 10 lo mide (25 fps) antes de dar nada por bueno.
4. **Zombis.** Medido hoy: 39 procesos `<defunct>` (`chrome`, `chrome_crashpad`) en el contenedor, porque PID 1 es `uvicorn`, que no recoge hijos. Con un Chrome que se abre y se cierra varias veces al día crecerían sin tope. Tarea 6 pone `init: true`.
5. **TOCTOU de la atadura al origen.** El servidor comprueba el host, teclea, y vuelve a comprobar. Entre la comprobación y el `fill` hay una ventana: es la MISMA que existe hoy en la Mac (la app comprueba `get url` y luego lanza `batch`), así que la semántica del módulo Forms no cambia; lo nuevo es que la segunda comprobación delata una navegación a mitad. Leer la sección D3.
6. **Mutaciones que deben ponerse rojas** (el ejecutor las prueba y lo anota en el informe de cada tarea): quitar el manejador del 422; quitar la comprobación de origen del endpoint; pasar el valor por argv; quitar `init: true`; quitar el `cierra()` tras `close`; quitar la condición de transporte cifrado en `puedeTeclearSecretos`.

---

## Mediciones (2026-11-12, solo lectura, SSH a `hashdown@100.91.174.81`)

| qué | medido |
|---|---|
| arquitectura / SO | `x86_64`, Ubuntu 24.04.4 LTS, i3-13100 (4 núcleos / 8 hilos, `nproc` = 8) → el `.deb` amd64 de Google Chrome vale (ya está instalado en la imagen) |
| RAM | 15 683 MB total, **7 370 MB disponibles**, 290 MB libres, swap 4 095 MB con **2 997 MB usados** (hay presión: `aapl-trader-db` 4,0 GiB, `aapl-trader-streamer` 2,2 GiB, `embedder` 625 MiB) |
| disco | 175 GB libres en `/` |
| Docker | 29.5.2, Compose v5.1.4 |
| contenedor del navegador | `gemma-browser-browser-1`, imagen construida el 2026-11-10 20:25, 62 MiB en reposo (sin Chrome vivo), sin límite de memoria (`HostConfig.Memory = 0`), `ShmSize` 1 GiB, `Init = null` |
| qué código corre | **Un híbrido que no existe en ninguna rama**: los `.py` (incl. `mando.py`, `test_mando.py`) son byte a byte los del **árbol de trabajo** del worktree `gemma-memory/.worktrees/mando-subsistema-a` (incluido el `stream.py` SIN COMMITEAR del arreglo del viewport), el `Dockerfile` es el de `feat/chrome-de-verdad` más la línea `COPY … mando.py …`, y `entrypoint.sh` y `docker-compose.yml` son los de `feat/chrome-de-verdad`. **El mando del servidor SÍ está desplegado.** Hay copias de seguridad `browser-antes-del-mando-20261109.tgz` y `browser-antes-del-viewport-20261110.tgz` en `~/Projects/gemma-browser/`. |
| perfil persistente | volumen `gemma-browser_perfil-navegador` montado en `/datos`; `/datos/perfil` existe, 175 MB, con `Default/`, `Local State` |
| `.env` del despliegue | una sola clave: `BROWSER_BEARER_TOKEN` |
| versiones | Google Chrome 157.0.8103.38, agent-browser 0.41.2 |
| PID 1 del contenedor | `uvicorn app:app …` → **39 zombis** `<defunct>` |
| **huella HOY** (sesión y perfil desechables `medida-ua`, `/tmp/medida-ua`, borrados al acabar) | `User-Agent: … HeadlessChrome/157.0.0.0 …`, `Sec-Ch-Ua: "Not-A.Brand";v="99", "Google Chrome";v="157", "Chromium";v="157"`, `Accept-Language: en-US,en;q=0.9`, **`navigator.webdriver = true`**, 5 plugins, ventana 1280×720 con `innerHeight` 633 |
| zona horaria | host del i3: `Etc/UTC`; contenedor: `TZ=America/Havana` (`date` → CST); **geolocalización de la IP pública del i3: Louisville, Kentucky (Charter), zona `America/Kentucky/Louisville`** |
| GPU | `/dev/dri/card1` y `renderD128` existen en el host (Intel UHD); hoy NO se pasan al contenedor |
| `agent-browser --cdp` | `AGENT_BROWSER_CDP` existe como variable (la Mac la usa: `ProcessAgentBrowserInvoker`, `entorno["AGENT_BROWSER_CDP"]`); `close` no cierra un navegador externo («externally connected browsers are not owned») |

**Lo que NO pude medir** (la clasificación de permisos denegó lanzar un Chrome temporal con ventana dentro del contenedor vivo, por ser escritura remota): la huella del Chrome real con ventana, Cloudflare (`pccomponentes.com`, `chatgpt.com`) con él, el login de Google, y el stream contra un Chrome externo. Todo eso es la Tarea 10, en vivo, después del despliegue.

**Lo que la medición corrige de la memoria.** La memoria `huella-del-browser` dice «la medición de `HeadlessChrome/156` es anterior al cambio a Chrome estable, hay que volver a medirla». Medida: con Chrome estable 157 **sigue diciendo `HeadlessChrome/157`** y `webdriver = true`. Cambiar de Chromium a Chrome arregló `Sec-Ch-Ua` (ya dice «Google Chrome») y los códecs, no la huella.

---

## Diseño

### D1. Chrome real con ventana, conducido por CDP — **confirmada, con dos correcciones**

Google Chrome stable (ya está en la imagen, `.deb` amd64; el i3 es `x86_64`), con ventana sobre Xvfb, perfil persistente en el volumen existente (`/datos/perfil`, no se pierde la sesión actual del perfil), CDP solo en `127.0.0.1:9222` del contenedor, sin `--enable-automation` ni `--headless`, y `agent-browser` lo conduce por `AGENT_BROWSER_CDP=9222`.

Banderas exactas (`chrome.argumentos()`):

```
--remote-debugging-port=9222
--remote-debugging-address=127.0.0.1
--user-data-dir=/datos/perfil
--no-first-run
--no-default-browser-check
--no-sandbox
--mute-audio
--autoplay-policy=no-user-gesture-required
--lang=en-US
--accept-lang=en-US,en;q=0.9,es;q=0.8
--window-size=1280,800
--window-position=0,0
about:blank
```

- `--no-sandbox`: obligatorio como root (ya estaba, ver comentario del compose).
- `--mute-audio` y `--autoplay-policy=…`: ya estaban (memoria `youtube-corta-la-reproduccion`), se trasladan de `AGENT_BROWSER_ARGS` a `chrome.py` porque con `--cdp` el CLI ya no lanza nada y `AGENT_BROWSER_ARGS` dejaría de aplicarse **en silencio**.
- **Idioma y zona horaria — corrección del coordinador aplicada.** El usuario vive en EE. UU. y habla inglés: `--lang=en-US` y `Accept-Language: en-US,en;q=0.9,es;q=0.8` (español como segundo idioma). Zona horaria: hoy el contenedor dice `America/Havana` y la IP del i3 geolocaliza en Louisville, Kentucky. Un `Intl.DateTimeFormat().resolvedOptions().timeZone` de La Habana con una IP de Kentucky es una incoherencia de huella (hoy el desfase horario coincide, UTC−5, pero el nombre de zona no, y las reglas de horario de verano de Cuba y EE. UU. difieren). **Decisión mía: `TZ=America/Kentucky/Louisville`** en el compose del navegador (solo afecta a ese contenedor; el host sigue en UTC). Coste si me equivoco: si el i3 no está físicamente en Louisville la IP manda igual, así que la zona correcta sigue siendo la de la IP; si el usuario prefiere `America/New_York` (misma regla horaria), es una línea.
  - **Nota sobre Amazon `.es`** (memoria `huella-del-browser`): allí «en-US contra un dominio `.es`» se anotó como desajuste. Con esta decisión **es deliberado y no un defecto**: el usuario compra desde EE. UU.; si vuelve a usar `amazon.es`, verá la página con preferencia de inglés y eso es lo correcto para su huella. No se corrige.
- `--window-size=1280,800`: la pantalla de Xvfb es 1280×800; con el cromo de Chrome (~87 px, memoria `viewport-declarado-no-es-el-real`) deja ≈1280×713 de página, por encima de los 1280×633 de hoy. El panel ya no mapea toques (se quita el mando), así que el desfase declarado/real ya no puede romper nada; la Tarea 10 lo vuelve a medir de todos modos, porque esa memoria manda re-medir ante cualquier cambio de ventana.

**Corrección 1 — quién lanza Chrome. Decisión mía: lo lanza el SERVICIO (`chrome.py`) a demanda, no el `entrypoint` en bucle.** Motivo: es el patrón exacto de la Mac (`asegura()` antes del `open`, `cierra()` tras el `close`), y el `close` de `agent-browser` no cierra un Chrome externo, así que alguien tiene que cerrarlo de todas formas; si lo lanzara el `entrypoint` como proceso permanente, un `close` dejaría la pestaña viva (un vídeo silenciado comiendo CPU) o habría que matarlo y relanzarlo igualmente. El `entrypoint` solo arranca Xvfb (≈20 MB) y limpia candados. Además el i3 está con 3 GB de swap usados: un Chrome que solo vive mientras se usa es lo que cabe. Coste si me equivoco: el primer `open` tras un cierre paga el arranque de Chrome (medido en la Mac: <2 s; en el i3, Tarea 10) — aceptable, ya lo paga la Mac.

**Corrección 2 — cierre por inactividad.** Con el Chrome externo, el `AGENT_BROWSER_IDLE_TIMEOUT_MS` del demonio apaga el demonio pero NO el Chrome. `chrome.py` lo cierra tras `BROWSER_CHROME_IDLE_S` (1800 s) sin ninguna invocación **y sin ningún visor del panel conectado** (el usuario puede estar viendo un vídeo de una hora sin pedirle nada al agente: con un visor conectado, no se cierra).

**Interruptor de reversión.** Todo lo de arriba se activa con `BROWSER_CHROME_REAL=1` en el compose. Sin ella (o con `0`), `chrome.py` no hace nada y el servicio se comporta exactamente como hoy (el CLI lanza su Chrome headless) — siempre que además se quite `AGENT_BROWSER_CDP`. La reversión rápida es editar dos líneas del compose y `docker compose up -d`, sin reconstruir (Tarea 11).

### D2. El stream — **confirmada; no cambia código, cambia una medición**

Medido en el código (`browser/relay.py`): el relé **no lanza Chrome ni habla CDP**; lee el puerto del servidor de streaming del demonio con `agent-browser --session gemma stream status --json` (vía `cli.run`, que pasa `os.environ` entero al hijo) y se conecta a `ws://127.0.0.1:<puerto>/?pacing=ack&maxFps=25`. Con `AGENT_BROWSER_CDP=9222` en el entorno del contenedor, ese `stream status` usa el demonio conectado al Chrome externo; el screencast es `Page.startScreencast` del CDP, que funciona igual con un Chrome con ventana. `AGENT_BROWSER_STREAM_{QUALITY,MAX_WIDTH,MAX_HEIGHT}` se conservan.

Riesgo que se mide (Tarea 10), no se supone: (a) que `stream status` de una sesión `--cdp` tenga servidor de streaming; (b) 25 fps con vídeo de YouTube (el techo medido con headless era 25,18 fps; con ventana Chrome además compone la ventana en Xvfb por software); (c) JPEG contra viewport declarado. La rama base `feat/chrome-de-verdad` **no tiene** el arreglo `_viewport_visible` (vive sin commitear en el worktree del mando) y no lo necesita: el fotograma que sale al cable no lleva viewport y la app ya no mapea toques.

### D3. Login sin mando: el endpoint `fill_secret` — **confirmada, con el diseño concreto**

Hoy: `POST /v1/browser/invoke` YA acepta `stdin` (`InvokeBody.stdin`, ≤256 KiB) y lo pasa al proceso, nunca al argv (`test_stdin_se_pasa_al_proceso_y_no_al_argv`). Bastaría con que el invocador HTTP lo mandara. **No se hace así, por cuatro motivos medidos en el código:**

1. `cli.validate_batch_payload` valida cada orden con `validate`, que rechaza cualquier posicional que empiece por `-`: **una contraseña que empiece por guion no se podría teclear nunca** («flag no permitido en el argumento #2»).
2. El 422 de FastAPI ecoa el cuerpo (`input`) en la respuesta; `invoke` no tiene manejador propio.
3. La atadura al origen solo la comprobaría la app; el servidor tecleará lo que le manden en la página que tenga abierta.
4. La salida del CLI vuelve tal cual; el redactor de la app es la única red.

**Endpoint:** `POST /v1/browser/fill_secret`, `Authorization: Bearer <BROWSER_BEARER_TOKEN>` (el mismo `require_bearer`), solo por Tailscale (el puerto 8083 no está expuesto fuera de la tailnet: verificarlo es prerrequisito de la Tarea 11).

Cuerpo (JSON, `Content-Type: application/json`):

```json
{"session": "gemma", "selector": "@e3", "origin": "accounts.google.com",
 "value": "<el secreto>", "timeout": 30}
```

| campo | regla (rechazo → 400 sin ecoar nada) |
|---|---|
| `session` | `cli.SESSION_NAME_PATTERN` |
| `selector` | 1..512 caracteres, no empieza por `-`, sin `\n` ni `\0` |
| `origin` | `chrome.normaliza_host(origin)` no es `None` (puerto exacto de `SecretVault.normalizaHost`) |
| `value` | 1..4096 caracteres, sin `\0` |
| `timeout` | `0 < t ≤ 120` |

Secuencia en el servidor (`fill_secret.rellena`):

1. Si `BROWSER_CHROME_REAL=1`, `chrome.toca()` (cuenta como actividad).
2. `agent-browser --session S get url --json` (sin stdin). Si falla o la URL no tiene host válido → `409 {"status":"no_page"}`. Si `not chrome.origen_permite(origin, host)` → `409 {"status":"wrong_origin","page_host":host}` y **no se ejecuta nada más** (el host de la página no es secreto; el origen pedido ya lo sabe la app).
3. `agent-browser --session S batch --omit-command --json` con stdin `json.dumps([["fill", selector, value]])` → por `cli.run(arguments, timeout, stdin=…)`, NO por `cli.validate` (el valor puede empezar por `-`; el `selector` ya se validó arriba y el subcomando lo fija el servidor).
4. `get url` otra vez. Si el host ya no casa: `200 {"status":"origin_changed", …}` — el valor ya se tecleó en una página que no es la suya; la app lo dice al usuario y le recomienda cambiar la contraseña. (Hoy en la Mac esta situación existe y NADIE la detecta.)
5. Respuesta `200 {"exitCode", "stdout", "stderr", "status": "ok"|"origin_changed"}` con `stdout`/`stderr` pasados por `redacta(texto, value)`: sustituye el valor literal, su forma escapada en JSON (`json.dumps(value)[1:-1]`) y su forma con `\uXXXX` (`json.dumps(value, ensure_ascii=True)[1:-1]`) por `[secreto]`. El cliente aplica además su `SecretRedactor` como siempre.

**Cómo viaja el valor.** Fuente única: el Keychain de la app (`SecretVault`, servicio `lambert-dev-group.Gemma.secretos`). La app lo lee **solo** después de que SU comprobación de origen pase (semántica intacta: en `evil.com` el valor nunca sale del Keychain), lo pone en el cuerpo de un POST sobre la conexión de Tailscale (WireGuard: cifrado extremo a extremo aunque la URL sea `http://`), y el servidor lo tiene en memoria del proceso Python durante la petición y en el pipe del stdin del CLI. **El i3 nunca lo persiste:** no hay log del cuerpo (uvicorn `--no-access-log`; el servicio no registra cuerpos; prueba con `caplog` a nivel DEBUG), la salida del CLI va a ficheros temporales en `/dev/shm` (tmpfs, RAM) que se borran al cerrar, y el perfil de Chrome **sí** puede guardarlo si Chrome ofrece «¿Guardar contraseña?» → se desactiva con la política de Chrome `PasswordManagerEnabled=false` en `/etc/opt/chrome/policies/managed/gemma.json` (Tarea 6). Las cookies de sesión resultantes sí se guardan: son el objetivo.

**Transporte. Decisión mía:** el invocador HTTP solo se declara capaz de teclear secretos si el token no está vacío **y** el transporte es cifrado: esquema `https`, o host en `100.64.0.0/10` (rango CGNAT de Tailscale), o terminado en `.ts.net`, o `localhost`/`127.0.0.1`. Una `browserBaseURL` `http://192.168.x.x:8083` (LAN en claro) no recibe secretos. Coste si me equivoco: si el usuario configura el i3 por IP de LAN, `present_form` con `secret` seguirá rechazándose con un motivo que lo dice; la solución es usar la IP de Tailscale (que es la que usa hoy).

**TOCTOU.** La ventana entre el paso 2 y el `fill` del paso 3 es de dos procesos del CLI (decenas de ms). Es la misma ventana que tiene hoy la Mac (app: `get url` → `batch`), así que la semántica de Forms no cambia; el paso 4 añade detección a posteriori. Cerrarla del todo exigiría comprobar el origen del marco DENTRO del `fill` (p. ej. con CDP directo sobre el `frameId`), fuera de alcance; anotado como mejora futura en el informe, no en el código.

**Lo que NO cambia en Forms:** `present_form` sigue atando el secreto al host de la página en el momento de pedirlo; `browser_fill_secret` sigue comprobando nombre, bóveda legible, existencia, origen, y redactando toda salida. Solo cambia por dónde viaja el valor cuando el navegador es el del i3.

### D4. Convivencia — **confirmada, sin cambios**

`HarnessModel.browserInvoker`: `browserBaseURL` vacío → Mac (`ProcessAgentBrowserInvoker(navegadorReal: ChromeRealDeLaMac())`); URL válida → i3 (`HTTPAgentBrowserInvoker`). No se toca. Las dos instalaciones tienen perfiles separados: iniciar sesión en Google en una no inicia sesión en la otra (hay que hacerlo una vez en cada una). El failover queda fuera.

### D5. Cloudflare y la sesión de Google — **confirmada**

No se promete pasar «Just a moment…»: medido hoy que con headless no se pasa ni esperando 45 s (memoria `huella-del-browser`). La Tarea 10 mide `pccomponentes.com` y `chatgpt.com` con el Chrome real y lo reporta tal cual, sin plugins ni parches. El login de Google: el agente abre `accounts.google.com`, teclea el correo con `browser_fill` (el correo no es un secreto; si el usuario prefiere, va en un campo `text` del formulario), pide la contraseña con `present_form` (campo `secret`, `secret_name` p. ej. `google_password`, que queda atado a `accounts.google.com`) y la teclea con `browser_fill_secret`. **2FA:** si Google pide un código (SMS, Authenticator), va por OTRO `present_form` con campo `secret` (`secret_name` `google_codigo_2fa`), nunca por el chat; tras usarlo, el agente llama a `forget_secret google_codigo_2fa` (un código de un solo uso no debe quedarse en la bóveda). Si Google pide «toca Sí en tu teléfono», el usuario lo hace en su teléfono y el agente espera (`browser_wait --text`).

### D6. Riesgo de cuenta — procedimiento

Iniciar sesión desde un dispositivo nuevo puede disparar «Verifica que eres tú» o un correo de alerta «Nuevo inicio de sesión en Linux». Mitigaciones y qué hacer:

1. **Misma IP que el usuario en casa:** el i3 sale por la misma conexión de Charter en Louisville. Hacer el primer login **estando el usuario en casa**, con el teléfono a mano, reduce el riesgo.
2. Huella coherente (D1): inglés de EE. UU., zona de Kentucky, Chrome estable real, sin `webdriver`.
3. Si Google responde «This browser or app may not be secure»: NO reintentar en bucle (cada intento sube el riesgo). Parar, reportar `navigator.webdriver` y el UA medidos en la Tarea 10, y decidir con el usuario.
4. Si llega la alerta «¿Fuiste tú?»: el usuario confirma «Sí, fui yo» desde su teléfono.
5. Si Google bloquea la cuenta temporalmente: recuperarla desde el teléfono del usuario (`g.co/recover`); el agente no lo intenta.
6. Recomendación (no requisito): usar una cuenta de Google con 2FA activado; con 2FA el robo del perfil del i3 no basta para entrar en otra máquina sin el teléfono… pero las cookies del perfil SÍ permiten actuar como él: el volumen `perfil-navegador` es ahora material sensible (ver Riesgos).

### D7. Memoria y CPU — dimensionado

Medido: 7 370 MB disponibles y 3 GB de swap en uso. Chrome con ventana + Xvfb + un vídeo de YouTube rondan 0,8–1,5 GB (estimación, NO medida en el i3: la Tarea 10 la mide con `docker stats` durante un vídeo de 2 min). **Decisión mía: `mem_limit: 3g` y `memswap_limit: 3g`** (sin swap extra: un Chrome que pagina vuelve el panel inservible y es mejor que el OOM mate una pestaña), `shm_size: 1gb` se conserva (cuenta dentro del límite cuando se usa). Sin límite de CPU: el techo de 25 fps se midió sin límite y un tope lo bajaría; si la Tarea 10 mide que el trader se resiente, se pone `cpus: 4`. Coste si me equivoco: si Chrome supera 3 GB el OOM killer mata un renderer (pestaña «Aw, Snap!»), no el contenedor; se sube el límite tras medir.

---

## Estructura de ficheros

Servidor (`/Users/hashdown/Projects/personal_agent/gemma-memory/.worktrees/chrome-real-i3/`):

| fichero | qué |
|---|---|
| `browser/chrome.py` (NUEVO) | `argumentos()`, `normaliza_host()`, `origen_permite()`, `subcomando_de()`, `pids_raiz()`, clase `ChromeDelContenedor` (`asegura`, `cierra`, `toca`, `vigila_inactividad`), `activo()` |
| `browser/test_chrome.py` (NUEVO) | pruebas puras y con dobles de `chrome.py` |
| `browser/fill_secret.py` (NUEVO) | `FillSecretBody`, `redacta()`, `rellena()` |
| `browser/test_fill_secret.py` (NUEVO) | pruebas del endpoint |
| `browser/app.py` | ganchos de Chrome en `invoke`, ruta `fill_secret`, manejador del 422, tarea de inactividad en `lifespan` |
| `browser/test_app.py` | pruebas de los ganchos en `invoke` |
| `browser/Dockerfile` | `COPY` de los módulos nuevos, política de Chrome, fuentes |
| `browser/chrome-policy.json` (NUEVO) | política gestionada de Chrome |
| `browser/entrypoint.sh` | arranca Xvfb `:99` |
| `docker-compose.browser.yml`, `docker-compose.yml` (raíz) | `init`, `mem_limit`, env nuevas, TZ, healthcheck |
| `browser/test_compose.py` | forma del compose, Dockerfile y entrypoint |

App (`/Users/hashdown/Projects/personal_agent`, rama `feat/chrome-real-i3`):

| fichero | qué |
|---|---|
| `Gemma/Gemma/NativeServices/AgentBrowserInvoker.swift` | protocolo nuevo `AgentBrowserTecleaSecretos` |
| `Gemma/Gemma/NativeServices/HTTPAgentBrowserInvoker.swift` | conformidad, `puedeTeclearSecretos`, `rellenaSecreto` |
| `Gemma/Gemma/NativeServices/AgentBrowserService.swift` | `sabeTeclearSecretos`, `rellenaSecretoRemoto` |
| `Gemma/Gemma/Forms/BrowserFillSecretTool.swift` | rama remota |
| `Gemma/Gemma/Forms/FormTools.swift` | la puerta de `present_form` consulta `sabeTeclearSecretos` |
| `Gemma/GemmaTests/HTTPAgentBrowserInvokerTests.swift`, `BrowserFillSecretToolTests.swift`, `FormToolsTests.swift` | pruebas |

---

### Task 1: `chrome.py` — las piezas puras

**Files:**
- Create: `browser/chrome.py`, `browser/test_chrome.py`

**Interfaces:**
- Consumes: nada.
- Produces:
  - `CDP_PORT: int = 9222`, `PERFIL: str = os.environ.get("AGENT_BROWSER_PROFILE", "/datos/perfil")`, `CHROME_BIN: str = "/usr/bin/google-chrome"`, `DISPLAY: str = ":99"`
  - `def argumentos(puerto: int, perfil: str) -> list[str]` — exactamente la lista de D1, en ese orden, terminando en `"about:blank"`.
  - `def normaliza_host(crudo: str) -> str | None` — puerto de `SecretVault.normalizaHost`: `strip()`, minúsculas, quita `:<dígitos>` final, quita UN punto final, cada etiqueta separada por `.` no vacía y solo `[a-z0-9-]`; si no, `None`.
  - `def origen_permite(guardado: str, pagina: str) -> bool` — `p == g or p.endswith("." + g)` con ambos normalizados; `False` si alguno es `None`.
  - `def host_de_url(url: str) -> str | None` — `urllib.parse.urlsplit(url).hostname` normalizado, solo si el esquema es `http`/`https`.
  - `def subcomando_de(arguments: list[str]) -> str | None` — primer argumento que no empieza por `-` y no es valor de `--session` (salta `--session X`).
  - `def pids_raiz(perfil: str, procesos: list[tuple[int, list[str]]]) -> list[int]` — pids cuyo argv contiene `--user-data-dir=<perfil>` (tolera `/` final) y ningún argumento que empiece por `--type=`.
  - `def activo() -> bool` — `os.environ.get("BROWSER_CHROME_REAL") == "1"`.

- [ ] **Step 1: Línea base.** Crear el worktree y medir:
  ```
  cd /Users/hashdown/Projects/personal_agent/gemma-memory
  git worktree add .worktrees/chrome-real-i3 -b feat/chrome-real-i3 feat/chrome-de-verdad
  cd .worktrees/chrome-real-i3/browser && python3 -m pytest -q 2>&1 | tail -3
  ```
  Anotar el número de pruebas que pasan (todas deben pasar; si no, PARAR y reportar).

- [ ] **Step 2: Escribir las pruebas que fallan** en `browser/test_chrome.py`:
  ```python
  import os, sys
  sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
  import chrome

  def test_argumentos_sin_automatizacion_y_con_cdp_en_loopback():
      a = chrome.argumentos(9222, "/datos/perfil")
      assert "--remote-debugging-port=9222" in a
      assert "--remote-debugging-address=127.0.0.1" in a
      assert "--user-data-dir=/datos/perfil" in a
      for prohibida in ("--enable-automation", "--headless", "--headless=new",
                        "--remote-debugging-address=0.0.0.0", "--disable-blink-features=AutomationControlled"):
          assert prohibida not in a
      assert not any(x.startswith("--headless") for x in a)

  def test_idioma_ingles_de_eeuu_con_espanol_secundario():
      a = chrome.argumentos(9222, "/p")
      assert "--lang=en-US" in a
      assert "--accept-lang=en-US,en;q=0.9,es;q=0.8" in a
      assert not any("es-ES" in x for x in a)

  def test_conserva_las_banderas_medidas_del_compose_viejo():
      a = chrome.argumentos(9222, "/p")
      for b in ("--no-sandbox", "--mute-audio", "--autoplay-policy=no-user-gesture-required",
                "--window-size=1280,800"):
          assert b in a
      assert a[-1] == "about:blank"

  def test_normaliza_host_como_la_boveda_de_la_app():
      assert chrome.normaliza_host(" Accounts.Google.COM. ") == "accounts.google.com"
      assert chrome.normaliza_host("a.test:8443") == "a.test"
      for malo in ("evil.com/.google.com", "evil.com#.google.com", "evil.com\n.google.com",
                   "a..b", "", "a.test.." , "https://a.test"):
          assert chrome.normaliza_host(malo) is None, malo

  def test_origen_permite_subdominio_y_no_sufijo_falso():
      assert chrome.origen_permite("google.com", "accounts.google.com")
      assert chrome.origen_permite("accounts.google.com", "accounts.google.com")
      assert not chrome.origen_permite("google.com", "evilgoogle.com")
      assert not chrome.origen_permite("accounts.google.com", "google.com")
      assert not chrome.origen_permite("google.com", "evil.com/.google.com")

  def test_host_de_url_solo_http_y_https():
      assert chrome.host_de_url("https://accounts.google.com/signin?x=1") == "accounts.google.com"
      assert chrome.host_de_url("about:blank") is None
      assert chrome.host_de_url("data:text/html,x") is None
      assert chrome.host_de_url("file:///etc/passwd") is None

  def test_subcomando_salta_la_sesion():
      assert chrome.subcomando_de(["--session", "gemma", "open", "https://a.test", "--json"]) == "open"
      assert chrome.subcomando_de(["close", "--json"]) == "close"
      assert chrome.subcomando_de(["--json"]) is None

  def test_pids_raiz_solo_el_proceso_principal_de_nuestro_perfil():
      procesos = [
          (10, ["/opt/google/chrome/chrome", "--user-data-dir=/datos/perfil", "--no-sandbox"]),
          (11, ["/opt/google/chrome/chrome", "--type=renderer", "--user-data-dir=/datos/perfil"]),
          (12, ["/opt/google/chrome/chrome", "--user-data-dir=/datos/perfil-otro"]),
          (13, ["/opt/google/chrome/chrome", "--user-data-dir=/datos/perfil/"]),
          (14, ["python3", "app.py"]),
      ]
      assert chrome.pids_raiz("/datos/perfil", procesos) == [10, 13]

  def test_activo_solo_con_la_variable_a_1(monkeypatch):
      monkeypatch.delenv("BROWSER_CHROME_REAL", raising=False)
      assert not chrome.activo()
      monkeypatch.setenv("BROWSER_CHROME_REAL", "0")
      assert not chrome.activo()
      monkeypatch.setenv("BROWSER_CHROME_REAL", "1")
      assert chrome.activo()
  ```

- [ ] **Step 3: Verificar que fallan.** `python3 -m pytest test_chrome.py -q` → `ModuleNotFoundError: No module named 'chrome'`.

- [ ] **Step 4: Implementar** `browser/chrome.py` con las funciones de «Produces» y un docstring de módulo que diga POR QUÉ existe (el `close` del CLI no cierra un Chrome externo; Google no deja iniciar sesión en el Chrome que lanza el CLI porque lleva `--enable-automation`; mismo patrón que `ChromeRealDeLaMac` en el repo `personal_agent`), y comentarios en `argumentos()` que trasladen el porqué de cada bandera desde el comentario de `AGENT_BROWSER_ARGS` del compose (no se borra el porqué al mover la bandera).

- [ ] **Step 5: Verificar que pasan.** `python3 -m pytest test_chrome.py -q` → 9 passed; `python3 -m pytest -q` → línea base + 9.

- [ ] **Step 6: Mutaciones** (cada una debe poner rojo al menos una prueba; revertir después): añadir `"--enable-automation"` a la lista; quitar el `.` del `endswith("." + g)`; aceptar `/` en las etiquetas.

- [ ] **Step 7: Commit.**
  ```
  git add browser/chrome.py browser/test_chrome.py
  git commit -m "feat(navegador): las piezas puras del Chrome real del contenedor"
  ```

### Task 2: `ChromeDelContenedor` — abrir, cerrar, actividad

**Files:**
- Modify: `browser/chrome.py`, `browser/test_chrome.py`

**Interfaces:**
- Consumes: `argumentos`, `pids_raiz`, `CDP_PORT`, `PERFIL`, `CHROME_BIN`, `DISPLAY` (Tarea 1).
- Produces:
  ```python
  class ChromeDelContenedor:
      def __init__(self, *, puerto: int = CDP_PORT, perfil: str = PERFIL,
                   binario: str = CHROME_BIN, display: str = DISPLAY,
                   espera: float = 20.0, espera_cierre: float = 5.0,
                   contesta: Callable[[int], Awaitable[bool]] | None = None,
                   lanza: Callable[[list[str], dict[str, str]], Awaitable[object]] | None = None,
                   procesos: Callable[[], list[tuple[int, list[str]]]] | None = None,
                   senal: Callable[[int, int], None] | None = None,
                   reloj: Callable[[], float] = time.monotonic) -> None
      async def asegura(self) -> str | None   # None = listo; str = motivo en español, sin datos sensibles
      async def cierra(self) -> bool          # True = el puerto ya no contesta
      def toca(self) -> None                  # marca actividad (reloj)
      def inactivo_desde(self) -> float       # segundos desde el último toca()
      async def vigila_inactividad(self, limite_s: float, hay_visores: Callable[[], bool],
                                   intervalo_s: float = 60.0) -> None  # bucle infinito; cancelable
  CHROME: ChromeDelContenedor  # instancia única del proceso
  ```
  - `contesta` por defecto: `GET http://127.0.0.1:<puerto>/json/version` con `httpx.AsyncClient(timeout=1)` → `True` si 200.
  - `lanza` por defecto: `asyncio.create_subprocess_exec(binario, *argumentos(...), env={**os.environ, "DISPLAY": display}, stdin=DEVNULL, stdout=DEVNULL, stderr=DEVNULL, start_new_session=True)`.
  - `procesos` por defecto: lee `/proc/<pid>/cmdline` de cada pid numérico (separador `\0`), ignorando los que desaparecen.
  - `senal` por defecto: `os.kill`.
  - `asegura`: si `contesta` → `None`. Si no: **antes de lanzar**, si `pids_raiz(perfil, procesos())` está vacío, borra `SingletonLock`, `SingletonCookie`, `SingletonSocket` del perfil (mismo razonamiento que `entrypoint.sh`: sin Chrome vivo del perfil, el candado es huérfano; con uno vivo NO se toca). Lanza, y sondea `contesta` cada 0,25 s hasta `espera`; si contesta → `None`; si no → `"Google Chrome se abrió pero no contesta en el puerto 9222."`. Un `asyncio.Lock` serializa `asegura`/`cierra` (dos `open` simultáneos no lanzan dos Chrome).
  - `cierra`: `SIGTERM` a cada pid de `pids_raiz`, espera hasta `espera_cierre` a que `contesta` sea `False`; si sigue, `SIGKILL` y otra espera de `espera_cierre`. Devuelve `not await contesta(puerto)`. Sin pids y sin puerto → `True`.
  - `vigila_inactividad`: cada `intervalo_s`, si `inactivo_desde() >= limite_s` y `not hay_visores()` y el puerto contesta → `cierra()` y `toca()` (para no repetir el cierre cada minuto).

- [ ] **Step 1: Pruebas que fallan** (añadir a `test_chrome.py`; todas con dobles, ninguna lanza un proceso ni manda señales reales):
  - `test_asegura_no_lanza_si_ya_contesta` — `contesta` siempre `True`; `lanza` registra llamadas → 0 llamadas, devuelve `None`.
  - `test_asegura_lanza_con_display_y_argumentos_y_espera_al_puerto` — `contesta` da `False, False, True`; comprueba que `lanza` recibió `[binario, *argumentos(9222, perfil)]` y `env["DISPLAY"] == ":99"`.
  - `test_asegura_borra_candados_huerfanos_solo_sin_chrome_vivo(tmp_path)` — perfil en `tmp_path` con los tres ficheros; con `procesos` vacío se borran; con un proceso raíz del perfil NO se borran.
  - `test_asegura_devuelve_motivo_si_no_contesta_a_tiempo` — `espera=0.3`, `contesta` siempre `False` → el motivo exacto de arriba.
  - `test_dos_asegura_simultaneos_lanzan_un_solo_chrome` — `asyncio.gather(c.asegura(), c.asegura())` con `contesta` que pasa a `True` tras el primer `lanza` → 1 lanzamiento.
  - `test_cierra_manda_sigterm_solo_a_los_pids_raiz_del_perfil` — señales registradas `[(10, SIGTERM)]` con la lista de procesos de la Tarea 1.
  - `test_cierra_escala_a_sigkill_si_el_puerto_sigue_vivo` — `espera_cierre=0.2`, `contesta` `True` hasta tras el SIGKILL → señales `[(10, SIGTERM), (10, SIGKILL)]`, devuelve `True`.
  - `test_cierra_devuelve_false_si_no_muere` — `contesta` siempre `True` → `False`.
  - `test_vigila_cierra_tras_el_limite_sin_visores` y `test_vigila_no_cierra_con_un_visor_conectado` — `reloj` falso, `intervalo_s=0.01`, cancelar la tarea tras 0,1 s.

- [ ] **Step 2: Verificar que fallan** (`AttributeError: module 'chrome' has no attribute 'ChromeDelContenedor'`).

- [ ] **Step 3: Implementar.** Ningún mensaje de error incluye argv ni rutas del perfil más allá de las fijas.

- [ ] **Step 4: Verificar que pasan** (`python3 -m pytest -q`).

- [ ] **Step 5: Mutaciones:** quitar el `asyncio.Lock`; borrar candados aunque haya Chrome vivo; omitir el SIGKILL. Cada una, roja.

- [ ] **Step 6: Commit** `git add browser/chrome.py browser/test_chrome.py && git commit -m "feat(navegador): el servicio abre y cierra el Chrome real del contenedor"`.

### Task 3: el Chrome se abre antes del `open`

**Files:**
- Modify: `browser/app.py` (`browser_invoke`), `browser/test_app.py`

**Interfaces:**
- Consumes: `chrome.activo()`, `chrome.subcomando_de()`, `chrome.CHROME.asegura()`, `chrome.CHROME.toca()`.
- Produces: `browser_invoke` sin cambios de firma. Con `activo()`: toda llamada válida hace `toca()`; si el subcomando es `open`, `asegura()` antes de `cli.run`; si devuelve motivo → `HTTPException(503, detail=motivo)` (la app lo convierte en `launchFailed` con «El navegador del i3 respondió 503: …»). Sin `activo()`: comportamiento idéntico al de hoy.

- [ ] **Step 1: Pruebas que fallan** en `test_app.py`:
  ```python
  def test_con_chrome_real_el_open_asegura_antes_de_ejecutar(monkeypatch):
      orden = []
      monkeypatch.setenv("BROWSER_CHROME_REAL", "1")
      async def asegura(): orden.append("asegura"); return None
      async def run(arguments, timeout, stdin=None):
          orden.append("run"); return {"exitCode": 0, "stdout": "{}", "stderr": ""}
      monkeypatch.setattr(appmod.chrome.CHROME, "asegura", asegura)
      monkeypatch.setattr(appmod.cli, "run", run)
      r = client.post("/v1/browser/invoke", json={"arguments": ["open", "https://a.test"]}, headers=AUTH)
      assert r.status_code == 200 and orden == ["asegura", "run"]

  def test_si_chrome_no_arranca_el_open_da_503_y_no_ejecuta(monkeypatch): ...
      # asegura devuelve "Google Chrome se abrió pero no contesta en el puerto 9222."
      # → 503, detail igual, run no llamado
  def test_sin_chrome_real_el_open_no_toca_chrome(monkeypatch): ...
      # BROWSER_CHROME_REAL ausente; asegura que lanza AssertionError si se llama → 200
  def test_un_get_no_abre_chrome(monkeypatch): ...
      # ["get","url"] con BROWSER_CHROME_REAL=1 → asegura no llamado
  def test_un_argv_rechazado_no_abre_chrome(monkeypatch): ...
      # ["eval","1"] → 400 y asegura no llamado (la validación va primero)
  ```
- [ ] **Step 2: Verificar que fallan.**
- [ ] **Step 3: Implementar** en `app.py`: `import chrome`; tras `cli.validate`, el gancho.
- [ ] **Step 4: Verificar que pasan** + suite completa.
- [ ] **Step 5: Mutación:** mover `asegura` antes de `cli.validate` → `test_un_argv_rechazado_no_abre_chrome` rojo.
- [ ] **Step 6: Commit** `git commit -m "feat(navegador): el open del agente abre el Chrome real del i3"` (add por ruta).

### Task 4: el Chrome se cierra tras el `close`, y por inactividad

**Files:**
- Modify: `browser/app.py`, `browser/test_app.py`

**Interfaces:**
- Consumes: `chrome.CHROME.cierra()`, `chrome.CHROME.vigila_inactividad()`, `_relay()`.
- Produces:
  - Con `activo()`, si el subcomando es `close`, tras `cli.run`: `await CHROME.cierra()`; si `False` → `HTTPException(502, detail="No pude cerrar Chrome en el i3: sigue abierto en el puerto 9222.")`. El usuario NO debe oír «cerrado» si no lo está (mismo contrato que `closeFailed` en la Mac).
  - Regla: se llama a `cierra()` siempre que el subcomando sea `close`, sea cual sea la salida del CLI (un `close` que el CLI rechaza porque no había sesión debe dejar igualmente Chrome cerrado: el usuario pidió cerrar). El 502 solo si `cierra()` devuelve `False`.
  - `Relay.viewer_count() -> int` (nuevo, público, lectura de `len(self._viewers)`).
  - `lifespan` de FastAPI: si `activo()`, crea la tarea `CHROME.vigila_inactividad(float(os.environ.get("BROWSER_CHROME_IDLE_S", "1800")), hay_visores=lambda: _relay_si_existe_tiene_visores())` y la cancela al apagar.

- [ ] **Step 1: Pruebas que fallan:** `test_close_cierra_chrome_tras_el_cli`, `test_close_que_no_cierra_chrome_da_502_con_motivo`, `test_close_rechazado_por_el_cli_cierra_chrome_igual`, `test_sin_chrome_real_close_no_toca_chrome`, `test_el_relay_cuenta_sus_visores` (añadir y quitar un visor falso como hacen las pruebas de relé existentes en `test_app.py`).
- [ ] **Step 2: Verificar que fallan.**
- [ ] **Step 3: Implementar.**
- [ ] **Step 4: Verificar que pasan** + suite.
- [ ] **Step 5: Mutación:** quitar la llamada a `cierra()` → `test_close_cierra_chrome_tras_el_cli` rojo.
- [ ] **Step 6: Commit** `git commit -m "feat(navegador): el close cierra de verdad el Chrome del i3, y se cierra solo si nadie lo usa"`.

### Task 5: `POST /v1/browser/fill_secret`

**Files:**
- Create: `browser/fill_secret.py`, `browser/test_fill_secret.py`
- Modify: `browser/app.py`

**Interfaces:**
- Consumes: `cli.run`, `cli.SESSION_NAME_PATTERN`, `chrome.host_de_url`, `chrome.origen_permite`, `chrome.normaliza_host`, `chrome.activo`, `chrome.CHROME.toca`, `require_bearer`.
- Produces:
  ```python
  class FillSecretBody(BaseModel):
      session: str = Field(min_length=1, max_length=64)
      selector: str = Field(min_length=1, max_length=512)
      origin: str = Field(min_length=1, max_length=253)
      value: str = Field(min_length=1, max_length=4096)
      timeout: float = Field(default=30, gt=0, le=120)
  def redacta(texto: str, valor: str) -> str
  async def rellena(body: FillSecretBody) -> tuple[int, dict]   # (status HTTP, cuerpo)
  ```
  Ruta en `app.py`: `@app.post("/v1/browser/fill_secret", dependencies=[Depends(require_bearer)])` → `JSONResponse(status_code=s, content=c)`.
  Manejador: `@app.exception_handler(RequestValidationError)` que para `request.url.path == "/v1/browser/fill_secret"` devuelve `400 {"detail": "cuerpo de fill_secret no válido"}` sin `input`, `loc` de valores ni `ctx`; para las demás rutas delega en `fastapi.exception_handlers.request_validation_exception_handler` (comportamiento de hoy).
  Respuestas: `400 {"detail": <motivo sin valores>}` | `409 {"status":"no_page"}` | `409 {"status":"wrong_origin","page_host":h}` | `200 {"status":"ok"|"origin_changed","exitCode","stdout","stderr"}` (redactados).
  Argv exactos: `["--session", S, "get", "url", "--json"]` y `["--session", S, "batch", "--omit-command", "--json"]`; stdin del batch: `json.dumps([["fill", selector, value]])`.

- [ ] **Step 1: Pruebas que fallan** en `test_fill_secret.py` (mismo arranque que `test_app.py`: `BROWSER_FAKE_CLI=1`, `BROWSER_BEARER_TOKEN=test-token`; `cli.run` sustituido por un doble que registra `(arguments, stdin)` y devuelve salidas en cola). Centinela: `VALOR = "-Cl4ve\"secreta\\ñ"` (empieza por `-`, lleva comilla, barra y no-ASCII).
  1. `test_sin_token_401` y `test_token_malo_401`.
  2. `test_teclea_por_stdin_y_nunca_por_argv` — salidas `[url("https://accounts.google.com/x"), BATCH_OK, url("https://accounts.google.com/y")]` → 200 `status=ok`; ningún `arguments` contiene `VALOR`; el stdin del batch es `json.dumps([["fill","@e3",VALOR]])`.
  3. `test_un_valor_que_empieza_por_guion_se_teclea` — mismo flujo, sin 400.
  4. `test_origen_distinto_409_y_no_lanza_batch` — `url("https://evil.com/accounts.google.com")` → 409 `wrong_origin`, `page_host == "evil.com"`, el doble solo vio UNA llamada.
  5. `test_subdominio_permitido` — origen `google.com`, página `accounts.google.com` → 200.
  6. `test_sin_pagina_409_no_page` — `get url` con `{"success":false,...}` → 409 `no_page`; y con `about:blank` → 409 `no_page`.
  7. `test_navegacion_a_mitad_se_reporta_origin_changed` — tercera salida `url("https://evil.com/")` → 200 `status=origin_changed`.
  8. `test_eco_del_valor_en_la_salida_se_redacta` — el batch devuelve stdout con `VALOR` literal, con `json.dumps(VALOR)[1:-1]` y con la forma `ensure_ascii` → ninguna aparece en `r.text`, sí `[secreto]`.
  9. `test_un_cuerpo_invalido_no_ecoa_el_valor` — `{"session":"gemma","selector":"@e3","origin":"a.test","value":VALOR,"timeout":999}` → 400 y `VALOR not in r.text` y `"secreta" not in r.text`.
  10. `test_un_cuerpo_invalido_en_invoke_sigue_dando_422` — no se rompe el resto de rutas.
  11. `test_selector_con_guion_o_salto_400` — `"-x"`, `"a\nb"` → 400 sin ecoar el selector.
  12. `test_origen_invalido_400` — `"evil.com/.google.com"` → 400.
  13. `test_sesion_invalida_400` — `"../x"` → 400.
  14. `test_ningun_log_lleva_el_valor(caplog)` — `caplog.set_level(logging.DEBUG)`; flujo completo + flujo 409 + cuerpo inválido; `VALOR not in caplog.text`.
  15. `test_el_valor_no_toca_el_disco(monkeypatch, tmp_path)` — `cli.run` real NO se usa; se comprueba en el fuente de `fill_secret.py` (sin comentarios) que no hay `open(`, `write_text`, `tempfile` ni `logging`/`_log` con `value`. (Prueba de fuente crudo, como las que ya existen en el repo.)
- [ ] **Step 2: Verificar que fallan.**
- [ ] **Step 3: Implementar.** Ningún `f"...{value}..."`, ningún `logger.*` en `fill_secret.py`; excepciones inesperadas → `500 {"detail":"fallo interno al rellenar"}` sin `str(exc)`.
- [ ] **Step 4: Verificar que pasan** + suite.
- [ ] **Step 5: Mutaciones (rojo obligatorio):** quitar el manejador del 422 (prueba 9); saltarse la comprobación de origen (prueba 4); poner `value` en argv (prueba 2); quitar la forma escapada de `redacta` (prueba 8).
- [ ] **Step 6: Commit** `git add browser/fill_secret.py browser/test_fill_secret.py browser/app.py && git commit -m "feat(navegador): rellenar un secreto en el i3 con el origen comprobado en el servidor"`.

### Task 6: imagen, entrypoint y compose

**Files:**
- Modify: `browser/Dockerfile`, `browser/entrypoint.sh`, `docker-compose.browser.yml`, `docker-compose.yml` (servicio `browser` de la raíz), `browser/test_compose.py`
- Create: `browser/chrome-policy.json`

**Interfaces:**
- Consumes: `chrome.py`, `fill_secret.py` (Tareas 1-5).
- Produces (valores exactos):
  - `Dockerfile`: `COPY app.py cli.py chrome.py fill_secret.py stream.py relay.py test_app.py test_chrome.py test_fill_secret.py test_stream.py ./`; `RUN mkdir -p /etc/opt/chrome/policies/managed` + `COPY chrome-policy.json /etc/opt/chrome/policies/managed/gemma.json`; añadir `fonts-noto-core fonts-noto-color-emoji` al `apt-get install` de Chrome.
  - `chrome-policy.json`: `{"PasswordManagerEnabled": false, "AutofillCreditCardEnabled": false, "MetricsReportingEnabled": false, "DefaultBrowserSettingEnabled": false}`.
  - `entrypoint.sh`: tras la limpieza de candados, si `BROWSER_CHROME_REAL=1`: `Xvfb :99 -screen 0 1280x800x24 -nolisten tcp &` (sin `-ac`, que desactivaría el control de acceso de X; el socket Unix basta) y `export DISPLAY=:99`; después `exec "$@"`.
  - `docker-compose.browser.yml`, servicio `browser`:
    - `init: true`
    - `mem_limit: 3g`, `memswap_limit: 3g`
    - `environment`: `TZ=America/Kentucky/Louisville` (sustituye `America/Havana`), `BROWSER_CHROME_REAL=1`, `AGENT_BROWSER_CDP=9222`, `BROWSER_CHROME_IDLE_S=1800`, `DISPLAY=:99`; se QUITAN `AGENT_BROWSER_ARGS` y `AGENT_BROWSER_EXECUTABLE_PATH` (con `--cdp` no se aplican; dejarlas mentiría al lector) con un comentario que diga dónde viven ahora (`chrome.argumentos`). Se conservan `AGENT_BROWSER_PROFILE` (lo lee `chrome.PERFIL` y el `entrypoint`), `BROWSER_STREAM_SESSION`, `AGENT_BROWSER_IDLE_TIMEOUT_MS`, `AGENT_BROWSER_SOCKET_DIR`, nitidez y `AGENT_BROWSER_NO_VERSION_CHECK`.
    - `healthcheck.test`: `["CMD", "curl", "-fsS", "http://localhost:8083/healthz"]` se conserva (Chrome a demanda: que no esté abierto NO es estar enfermo).
    - El comentario largo de `volumes` se actualiza: el relevo ya no es el mando, es `present_form` + `fill_secret`; y el volumen pasa a contener cookies de una sesión de Google iniciada (material sensible).
  - `docker-compose.yml` de la raíz: mismo bloque (hoy tiene `AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium`, que la imagen ya no trae: medido, es una divergencia previa).

- [ ] **Step 1: Pruebas que fallan** en `test_compose.py`:
  - `test_el_contenedor_recoge_zombis` — `init == "true"` en los dos composes.
  - `test_chrome_real_activo_y_conducido_por_cdp_en_loopback` — `BROWSER_CHROME_REAL == "1"`, `AGENT_BROWSER_CDP == "9222"`, `DISPLAY == ":99"`.
  - `test_las_banderas_ya_no_viven_en_el_compose` — `AGENT_BROWSER_ARGS` y `AGENT_BROWSER_EXECUTABLE_PATH` ausentes.
  - `test_zona_horaria_coherente_con_la_ip_del_i3` — `TZ == "America/Kentucky/Louisville"`; comentario de la prueba: medido 2026-11-12, IP del i3 geolocaliza en Louisville, KY.
  - `test_memoria_acotada` — `mem_limit == "3g"`, `memswap_limit == "3g"`, `shm_size == "1gb"`.
  - `test_los_dos_composes_dicen_lo_mismo_en_chrome_real` — las claves anteriores iguales en ambos.
  - `test_el_dockerfile_copia_los_modulos_nuevos` — el `COPY` contiene `chrome.py` y `fill_secret.py`, y el cierre de imports de `app.py` (parsear `import X`/`from X import` de cada `.py` del directorio, transitivamente) está todo en el `COPY` (versión de la prueba que el despliegue del mando tuvo que añadir tras romperse por `mando.py`).
  - `test_la_politica_de_chrome_apaga_el_gestor_de_contrasenas` — `json.load(chrome-policy.json)["PasswordManagerEnabled"] is False` y el Dockerfile la copia a `/etc/opt/chrome/policies/managed/`.
  - `test_el_entrypoint_arranca_xvfb_sin_tcp` — el texto contiene `Xvfb :99` y `-nolisten tcp`, no contiene ` -ac`, y `exec "$@"` sigue siendo la última orden.
- [ ] **Step 2: Verificar que fallan.**
- [ ] **Step 3: Implementar.**
- [ ] **Step 4: Verificar:** `python3 -m pytest -q` (todo verde) y `docker compose -f docker-compose.browser.yml config >/dev/null` (necesita un `.env` de prueba: `BROWSER_BEARER_TOKEN=x` en un directorio temporal; NO tocar `.env` reales).
- [ ] **Step 5: Verificar la imagen localmente (en la Mac, sin desplegar):** `docker build --platform linux/amd64 -t gemma-browser:chrome-real-prueba browser/` y `docker run --rm --platform linux/amd64 gemma-browser:chrome-real-prueba python3 -m pytest -q` → todo verde dentro de la imagen.
- [ ] **Step 6: Mutación:** quitar `init: true` → `test_el_contenedor_recoge_zombis` rojo.
- [ ] **Step 7: Commit** `git add browser/Dockerfile browser/entrypoint.sh browser/chrome-policy.json browser/test_compose.py docker-compose.browser.yml docker-compose.yml && git commit -m "feat(navegador): imagen y compose del Chrome real con ventana en el i3"`.

### Task 7: app — el invocador HTTP sabe teclear secretos

**Files:**
- Modify: `Gemma/Gemma/NativeServices/AgentBrowserInvoker.swift`, `Gemma/Gemma/NativeServices/HTTPAgentBrowserInvoker.swift`, `Gemma/GemmaTests/HTTPAgentBrowserInvokerTests.swift`

**Interfaces:**
- Consumes: el endpoint de la Tarea 5 (contrato exacto arriba).
- Produces:
  ```swift
  /// Invocador que sabe teclear un secreto en el navegador REMOTO, con el origen comprobado
  /// también allí. Hermano de `AgentBrowserInvokingConStdin` (que es stdin de un proceso local).
  public protocol AgentBrowserTecleaSecretos: AgentBrowserInvoking {
      /// `false` si este invocador no debe recibir secretos (token vacío o transporte en claro).
      var puedeTeclearSecretos: Bool { get }
      func rellenaSecreto(session: String, selector: String, origen: String,
                          valor: String, timeout: TimeInterval) async
          -> Result<RellenoRemoto, AgentBrowserInvocationFailure>
  }
  public enum RellenoRemoto: Equatable, Sendable {
      case tecleado(AgentBrowserInvocation)          // 200 status=ok
      case origenCambio(AgentBrowserInvocation)      // 200 status=origin_changed
      case origenDistinto(hostDeLaPagina: String)    // 409 wrong_origin
      case sinPagina                                 // 409 no_page
  }
  extension HTTPAgentBrowserInvoker: AgentBrowserTecleaSecretos
  static func transporteCifrado(_ url: URL) -> Bool  // https, 100.64.0.0/10, *.ts.net, localhost, 127.0.0.1
  ```
  `HTTPAgentBrowserInvoker` **NO** se declara `AgentBrowserInvokingConStdin` (la prueba existente `test_el_invocador_http_no_acepta_stdin` se queda tal cual y sigue verde).
  Petición: `POST <base>/v1/browser/fill_secret`, cabecera `Authorization: Bearer <token>`, cuerpo JSON `{session, selector, origin, value, timeout}`, `timeoutInterval = timeout + networkMargin`. Errores 400/401/5xx → `.failure(.launchFailed(...))` con los textos de `describe` (que NUNCA incluyen el cuerpo enviado).

- [ ] **Step 1: Línea base de la app** (desde la raíz del repo, rama nueva):
  ```
  git switch -c feat/chrome-real-i3 main
  xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' 2>&1 | tee /tmp/base.log | tail -3
  grep -E "^Test case" /tmp/base.log | grep "' failed" | sed 's/ on .*//' | sort -u > /tmp/base-fallos.txt
  ```
- [ ] **Step 2: Pruebas que fallan** (reusan `VoiceClientTests.StubProtocol` como el resto del fichero):
  - `test_rellena_secreto_manda_el_valor_en_el_cuerpo_y_no_en_la_url` — captura la petición: ruta `/v1/browser/fill_secret`, `url.query == nil`, el cuerpo decodificado tiene `value == "s3cr3t-ñ"`, `origin`, `selector`, `session`; cabecera Bearer.
  - `test_200_ok_es_tecleado`, `test_200_origin_changed_es_origenCambio`, `test_409_wrong_origin_trae_el_host`, `test_409_no_page_es_sinPagina`.
  - `test_un_400_no_ecoa_el_valor` — el servidor responde `{"detail":"…s3cr3t-ñ…"}` (simulado) → el mensaje de `.launchFailed` no contiene el valor (el `describe` se reutiliza pero el fallo de esta ruta usa un texto fijo: «El i3 rechazó la petición de rellenar (400).»).
  - `test_puede_teclear_secretos_solo_con_token_y_transporte_cifrado` — tabla: `http://100.91.174.81:8083` + token → `true`; mismo con token `""` → `false`; `http://192.168.1.10:8083` → `false`; `https://i3.example.com` → `true`; `http://i3.tail1234.ts.net:8083` → `true`; `http://100.128.0.1` (fuera de /10) → `false`; `http://127.0.0.1:8083` → `true`.
  - Se conserva sin cambios `test_el_invocador_http_no_acepta_stdin`.
- [ ] **Step 3: Verificar que fallan** (no compila: tipo inexistente).
- [ ] **Step 4: Implementar.** Doc-comment del protocolo con el porqué (no se reusa `ConStdin`: su contrato es el de un proceso local; reusarlo haría que el servidor pasara el valor por `cli.validate`, que rechaza un valor que empiece por `-`).
- [ ] **Step 5: Verificar** pruebas nuevas verdes, suite con los mismos fallos que la línea base, build iOS verde.
- [ ] **Step 6: Mutaciones:** quitar la condición de transporte → fila `192.168.1.10` roja; poner el valor en la query → primera prueba roja.
- [ ] **Step 7: Commit** `git add Gemma/Gemma/NativeServices/AgentBrowserInvoker.swift Gemma/Gemma/NativeServices/HTTPAgentBrowserInvoker.swift Gemma/GemmaTests/HTTPAgentBrowserInvokerTests.swift && git commit -m "feat(browser): el invocador del i3 sabe rellenar un secreto, solo con token y por Tailscale"`.

### Task 8: app — `browser_fill_secret` y `present_form` con el i3

**Files:**
- Modify: `Gemma/Gemma/NativeServices/AgentBrowserService.swift`, `Gemma/Gemma/Forms/BrowserFillSecretTool.swift`, `Gemma/Gemma/Forms/FormTools.swift`, `Gemma/GemmaTests/BrowserFillSecretToolTests.swift`, `Gemma/GemmaTests/FormToolsTests.swift`

**Interfaces:**
- Consumes: `AgentBrowserTecleaSecretos`, `RellenoRemoto` (Tarea 7).
- Produces:
  ```swift
  // AgentBrowserService
  /// Local con stdin (Mac) O remoto autenticado y cifrado (i3). Lo consulta `present_form`.
  public var sabeTeclearSecretos: Bool {
      aceptaEntradaEstandar || ((invoker as? AgentBrowserTecleaSecretos)?.puedeTeclearSecretos ?? false)
  }
  /// `nil` si el invocador no es remoto capaz. Usa `sessionName` (privado) por dentro.
  func rellenaSecretoRemoto(selector: String, origen: String, valor: String,
                            timeout: TimeInterval) async -> Result<RellenoRemoto, AgentBrowserInvocationFailure>?
  ```
  `aceptaEntradaEstandar` y `sinEntradaEstandar` se conservan (los usan pruebas existentes y el camino de dobles).
  `BrowserFillSecretTool.ejecuta`: idéntico hasta la lectura del valor (pasos 1-4 de su doc, incluida la comprobación de origen EN LA APP con `PaginaActual.host`). Después: si `service.aceptaEntradaEstandar` → camino de hoy (`batch` por stdin). Si no, si `rellenaSecretoRemoto` no es `nil` → mapear:
  - `.tecleado(inv)`: interpretar `inv.standardOutput` con la misma normalización de `batch` (`AgentBrowserService.lote`; exponer como `static func interpretaLote(_ raw: String) -> AgentBrowserOutcome` si hace falta) y seguir con el `switch outcome` de hoy.
  - `.origenCambio`: `invalidArguments("La página cambió de sitio mientras se tecleaba el secreto '\(nombre)'. Avisa al usuario: puede que el valor se haya escrito fuera de \(origen); que cambie esa contraseña si no reconoce la página.")`.
  - `.origenDistinto(h)`: el mismo texto de hoy («Ese secreto pertenece a … y la página abierta es \(h). No se ha tecleado nada…»).
  - `.sinPagina`: el mismo texto de hoy de `.sinPagina`.
  - `.failure(f)`: `AgentBrowserService.unavailable(for: f)` resuelto como hoy en la rama `.unavailable`.
  Si no hay ni stdin ni remoto → el `.unavailable(sinEntradaEstandar)` de hoy (texto: se actualiza a «browser_fill_secret necesita el navegador local de la Mac o el del i3 configurado con token y por Tailscale»; actualizar la aserción de `test_sin_un_invocador_con_stdin_falla_claro_y_no_teclea`).
  Todo sigue pasando por `SecretRedactor.limpia` en `run`.
  `FormTools`: `if let service, !service.aceptaEntradaEstandar` → `if let service, !service.sabeTeclearSecretos`; el texto del rechazo se actualiza a «…un secreto solo se puede teclear con el navegador local de la Mac o con el del i3 (con su token y por Tailscale)…».

- [ ] **Step 1: Pruebas que fallan.** Doble nuevo en `BrowserFillSecretToolTests.swift`:
  ```swift
  final class InvocadorRemotoFalso: AgentBrowserTecleaSecretos, @unchecked Sendable {
      var puedeTeclearSecretos = true
      var salidas: [String]                       // para invoke (get url)
      var relleno: Result<RellenoRemoto, AgentBrowserInvocationFailure>
      private(set) var rellenos: [(session: String, selector: String, origen: String, valor: String)] = []
      private(set) var argumentos: [[String]] = []
      // invoke devuelve salidas en orden; rellenaSecreto registra y devuelve `relleno`
  }
  ```
  - `test_remoto_teclea_tras_comprobar_el_origen_en_la_app` — `get url` = accounts.google.com, relleno `.tecleado(batchOK)` → `success`; un relleno con `origen == "accounts.google.com"`, `valor` = el de la bóveda; ningún `argumentos` contiene el valor.
  - `test_remoto_en_otro_origen_no_lee_el_valor_ni_llama_al_i3` — `get url` = evil.com → 0 rellenos y el almacén (`AlmacenQueCuenta`) no leyó el secreto.
  - `test_remoto_origen_distinto_en_el_servidor_no_es_success`, `test_remoto_origen_cambio_avisa_de_cambiar_la_contrasena`, `test_remoto_sin_pagina`.
  - `test_remoto_sin_permiso_de_secretos_cae_al_rechazo_claro` — `puedeTeclearSecretos = false` → mensaje de «necesita…», 0 rellenos.
  - `test_remoto_eco_del_valor_se_redacta` — `.tecleado` con stdout que contiene el valor → no sale.
  - `FormToolsTests`: `test_present_form_con_secreto_y_el_i3_capaz_se_presenta` y `test_present_form_con_secreto_y_el_i3_sin_token_se_rechaza_antes_de_presentar`.
- [ ] **Step 2: Verificar que fallan.**
- [ ] **Step 3: Implementar.**
- [ ] **Step 4: Verificar:** nuevas verdes; `test_ninguna_rama_que_no_sea_ok_cae_al_success` (fuente crudo) sigue verde — si la rama remota añade un `"success"` fuera de `.ok`, se pone roja y es CORRECTO: la rama remota debe reconducir a ese mismo `switch outcome`, no tener su propio éxito. Suite con los mismos fallos que la línea base; build iOS verde.
- [ ] **Step 5: Mutaciones:** quitar la comprobación de origen de la app en la rama remota → `test_remoto_en_otro_origen_no_lee_el_valor_ni_llama_al_i3` rojo; `sabeTeclearSecretos` devolviendo siempre `true` → `test_present_form_con_secreto_y_el_i3_sin_token…` rojo.
- [ ] **Step 6: Commit** `git add <los cinco ficheros> && git commit -m "feat(forms): los secretos se teclean también en el navegador del i3"`.

### Task 9: revisión de rama (antes de desplegar)

- [ ] **Step 1:** `superpowers:requesting-code-review` sobre las dos ramas y, por la regla del `CLAUDE.md`, `/codex:adversarial-review` (o agente `codex:codex-rescue`) con el foco de «Review Focus» de arriba.
- [ ] **Step 2:** Atender los hallazgos (`superpowers:receiving-code-review`), con prueba roja primero para cada defecto real.
- [ ] **Step 3:** `graphify update .` en `personal_agent` (regla del `CLAUDE.md`).

### Task 10: medición en vivo (tras la Tarea 11, con el usuario)

Comandos desde el Mac con el token del navegador en `$T` (está en el llavero de la app / iPhone; NUNCA pegarlo en el chat ni en ficheros del repo). `B=http://100.91.174.81:8083`.

```
inv() { curl -s -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d "{\"arguments\": $1, \"timeout\": 60}" $B/v1/browser/invoke; }
```

- [ ] **Step 1: Huella.** `inv '["--session","gemma","open","https://httpbin.org/headers","--json"]'` y `inv '["--session","gemma","get","text","body","--json"]'`. Esperado y anotado en la tabla del informe: `User-Agent` con `Chrome/157` y **sin** `HeadlessChrome`; `Sec-Ch-Ua` con «Google Chrome»; `Accept-Language: en-US,en;q=0.9,es;q=0.8`. Para `navigator.webdriver`, `Intl…timeZone` e `innerWidth/innerHeight` (no hay `eval` por red, a propósito): por SSH, `docker exec gemma-browser-browser-1 agent-browser --session gemma eval "JSON.stringify({wd:navigator.webdriver,tz:Intl.DateTimeFormat().resolvedOptions().timeZone,lang:navigator.languages,iw:innerWidth,ih:innerHeight})"`. Esperado: `wd:false`, `tz:"America/Kentucky/Louisville"`, `["en-US","en","es"]`. Línea base de hoy: `HeadlessChrome/157`, `wd:true`, `en-US,en;q=0.9`, 1280×633.
- [ ] **Step 2: Stream.** Abrir el panel en la app (iPhone) contra un vídeo de YouTube; dentro del contenedor, con el método de la memoria `viewport-declarado-no-es-el-real`, medir fps (meta: ≥24) y comparar JPEG contra lo declarado. Dejar el vídeo 120 s: anotar si sigue reproduciendo a los 60 s (hoy muere a los ~45 s sin sesión; con sesión de Google iniciada es la hipótesis que queda en pie, memoria `youtube-corta-la-reproduccion`).
- [ ] **Step 3: Memoria/CPU.** `docker stats --no-stream gemma-browser-browser-1` con el vídeo a los 60 s y en reposo con Chrome cerrado; `free -m` del host. Ajustar `mem_limit` si el pico pasa de 2,5 GiB.
- [ ] **Step 4: Cloudflare.** `open` + `get title` de `https://www.pccomponentes.com/` y `https://chatgpt.com/`, a los 5 s y a los 45 s. Reportar el título tal cual (`Just a moment...` = no pasa). Sin reintentos en bucle.
- [ ] **Step 5: Amazon.** Las cinco búsquedas seguidas en `amazon.com` (no `.es`: el usuario está en EE. UU.) con 6 s entre ellas; comparar con la línea base de 3/5 fallos medida en `amazon.es` (anotar que el dominio cambió, así que la comparación es indicativa).
- [ ] **Step 6: Login de Google con formulario** (D5, con el usuario presente y en casa — D6). En la app: «inicia sesión en Google en el navegador». Comprobar: el agente abre `accounts.google.com`, teclea el correo, llama a `present_form` con campo `secret` (y NO dice «aquí no se pueden usar campos secret»), el usuario escribe la contraseña en la tarjeta, `browser_fill_secret` responde `success`, y la contraseña no aparece en el transcripto, en el log del chat, ni en `docker logs gemma-browser-browser-1 2>&1 | grep -c '<un fragmento de 6 caracteres de la contraseña que el usuario mire él mismo>'` (= 0; ese grep lo hace el usuario, no el agente). 2FA por otro `present_form` y `forget_secret` tras usarlo. Si Google dice «This browser or app may not be secure»: PARAR (D6.3).
- [ ] **Step 7: Zombis.** Tras tres ciclos `open`/`close`: `docker exec gemma-browser-browser-1 sh -c 'ps -eo stat | grep -c Z'` → 0 (hoy 39).
- [ ] **Step 8: Persistencia.** `docker compose restart browser` y abrir `https://myaccount.google.com/`: sigue con la sesión iniciada.
- [ ] **Step 9: Informe** en `docs/superpowers/notes/2026-11-1X-chrome-real-i3-medicion.md` (personal_agent) con la tabla antes/después y actualizar las memorias `huella-del-browser`, `youtube-corta-la-reproduccion` y `viewport-declarado-no-es-el-real` con lo medido.

### Task 11: despliegue al i3 (DESCRITO — lo ejecuta el coordinador con OK explícito del usuario)

**Prerrequisitos:**
1. Tareas 1-9 cerradas y la revisión adversarial atendida; la rama de app instalada en el iPhone (memoria `el-cliente-real-es-el-telefono`), porque sin la app nueva `present_form` sigue rechazando secretos.
2. El plan `2026-11-12-quitar-el-mando.md` ejecutado o aceptado: este despliegue **retira el mando del servidor** que hoy corre (los `.py` del i3 son los del worktree del mando). Una app vieja con mando que intente tomar el volante recibirá un servidor que no sabe de mando: la app de `quitar-el-mando` ya no lo intenta.
3. Puerto 8083 accesible solo por Tailscale: `ssh hashdown@100.91.174.81 'sudo ufw status; ss -ltnp | grep 8083'` y comprobar que no hay reenvío del router a 8083. Si está abierto fuera de la tailnet, PARAR: `fill_secret` no se despliega expuesto a internet.
4. Hueco de RAM: `free -m` con ≥3 GB disponibles.

**Pasos:**
1. Copia de seguridad de lo desplegado: `ssh hashdown@100.91.174.81 'cd ~/Projects/gemma-browser && tar czf browser-antes-de-chrome-real-$(date +%Y%m%d).tgz browser docker-compose.yml && docker image tag gemma-browser-browser:latest gemma-browser-browser:antes-de-chrome-real'`.
2. Copia de seguridad del perfil (lleva cookies): `docker run --rm -v gemma-browser_perfil-navegador:/datos -v ~/Projects/gemma-browser:/out busybox tar czf /out/perfil-antes-de-chrome-real.tgz -C /datos perfil` y `chmod 600` del fichero.
3. Sincronizar desde la rama del servidor: `rsync -av --delete --exclude __pycache__ <worktree>/browser/ hashdown@100.91.174.81:~/Projects/gemma-browser/browser/` y `scp <worktree>/docker-compose.browser.yml hashdown@100.91.174.81:~/Projects/gemma-browser/docker-compose.yml`. (El `--delete` borra `mando.py`/`test_mando.py`: es lo buscado.)
4. `ssh hashdown@100.91.174.81 'cd ~/Projects/gemma-browser && docker compose build && docker compose up -d && sleep 5 && docker compose ps && curl -fsS localhost:8083/healthz'`.
5. Prueba de humo: `docker compose exec browser python3 -m pytest -q` (verde) y la Tarea 10, paso 1.

**Rollback** (cualquiera de los tres, del más rápido al más completo):
- A. Sin reconstruir: en el `docker-compose.yml` del i3 poner `BROWSER_CHROME_REAL=0`, quitar `AGENT_BROWSER_CDP`, restaurar `AGENT_BROWSER_ARGS=--no-sandbox,--mute-audio,--autoplay-policy=no-user-gesture-required` y `AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/google-chrome`; `docker compose up -d`. Vuelve el headless de hoy con el código nuevo (sin mando).
- B. Imagen anterior: `docker image tag gemma-browser-browser:antes-de-chrome-real gemma-browser-browser:latest`, restaurar `browser/` y `docker-compose.yml` desde el `.tgz` del paso 1, `docker compose up -d --no-build`.
- C. Perfil: si el perfil quedó inservible, `docker compose down`, restaurar `perfil-antes-de-chrome-real.tgz` dentro del volumen y `up -d`.

---

## Riesgos

1. **El volumen del perfil pasa a ser una credencial.** Con una sesión de Google iniciada, quien copie `gemma-browser_perfil-navegador` (o tenga el token del navegador, que conduce ese Chrome) actúa como el usuario en Google. Mitigación: el puerto solo por Tailscale (prerrequisito 3), el token largo y aleatorio ya existente, la copia del perfil con `chmod 600`, y la política que apaga el gestor de contraseñas para que al menos la contraseña no quede en el perfil.
2. **Google puede negarse igualmente** («This browser or app may not be secure») por señales que no se arreglan honestamente (Linux en Xvfb, WebGL por software — `/dev/dri` existe en el host y NO se pasa al contenedor en este plan). Se mide y se para; no se cruza la línea.
3. **TOCTOU residual** entre la comprobación de origen y el `fill` (D3): igual que hoy en la Mac, ahora detectado a posteriori, no impedido.

## Autorrevisión

- Cobertura del encargo: D1 (Tareas 1-2, 6; idioma en-US y TZ corregidos), D2 (sin código; Tarea 10.2), D3 (Tareas 5, 7, 8), D4 (sin cambios, declarado), D5 (D5 + Tarea 10.4/10.6), D6 (sección D6), D7 (Tarea 6 + 10.3). Mediciones pedidas: todas en la tabla salvo las que exigían lanzar Chrome con ventana en el contenedor vivo (denegado; pasan a la Tarea 10).
- Nombres consistentes: `chrome.CHROME`, `ChromeDelContenedor.asegura/cierra/toca/vigila_inactividad`, `fill_secret.rellena/redacta/FillSecretBody`, `AgentBrowserTecleaSecretos.puedeTeclearSecretos/rellenaSecreto`, `RellenoRemoto.{tecleado,origenCambio,origenDistinto,sinPagina}`, `AgentBrowserService.sabeTeclearSecretos/rellenaSecretoRemoto`. Revisados entre tareas.
- Sin marcadores pendientes. Un punto que el ejecutor DEBE confirmar al implementar, no inventar: si `AgentBrowserService.lote` no es accesible desde `BrowserFillSecretTool`, exponerlo como `static func interpretaLote` (Tarea 8), sin cambiar su lógica.
- Corregido durante la autorrevisión: en la Tarea 4 la primera redacción cerraba Chrome solo si el `close` del CLI tenía éxito; se cambió a «siempre que el subcomando sea `close`», porque un `close` sin sesión debe dejar Chrome cerrado igual. En la Tarea 6, `-ac` en Xvfb desactivaría el control de acceso de X: eliminado, y una prueba lo fija.

## Dudas para el usuario

1. ¿El i3 está en Louisville? (la IP lo dice). Si no, ¿qué zona horaria quieres? Propuesta: `America/Kentucky/Louisville`.
2. ¿Iniciamos sesión en Google con tu cuenta principal o con una cuenta secundaria para el agente? (riesgo 1).
3. ¿Aceptas que el agente cierre el Chrome del i3 tras 30 min sin uso y sin el panel abierto? Con la sesión guardada no pierdes nada salvo las pestañas abiertas.
