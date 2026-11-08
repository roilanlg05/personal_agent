# El mando compartido del navegador

Diseño, 2026-11-08. Sucede al spec `2026-11-08-navegador-visible-y-busqueda-design.md`,
del que **retira un no-objetivo**: allí escribí que el control remoto quedaba
fuera de alcance. El usuario lo ha pedido como requisito central y manda él.

## Por qué

El agente no puede comprar. El usuario lo dijo con un caso concreto: «le pedí que
entrara a AutoZone y que agregara cierto producto al carrito, pero la página no me
dejó entrar. Así me pasa con casi todas las páginas. Me bloquean.»

Medido el 2026-11-08 contra el navegador del i3, no son «las páginas»: son **tres
sistemas distintos**, y cada uno falla de otra manera.

| sitio | qué sirve | quién bloquea |
|---|---|---|
| `autozone.com` | 447 caracteres, `var dd={'rt':'c','cid':…,'hsh':…}` | **DataDome** |
| `pccomponentes.com` | título `Just a moment...` | **Cloudflare** |
| `claude.ai`, `chatgpt.com` | título `Just a moment...` | **Cloudflare** |
| `decathlon.es` | `Attention Required! \| Cloudflare` | **Cloudflare**, bloqueo duro |
| `amazon.es` | 357 caracteres, «Lo sentimos» — **3 de 5 búsquedas seguidas** | estrangulamiento propio de Amazon |
| `ebay.es`, `idealo.es` | error propio del sitio | ninguno de los dos |
| `es.aliexpress.com` | su página de resultados real, 171 `<img>` | — |
| `es.wikipedia.org` | la página real | — |

Y la señal que lo explica casi todo, medida contra `httpbin.org/headers` desde
dentro del contenedor:

```
User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/156.0.0.0 Safari/537.36
Accept-Language: en-US,en;q=0.9
Sec-Ch-Ua: "Not:A-Brand";v="8", "Chromium";v="156"
```

`HeadlessChrome` escrito en la propia cabecera. Nadie necesita huellear nada
sofisticado para saber que esto es un robot.

**Dos hechos que cierran el camino fácil, los dos medidos:**

1. **El desafío de Cloudflare no se pasa esperando.** `pccomponentes.com` sigue en
   `Just a moment...` a los 5, 15, 30 y 45 segundos. El texto «Verification
   successful. Waiting for chatgpt.com to respond» que sirve `chatgpt.com` es
   parte de la página de desafío, no un estado alcanzado.
2. **No son captchas de imágenes.** Cloudflare y DataDome, en estos sitios,
   comprueban la huella del navegador sin pedir nada al visitante. No hay puzle
   que resolver, así que un modelo mirando la pantalla no tiene nada que hacer
   ahí. El usuario pidió «captchas que necesito que el modelo resuelva» creyendo
   que los había; la medición dice que no.

De ahí sale la forma del proyecto. Si el muro no se burla y no hay puzle que
resolver, lo que queda es **ser un navegador de verdad** y, cuando aun así haya
una comprobación humana, **que la haga el humano**.

## Lo que el usuario decidió

Textual, para que no se reinterprete:

- **Alcance:** «lo que haga falta para que no bloquee» — perfil persistente,
  cookies que sobrevivan, proxy si hace falta.
- **El paso de mando:** «necesito tomar el control por ese instante. Luego el
  control regresa al agente. Cuando este detecte que cambió la página o cambió
  algo que no sea, por ejemplo, un error de que el captcha no se resolvió o algo
  así.»
- **Los clientes:** «necesito que pueda manejarlo no solo desde el teléfono, sino
  también desde una página web o desde una computadora.»
- **Dónde vive:** «todo el sistema que hay detrás tiene que vivir en el I3.»
- Y antes, en el brainstorming del navegador visible: «si no hay ninguna
  interacción de la gente con el navegador, o mía con el agente para que
  interactúe con el navegador, entonces se cierra a los 15 minutos
  automáticamente, o mejor, a los 10 minutos.»

Y cuatro que eligió sobre preguntas que la revisión de constructor sacó, porque
cada una partía el proyecto en dos proyectos distintos:

- **Cómo espera el agente al humano: termina el turno y lo reanuda luego.** No se
  queda bloqueado dentro del turno. Eso obliga a que un turno sea reanudable y a
  que el sistema sepa avisarle, y es más trabajo, pero aguanta que cierre la app,
  se vaya y vuelva en una hora.
- **La puerta de compra entra antes de guardar la primera tarjeta.** Se construyen
  A, B y D sin ningún medio de pago en el perfil; la puerta va justo antes del
  primero.
- **Los SMS salen de Telnyx**, que es donde ya tiene sus números.
- **El cliente web empieza siendo el que ya trae el CLI**, con su control de
  orígenes. Se mide, y solo si no sirve se hace uno propio.

Y la premisa que lo ordena todo, en dos frases suyas que llegaron una detrás de
otra y que hay que leer juntas:

1. **«El agente debería usar el navegador como si fuera mi computadora, como si yo
   fuera el que estuviera usando.»**
2. **«Le voy a crear un correo electrónico de Gmail al agente y este se podrá
   registrar ahí en cualquier página. Y le voy a dar un número de teléfono
   también para que reciba códigos de las páginas.»**

La segunda refina la primera y es la que manda. El navegador del i3 no es «el
navegador del robot» ni es la cuenta del usuario: es **el navegador de una
persona, y esa persona es el agente**, con su correo, su teléfono, sus cuentas
propias, su historial y sus cookies.

Eso no es un detalle de permisos, es la forma del proyecto, y arregla tres cosas
a la vez:

- **Las cuentas del usuario no entran en juego.** Lo que se pueda romper es
  revocable y no es suyo. Ninguna contraseña suya pasa jamás por el agente.
- **El agente puede completar un registro de principio a fin**, porque el código
  de verificación llega a un buzón y a un teléfono que son suyos.
- **Es la mejor postura antibot que existe**, y no por disfraz: una cuenta con
  antigüedad, historial y pedidos hechos no parece una persona, *es* el uso normal
  de una identidad real. El objetivo de usabilidad y el de la huella resultan ser
  el mismo objetivo.

