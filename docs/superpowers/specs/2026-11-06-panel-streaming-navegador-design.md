# Panel de streaming del navegador — documento de diseño

**Fecha:** 2026-11-06
**Estado:** propuesta de diseño, pendiente de aprobación del usuario.
**Rama de la que depende:** `feat/agent-browser`, ya mergeada a `main` (merge commit
`6a87231`). Las nueve herramientas de navegador y `read_webpage` existen y están
verificadas contra el binario real.

**Sub-proyecto 1 de 4** del trabajo de navegador. Los otros tres, en el orden que
fijó el usuario: manejo de secretos, puerta de compra con topes, y recibos. Este
documento cubre **solo el panel**. El usuario fue explícito sobre el orden:
«Quiero que el streaming sea lo primero que hagas.»

---

## 1. Intención y por qué

Gemma ya puede navegar la web. Hoy eso ocurre a ciegas: el usuario escribe
«cómprame los filtros de agua», y entre esa frase y la respuesta final hay entre
cinco y diez acciones de navegador sobre las que no tiene ninguna visibilidad.
Si algo sale mal, lo único que recibe es un mensaje de error del final de la
cadena.

El usuario pidió esto en una frase, y la frase es el requisito entero:

> «Necesito ver cómo ella se mueve, o simplemente quiero ver cómo se está
> moviendo en el panel. Tan simple como eso.»

Y más adelante, sobre el momento del pago:

> «Realmente no me interesa seguir viéndolo en vivo. De hecho, sería bueno para
> debuguear. Así que sí, quiero verlo en vivo.»

Las dos citas apuntan a lo mismo: el valor del panel es **saber qué está
pasando**, tanto por confianza como para depurar. No es una herramienta de
control. No es una función de producto para terceros —el usuario, preguntado si
esto lo usarían otros, respondió «los mostraré a mi abuela», que es un no.

El `agent-browser` 0.41.2 ya emite todo lo necesario por un WebSocket local, y
el recon en vivo (sección 4) confirmó que además hace eco de cada comando
ejecutado sobre la sesión. Eso significa que el panel puede narrar lo que el
agente hace sin que haya que instrumentar nada en el lado de las herramientas.
El trabajo es de consumo y presentación, no de instrumentación.

---

## 2. Objetivos

1. Mientras hay una sesión de navegador viva, el usuario ve en el chat una
   imagen en vivo de la página, con el cursor donde el agente hace clic y el
   texto que teclea.
2. El usuario ve **qué comando** está corriendo en cada momento, en lenguaje
   legible («navegando a amazon.es», «rellenando el buscador»).
3. El panel se ve también durante el checkout, incluido el paso del pago. Esto
   es una decisión explícita del usuario, tomada tras advertirle de que los
   frames llevarían su número de tarjeta.
4. El panel no degrada el chat: cuando no hay sesión de navegador, no ocupa
   nada.
5. El panel distingue «en vivo» de «congelado». Un frame rancio presentado como
   vivo es peor que no mostrar nada, y contradice el contrato de honestidad del
   repo.

## 3. No objetivos

- **Control remoto.** El panel es para mirar. El usuario no agarra el ratón ni
  teclea en la página. El protocolo lo permite (`input_mouse`,
  `input_keyboard`, `input_touch`) y se descarta a propósito: ver la sección 7.
- **Grabación.** No se guarda vídeo, ni GIF, ni secuencias de frames. El panel
  es un feed en vivo y nada más.
- **Un panel para el iPhone.** Las herramientas de navegador son
  `#if os(macOS)`, porque `agent-browser` es un binario nativo que se lanza con
  `Process` y iOS no tiene subprocesos. El panel es macOS. Cuando llegue el
  cliente de iOS (M3b del roadmap), el camino será el mismo que ya se usa para
  la memoria del i3: el navegador corre en el Mac y el teléfono habla por red.
  Eso es otro proyecto.
