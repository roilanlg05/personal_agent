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
2. **Que el navegador deje de anunciarse como robot**, hasta donde se pueda sin
   burlar un control de acceso: Chrome con ventana, perfil persistente, cookies
   que sobrevivan entre turnos y entre días, idioma y cabeceras coherentes.
3. **Tres clientes, un solo sistema.** Teléfono, página web y computadora hacen lo
   mismo porque el sistema está en el i3 y los tres son vistas.
4. **Que el navegador se cierre solo a los 10 minutos sin interacción**, y que la
   interacción humana cuente como interacción.
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
- **Un proxy residencial de pago.** Entra en el alcance que el usuario eligió
  («proxy si hace falta»), pero se deja para el final y solo si lo demás no
  basta: cuesta dinero recurrente y mete un tercero en el camino de sus compras.
  Decidirlo con la medición delante, no antes.

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

## Los cuatro subsistemas

El proyecto son cuatro subsistemas. Cada uno es un plan aparte y **el orden
importa**: sin A no hay nada que probar, D habilita la pieza más potente de C, y
C se mide contra una línea base que ya existe. Orden: **A, B, D, C**.

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
  detecta un muro; el usuario puede tomarlo en cualquier momento sin pedir
  permiso, porque es su navegador.
- **Un solo portador a la vez.** Si el usuario tiene abiertos el teléfono y la
  web, conduce uno. Quien lo tiene, lo tiene; el otro lo ve y puede reclamarlo.
- **La detección del muro es una lista de firmas**, medidas y escritas: el título
  `Just a moment...`, el título que empieza por `Attention Required!`, un cuerpo
  que empieza por `var dd={` con `cid` y `hsh`, el cuerpo de 357 caracteres de
  Amazon. Más dos señales genéricas que no son firmas de nadie: una herramienta
  del navegador que devolvió un estado de fallo, y una acción que no cambió la
  página.
- **El mando vuelve al agente cuando llega un `url` nuevo que no es un muro.** La
  señal la da el demonio y no hay que inventarla. Con tres salvaguardas: una
  página de muro que navega a sí misma no cuenta (es el «error de que el captcha
  no se resolvió» del usuario); hace falta que el muro deje de estar presente, no
  solo que la URL cambie; y el usuario puede devolver el mando a mano.
- **Y un plazo.** Si el usuario toma el mando y se va, el agente no puede quedarse
  esperando para siempre: pasado un tiempo, el turno termina y se lo dice.

Lo que el constructor decide aquí: los nombres de los mensajes, cómo se
representa el portador, los plazos concretos, y si la detección del muro vive en
el mismo módulo puro que ya filtra los mensajes del demonio (`browser/stream.py`,
que es puro a propósito: sin red, sin ficheros, sin reloj) o en uno nuevo al
lado. Lo segundo es probablemente mejor: ese módulo es puro y la detección
también puede serlo.

### B. Las tres interfaces

Las tres son vistas finas sobre A. Ninguna lleva lógica de estado.

- **El teléfono y la computadora ya tienen panel** (`BrowserPanelCoordinator`,
  `BrowserRelayClient`, la vista del chat). Lo que les falta es mandar entrada y
  enseñar de quién es el turno.
- **La página web es nueva**, la sirve el i3, y es la que menos tiene hoy. Ojo con
  un detalle medido: el demonio da **403 en el upgrade** a un cliente de navegador
  cuyo origen no sea local. No nos afecta —el cliente web habla con nuestro relé,
  no con el demonio— pero sí obliga a que el relé sirva la página y el socket del
  mismo origen, o a declarar explícitamente qué orígenes acepta.
- **Mapear un toque a una coordenada de la página es trabajo de verdad, no una
  resta.** El fotograma viene recortado a 1080×608 mientras la página mantiene su
  viewport: la ayuda del CLI lo dice, `MAX_WIDTH` «caps the frame, does not resize
  the page». Así que el fotograma es una imagen **escalada** del viewport, y el
  cliente tiene que deshacer dos escalas: la del recorte del servidor (que viene
  en `metadata.deviceWidth`/`deviceHeight`) y la de su propia pantalla. Sacarlo de
  los metadatos de cada fotograma, nunca de constantes.
- **El puntero del ratón**, que el usuario pidió aparte: el CLI **no lo ofrece en
  el stream** (su `--cursor` es solo de `record`, y el screencast viene de CDP, que
  no dibuja cursor). Con esto construido sale casi gratis por el otro lado: el
  cliente ya sabe dónde está el puntero porque es él quien lo mueve, y las
  acciones del agente ya viajan al panel. Dibujarlo es cosa del cliente.

Lo que el constructor decide aquí: qué eventos manda cada cliente (un teléfono
manda `input_touch`, una computadora `input_mouse`), cómo se ve de quién es el
turno, y con qué se hace la página web. Para la web, lo que ya usa el proyecto
antes que algo nuevo.