El precio es una pieza nueva que no estaba en el proyecto: **el agente tiene que
poder leer su propio correo y sus propios SMS.** Eso es el subsistema D.

## Lo que ya existe y hay que aprovechar

**El protocolo del demonio ya es de control remoto.** Medido leyendo la
referencia `streaming` del propio CLI (`agent-browser skills get core --ref
streaming`, versión 0.41.2 en la imagen del i3). Nada de esto hay que inventarlo:

| pieza | qué dice el CLI |
|---|---|
| entrada | el cliente manda `input_mouse`, `input_keyboard`, `input_touch` |
| despacho | «Input dispatches to the browser on a task of its own, separate from frame delivery… Ordering is preserved: press never overtakes move» |
| **inactividad** | «Mouse, keyboard, and touch input also reset the daemon idle timer, so an actively driven preview is not shut down by the idle timeout» |
| **navegación** | el servidor manda `url` en navegación de documento completo, History API y fragmento, del frame principal de la pestaña activa |
| otros mensajes | `status` (estado, viewport, motor), `tabs`, `console` |
| metadatos del fotograma | `deviceWidth`, `deviceHeight`, `pageScaleFactor`, `offsetTop`, `scrollOffsetX/Y`, `timestamp` |
| ritmo | `maxFps` por cliente y `pacing: ack` con un fotograma en vuelo |
| acuses con proxy | «With a proxy in the path, forward the renderer's acks; acks generated on receipt leave frames queued on the far side». **Acks acumulativos.** |
| alcance | «Localhost only. Exposing the stream beyond the machine is the embedder's job» |
| origen | un cliente de navegador que no cargue de `localhost`, `127.0.0.1`, `::1` o `file://` recibe **403 en el upgrade** |

Dos de esas filas son regalos directos a lo que el usuario pidió: el temporizador
de inactividad que se reinicia con la entrada humana (conduces y no se te cierra
en mitad del captcha) y el mensaje `url` (la señal de «cambió la página» que
devuelve el mando, sin que haya que adivinarla).

**El i3 está en una conexión residencial de Estados Unidos**, y esto importa más
de lo que parece: medido, su IP de salida es `76.35.238.122`,
`res.spectrum.com`, **Louisville, Kentucky**, AS10796 Charter Communications. No
es un centro de datos. Para un sistema antibot, una IP residencial estadounidense
es la mejor posición de partida que se puede tener, y descarta de entrada la
sospecha de que los bloqueos vengan del rango de IP. (AutoZone, además, es
alcanzable desde ahí: da 403 a un `curl` pelado, que es su DataDome haciendo su
trabajo, no un bloqueo geográfico.)

**La imagen del i3 ya trae `Xvfb` y `xvfb-run`** (`/usr/bin/Xvfb`,
`/usr/bin/xvfb-run`), y el CLI tiene `--headed` / `AGENT_BROWSER_HEADED`. Un
Chrome con ventana de verdad, dentro del contenedor, es posible hoy sin añadir
nada.

**Variables que el CLI ya reconoce** y que son el inventario del que sale la parte
de la huella: `AGENT_BROWSER_USER_AGENT`, `AGENT_BROWSER_ARGS` (flags de Chrome),
`AGENT_BROWSER_PROFILE`, `AGENT_BROWSER_STATE` con `AGENT_BROWSER_STATE_EXPIRE_DAYS`
y `AGENT_BROWSER_RESTORE`, `AGENT_BROWSER_PROXY` con `AGENT_BROWSER_PROXY_BYPASS`,
`AGENT_BROWSER_PLUGINS`, `AGENT_BROWSER_INIT_SCRIPTS`, `AGENT_BROWSER_COLOR_SCHEME`.
El plugin `stealth` que menciona la ayuda (con capacidad `launch.mutate`) **no está
instalado en la imagen**: `npm ls -g` da solo `agent-browser@0.41.2`, `corepack` y
`npm`.

**Y lo que hay que cambiar a conciencia.** Hoy el relé del i3
(`gemma-memory/browser/relay.py`) dice en su propia cabecera: «no acepta del visor
ningún mensaje que no sea `ack`: **no hay control remoto**». Eso fue una decisión
deliberada de seguridad, no un olvido. Este proyecto la revierte, y la sección de
Restricciones dice qué la sustituye. Un relé que acepte entrada sin lo de abajo es
peor que el de hoy.

## Objetivos

1. **Que el usuario pueda tomar el mando del navegador del i3 un instante,
   resolver lo que haya que resolver a mano, y que el agente siga desde ahí** sin
   que él tenga que decir nada.
2. **Que el navegador sea un navegador de verdad**, sin burlar ningún control de
   acceso: Chrome con ventana, perfil con uso acumulado, cookies que sobrevivan
   entre turnos y entre días, idioma coherente, entrada humana.
3. **Tres clientes, un solo sistema.** Teléfono, página web y computadora hacen lo
   mismo porque el sistema está en el i3 y los tres son vistas.
4. **Que el navegador se cierre solo a los 10 minutos sin interacción**, y que la
   interacción humana cuente como interacción. **Ojo a un conflicto que el revisor
   encontró entre este objetivo y el 2:** el CLI documenta el modo con ventana como
   exento del cierre por inactividad por omisión, así que el plan tiene que
   comprobar cuál de los dos gana en la práctica y, si de verdad se excluyen,
   decidirlo con el usuario — perder un login hecho a mano por un cierre
   automático es el daño más caro de todo el sistema.
5. **Que el agente pueda registrarse en un sitio con su propia identidad** y
   completar la verificación por su cuenta, leyendo el código que llegue a su
   correo o a su teléfono.
6. **Que el agente pueda comprar en AutoZone**: entrar, encontrar el producto y
   dejarlo en el carrito. Es el caso que el usuario puso y es la prueba de que
   esto funciona.

## No objetivos

- **Resolver captchas automáticamente.** No se construye. Es la pieza que existe
  para saltarse un control de acceso, y además, medido, los sitios que el usuario
  nombró no ponen captchas de imágenes: ponen comprobaciones de huella. Cuando
  haya una comprobación humana, la hace el humano. Eso es el proyecto.