- **Un panel para varias sesiones a la vez.** Una sesión de navegador, un panel.
- **Reemplazar el log del agente.** El panel muestra lo que pasa en la página;
  el log del chat sigue siendo el registro de lo que el agente hizo.

## 4. Anti objetivos — qué haría fracasar esto aunque funcione

- **Que el panel mienta.** Un frame de hace treinta segundos pintado como si
  fuera ahora. El repo tiene un contrato de honestidad de cinco estados en sus
  71 herramientas; un panel que presenta historia rancia como presente lo viola
  en el sitio más visible de la app.
- **Que un secreto acabe en pantalla o en un log por una vía que no sea la
  página.** Los frames mostrarán la tarjeta porque la página la muestra, y el
  usuario lo aceptó. Lo que no es aceptable es que el panel añada **una segunda
  fuente de fuga**: el mensaje `command` del CLI lleva los `params` del comando,
  y el `params` de un `fill` de secreto contiene el valor. Si eso se pinta o se
  registra, el panel filtra un secreto que no era suyo.
- **Que los frames lleguen a disco.** Decisión mía, no del usuario: ver la
  sección 6.
- **Que el panel rompa el turno.** Si el socket no conecta, si el puerto no se
  lee, si el CLI deja de emitir `command`, el agente debe seguir funcionando
  exactamente como hoy. El panel es un adorno informativo sobre una capacidad
  que ya existe y funciona sin él.
- **Que haga el chat más lento.** El chat es la función principal. Un panel que
  bloquea el hilo principal pintando JPEGs, o que acumula memoria, es peor que
  no tener panel.

---

## 5. Restricciones verificadas del CLI

Todo lo de esta sección se verificó **en vivo** contra
`/opt/homebrew/bin/agent-browser` 0.41.2, no se leyó de documentación. El recon
completo, con las transcripciones, está en
`docs/superpowers/notes/2026-11-06-recon-streaming-agent-browser.md`. Lo que
sigue es lo que obliga al diseño.

### 5.1 El streaming ya está encendido — nunca llamar a `stream enable`

```
$ agent-browser --session <s> stream enable --json
{"success":false,"data":null,"error":"Streaming is already enabled for this session"}
```

Esto es una trampa concreta para esta base de código. `AgentBrowserToolOutput`
traduce un `success:false` del envelope a un estado de fallo, y aquí lo
traduciría a `refused`: un fallo **inventado** sobre una operación que en
realidad no hacía falta. La app debe llamar a:

```
$ agent-browser --session <s> stream status --json
{"success":true,"data":{"connected":true,"enabled":true,"port":55058,
 "screencasting":false,"lifecycle":{...}},"error":null}
```

### 5.2 El puerto se lee, no se asume

Lo asigna el sistema operativo y **cambia por demonio**. La documentación del
propio CLI lo dice: «Read the port from `stream status --json` rather than
assuming one».

Existe `AGENT_BROWSER_STREAM_PORT` para pinarlo, y la app es quien lanza el
demonio, así que podría usarlo. **Leerlo es mejor**: sobrevive a que el demonio
lo haya levantado otro proceso, que es un caso real porque el usuario también
usa el CLI a mano.

### 5.3 Calidad y tamaño se fijan al lanzar el demonio

Tres variables de entorno, **de todo el demonio, leídas una sola vez al
arrancar**. Cambiarlas después no hace nada; hay que relanzar.

| Variable | Defecto | Efecto |
|---|---|---|
| `AGENT_BROWSER_STREAM_QUALITY` | `80` | Calidad JPEG 0–100, se clampa |
| `AGENT_BROWSER_STREAM_MAX_WIDTH` | el viewport | Acota el frame, no redimensiona la página |
| `AGENT_BROWSER_STREAM_MAX_HEIGHT` | el viewport | Igual |