### D. La identidad del agente: su correo y su teléfono

Nueva, y es la que el usuario acaba de pedir. Él crea la identidad a mano —una
cuenta de Gmail y un número de teléfono— y el agente la usa. **El reparto es
exactamente ese: él crea, el agente usa.** Darle a un agente la capacidad de
crearse cuentas de correo sería otra cosa y no está pedido.

Lo que el agente necesita poder hacer, y nada más:

- **Leer su propio correo**, para sacar un código de verificación o un enlace de
  confirmación de un registro.
- **Leer sus propios SMS**, para lo mismo cuando el sitio manda el código al
  teléfono.
- **Registrarse en un sitio** con esa identidad, cuando el usuario se lo pide.

Lo que **no** necesita y no debe tener: escribir correos, borrarlos, leer nada que
no sea un código o una confirmación de un registro que él mismo inició, ni tocar
ninguna otra cuenta.

Lo que el constructor decide aquí: por dónde se lee el correo (la API de Gmail o
IMAP; la API es más acotable y permite pedir solo lectura), de dónde salen los
SMS (un proveedor con API, o el teléfono reenviándolos), y cómo se expone al
agente —mi inclinación es **una sola herramienta estrecha** del tipo «dame el
código de verificación que acaba de llegar de este sitio», no un cliente de
correo, porque una herramienta que lee el buzón entero es una herramienta que
puede leer cualquier cosa que llegue a ese buzón.

**Esto convierte el manejo de secretos en una dependencia, no en un punto
siguiente de la hoja de ruta.** Hasta ahora el único secreto del navegador era su
token de acceso, que vive en un `.env` del i3. La identidad del agente trae
credenciales de verdad —el acceso a un buzón y a un teléfono— y esas no se guardan
a ojo. El punto 4 de la hoja de ruta del usuario (vault, `--password-stdin`,
`eval --stdin`) entra aquí.

### C. La huella

Se mide **contra la línea base que ya existe**: cinco búsquedas seguidas en
`amazon.es`, de las que hoy fallan 3. Y contra AutoZone, que hoy devuelve 447
caracteres de DataDome.

En orden de menos a más invasivo, y **midiendo entre cada paso** en vez de
aplicarlo todo junto y no saber qué funcionó:

1. **Cabeceras coherentes.** `AGENT_BROWSER_USER_AGENT` con un Chrome normal, y el
   idioma a español por `AGENT_BROWSER_ARGS`. Es lo más barato y lo que hoy se
   está gritando.
2. **Chrome con ventana** (`--headed` sobre el `Xvfb` que ya está en la imagen) en
   vez de headless.
3. **Perfil persistente y estado que sobrevive** (`AGENT_BROWSER_PROFILE`,
   `AGENT_BROWSER_STATE`). Esto es lo que de verdad convierte al navegador en «un
   cliente que vuelve»: cookies, historial y sesión. Y es lo que hace útil el paso
   de mando, porque el inicio de sesión que el usuario haga a mano **se queda**.
4. **El plugin `stealth`**, si hace falta. Hay que instalarlo en la imagen.
5. **Un proxy**, solo si lo demás no basta. Ver No objetivos.

Lo que el constructor decide aquí: dónde vive el perfil (un volumen, no la imagen,
o se pierde en cada reconstrucción), cuánto dura el estado, y qué user-agent
exacto. **Lo que no decide: dar un paso por bueno sin medirlo.** Cada paso se
compara con la línea base, y lo medido se escribe, como se hizo con la nitidez.

**Y una pieza de C que vale más que los cinco pasos juntos:** una cuenta propia,
con antigüedad e historial, iniciada sesión en el perfil persistente. Eso no es
camuflaje, es ser un cliente. Depende del subsistema D y del punto 1 de
Decisiones mías, y es la razón por la que D no es un añadido sino parte del
camino principal.

## Restricciones

**De seguridad, y son las que no se negocian:**

- **Ningún secreto por `argv`.** `ps` lee el argv de cualquier proceso. El token
  del navegador viaja por `env_file` y las cosas sensibles por `stdin`. Es la
  regla que ya gobierna `browser/cli.py` y su lista de permitidos.
- **La lista de permitidos de subcomandos no se abre para que algo funcione.** Ya
  pasó en este proyecto: durante la medición de la nitidez necesité `scroll`, no
  estaba permitido, y usé `press PageDown`, que sí. Mismo criterio aquí. En
  particular `eval` y `--init-script` **no** se aceptan por red: ejecutan
  JavaScript. `AGENT_BROWSER_INIT_SCRIPTS` como variable del contenedor es otra
  cosa —es configuración del servidor, no entrada del cliente— y esa distinción
  hay que conservarla.