- **Guardar credenciales del usuario.** El agente navega logueado, pero la
  contraseña no pasa nunca por él: entra el usuario a mano una vez y el perfil se
  queda con la sesión. Ver Decisiones mías, punto 1.
- **Pagar.** La puerta de compra con topes, la confirmación forzada por la
  aplicación y los recibos tienen su propio diseño. Aquí se llega al carrito y se
  para. **Pero ojo**: desde que este proyecto hace que el navegador esté logueado,
  esa puerta deja de ser «lo siguiente» y se convierte en una dependencia. Ver
  Decisiones mías, punto 1.
- **Audio.** Ya estaba fuera en el spec anterior y sigue fuera.
- **Consumo a pantalla completa** (ver un vídeo en el navegador del i3 desde el
  teléfono). Fuera, igual que antes.
- **Rotar el `MEMORY_BEARER_TOKEN` del i3**, que sigue siendo el placeholder
  `replace-me-with-a-long-random-string`. Es un pendiente real pero de otro
  proyecto, y el usuario no lo ha autorizado.
- **Un proxy.** El usuario lo puso en el alcance («proxy si hace falta»), pero
  **queda fuera de este proyecto**, y no por precio: medido, el i3 ya sale por una
  conexión residencial de Spectrum en Louisville, Kentucky, que es la mejor
  posición posible. Un proxy solo empeoraría eso. Si algún día hiciera falta por
  otra razón —geografía de una tienda, por ejemplo— será un proyecto suyo con su
  propia medición. Lo retiro de los cinco subsistemas para que no aparezca en tres
  sitios diciendo tres cosas distintas, como pasaba en la primera versión de este
  documento.

## Anti-objetivos

Cosas que harían fracasar esto aunque funcionara:

- **Que el relé acepte entrada de cualquiera que tenga el token.** El token da
  hoy acceso de lectura a una pantalla; esto convertiría ese token en «conduce un
  Chrome con mis sesiones abiertas». Si el paso de mando no está acotado como dice
  Restricciones, este proyecto empeora la seguridad del sistema.
- **Que el modelo decida cuándo tiene el mando.** El estado lo lleva el servicio.
  Un modelo que *dice* que ha devuelto el mando y sigue mandando órdenes es
  exactamente el fallo que el usuario ya cerró en la puerta de compra: la
  aplicación lo impone, el modelo no lo promete.
- **Que una contraseña del usuario acabe en un log, en una narración o en el
  contexto del modelo.** Él va a teclear credenciales durante el paso de mando.
  Si un `input_keyboard` se registra, se narra con su tecla o se le pasa al
  modelo, el proyecto ha filtrado una contraseña.
- **Que el usuario se quede con el mando sin saberlo**, y el agente parado
  esperándole en silencio mientras él cree que está trabajando.
- **Que detectar el muro sea adivinar.** Una lista de firmas explícitas, no una
  coincidencia difusa de palabras sobre el texto de la página. El usuario ya fijó
  ese criterio para la confirmación de compra y vale igual aquí.
- **Que la herramienta del correo sea un cliente de correo.** Si puede leer el
  buzón entero, puede leer cualquier cosa que llegue a ese buzón durante los
  próximos años, y ese buzón va a acumular confirmaciones de pedidos, direcciones
  de envío y recibos. Estrecha o no se construye.
- **Que esto se convierta en una fábrica de identidades.** El usuario crea una
  cuenta de correo y da un número; el agente las usa. Un agente que se crea
  cuentas a sí mismo es otro producto y nadie lo ha pedido.

## Los cinco subsistemas

El proyecto son **cinco** subsistemas, no cuatro: la revisión de constructor
señaló con razón que la puerta de compra tenía posición en el orden y no estaba en
la lista. Cada uno es un plan aparte y el orden importa.

| | qué | por qué ahí |
|---|---|---|
| **A** | El mando compartido, en el i3 | sin él no hay nada que probar |
| **B** | Las tres interfaces | hace el mando usable desde donde el usuario está |
| **D** | La identidad del agente | habilita la pieza más potente de C, y sin ella el agente no completa un registro |
| **C** | Ser un navegador de verdad | se mide contra una línea base que ya existe |
| **E** | La puerta de compra con topes | **decisión del usuario: antes de guardar la primera tarjeta** |

**El orden es A, B, D, C, y E entra justo antes de que un medio de pago toque ese
perfil.** Hasta entonces se construye y se prueba sin ninguna tarjeta guardada. E
tiene su propio diseño y no se detalla aquí; lo que este documento fija es su
posición, que no es negociable por conveniencia: en cuanto el navegador esté
logueado con una tarjeta, puede comprar de un clic.

### A. El mando: la máquina de estados, en el i3

El corazón. Dos estados y nada más: **el agente conduce** o **el humano conduce**.
Vive en el servicio del navegador del i3, no en ningún cliente.

- **Quién tiene el mando es un dato del servidor**, no una creencia de nadie. Se
  publica a todos los visores conectados, igual que hoy se publica el estado del
  panel, para que las tres interfaces coincidan sin hablar entre ellas.
- **Mientras conduce el humano, el servicio rechaza las órdenes del agente.** No
  las encola: las rechaza con un motivo que el agente pueda leer y contarle al
  usuario. Es el mismo principio que la puerta de compra.
- **Mientras conduce el agente, el servicio ignora la entrada de los visores**,
  que es exactamente lo que hace hoy.
- **El mando lo pide el agente o lo toma el usuario.** El agente lo pide cuando
  detecta un muro; el usuario puede tomarlo en cualquier momento, también entre
  turnos, porque es su navegador. Eso obliga a que el relé sirva el mando fuera
  de un turno vivo, que hoy no hace.
- **El turno termina y se reanuda; no se bloquea.** Decisión del usuario. El
  agente dice qué necesita, cierra el turno y suelta al usuario. Cuando el mando
  vuelve, la tarea se retoma donde estaba. Eso pide dos cosas que hoy no existen:
  que el estado de la tarea sobreviva al fin del turno, y que el sistema sepa
  avisar al usuario cuando la app está cerrada.