Medidas del proyecto a 1280×720 sobre una página con actividad: calidad 80 ≈
54 KB/frame; calidad 20 ≈ 25 KB/frame; calidad 20 a 640×360 ≈ 9 KB/frame. Mi
propia medición con los defectos, contando el base64 tal como llega por el
socket: ~92.5 KB de base64 por frame, unos ~69 KB de JPEG.

Un valor inservible **deja el defecto en pie**, no falla.

**Y aquí está la trampa que importa: en el caso normal estas variables no hacen
nada.** El demonio suele estar ya levantado cuando la app arranca —el usuario
también usa el CLI a mano; mientras se escribía este documento había un demonio
vivo (pid 10685, sesión `default`) arrancado fuera de la app—. Como la
codificación se lee una sola vez al arrancar el demonio, poner las variables en
el entorno del hijo **no tiene ningún efecto sobre un demonio existente**. Y
`stream status` **no reporta la calidad**, así que la app tampoco puede detectar
con qué codificación está corriendo.

Había tres salidas y dos son malas:

| Salida | Por qué no |
|---|---|
| Demonio propio con `--namespace` | mata la propiedad de demonio compartido que la sección 5.2 valora a propósito: el usuario conduce el CLI a mano |
| Forzar el reinicio del demonio | mata las sesiones y las páginas vivas del usuario |
| **Aceptar lo que venga y reducir en la app** | **es la que se elige** — ver 6.2(b) |

### 5.4 Los frames son JSON en texto, con JPEG en base64

No hay frames binarios. Verificado poniendo `binaryType = "arraybuffer"`: no
llegó ni un mensaje binario.

```json
{"type":"frame","seq":41,"data":"/9j/4AAQSkZJRg...","metadata":{
  "deviceWidth":1280,"deviceHeight":720,"pageScaleFactor":1,
  "offsetTop":0,"scrollOffsetX":0,"scrollOffsetY":0,
  "timestamp":1793996915607}}
```

- `data` empieza por `/9j/4AAQSkZJRg`, que es `FF D8 FF E0 … JFIF`: JPEG.
- **El mensaje `frame` no lleva campo de formato.** La documentación advierte de
  que un `screencast_start` explícito puede reconfigurar el screencast por
  debajo y cambiar el formato a media corriente. Nosotros no llamamos a
  `screencast_start`, pero el decodificador debe mirar los bytes y no asumir.
- `seq` es monótono y **estable incluso si el navegador se relanza**.
- `metadata.timestamp` es epoch ms de captura. `ahora - timestamp` es la **edad
  real del frame**, y es lo que decide si el panel puede decir «en vivo».

### 5.5 Solo localhost, y el ritmo hay que declararlo en la URL

La conexión es `ws://127.0.0.1:<port>`. Un cliente de navegador con otro origen
recibe **403 en el upgrade**; para la app nativa es indiferente, porque
`URLSessionWebSocketTask` no manda `Origin` y el socket es local.

Dos ajustes se pueden declarar en la URL, y es la **única forma de que cubran el
frame de apertura**:

```
ws://127.0.0.1:<port>/?pacing=ack&maxFps=10
```

Un mensaje `config` posterior gana sobre lo declarado en la URL, pero llega
tarde para el primer frame.

### 5.6 Ack contra push — por qué ack

El servidor guarda **solo el frame más nuevo por cliente** y lo lee al enviar.
Un frame producido mientras se escribe otro se descarta, no se encola.

- En **push** (el defecto), el transporte por debajo sigue siendo ordenado: los
  frames que el socket ya aceptó se entregan en orden, así que un cliente que se
  atasca drena lo que el kernel almacenó. **Resultado: se pinta historia
  rancia.** Eso es exactamente el anti objetivo «que el panel mienta».
- En **ack** (`?pacing=ack`), el servidor mantiene **como máximo un frame en
  vuelo** y espera `{"type":"ack","seq":N}`. Los frames producidos mientras hay
  un ack pendiente se reemplazan entre sí y **nunca llegan al socket**. Un
  cliente que se atasca diez segundos y vuelve recibe **la página actual**.