- **La entrada del visor no se registra, no se narra con su contenido y no entra
  en el contexto del modelo.** Un `input_keyboard` se narra como «el usuario está
  escribiendo», nunca con la tecla. El módulo `browser/stream.py` ya hace
  exactamente esto con los `params` de las acciones del agente —de un `fill` solo
  sale la frase «rellenando un campo»— y ese es el patrón a copiar.
- **Mientras conduce el humano, el agente no mira la página.** Ni `snapshot`, ni
  `get value`, ni `read`. El usuario va a teclear contraseñas ahí.
- **El token actual del navegador da acceso a conducir.** Eso es un cambio de
  categoría respecto a hoy, y el diseño tiene que decidir si basta con que el paso
  de mando esté acotado o si el control pide su propia credencial. **Mi inclinación
  es que basta**, porque el mando solo se puede tomar sobre un turno vivo y el
  usuario es el único que tiene el token, pero es una decisión que merece estar
  escrita y no asumida.

**Técnicas:**

- **El acuse del visor no es opcional, y con un proxy en medio hay que reenviar el
  del renderizador.** El relé es ese proxy y ya lo hace bien. Está medido lo que
  pasa si no: tres barridos de medición de la nitidez salieron con un solo
  fotograma porque mi cliente no acusaba. Los acuses son acumulativos.
- **El presupuesto de caudal del panel es 400 kB/s** y hoy se cumple con 1080×608
  a calidad 45 y 7 fotogramas por segundo (pico medido 383 kB/s). Un humano
  conduciendo quiere más fotogramas que un espectador. Si el mando humano pide
  subir el ritmo, se mide otra vez; no se sube a ojo.
- **El `stack` de la memoria y el de la voz no se tocan.** Son los puertos 8081 y
  8082 del mismo i3, y el navegador es el 8083.
- **El stack `aapl-trader` del i3 no se toca.** Nunca un `docker compose down` sin
  nombre de servicio, nunca un `docker system prune`, nunca un comando de compose
  desde `~/Projects/gemma-memory`.
- **El compose del navegador se despliega copiando a `~/Projects/gemma-browser/`,**
  no cambiando la rama del checkout del i3, que tiene trabajo sin commitear de
  otra persona. Y los valores de nitidez viven en **dos** composes con una prueba
  que exige que coincidan.

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
3. **Para ChatGPT y Claude, la respuesta no es este proyecto: es su API.** El
   usuario los nombró entre los sitios bloqueados. Conducir su web a través de un
   muro antibot es la herramienta equivocada para algo que tiene puerta de
   entrada documentada. Queda fuera de alcance y señalado.
4. **El proxy va al final y quizá no va.** Él lo incluyó en el alcance; yo lo pongo
   último porque cuesta dinero recurrente y mete un tercero en el camino de sus
   compras. Con la medición delante se decide.
5. **La máquina de estados del mando vive en el servicio, no en la app.** Él dijo
   que todo el sistema vive en el i3 y esto es la consecuencia directa, pero la
   escribo porque es la decisión que hace que las tres interfaces sean finas.
6. **Un solo portador del mando a la vez.** Él pidió tres clientes y no dijo qué
   pasa si dos agarran a la vez. Lo decido yo: uno conduce, los otros miran y
   pueden reclamarlo.
7. **El plazo del mando humano existe.** Él no lo pidió. Sin él, un turno queda
   colgado para siempre si se distrae, y el agente esperando en silencio es uno de
   los anti-objetivos.
8. **El orden de los cuatro subsistemas es A, B, D, C** y cada uno es un plan
   aparte. A es el que no se puede probar sin construirlo. B lo hace usable desde
   los tres sitios. **D va antes que C** porque la pieza más potente de C —una
   cuenta propia con antigüedad, iniciada sesión en el perfil— depende de D, y
   porque medir los cinco pasos de la huella sin tener cuenta es medir el caso
   peor. C cierra, midiendo contra la línea base que ya existe.
10. **La herramienta del correo es estrecha a propósito.** Una que lea el buzón
    entero puede leer cualquier cosa que llegue a ese buzón, hoy y en dos años.
    Una que diga «dame el código de verificación que acaba de llegar de este
    sitio» hace el trabajo y no más. El usuario no pidió ninguna de las dos
    formas; elijo la estrecha.
11. **El agente no se crea cuentas de correo.** Él dijo «le voy a crear un correo»
    y «le voy a dar un número»: crea él, usa el agente. Dejo escrito ese reparto
    porque es la diferencia entre un asistente con una identidad y una fábrica de
    identidades, y nadie ha pedido la segunda.
9. **La inactividad baja a 10 minutos**, que es el extremo del rango que él dio
   («a los 15 minutos, o mejor, a los 10»). Elijo el suyo más estricto. Con la
   entrada humana reiniciando el temporizador —que está medido— no hay riesgo de
   que se cierre mientras trabaja.

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