**La detección del muro, corregida por lo que se midió.** Mi primera versión
decía que las firmas se leen del cuerpo de la página (`var dd={`, los 357
caracteres de Amazon) y eso contradecía la restricción de no mirar la página
mientras conduce el humano. La contradicción desaparece con un hecho medido: **el
mensaje `tabs` del demonio trae el título de la pestaña activa**, y las dos firmas
de Cloudflare —`Just a moment...` y `Attention Required!`— son títulos. Se
detectan **sin leer la página**.

Así que la detección se ordena en dos niveles:

1. **Sin mirar la página**, siempre disponible: el título que llega en `tabs`, el
   estado de fallo que devolvió una herramienta del navegador, y una acción que no
   cambió nada.
2. **Mirando la página**, solo mientras conduce el agente y nunca durante un paso
   de mando: las firmas de cuerpo, para los muros que no se anuncian en el título
   (DataDome en AutoZone, el estrangulamiento de Amazon).

**La señal de vuelta existe pero hoy se tira.** El demonio manda un mensaje `url`
en cada navegación, que es exactamente el «detectó que cambió la página» que pidió
el usuario. Medido: **`stream.decode` lo clasifica como `other` y muere en el
relé**. Hacerlo llegar es trabajo de este subsistema, no un detalle.

El mando vuelve al agente cuando llega un `url` nuevo que no es un muro, con tres
salvaguardas: una página de muro que navega a sí misma no cuenta (es el «error de
que el captcha no se resolvió» del usuario); hace falta que el muro deje de estar
presente, no solo que la URL cambie; y el usuario puede devolverlo a mano. Y un
plazo: si toma el mando y se va, el turno termina y se lo dice.

**Lo que el relé puede reenviar del visor, y lo que no.** Esto es una lista de
permitidos, no una de prohibidos, y sale de una medición: `{"type":"config",
"maxFps":0}` enviado a mitad de conexión **levanta el tope de fotogramas**. Si el
relé reenvía los mensajes del visor sin filtrar, reabre el agujero de caudal
ilimitado que la rama anterior acaba de cerrar y además rompe el `pacing=ack` del
que depende todo el ritmo. Por tanto:

- **Se reenvían** `input_mouse`, `input_keyboard` e `input_touch`, y solo del
  portador del mando.
- **No se reenvía nunca** `config`. El ritmo lo decide el servicio, como ya se
  decidió al bajar los topes a 7.
- El `ack` sigue tratándose como hoy, que es el único mensaje del visor que el
  relé ya entiende.

Lo que el constructor decide aquí: los nombres de los mensajes, cómo se
representa el portador, los plazos concretos, y dónde vive la detección del muro.
Mi recomendación es un módulo nuevo al lado de `browser/stream.py`, puro como él
—sin red, sin ficheros, sin reloj— porque la detección puede serlo y así se
prueba sola.

### B. Las tres interfaces

Las tres son vistas finas sobre A. Ninguna lleva lógica de estado.

- **El teléfono y la computadora ya tienen panel** (`BrowserPanelCoordinator`,
  `BrowserRelayClient`, la vista del chat), pero **el panel de hoy es por turno**:
  `endTurn()` lo congela y cancela su flujo. Para que el usuario pueda tomar el
  mando entre turnos, al panel no le falta «mandar entrada»: le falta **existir
  fuera de un turno**. Eso es lo primero de este subsistema, no un añadido.
- **El cliente web empieza siendo el que ya trae el CLI.** Decisión del usuario.
  `agent-browser` tiene un dashboard propio con `--allowed-origins`; se mide
  contra lo que hace falta y solo si no sirve se escribe uno. Ahorra todo un
  cliente si cumple.
- **Mapear un toque a una coordenada de la página: mi fórmula era errónea.** Decía
  que `metadata.deviceWidth/deviceHeight` daba el tamaño del recorte. Medido: ese
  campo es **el viewport** (1280×720) y no el recorte (1080×608), y además
  **`metadata` no sale del relé** — `_decode_frame` solo deja `seq`, el JPEG y el
  timestamp. Así que hay dos trabajos: hacer llegar al cliente lo que necesita
  para deshacer **las tres** escalas (viewport → recorte del servidor → pantalla
  del cliente), y escribir la fórmula contra las dimensiones reales del JPEG
  recibido, no contra una constante ni contra el viewport.
- **El puntero del ratón**, que el usuario pidió aparte: el CLI **no lo ofrece en
  el stream** (su `--cursor` es solo de `record`, y el screencast viene de CDP, que
  no dibuja cursor). Con esto construido sale casi gratis por el otro lado: el
  cliente ya sabe dónde está el puntero porque es él quien lo mueve, y las
  acciones del agente ya viajan al panel. Dibujarlo es cosa del cliente.
- **Avisar al usuario cuando la app está cerrada.** Lo pide la decisión de que el
  turno termine y se reanude: un paso de mando que nadie ve no sirve de nada. Hoy
  la app no tiene notificaciones de ningún tipo. Es la pieza de B con más riesgo de
  crecer, y conviene acotarla a lo mínimo que funcione.

Lo que el constructor decide aquí: qué eventos manda cada cliente (un teléfono
manda `input_touch`, una computadora `input_mouse`), cómo se ve de quién es el
turno, y por dónde llega el aviso.

### D. La identidad del agente: su correo y su teléfono

El usuario crea la identidad a mano —una cuenta de Gmail y un número— y el agente
la usa. **El reparto es exactamente ese: él crea, el agente usa.** Darle a un
agente la capacidad de crearse cuentas de correo sería otra cosa y no está pedido.

**El correo se lee por la API de Gmail con OAuth de solo lectura, nunca
conduciendo la web de Google.** Esto dejó de ser una preferencia y pasó a ser la
única opción: el usuario lo intentó por el navegador y Google le respondió que no
podía autorizar ese navegador por automatizado. No hay que pelear ese muro, hay
que no pasar por él. El usuario autoriza una vez desde su navegador normal, en una
sesión humana que Google acepta sin fricción, y el agente recibe un token
revocable con el alcance mínimo. Ventaja adicional: no hay contraseña de Google en
ninguna parte, ni siquiera en el perfil del navegador.