El coste de ack es un viaje de ida y vuelta del acuse por frame. En localhost es
despreciable. **Para este panel, ack es la elección correcta**, y es la que
cierra el anti objetivo principal.

Los acuses son **acumulativos**: acusar un id más nuevo cubre los anteriores. Un
cliente que deja de acusar simplemente deja de recibir frames, mientras
`status`, `tabs`, `url` y `console` siguen fluyendo. **Eso da el apagado limpio:
para congelar el panel, basta dejar de acusar.**

`pacing` y `maxFps` **se componen**: uno acota lo que hay en vuelo, el otro la
tasa. Verificado: con `?pacing=ack&maxFps=4` sobre `example.com` llegaron **4
frames en 8 segundos**, no 32. Los frames se emiten **por cambio, no por
reloj**: una página quieta no gasta ancho de banda.

`config` acepta `maxFps` de 1 a 120, o `0` para sin tope. Por encima de 120 se
clampa; un valor negativo o no numérico **se ignora** dejando el tope actual.
Ninguno de los dos rechaza la conexión.

### 5.7 `command` y `result` existen, no están documentados, y son el regalo

Capturado en vivo lanzando `agent-browser --session <s> open <url>` **desde otro
proceso** mientras el socket estaba abierto:

```json
{"type":"command","action":"navigate","id":"r990307",
 "params":{"action":"navigate","id":"r990307","url":"https://news.ycombinator.com"},
 "timestamp":1793996943990}
{"type":"result","action":"navigate","data":{"lifecycle":{...},"targetId":"..."}}
```

El stream hace eco de **cada comando que cualquier proceso ejecuta sobre esa
sesión, y de su resultado**. Eso es el objetivo 2 regalado: la narración en vivo
sin instrumentar las herramientas.

Dos consecuencias obligatorias:

1. **Está indocumentado, así que puede desaparecer en una actualización.** El
   panel lo trata como un extra: si no llega, se degrada a mostrar solo frames.
   Nunca se rompe por su ausencia.
2. **`params` puede llevar el texto de un `fill`.** El `params` de un `fill` de
   secreto contiene el valor. **Hay que filtrar por acción antes de pintar o
   registrar.** Ver la sección 6.3, que es la regla, no una lista.

### 5.8 Lo que el servidor ignora en silencio

Probé nombres de mensaje inventados (`{"type":"click"}`, `{"type":"scroll"}`,
`{"type":"notarealtype"}`): el servidor **no respondió ni con error ni con
acuse**. Ignora lo que no entiende.

Consecuencia operativa: **no hay forma de detectar un mensaje mal formado por la
respuesta del servidor**, solo por el efecto que no se produce. El formato de
`ack` y de `config` hay que acertarlo, y conviene una prueba que lo verifique
por el efecto (los frames siguen llegando tras acusar) y no por un acuse que no
existe.

### 5.9 Garantías de orden de los mensajes de canal

`status`, `tabs`, `url` y `console` viajan por un canal ordenado: llegan en
orden y no los reemplaza un mensaje más nuevo, al contrario que los frames.
**Pero no son durables sin condiciones**: un cliente que se retrase lo bastante
puede caerse del canal y perder mensajes. La documentación es explícita en que
`console` es un feed en vivo y **no un registro de auditoría**. El panel no debe
derivar ningún estado importante de haber visto todos los mensajes.

---

## 6. Las decisiones

### 6.1 Decisiones del usuario

Estas son suyas, tomadas en la conversación de diseño. No se vuelven a
preguntar.

