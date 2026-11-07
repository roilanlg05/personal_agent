# Recon verificado: streaming de agent-browser 0.41.2

Todo lo de aquí se verificó **en vivo** contra el binario real
(`/opt/homebrew/bin/agent-browser`, v0.41.2) en la sesión de prueba
`gemma-stream-probe`, ya cerrada. Las fuentes son dos: la ejecución real y los
dos documentos oficiales que vienen con el CLI:

- `skill-data/core/references/streaming.md` (105 líneas)
- `skill-data/core/references/trust-boundaries.md` (69 líneas)

Ruta base de esos docs:
`/opt/homebrew/Cellar/agent-browser/0.41.2/libexec/lib/node_modules/agent-browser/skill-data/core/references/`

---

## 1. Cómo se obtiene el stream

**El streaming está siempre activo.** No hay que habilitarlo. Esto es lo primero
que hay que corregir respecto a la suposición inicial del diseño:

```
$ agent-browser --session gemma-stream-probe stream enable --json
{"success":false,"data":null,"error":"Streaming is already enabled for this session"}
```

Es decir: **llamar a `stream enable` sobre una sesión viva devuelve
`success:false`**, y por el contrato de honestidad de nuestra integración eso se
traduciría en un `refused` — un falso fallo presentado al modelo. La app **no
debe llamar a `stream enable`**. Debe llamar a `stream status`:

```
$ agent-browser --session gemma-stream-probe stream status --json
{"success":true,"data":{
  "connected":true,
  "enabled":true,
  "port":55058,
  "screencasting":false,
  "lifecycle":{...}
},"error":null}
```

El puerto es **asignado por el sistema operativo y cambia por demonio**. El doc
oficial lo dice explícitamente: «Read the port from `stream status --json`
rather than assuming one». Nunca cablear un puerto.

Para fijarlo, existe `AGENT_BROWSER_STREAM_PORT`, que lo pina **para todo el
demonio**. Como la app es quien lanza el demonio, puede fijarlo si prefiere un
puerto estable en lugar de leerlo; aun así leerlo es más robusto, porque
sobrevive a que el demonio lo haya levantado otra cosa.

`screencasting` es `false` hasta que un cliente WebSocket se conecta, y pasa a
`true` solo. No hay mensaje de suscripción: **conectarse es suscribirse**.

## 2. Calidad y ancho de banda — se configuran al lanzar el demonio

Estas tres variables de entorno son **de todo el demonio y se leen una sola vez
al arrancar**. Cambiarlas después no tiene efecto; hay que relanzar. Como la app
spawnea el proceso, las controla:

| Variable | Defecto | Efecto |
|---|---|---|
| `AGENT_BROWSER_STREAM_QUALITY` | `80` | Calidad JPEG, 0–100, se clampa |
| `AGENT_BROWSER_STREAM_MAX_WIDTH` | el viewport | Acota el **frame**, no redimensiona la página |
| `AGENT_BROWSER_STREAM_MAX_HEIGHT` | el viewport | Igual |

Cifras medidas por el propio proyecto sobre una página con actividad a 1280×720:

- calidad 80 → ~54 KB por frame
- calidad 20 → ~25 KB por frame
- calidad 20 a 640×360 → ~9 KB por frame

Mi propia medición, con los defectos (calidad 80, 1280×720) y contando el
base64 tal como llega por el socket: **~92.5 KB de base64 por frame**, que son
unos ~69 KB de JPEG. Coherente con sus ~54 KB sobre una página distinta.

Para un panel embebido en el chat, el ajuste correcto es **calidad 20 a 640×360
(~9 KB/frame)** más un tope de FPS por cliente. Un valor inservible deja el
defecto en pie, no falla.

## 3. Conexión

`ws://127.0.0.1:<port>`. Solo localhost. Un cliente de navegador debe cargarse
desde `localhost`, `127.0.0.1`, `::1` o `file://`; cualquier otro origen recibe
un **403 en el upgrade**. Para la app nativa de macOS esto es indiferente:
`URLSessionWebSocketTask` no manda `Origin`, y de todos modos el socket es
local.

Dos ajustes se pueden declarar **en la URL**, y es la **única** forma de que
cubran el frame de apertura:

```
ws://127.0.0.1:<port>/?pacing=ack&maxFps=10
```