**Los SMS salen de Telnyx**, que es donde el usuario ya tiene sus números.
Decisión suya. Y una consecuencia que decido yo: **se consultan por su API, no se
reciben por webhook.** Un webhook obligaría a que el i3 fuera alcanzable desde
internet, y hoy solo está en Tailscale; abrirlo para recibir un SMS sería la
superficie nueva más grande del proyecto por el beneficio más pequeño. Consultar
no necesita nada expuesto.

**Corrección del usuario (2026-11-08, posterior a la primera versión de este
documento):** no se habla con Telnyx directamente. Él ya tiene **un proyecto
propio, Boxia, con un MCP que trabaja contra Telnyx y gestiona los números de
teléfono**, y por ahí van a salir los SMS. Textual: «el SMS creo que lo voy a
utilizar a través de un MCP de mi proyecto Boxia, que ya trabaja con Telnix y
gestiona números de teléfono».

Esto **cambia el subsistema D y lo abarata**: el i3 no guarda ninguna credencial
de Telnyx, no hay cliente de su API que escribir, y la decisión de «consultar en
vez de webhook» pasa a ser problema de Boxia y no de este proyecto. Lo que queda
por decidir, y que **no se decide aquí porque el subsistema D aún no se ha
planificado**: quién habla con ese MCP (el agente de la app, o el servicio del i3),
y si Boxia es alcanzable desde el i3. Cuando le toque el turno a D, se empieza por
mirar Boxia, no por escribir un cliente de Telnyx.

Lo que el agente necesita poder hacer, y nada más:

- **Leer su propio correo**, para sacar un código de verificación o una
  confirmación de un registro que él mismo inició.
- **Leer sus propios SMS**, para lo mismo.
- **Registrarse en un sitio** con esa identidad, cuando el usuario se lo pide.

Lo que **no** necesita y no debe tener: escribir correos, borrarlos, leer nada que
no sea un código o una confirmación, ni tocar ninguna otra cuenta.

**La forma de la herramienta importa más que la plomería.** Una sola, estrecha,
del tipo «dame el código de verificación que acaba de llegar de este sitio»: no un
cliente de correo. Una herramienta que lee el buzón entero puede leer cualquier
cosa que llegue a ese buzón durante años, y ese buzón va a acumular confirmaciones
de pedidos, direcciones de envío y recibos. El alcance `readonly` de Gmail **no**
acota por remitente, así que el filtro tiene que estar en nuestra herramienta.

**Y el vault no se escribe: el CLI ya trae uno.** Medido por el revisor:
`agent-browser auth --password-stdin`. Antes de construir almacén de secretos
propio hay que medir si ese sirve, porque además resuelve de paso la regla de que
nada viaje por `argv`.

⚠️ **Un aviso que no se puede ignorar al elegir dónde guardar los tokens de
Telnyx y de Gmail.** `ConfigCrypto`, en `main`, **deriva su clave AES del bearer
del servicio**, y el bearer del servicio de memoria del i3 es hoy el placeholder
conocido `replace-me-with-a-long-random-string`. Guardar ahí los tokens de la
identidad sería cifrarlos con una clave publicada. O se usa otro sitio, o rotar
ese token deja de ser un pendiente aparcado y se convierte en parte de este
subsistema.

Lo que el constructor decide aquí: dónde vive el servicio de la identidad (mi
recomendación: **aditivo, su propio contenedor y su propio puerto**, como se hizo
con el navegador en `~/Projects/gemma-browser/`, y no dentro del de memoria, que
es el que el usuario dijo que no se toca), y cómo se expone la herramienta.

### C. Ser un navegador de verdad

No es «esconderse»: es que el navegador del i3 deje de ser un recién nacido. El
usuario lo puso en palabras exactas comparándolo con otros agentes: «esto es algo
que no pasa con otros agentes y otros navegadores… me han navegado por todas las
páginas sin ningún problema, sin que salte ninguna verificación de
automatización.» Tiene razón, y la razón es concreta: los agentes que ha visto
conducen **un Chrome real con un perfil real** —el del usuario, con su historial y
sus cookies—, y el suyo conduce **un Chromium headless recién creado en un
contenedor**, sin una sola visita previa. No es que a ellos no les salten las
comprobaciones: es que ellos no parecen nuevos.

Se mide **contra la línea base que ya existe**: cinco búsquedas seguidas en
`amazon.es`, de las que hoy fallan 3, y AutoZone, que hoy devuelve 447 caracteres
de DataDome. **Midiendo entre cada paso**, no aplicándolo todo junto.

El orden, corregido por lo que se midió:

1. **Chrome con ventana** (`AGENT_BROWSER_HEADED=1` sobre el `Xvfb` que ya está en
   la imagen). Medido: eso **solo** ya convierte `HeadlessChrome/156` en
   `Chrome/156`. Va primero.
2. **El idioma correcto** por `AGENT_BROWSER_ARGS`. Hoy pide `en-US` a dominios
   españoles, que es incoherente con todo lo demás.
3. **Perfil persistente y estado que sobrevive** (`AGENT_BROWSER_PROFILE`,
   `AGENT_BROWSER_STATE`), **cifrado y con caducidad** (`AGENT_BROWSER_ENCRYPTION_KEY`,
   `AGENT_BROWSER_STATE_EXPIRE_DAYS`). Esta es la pieza que pesa: cookies,
   historial, sesión. Un navegador que ya se ha usado.
4. **`--input-mode human`**, que el CLI ya trae: entrada con temporización humana
   en vez de clics instantáneos.
5. **Una cuenta propia con antigüedad e historial**, iniciada sesión en ese
   perfil. Vale más que los cuatro anteriores juntos y depende de D. No es
   camuflaje: es ser un cliente.

**Lo que ya no está en la lista, y por qué.** El paso que yo tenía primero —poner
el user-agent a mano con `AGENT_BROWSER_USER_AGENT`— sale: es redundante con el
paso 1 y contraproducente, porque una cabecera a mano se desalinea de las
`Sec-Ch-Ua` que el navegador sigue enviando y eso es peor que no tocar nada.