| Decisión | Palabras del usuario |
|---|---|
| **El panel vive dentro del chat**, como un mensaje más, en el punto de la conversación donde el agente empezó a navegar | eligió la opción A sobre un panel lateral y una ventana aparte |
| **Mirar, no tocar** | «Necesito ver cómo ella se mueve… tan simple como eso» |
| **En vivo durante el pago, sin pantalla negra** | «Sería bueno para debuguear. Así que sí, quiero verlo en vivo» |
| **Streaming antes que todo lo demás** | «Quiero que el streaming sea lo primero que hagas» |

Sobre la opción A, el usuario conoce su coste porque se le presentó: el panel es
pequeño y **se va de pantalla al scrollear**. Lo eligió igual. El diseño no
intenta compensarlo con un panel flotante ni anclándolo: eso sería construir la
opción B o C después de que eligiera la A.

### 6.2 Decisiones mías

Marcadas como mías. El usuario puede revocar cualquiera.

**(a) Los frames nunca se escriben a disco.** Ni caché, ni temporal, ni log, ni
el contenedor de la app. Viven en memoria el tiempo de pintarlos y se sueltan.
El `trust-boundaries.md` del CLI advierte de que capturas y vídeos pueden
recoger secretos sin querer, y el usuario ya aceptó ver su tarjeta en pantalla
—que es su pantalla, en su Mac, para sus ojos—. Un fichero es otra cosa: es un
secreto en reposo que sobrevive a la sesión, al cierre de la app y a una copia
de seguridad. La diferencia entre ver y guardar es toda la diferencia.

**(b) La app no depende de la codificación del demonio. Reduce ella.**

La intención original era calidad 20 a 640×360, ~9 KB por frame, porque el panel
vive en una burbuja del chat y la calidad 80 a 1280×720 son ~69 KB de JPEG para
pintar algo que se muestra a un tercio de su tamaño. Pero por la razón de la
sección 5.3 eso **no se puede garantizar**: si el demonio ya estaba levantado,
las variables no hacen nada y la app no tiene forma de saberlo.

Así que la regla se invierte:

- La app **sí** pone `AGENT_BROWSER_STREAM_QUALITY=20`,
  `AGENT_BROWSER_STREAM_MAX_WIDTH=640` y `AGENT_BROWSER_STREAM_MAX_HEIGHT=360` en
  el entorno del hijo. Es gratis y surte efecto **cuando la app es la que arranca
  el demonio en frío**.
- La app **nunca cuenta con que hayan surtido efecto.** El decodificador y la
  vista tienen que tragar un frame de 1280×720 a calidad 80 sin inmutarse, y
  reducirlo al tamaño de presentación.

El coste de aceptar lo peor es menor de lo que parece y conviene dejarlo escrito
para que nadie lo vuelva a optimizar: el socket es **localhost**, así que los
~69 KB por frame no son ancho de banda real. El coste verdadero es decodificar
JPEG, y a 10 fps son unos 690 KB/s de decodificación, que en un Mac de la serie M
es nada. Lo único que no es negociable es **no decodificar en el hilo
principal**.

Esto además elimina una decisión que fallaba en silencio: ya no hay un ajuste
del que el diseño dependa y que pueda no estar puesto sin que nadie se entere.

**(c) `?pacing=ack&maxFps=10` en la URL.** Ack por la razón de la sección 5.6:
es lo que impide pintar historia rancia, que es el anti objetivo principal.
`maxFps=10` porque los frames se emiten por cambio y diez por segundo ya se ve
fluido en un panel de ese tamaño. En la URL y no por `config` porque es la única
forma de cubrir el frame de apertura.

**(d) Mirar y no tocar, confirmado como decisión de diseño y no solo como
lectura de lo que dijo el usuario.** Ver la sección 7.

**(e) El panel se degrada, nunca rompe.** Cinco fallos posibles y qué hace el
panel en cada uno, porque un panel que se cae debe caerse callado:

| Fallo | Qué hace el panel |
|---|---|
| `stream status` no devuelve puerto | no aparece; el turno sigue igual |
| el WebSocket no conecta | no aparece; el turno sigue igual |
| el socket se cae a mitad | se congela con el último frame y se marca **congelado**, no «en vivo» |
| no llegan mensajes `command` | muestra frames sin narración |
| un frame no decodifica | se descarta ese frame y se acusa igual, para no atascar el ritmo |

**(f) «En vivo» es una propiedad de la CONEXIÓN, no de la edad del frame.**

Esto corrige una versión anterior de este documento que decía lo contrario, y la
corrección importa porque la versión anterior producía exactamente el anti
objetivo principal.

El error: «si la edad del frame pasa de un umbral, deja de decir en vivo». Suena
razonable y está mal, porque **los frames se emiten por cambio y no por reloj**
(verificado: 4 frames en 8 segundos sobre `example.com` con `maxFps=4`). En una
página quieta no llega ningún frame nuevo, y el último envejece sin tope. Con la
regla de la edad, el panel gritaría **congelado** sobre una página perfectamente
viva a los dos segundos de quietud. Eso es el panel mintiendo, que es justo lo
que el umbral pretendía evitar.

**El predicado correcto:** el panel está en vivo cuando

1. el socket está abierto, y
2. la app está acusando los frames que recibe (en `pacing=ack`, dejar de acusar
   es la forma de congelarlo a propósito), y
3. el último `status` recibido dice `screencasting: true`.

Las tres son propiedades de la conexión y ninguna depende de que la página se
mueva.

**La edad del frame se muestra, pero no decide nada.** Es información útil para
depurar —«último cambio hace 14 s» es una frase verdadera y útil— y es
precisamente lo que el usuario pidió el panel para poder ver. Lo que no es es un
indicador de salud.

**Congelado** se dice cuando el socket se cae, cuando la app deja de acusar, o
cuando la sesión se cierra. Esos son eventos, no umbrales, así que no hay ningún
número que afinar.

**(g) Un panel congelado SUELTA su último frame y se colapsa a una etiqueta.**

El usuario consintió ver su tarjeta **en vivo**, y la razón que dio fue depurar.
Nadie le preguntó por un frame del checkout aparcado en el historial del chat
durante horas y repintado cada vez que scrollea.

Son dos cosas distintas y solo consintió la primera. Un frame en vivo es una
imagen que existe mientras la mira. Un frame en el historial es **un secreto en
reposo dentro de la interfaz**, que sobrevive al turno, a la conversación y a que
el usuario se levante de la silla con la app abierta.

Así que al congelarse —socket caído, sesión cerrada, turno acabado— el panel
suelta la imagen y deja en su sitio una línea: «navegó en amazon.es · 7
acciones». El historial queda legible y no guarda ninguna imagen.

Revocable como todas las mías. Si el usuario quiere el último frame aparcado en
el historial, se lo damos; pero entonces lo pide sabiendo que ahí queda la
pantalla del pago.

### 6.3 La regla del filtrado, que es una regla y no una lista

El mensaje `command` lleva `params`, y `params` puede llevar un secreto. La
tentación es hacer una lista de acciones peligrosas (`fill`, `type`) y filtrar
esas.

**Eso está mal, y por una razón que esta base de código ya aprendió.** Una lista
de prohibidos falla abierto: el día que el CLI añade una acción nueva que lleva
texto en `params`, la lista no la conoce y el secreto pasa. El commit `6990231`
de la rama del navegador hizo exactamente esta corrección en otro sitio
—«expresar la marca de contenido no confiable como regla, no como lista»— y la
misma lógica aplica aquí.

**La regla:** del mensaje `command`, el panel muestra **solo** `action` y, para
las acciones de navegación, la URL. **Nunca muestra `params` completo, para
ninguna acción, conocida o no.** El texto legible se construye a partir de
`action` y de una tabla de plantillas que el panel controla:

- `navigate` → «navegando a `<host de la url>`»
- `click` → «haciendo clic»
- `fill` / `type` → «rellenando un campo» — **sin el valor, sin el selector**
- cualquier acción que el panel no conozca → «`<action>`», el nombre a secas