Un mensaje `config` posterior gana sobre lo declarado en la URL.

## 4. Mensajes del servidor al cliente

Todos son **JSON en texto** con campo `type`. No hay frames binarios. Verificado:
puse `ws.binaryType = "arraybuffer"` y no llegó ni un solo mensaje binario.

### `frame` — el fotograma
```json
{"type":"frame","seq":41,"data":"<jpeg en base64>","metadata":{
  "deviceWidth":1280,"deviceHeight":720,"pageScaleFactor":1,
  "offsetTop":0,"scrollOffsetX":0,"scrollOffsetY":0,
  "timestamp":1793996915607}}
```
Capturado en vivo, `metadata` idéntico al documentado. `data` empieza por
`/9j/4AAQSkZJRg`, que es `FF D8 FF E0 ... JFIF`: **JPEG**. El doc advierte que
el mensaje `frame` **no lleva campo de formato** y que un `screencast_start`
explícito puede reconfigurar el mismo screencast por debajo y cambiar el formato
a media corriente — así que **hay que mirar los bytes, no asumir**. En la
práctica: el stream vivo pide jpeg siempre, y nosotros no vamos a llamar a
`screencast_start`.

`seq` es un id monótono, **estable incluso si el navegador se relanza**.
`metadata.timestamp` es la hora de captura en epoch ms, así que
`Date.now() - timestamp` es la edad real del frame que se está pintando: eso es
lo que hay que usar para decidir si el panel está mostrando algo rancio.

### `status`
```json
{"type":"status","connected":true,"engine":"chrome","recording":false,
 "screencasting":false,"viewportWidth":1280,"viewportHeight":720}
```
Se manda una vez al conectar y otra vez en cada cambio. Verificado: llegó con
`screencasting:false` y luego otro con `screencasting:true` en cuanto el
screencast arrancó.

### `tabs`
```json
{"type":"tabs","timestamp":1793996915605,"tabs":[
  {"active":true,"label":null,"tabId":"t1",
   "targetId":"60D431FE...","title":"example.com",
   "type":"page","url":"https://example.com/"}]}
```

### `url`
```json
{"type":"url","timestamp":1793996944431,"url":"https://news.ycombinator.com/"}
```
Solo Chrome, y solo el **main frame de la pestaña activa**: documento completo,
History API y fragmento. La navegación en iframes hijos y en pestañas de fondo
**no emite** `url`.

### `console`
Documentado, no lo provoqué. Eventos de consola.

### `command` y `result` — NO DOCUMENTADOS, pero existen
Esto es el hallazgo más valioso y no aparece en `streaming.md`. Capturado en vivo
al lanzar `agent-browser --session gemma-stream-probe open <url>` **desde otro
proceso** mientras el socket estaba abierto:

```json
{"type":"command","action":"navigate","id":"r990307",
 "params":{"action":"navigate","id":"r990307","url":"https://news.ycombinator.com"},
 "timestamp":1793996943990}
{"type":"result","action":"navigate","data":{"lifecycle":{...},"targetId":"..."}}
```

O sea: **el stream hace eco de cada comando que cualquier proceso ejecuta sobre
esa sesión, y de su resultado.** El panel del chat puede mostrar en vivo lo que
el agente está haciendo — «navegando a X», «rellenando Y» — sin que la app tenga
que instrumentar nada en el lado de las herramientas. Es exactamente lo que se
ve en la app de ChatGPT.

Aviso: por estar indocumentado, puede desaparecer en una actualización del CLI.
El panel debe tratarlo como un extra: si no llega, se degrada a mostrar solo
frames, nunca a romperse. Y como `params` puede llevar el texto de un `fill`,
**un `command` de un `fill` de secreto no se debe pintar en la UI ni registrar**:
hay que filtrar por acción antes de mostrar.

### Garantías de orden
`status`, `tabs`, `url` y `console` viajan por un **canal ordenado**: llegan en
orden y nunca los reemplaza un mensaje más nuevo, al contrario que los frames.
Pero **no son durables sin condiciones**: un cliente que se retrase lo bastante
puede caerse de ese canal y perder mensajes que nunca vio. El doc es explícito:
trata `console` como un feed en vivo, **no como un registro de auditoría**.

## 5. Mensajes del cliente al servidor