**Dónde está el límite de este subsistema, y es un límite firme.** Se configura el
navegador para que sea un navegador real: ventana de verdad, perfil con uso,
idioma coherente, entrada humana, cuenta propia. **No se mide ni se neutraliza
señal por señal lo que un sitio usa para detectar automatización, con el fin de
pasar una comprobación concreta.** Eso es evasión de detección y queda fuera, con
cuenta propia o sin ella. Dos consecuencias prácticas:

- **Google queda fuera de alcance, y no hace falta.** Iniciar sesión en Google
  desde un navegador automatizado y buscar en su buscador los dos saltan su
  verificación, y el usuario lo comprobó: «le dije, búscame en Google a través del
  navegador las raquetas. Y Google me bloqueó de nuevo». La respuesta no es pasar
  el muro: el correo se lee por la API de Gmail (subsistema D, sin navegador), y
  **la búsqueda no va por Google** sino por una API de búsqueda o por el buscador
  de la propia tienda, que es donde acaba la compra. El panel se ve en vivo igual.
- **El motor `obscura` con `AGENT_BROWSER_OBSCURA_STEALTH` y el plugin `stealth`
  quedan fuera.** Son herramientas de evasión, y además el revisor midió que
  `obscura` es **incompatible** con el modo con ventana y el perfil persistente,
  que es justo el camino que sí se toma.

Lo que el constructor decide aquí: dónde se monta el volumen del perfil (ningún
compose declara hoy `volumes:` para `browser`, así que hay que añadirlo o el
perfil se pierde en cada reconstrucción), cuánto dura el estado, y el idioma
exacto. **Lo que no decide: dar un paso por bueno sin medirlo** contra la línea
base.

## Restricciones

### Las de seguridad, que son las que no se negocian

Esta sección cambió de tamaño después de la revisión de constructor, que encontró
agujeros reales. **El proyecto convierte un token de solo mirar en un token de
conducir un Chrome con sesiones abiertas.** Eso es un cambio de categoría, y lo de
abajo no es prudencia decorativa: es lo que hace que este proyecto no empeore la
seguridad del sistema.

- **El socket del visor tiene que comprobar el `Origin`.** Un WebSocket **no**
  respeta CORS, así que hoy cualquier página web que el usuario visite podría
  abrir el socket del relé y, en cuanto exista el control remoto, conducir su
  Chrome logueado, con solo conocer el token. El demonio sí trae esa protección
  —da 403 a un origen no local— y **el relé la perdió al ponerse delante**.
  Recuperarla es requisito de A, no mejora de B.
- **El token no viaja en la URL.** Hoy el visor se autentica con `?token=` en la
  query, que acaba en el historial del navegador, en la caché de navegación atrás
  y en la cabecera `Referer`. Para un token de mirar era discutible; para uno de
  conducir no lo es. Hace falta un ticket de un solo uso que se canjee por una
  cookie o por una cabecera, igual que el token del stream del demonio viaja en la
  cabecera del handshake y nunca en la query.
- **Un solo portador del mando gobierna la ENTRADA, y eso no basta.** Los
  fotogramas van hoy a **todos** los visores conectados. Cuando el usuario teclee
  una contraseña durante un paso de mando, lo que la filtra no es el teclado: es
  **la imagen**. Mientras conduce el humano, los fotogramas van solo al portador.
- **La entrada del visor necesita su propio límite de caudal.** El demonio tiene
  un único socket, y una inundación de eventos de entrada por él hambrea los
  acuses de los fotogramas y congela el panel de todos los visores a la vez.
- **El perfil persistente es una credencial durable.** Se cifra y caduca
  (`AGENT_BROWSER_ENCRYPTION_KEY`, `AGENT_BROWSER_STATE_EXPIRE_DAYS`): un
  directorio con las cookies de sesión de las tiendas del agente es, en la
  práctica, el equivalente a sus contraseñas.
- **El token de conducir no se guarda en claro en el cliente.** Hoy vive en
  `UserDefaults` vía `@AppStorage`, en el Mac y en el iPhone.
- **La restricción de no mirar la página durante el paso de mando se extiende al
  `snapshot` inmediatamente posterior.** Proteger el momento del login y no el
  instante siguiente no protege nada: los datos están en la página de después.
- **Ningún secreto por `argv`.** `ps` lee el argv de cualquier proceso. Es la
  regla que ya gobierna `browser/cli.py`, y el `auth --password-stdin` del propio
  CLI está hecho para eso.
- **La lista de permitidos de subcomandos no se abre para que algo funcione.** Ya
  pasó en este proyecto: durante la medición de la nitidez necesité `scroll`, no
  estaba permitido, y usé `press PageDown`, que sí. Y el revisor midió que **el
  scroll remoto se hace con `input_mouse`/`mouseWheel` por el stream**, así que
  tampoco hace falta abrirlo ahora. En particular **`eval` no se acepta por red**:
  ejecuta JavaScript, y pasarlo por `stdin` no cambia eso. La hoja de ruta del
  usuario mencionaba `eval --stdin` para los secretos; ese camino no es el bueno y
  el vault del CLI lo sustituye.
- **La entrada del visor no se registra, no se narra con su contenido y no entra
  en el contexto del modelo.** Un `input_keyboard` se narra como «el usuario está
  escribiendo», nunca con la tecla. `browser/stream.py` ya hace exactamente esto
  con los `params` del agente —de un `fill` solo sale «rellenando un campo»— y ese
  es el patrón. **Con una consecuencia incómoda que hay que asumir a sabiendas:**
  esa disciplina hace que un uso indebido del token sea indistinguible del uso
  legítimo. Si alguna vez se filtra, no habrá rastro que mirar, así que el plan
  tiene que decir cómo se revoca y se rota, no solo cómo se protege.
- **El camino del navegador local se salta la máquina de estados.** Cuando no hay
  `browserBaseURL` configurada, el agente conduce un navegador en la máquina del
  usuario, con su `--profile Default` al alcance. La máquina de estados tiene que
  gobernar también ese camino, o el proyecto deja una puerta sin cerrar justo al
  lado de la que cierra.

### Técnicas

- **El relé reenvía una lista de permitidos de mensajes del visor, nunca todo.**
  `config` no se reenvía jamás: medido, `{"type":"config","maxFps":0}` a mitad de
  conexión levanta el tope y rompe `pacing=ack`.