Así una acción nueva del CLI aparece como su nombre y nada más. Falla cerrado.

El mismo criterio para el log: el panel no registra `params` en ningún sitio,
ni en consola de depuración.

---

## 7. Por qué no hay control remoto

El protocolo lo soporta: `input_mouse`, `input_keyboard` e `input_touch`, con un
`eventType` de CDP dentro. Verificado que existe, y además bien hecho —la
entrada se despacha en una tarea separada de la entrega de frames, se envía al
navegador sin esperar respuesta, se preserva el orden, y **reinicia el
temporizador de inactividad del demonio**, así que una vista previa que el
usuario maneja no se apaga por timeout.

Se descarta por dos razones.

**La primera es lo que pidió.** «Tan simple como eso» fue la respuesta completa a
qué necesitaba del panel. Construir control remoto es construir algo que no
pidió, y se le dijo en pantalla que si lo quería había que decirlo porque
«cambia bastante el diseño». No lo dijo.

**La segunda es que no es una decisión de UI.** Un clic del usuario dentro de una
página que el agente abrió es una acción sobre una página no confiable, por una
vía que no pasa por ninguna de las puertas que el sub-proyecto de compras va a
construir: ni la política de acciones, ni la confirmación del CLI, ni el código
de compra. Si algún día se añade, se diseña **con** las reglas de compra, no
como un detalle del panel.

---

## 8. Qué queda al constructor

El plan de implementación decide estas, y son decisiones de oficio, no de
producto.

1. **Dónde vive el cliente de WebSocket.** `URLSessionWebSocketTask` es lo
   natural en esta app. Si va en un actor propio, si es un `AsyncStream` de
   frames que la vista consume, o si cuelga de `HarnessModel`, es del
   constructor. Lo que no es negociable: no bloquear el hilo principal
   decodificando JPEG.
2. **Cómo se presenta la edad del frame.** El predicado de «en vivo» ya no
   depende de ella (sección 6.2(f)), así que esto es presentación: si se muestra
   siempre, solo por encima de unos segundos, o solo en un modo de depuración.
   No hay umbral que afine ningún comportamiento.
3. **Cómo se dispara y se cierra el panel.** Lo natural es que la vista aparezca
   cuando `browser_open` tiene éxito y se cierre cuando `browser_close` lo tiene,
   pero el disparo exacto depende de cómo el chat renderiza entradas, y eso lo ve
   el constructor con el código delante.
4. **Dónde se fijan las variables de entorno del demonio.** El demonio lo lanza
   `AgentBrowserInvoker`, y ya construye el entorno del hijo con
   `Self.childEnvironment(from: environment)`. Las tres variables de calidad y
   tamaño van ahí, como esfuerzo de mejor caso y nada más: por la sección 6.2(b),
   la vista tiene que funcionar igual si no surten efecto. Hay que respetar la
   memoización de la resolución del binario.
5. **La forma del acuse y su prueba.** El servidor ignora en silencio lo que no
   entiende (sección 5.8), así que la prueba de que `{"type":"ack","seq":N}` está
   bien formado **no puede** ser un acuse del servidor: tiene que ser por el
   efecto, comprobando que los frames siguen llegando tras acusar. Es la única
   verificación posible y el plan debe pedirla explícitamente.
6. **Qué pasa con dos sesiones.** El no objetivo dice una sesión, un panel. Si
   el código permite hoy que haya dos demonios con dos sesiones, el plan decide
   si el panel sigue a la sesión del turno activo o si simplemente no aparece.

### Clases de entrada que el plan debe cubrir con tests

Ninguna la ejercita el camino felíz, y todas son de las que muerden:

- Un `command` con una `action` que el panel no conoce → aparece el nombre a
  secas, **nunca `params`**.