```json
{"type":"input_mouse","eventType":"mousePressed","x":40,"y":40,"button":"left","clickCount":1}
{"type":"input_keyboard","eventType":"keyDown","key":"a","text":"a"}
{"type":"input_touch","eventType":"touchStart","touchPoints":[]}
{"type":"config","maxFps":10}
{"type":"config","pacing":"ack"}
{"type":"ack","seq":41}
```

Los nombres de los eventos de entrada son `input_mouse`, `input_keyboard` e
`input_touch`, con un `eventType` de CDP dentro (`mousePressed`, `keyDown`,
`touchStart`...). **Probé nombres inventados** (`{"type":"click",...}`,
`{"type":"scroll",...}`, `{"type":"notarealtype"}`) y el servidor **no respondió
ni con error ni con acuse**: ignora en silencio lo que no entiende. Conclusión
operativa: no hay forma de detectar un mensaje mal formado por respuesta del
servidor — solo por el efecto que no se produce. Hay que acertar el formato.

Detalles que importan para que el panel se sienta vivo:

- La entrada se despacha al navegador en una tarea propia, **separada de la
  entrega de frames**: un clic no se encola detrás de la escritura de un frame.
- Los eventos se envían al navegador **sin esperar su respuesta**, así que un
  clic sigue siendo responsivo detrás de una ráfaga de movimientos de ratón.
- Se preserva el orden: un `press` nunca adelanta a un `move`.
- **La entrada reinicia el temporizador de inactividad del demonio.** Una vista
  previa que el usuario está manejando activamente no se apaga por timeout.

`config` fija un tope de FPS **por cliente**: 1 a 120, o `0` para sin tope (el
defecto). Toma efecto de inmediato, incluso al **aflojar** el tope. El tope de
cada cliente es suyo; los demás clientes conectados no se ven afectados. Un
valor por encima de 120 se clampa a 120; un valor negativo o no numérico se
**ignora** dejando el tope actual en pie. Ninguno de los dos rechaza la conexión.

## 6. Ritmo y frescura — el punto fino

El servidor guarda **solo el frame más nuevo por cliente** y lo lee en el momento
de enviar. Un frame producido mientras se está escribiendo otro **se descarta,
no se encola**: la aplicación nunca acumula atraso.

- **Push** (el defecto) para ahí. El transporte por debajo sigue siendo
  ordenado: los frames que el socket ya aceptó se entregan en orden, así que un
  cliente que se atasca drena lo que el kernel hubiera almacenado antes de que
  el escritor se bloqueara. Resultado: puedes pintar historia rancia.
- **Ack** cierra ese hueco. Con `{"type":"config","pacing":"ack"}` el servidor
  mantiene **como máximo un frame en vuelo** y espera `{"type":"ack","seq":N}`
  antes de mandar el siguiente. Los frames producidos mientras hay un ack
  pendiente **se reemplazan entre sí y nunca llegan al socket**: un cliente que
  se atasca diez segundos y vuelve recibe **la página actual**, no diez segundos
  de historia.

Coste de ack: la tasa es un frame por transferencia **más un viaje de ida y
vuelta del acuse**. La latencia del enlace la acota. En localhost eso es
despreciable, así que **para nuestro panel, ack es la elección correcta**.

Los acuses son **acumulativos**: acusar un id más nuevo cubre los anteriores. Un
cliente que opta por ack y luego deja de acusar simplemente deja de recibir
frames; `status`, `tabs`, `url` y `console` siguen fluyendo. Eso da un apagado
limpio: para congelar el panel, basta dejar de acusar.

Los dos ajustes **se componen**: `pacing` acota cuánto hay en vuelo, `maxFps`
acota la tasa. Una vista previa con restricciones quiere los dos.

Verificado en vivo: con `?pacing=ack&maxFps=4` sobre `example.com` (una página
estática) llegaron **4 frames en 8 segundos**, no 32. Los frames se emiten por
cambio, no por reloj. Una página quieta no gasta ancho de banda.

## 7. Límites declarados

- **Solo localhost.** Exponer el stream más allá de la máquina es trabajo del
  que lo embebe (túnel, proxy o reenvío de puerto), y la lista de orígenes
  permitidos aplica a clientes de navegador. Para nosotros no hace falta: la app
  y el demonio corren en el mismo Mac.