- **El acuse del visor no es opcional, y con un proxy en medio hay que reenviar el
  del renderizador.** Los acuses son acumulativos. Está medido lo que pasa si no:
  tres barridos de la medición de la nitidez salieron con un solo fotograma porque
  mi cliente no acusaba.
- **El plazo de inactividad se congela al crear el demonio.** El CLI lo dice:
  «Close the session to change it». Cambiar el compose a 10 minutos **no basta**
  para una sesión ya viva. Y hay que decidir si esos 10 minutos apagan el demonio
  o solo cierran la página: apagarlo puede tirar por la borda un login que el
  usuario acabó de hacer a mano, que es lo más caro de perder en todo el sistema.
- **El presupuesto de caudal del panel es 400 kB/s** y hoy se cumple con 1080×608
  a calidad 45 y 7 fotogramas por segundo (pico medido 383 kB/s). Un humano
  conduciendo quiere más fotogramas que un espectador; si el mando humano pide
  subir el ritmo, **se mide otra vez**, no se sube a ojo.
- **Antes de escribir una pieza, mirar si el CLI ya la trae.** El revisor
  encontró cuatro que yo había dado por hacer desde cero: vault
  (`auth --password-stdin`), puerta de confirmación de acciones
  (`--action-policy` con `confirm`/`deny`), un dashboard con `--allowed-origins`,
  y `--input-mode human`. También `--allowed-domains`, que es una lista de
  permitidos de sitios y suena muy bien para una puerta de compra — con el aviso
  de que el revisor la midió **incompatible** con el modo con ventana y el perfil
  persistente, que es el camino que sí se toma.
- **Ningún compose declara hoy `volumes:` para `browser`.** Sin eso, el perfil
  persistente no persiste a una reconstrucción. La sintaxis corta no rompe el
  lector YAML a mano de `test_compose.py`.
- **Los puertos del i3 son tres y no se pisan:** memoria 8081, voz 8082,
  navegador 8083. El servicio de la identidad necesita el suyo.
- **El stack `aapl-trader` del i3 no se toca.** Nunca un `docker compose down` sin
  nombre de servicio, nunca `docker system prune`, nunca un comando de compose
  desde `~/Projects/gemma-memory`.
- **El compose del navegador se despliega copiando a `~/Projects/gemma-browser/`,**
  no cambiando la rama del checkout del i3, que tiene trabajo sin commitear de
  otra persona. Los valores de nitidez viven en **dos** composes con una prueba
  que exige que coincidan.

### Un conflicto con trabajo de otro, que hay que resolver antes de mezclar

En el árbol de `main` de `gemma-memory` hay trabajo sin commitear de otro agente
(Codex) que incluye `AtoZSessionVerifier` y `ConnectionServicesStore`, y que
**guarda la cookie de sesión del usuario** del portal AtoZ de Amazon junto a su
identificador de empleado. Eso contradice de frente la decisión 1 de este
documento, que dice que ninguna credencial del usuario entra en el sistema.

No lo resuelve este proyecto: es trabajo ajeno y su autor tendrá sus razones.
Pero cuando las dos ramas se reconcilien, **alguien tiene que decidir cuál de las
dos reglas gana**, y conviene que sea una decisión y no un merge.

## Decisiones mías, no suyas

Marcadas porque el usuario no las eligió y debería poder discutirlas.

1. **El agente tiene sus propias cuentas, nunca las del usuario.** La identidad
   propia —el Gmail y el teléfono— es decisión suya. Lo que decido yo es la
   consecuencia: **ninguna credencial del usuario entra en este sistema, en ningún
   momento, ni siquiera de paso.** Cuando un sitio exige una cuenta, el agente usa
   la suya. Si alguna vez hiciera falta una cuenta del usuario, el camino es el
   paso de mando —entra él a mano y el perfil se queda con la cookie—, no
   guardarle una contraseña.

   **La consecuencia, y hay que decirla en voz alta:** un navegador logueado con
   un método de pago guardado es un navegador que puede comprar de un clic. La
   identidad propia reduce mucho el daño posible —no hay contraseñas del usuario,
   y sus cuentas no se tocan— pero no reduce el de una compra que él no pidió, en
   cuanto haya una tarjeta en ese perfil. **La puerta de compra con topes pasa de
   ser un punto siguiente de la hoja de ruta a ser una dependencia.** Mi
   recomendación: construir A, B y D sin guardar ningún medio de pago, y meter la
   puerta de compra antes de guardar el primero. La decisión de orden es suya.
2. **No se construye solucionador de captchas**, ni siquiera para los sitios donde
   sí hay un puzle. Es la pieza que existe para saltarse un control de acceso. Lo
   que se construye es el paso de mando, que resuelve el mismo problema del
   usuario sin ser eso.
3. **Cuando un sitio tiene API, el navegador es la herramienta equivocada.** Vale
   para ChatGPT y Claude, que el usuario nombró entre los bloqueados, y vale
   sobre todo para Google: su correo se lee por la API de Gmail y la búsqueda no
   va por su buscador. El usuario lo comprobó por las malas en los dos frentes —
   «Google me dijo que el navegador no lo podía autorizar» al intentar la sesión,
   y «le dije, búscame en Google a través del navegador las raquetas. Y Google me
   bloqueó de nuevo» al intentar el buscador. Un muro antibot delante de algo que
   tiene puerta documentada es una señal de que el camino era el otro.

4. **No se construye evasión de detección, y eso incluye medirla.** Lo digo aparte
   del no-objetivo de los captchas porque es una línea más amplia y más fácil de
   cruzar sin darse cuenta: configurar el navegador para que sea un navegador real
   —ventana, perfil con uso, idioma coherente, entrada humana, cuenta propia— es
   configuración ordinaria y es el subsistema C. Ir señal por señal viendo qué
   detecta un sitio concreto para neutralizarla y pasar su comprobación, no, con
   cuenta propia o sin ella. Por eso `obscura`, `AGENT_BROWSER_OBSCURA_STEALTH` y
   el plugin `stealth` quedan fuera aunque estén a mano, y por eso Google queda
   fuera de alcance en vez de ser un objetivo.

   Esto le cuesta algo real al usuario y conviene decirlo: hay sitios a los que el
   agente no va a entrar. La apuesta del proyecto es que una identidad propia con
   historial abre bastantes más de los que cierra esta línea, y eso se puede medir
   contra la línea base.