- Un `command` de `fill` con un valor en `params` → el valor **no** aparece en la
  vista ni en ningún log.
- Un `frame` cuyo `data` no decodifica → se descarta y **se acusa igual**, el
  ritmo no se atasca.
- `stream status` devuelve `success:false`, o sin `port` → el panel no aparece y
  el turno del agente **no cambia en nada**.
- El socket se cae con una sesión viva → el panel se marca **congelado** y no
  «en vivo».
- **Una página quieta durante treinta segundos → el panel SIGUE diciendo «en
  vivo».** Este es el test que la versión anterior de este documento habría
  suspendido, y es el que protege el anti objetivo principal. Se monta con una
  página estática y sin tocarla.
- El último `status` dice `screencasting: false` → el panel **no** dice «en
  vivo», aunque el socket siga abierto.
- La app deja de acusar → los frames paran y el panel se marca **congelado**, no
  «en vivo con un frame viejo».
- El panel se congela → **no queda ninguna imagen** en el historial, solo la
  etiqueta de resumen (sección 6.2(g)).
- Un frame de 1280×720 a calidad 80 (el demonio ya estaba levantado y las
  variables no surtieron efecto) → **se pinta igual**, reducido, sin decodificar
  en el hilo principal.

---

## 9. Lo que este documento NO decide, y dónde se decide

- **Cómo se guarda y se teclea un secreto.** Sub-proyecto 2.
- **La puerta de compra, el código hablado y los topes.** Sub-proyecto 3. El
  recon encontró que el CLI trae `--confirm-actions` con auto denegación a los
  60 s, que es un punto de aplicación por debajo del modelo; eso cambia ese
  diseño y está registrado en
  `docs/superpowers/notes/2026-11-06-recon-contencion-y-confirmacion.md`.
- **Los recibos.** Sub-proyecto 4. La escalera de cuatro peldaños está decidida
  y registrada en `docs/superpowers/notes/2026-11-06-compras-decisiones.md`.
- **El panel en el iPhone.** Es el M3b del roadmap y es otro proyecto.

---

## 10. Lo que el usuario tiene que decidir

Una cosa, y solo él puede, porque cambia lo que se construye.

**¿Un panel por sesión de navegador, o un panel nuevo por cada turno que
toque el navegador?**

La sección 6.1 fija que el panel vive dentro del chat, como un mensaje más, y
que el usuario aceptó el coste de que se vaya de pantalla al scrollear. Lo que
no fija es cuántos paneles hay.

Las dos lecturas son coherentes con lo que él dijo, y llevan a software
distinto:

- **Un panel, anclado donde ella empezó a navegar.** En el turno 1 se ve todo.
  En el turno 2 el panel ya subió fuera de la vista: el usuario escribe, ella
  navega, y él está ciego mientras mira la parte baja de la conversación. Eso
  es exactamente el fallo que el proyecto existe para arreglar —el anti
  objetivo número uno de la sección 4 es un panel que dice estar en vivo sin
  estarlo, y uno que está en vivo pero fuera de pantalla es el primo del mismo
  problema.
- **Un panel nuevo por cada turno que toque el navegador**, con los anteriores
  colapsados a una etiqueta («navegó en amazon.es · 14 acciones»). Cada turno
  trae su propia ventana a lo que está pasando, al lado de lo que él acaba de
  escribir. Es más trabajo de ciclo de vida: hay varios paneles, solo el último
  está conectado, y los viejos tienen que haber soltado su último frame por la
  decisión 6.2(g).

**Mi recomendación: un panel nuevo por turno, con los anteriores colapsados.**
El coste extra es ciclo de vida, que es código acotado y testeable. El coste de
la otra opción lo paga el usuario cada vez que la conversación pasa del primer
turno, y lo paga mirando a una burbuja que no está ahí.

Si él elige un solo panel, la sección 6.2(g) sigue valiendo tal cual y el
constructor tiene menos que hacer; nada más del documento cambia.