- **Los frames son imágenes, no un códec de vídeo.** El ancho de banda escala
  con el tamaño del viewport y con la actividad de la página.
- En push, el servidor no distingue un renderizador lento de uno rápido más allá
  de la contrapresión del transporte. Ack existe para esa distinción.

---

## 8. Lo que esto cambia en el diseño del panel

1. **No llamar a `stream enable`.** Llamar a `stream status --json`, leer `port`.
   Llamar a `enable` sobre una sesión viva produce `success:false`, que nuestra
   capa traduciría a `refused` — un fallo inventado.
2. **El puerto se lee, no se asume.** Cambia por demonio.
3. **Fijar calidad y tamaño al lanzar el demonio**, no después: son de todo el
   demonio y se leen una sola vez. Para el panel: calidad 20, 640×360.
4. **Conectar con `?pacing=ack&maxFps=N` en la URL**, porque es la única forma de
   cubrir el frame de apertura. Acusar cada `seq` tras pintarlo.
5. **Pintar la edad del frame** desde `metadata.timestamp`, y mostrar el panel
   como «en vivo» solo cuando esa edad sea pequeña.
6. **El panel es un consumidor, no un controlador.** Los frames llegan solos;
   no hay suscripción. Cerrar el socket es toda la baja que hace falta.
7. **`command`/`result` dan la narración en vivo gratis**, pero están
   indocumentados: tratarlos como un extra degradable, y **filtrar por acción**
   para que el `params` de un `fill` de secreto nunca llegue a la pantalla ni al
   log.
8. **La entrada remota es posible** (`input_mouse`/`input_keyboard`/
   `input_touch`) y reinicia el temporizador de inactividad. Decidir aparte si
   el usuario puede tocar el panel; si puede, eso es una vía por la que un clic
   suyo entra en una página que el agente abrió, y hay que pensarla con las
   reglas de compra, no como un detalle de UI.

## 9. Hallazgos para el trabajo de compras y secretos

De `trust-boundaries.md`, y son respuestas directas a preguntas abiertas:

- **La forma oficial de autenticar sin que el secreto pase por el modelo es
  importar cookies desde un fichero:** `cookies set --curl <fichero>`, que
  autodetecta formato JSON, cURL o cabecera `Cookie` cruda. Los mensajes de
  error **nunca hacen eco del valor de la cookie**. La instrucción exacta para
  el usuario: DevTools → Network, clic en cualquier petición autenticada, clic
  derecho → Copy → Copy as cURL, pegar todo en un fichero, dar la ruta.
- **`state save` / `state load`** persiste cookies + localStorage a un JSON. Es
  el mecanismo para seguir con la sesión iniciada entre ejecuciones. **El
  fichero de estado es un secreto**: misma disciplina que un fichero de cookies.
- **`--allowed-domains`** es contención a nivel de navegador: bloquea HTTP no
  permitido, WebSocket, EventSource y `sendBeacon`, y desactiva
  `RTCPeerConnection`. Era un no-objetivo del navegador; **para compras pasa a
  ser deseable**, para acotar el checkout al dominio del comercio.
  **CONFLICTO REAL que hay que resolver en el diseño de compras:**
  `--allowed-domains` **se rechaza** junto con restauración de agent-browser,
  repetición de ficheros de estado, perfiles de Chrome, sesiones CDP
  preexistentes y auto-connect — porque el CLI no puede instalar contención
  equivalente antes de que corran los scripts de la página. Es decir:
  **`state load` y `--allowed-domains` no se pueden combinar.** Hay que elegir
  entre sesión persistente y contención de dominio, o encontrar un tercer
  camino. Y en cualquier caso es contención de navegador, no una frontera de
  seguridad del sistema operativo.
- **`har start`/`har stop` graba a disco cada petición y respuesta, cabeceras de
  autorización y tokens incluidos.** No compartir sin redactar.
- **Las capturas y los vídeos pueden capturar secretos** sin querer: campos
  autorrellenados, tokens visibles en la barra de direcciones. Revisar antes de
  enviar. Esto aplica directamente al panel de streaming: **los frames del panel
  pueden contener el número de tarjeta mientras se teclea en el checkout.**
  Decisión pendiente: o no persistir frames nunca, o pausar el stream durante la
  fase de pago, o ambas.