5. **El proxy sale del proyecto.** Él lo incluyó en el alcance; lo retiro porque
   la medición dice que no hace falta: el i3 ya sale por una conexión residencial
   de Spectrum en Louisville, Kentucky, que es la mejor posición posible. Un
   proxy solo la empeoraría.
6. **La máquina de estados del mando vive en el servicio, no en la app.** Él dijo
   que todo el sistema vive en el i3 y esto es la consecuencia directa, pero la
   escribo porque es la decisión que hace que las tres interfaces sean finas.
7. **Un solo portador del mando a la vez.** Él pidió tres clientes y no dijo qué
   pasa si dos agarran a la vez. Lo decido yo: uno conduce, los otros miran y
   pueden reclamarlo.
8. **El plazo del mando humano existe.** Él no lo pidió. Sin él, un turno queda
   colgado para siempre si se distrae, y el agente esperando en silencio es uno de
   los anti-objetivos.
9. **El orden es A, B, D, C**, con E donde lo puso el usuario. A no se puede
   probar sin construirlo. B lo hace usable desde donde él está. **D va antes que
   C** porque la pieza más potente de C —una cuenta propia con antigüedad,
   iniciada sesión en el perfil— depende de D, y porque medir los pasos de C sin
   tener cuenta es medir el caso peor. C cierra, contra la línea base.
10. **La inactividad baja a 10 minutos**, que es el extremo del rango que él dio
   («a los 15 minutos, o mejor, a los 10»). Elijo el suyo más estricto. Con la
   entrada humana reiniciando el temporizador —que está medido— no hay riesgo de
   que se cierre mientras trabaja.

11. **La herramienta del correo es estrecha a propósito.** Una que lea el buzón
    entero puede leer cualquier cosa que llegue a ese buzón, hoy y en dos años.
    Una que diga «dame el código de verificación que acaba de llegar de este
    sitio» hace el trabajo y no más. El usuario no pidió ninguna de las dos
    formas; elijo la estrecha.
12. **El agente no se crea cuentas de correo.** Él dijo «le voy a crear un correo»
    y «le voy a dar un número»: crea él, usa el agente. Dejo escrito ese reparto
    porque es la diferencia entre un asistente con una identidad y una fábrica de
    identidades, y nadie ha pedido la segunda.
## Lo que queda para el constructor

Todo lo que no está arriba, y en particular: los nombres de los mensajes del
protocolo del mando, la forma concreta de publicar el portador a los visores, los
plazos, la tecnología de la página web, el user-agent exacto, dónde se monta el
volumen del perfil, y cómo se dibuja el puntero. El diseño fija el qué y el por
qué; esas son el cómo.

Dos cosas que conviene leer antes de planear nada:

- `docs/superpowers/notes/2026-11-08-nitidez-decisiones.md` — las diecinueve
  decisiones de la rama anterior, con su coste si fueran erróneas. Ahí está por
  qué el acuse no es opcional, por qué el censo de estados necesita el grep ancho
  y por qué un `nonisolated async` no corre fuera del hilo principal.
- `docs/superpowers/notes/2026-11-06-defectos-preexistentes-en-main.md` — lo
  abierto, incluido lo que sí se midió del ciclo de vida del navegador:
  `browser_close` limpia la página de verdad, el proceso sobrevive al cierre
  porque el CLI asegura el navegador en cada invocación, y sin cierre la página se
  queda donde estaba.

---

## Qué cambió después de la revisión de constructor

Este documento se escribió, pasó por un revisor que lo leyó como si fuera a
planearlo solo, y se corrigió. Lo que el revisor midió y que **invalidaba** partes
de la primera versión, para que nadie reconstruya el razonamiento viejo:

| lo que decía | lo que se midió |
|---|---|
| el mensaje `url` es la señal de vuelta | lo es, pero **`stream.decode` lo tira como `other`**: muere en el relé |
| las firmas del muro se leen del cuerpo | el mensaje `tabs` trae el **título**, así que las dos de Cloudflare se detectan **sin leer** la página |
| el relé reenvía los mensajes del visor | `config` **no** puede reenviarse: `maxFps:0` a mitad de conexión levanta el tope y rompe `pacing=ack` |
| `metadata.deviceWidth` da el recorte | da el **viewport** (1280×720, no 1080×608) y además **`metadata` no sale del relé** |
| paso 1 de C: user-agent a mano | redundante y contraproducente: `AGENT_BROWSER_HEADED=1` **solo** ya cambia `HeadlessChrome` por `Chrome` |
| bajar la inactividad en el compose | **no basta**: el plazo se congela al crear el demonio |
| el proxy, al final del alcance | innecesario: el i3 sale por **residencial de Spectrum en Louisville** |
| AutoZone puede ser inalcanzable por geografía | lo es alcanzable; el 403 es DataDome, no geografía |
| hay que escribir vault, puerta y cliente web | el CLI **ya trae** `auth --password-stdin`, `--action-policy`, dashboard con `--allowed-origins` e `--input-mode human` |

Y las contradicciones internas que señaló, todas resueltas en el cuerpo: las
firmas contra la restricción de no mirar la página (se resuelve con `tabs`); «ni
una credencial del usuario, ni de paso» contra el login a mano (se resuelve con
la identidad propia, que lo hace innecesario); el token único contra «un portador
y el otro reclama»; «a las interfaces solo les falta mandar entrada» contra el
panel por turno (les falta existir entre turnos); el modo con ventana contra el
cierre por inactividad (queda anotado como conflicto a medir, no resuelto); el
proxy apareciendo en tres sitios a la vez; y los «cuatro subsistemas» que eran
cinco.

**Lo que no se resolvió y queda en manos del plan:** si el modo con ventana es de
verdad incompatible con el cierre a los 10 minutos, y si esos 10 minutos apagan el
demonio o solo cierran la página. Las dos piden medición, no decisión.

El informe completo del revisor está en `.builder-check-mando.md`, junto a este
fichero y fuera de git.
