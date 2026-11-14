# El navegador visible, la búsqueda sin navegador, y el vídeo del turno

**Fecha:** 2026-11-08
**Estado:** diseño aprobado por el usuario, pendiente de plan de implementación
**Rama anterior:** `feat/panel-streaming-navegador`, mergeada el 2026-11-08
(`personal_agent` `661462f`, `gemma-memory` `39efbe0`). Este diseño parte de ahí
y arregla lo que esa rama dejó a medias o rompió.
**Decisiones de esa rama:** `docs/superpowers/notes/2026-11-08-panel-streaming-decisiones.md`

---

## Intención y por qué

El panel de streaming funciona: el navegador vive en el i3 y la app pinta su
pantalla. Pero la primera vez que el usuario lo usó de verdad —buscar unas
raquetas de ping pong en Amazon— falló en casi todas las dimensiones que
importan, y falló de formas que no son bugs sueltos sino un modelo mental
equivocado sobre para qué sirve ver el navegador.

Lo que pasó, en sus palabras y en tres mensajes seguidos:

1. «entra en Amazon y busca un par de raquetas de tenis» → el agente entró,
   buscó, dio las mejor valoradas y **cerró el navegador**. «Ni siquiera pude
   ver nada prácticamente. No me hizo ninguna pregunta mientras el navegador
   estaba abierto.»
2. «entra y buscara una prospin azul» → el agente usó `web_search` (texto), no
   el navegador, y no encontró nada. «Aunque debería haber entrado con el
   navegador para yo ver la raqueta.»
3. «enséñamelo» → abrió el navegador y contestó: «el texto de la página no
   indica el color de las PRO-SPIN, así que no puedo confirmarte cuál es azul».

El tercer mensaje es el diagnóstico de todo. El agente no ve la página. Recibe
un volcado de **texto**. El usuario le pidió algo **azul** —un dato que vive en
los píxeles— y el agente pudo darle precios exactos (59,99 €, 32,99 €) y
estrellas exactas (4,7) porque eso está escrito, y no pudo darle el color.

El propósito de este trabajo es que el navegador sirva para lo que el usuario lo
quiere: **mirar cosas antes de comprarlas, con el agente mirándolas contigo.**

### El contexto que ordena todas las decisiones

El usuario dijo esto explícitamente durante el diseño, y condiciona dónde va
cada pieza:

> «recuerda que esto quiero moverlo a un servidor completo y que sea nada más
> conectarle una interfaz. O sea, que yo quiero correrlo también en el
> navegador. Y que sea una voz, no un chat. No va a tener una interfaz de chat,
> a menos que yo la ponga explícitamente. Será todo por voz al final de este
> proyecto. Y chat solo por el teléfono cuando yo no puedo usar la voz.»

De aquí se deriva, y no es negociable: **el panel no es una cosa de SwiftUI.**
Es un flujo que el i3 sirve y que cualquier cliente con pantalla dibuja. Todo lo
que decida, guarde o cuente el tiempo va en el i3. La app solo pinta. En modo
voz no hay panel porque no hay pantalla, y el vídeo se graba igual para
revisarlo luego desde donde haya una.

---

## Los tres modos

Esta es la pieza central del diseño y viene directamente de cómo el usuario
describe su propio uso. No son tres funciones: son tres intenciones distintas
que hoy el agente confunde entre sí.

### 1. Buscar — sin navegador visible, sin vídeo, sin panel

«búscame en internet información acerca de los mercados en Estados Unidos.»

El usuario fue tajante:

> «la gente puede usar el browser como si fuera por terminal de comandos,
> usando algo así como playwright pero con agent browser. Sin hacer este
> screencast, sin abrir un navegador, etc. para búsquedas normales como eso de
> los mercados. ¿Cómo funciona un web search en cualquier agente de
> codificación como el Claude Code o Codex?»

Es decir: el navegador es la **implementación** de la búsqueda, no su interfaz.
El usuario no ve nada. Recibe la respuesta. Exactamente como una herramienta de
búsqueda en un agente de programación.

### 2. Mirar — un fotograma fijo o un dato, y se cierra

«éntrate a tal página y mira a ver qué hay.»

> «Este me va a devolver solo screenshot de lo que hay o una respuesta si es en
> texto.»

El agente abre, mira, responde y cierra. La respuesta es **un fotograma fijo**
cuando lo que importa es verlo, o texto cuando lo que importa es el dato. Queda
el fijo en la conversación y el vídeo del turno por si el usuario quiere
repasar.

El fotograma fijo como respuesta **no existe hoy**: hoy solo hay panel en vivo
que se congela y suelta la imagen.

### 3. Conducir — la sesión sobrevive al turno

«enséñame esa raqueta en Amazon.»

> «este va a coger y va a mostrarme la página. Y va a estar al tanto de que yo
> le escriba otra cosa. Si lo que yo le escribo después es como, por ejemplo,
> ok, compra esa misma. Entonces, este va a ir a hacer la compra. Y hasta que no
> termine, no va a cerrar.»

El panel se queda en vivo entre mensajes. La conversación sigue siendo sobre esa
página. El agente puede preguntar —«¿te importa el color, o vamos por la mejor
valorada?»— **con la página delante**, que es lo que faltó en el episodio 1.

### Quién decide el modo, y la red que va debajo

Lo decide el modelo, leyendo la intención del mensaje. Eso acierta la mayoría de
las veces y **no puede ser la única defensa**: si el modelo se equivoca o se
olvida de cerrar, queda un Chromium con las cookies de Amazon del usuario vivo
en el i3 esperando un mensaje que no llega.

Decisión del usuario:

> «si no hay ninguna interacción de la gente con el navegador, o mío con el
> agente para que interactúe con el navegador, entonces se cierra a los 15
> minutos automáticamente, o mejor, a los 10 minutos.»

**10 minutos de inactividad → cierre automático.** Y, decisión mía marcada como
tal: **ese plazo lo cuenta el i3, no la app.** Si lo contara el teléfono,
bastaría que iOS matara la app en segundo plano, o que el usuario se quedara sin
cobertura, para que nadie cerrara nada. El i3 es el único que siempre está
encendido para contarlo.

---

## Objetivos

1. **El agente ve la página.** Recibe, en el mismo turno, el texto del snapshot
   **y** la imagen. Decisión del usuario: «obviamente tiene que ver la imagen.
   Los modelos que uso todos aceptan imágenes.»
2. **La imagen que el usuario ve es nítida.** Hoy la fuente es 640×360 a calidad
   JPEG 20. «La resolución es como la de 600 algo. O sea, se ve bien borroso.»
3. **El panel sobrevive al turno** cuando la intención es conducir, y el agente
   puede preguntar con la página delante.
4. **El turno queda grabado en vídeo**, con sus acciones fechadas, y el panel
   plegado es la portada: se toca y se reproduce. «me gustaría ver las acciones
   que tomó y en qué momento las tomó durante ese video.»
5. **Las filas de herramienta se plegan.** Hoy vuelcan el resultado entero en
   pantalla.
6. **La búsqueda normal pasa por `agent-browser`**, sin panel y sin vídeo, y el
   cliente viejo de DuckDuckGo desaparece.
7. **La búsqueda corre en una sesión propia, aislada de la que el panel
   transmite.** Corrección de una primera versión de este documento, que
   afirmaba que `read_webpage` conduce hoy la sesión `gemma`: **no lo hace.**
   Pasa `sessioned: false` (`ReadWebpageTool.swift:59`), así que su argv no
   lleva `--session` y el CLI la atiende en su sesión por omisión, que el relé
   no transmite. El riesgo es real pero es del modo buscar, que todavía no
   existe: si se implementa reutilizando la `AgentBrowserService` compartida,
   heredará `defaultSessionName = "gemma"` y entonces sí moverá la página que
   el usuario está mirando.

## No objetivos

- **Controlar el navegador desde el teléfono.** El usuario lo preguntó y
  después lo descartó: «está bien que no lo pueda controlar desde mi teléfono.»
  El relé se queda **de una sola dirección**, que es lo que lo mantiene seguro:
  un evento de entrada es «pulsa en x,y», y eso puede pulsar «Comprar ahora».
  El canal de vuelta, si alguna vez se abre, es un diseño propio y tiene que
  resolverse junto a la puerta de compra, no antes.
- **Audio.** Ni el stream en vivo ni `record` llevan sonido, así que
  «reprodúceme un vídeo de YouTube» daría imagen muda. El usuario lo aparcó:
  «lo del audio sí lo podemos resolver luego creando esa pieza nosotros mismos,
  pero no es algo que me interese hacer ahora.»
- **Pantalla completa para consumir contenido** (YouTube, TikTok). Depende del
  audio y del control remoto, que son los dos no-objetivos de arriba.
- Rotar el `MEMORY_BEARER_TOKEN` del i3. Sigue pendiente y sigue necesitando que
  el usuario lo pida.

## Anti-objetivos

Cosas que harían fracasar este trabajo aunque funcionara técnicamente:

- **Que el vídeo se acumule.** Un turno de compra graba la página con la
  dirección del usuario, su nombre y su método de pago a medio rellenar. Si esos
  ficheros sobreviven al día, este trabajo ha empeorado la privacidad del
  sistema en vez de mejorar su utilidad.
- **Que la búsqueda normal abra un panel.** Convertiría cada pregunta en un
  espectáculo y levantaría un Chromium que el usuario no pidió ver.
- **Que una búsqueda o un `read_webpage` muevan la página que el usuario está
  mirando.** Es el defecto nuevo que este diseño cierra; reintroducirlo por otra
  vía es el peor resultado posible.
- **Que el panel sea de la app.** Si la lógica de modos, plazos o grabación vive
  en Swift, el día que el usuario abra esto desde el navegador habrá que
  escribirlo otra vez. Ese día está en su plan, no es hipotético.
- **Que subir la resolución rompa el panel en datos móviles.** El tope de 10
  fotogramas por segundo se fijó cuando el único cliente era un Mac por cable.

---

## Restricciones

- **Swift 6, concurrencia estricta.** Y la lección de la rama anterior, que
  costó caro: un `nonisolated async` **hereda** la isolation de quien llama, así
  que no corre fuera del hilo principal. Para eso está `@concurrent`, y el
  `assert(!Thread.isMainThread)` de `BrowserPanelView` se queda donde está.
- **Un solo objetivo multiplataforma** (`iphoneos iphonesimulator macosx`). Todo
  lo nuevo funciona en iOS y en macOS, sin verjas `#if os(macOS)` salvo para
  algo que de verdad solo exista en una plataforma.
- **El filtro de `browser/stream.py` no se toca.** Solo deja pasar
  `params["url"]`, y solo bajo `navigate`. Es lo que impide que un selector o el
  valor de un formulario salgan del i3. Cualquier cosa que necesite más datos en
  el cable se diseña aparte, con su prueba de seguridad.
- **Ningún secreto por `argv`.** `ps` lee el argv de cualquier proceso. Lo que
  haya que pasar al CLI va por stdin, como ya hace `cli.run`.
- **Lista de permitidos, no de prohibidos.** Si este trabajo necesita un
  subcomando o un flag nuevo del CLI, se añade a `FLAGS_BY_SUBCOMMAND` y a
  `ALLOWED_SECOND_WORD` con su aridad y citando la fuente (`--help` del CLI y el
  sitio de llamada real). Nunca se abre el filtro «por si acaso».
- **El servicio corre con `--no-access-log`** y con la fábrica de registros que
  tacha `token=`. No se añade logging que pueda escribir una URL con query
  string.
- **El i3 no se toca sin nombrar el servicio.** Nunca un `docker compose down`
  sin servicio, nunca un `docker system prune`, nunca un comando de compose
  desde `~/Projects/gemma-memory`. El servicio del navegador vive en
  `~/Projects/gemma-browser/`.
- **Nunca `git add -A` en `personal_agent`**: barre las instantáneas de
  `graphify-out/`, y una de ellas pasó del límite de 100 MB de GitHub.

---

## Lo que está medido

Todo esto se verificó durante el diseño, con el comando al lado. No son
suposiciones y no hay que volver a comprobarlas.

| Hecho | Cómo se midió |
|---|---|
| La fuente del panel es **640×360, calidad JPEG 20** | `AGENT_BROWSER_STREAM_QUALITY/MAX_WIDTH/MAX_HEIGHT` en el compose del i3 |
| `web_search` pega a `https://api.duckduckgo.com/?q=…&format=json` | `WebSearchService.swift:66` |
| Esa API es *Instant Answer*, no un buscador: «Cuba» y «python programming language» devuelven abstract; **«raqueta ping pong Pro Spin mejores» devuelve 0 siempre** | tres llamadas reales a la API |
| Ninguna herramienta devuelve una imagen al modelo: `snapshot` da texto con `@eN`, `get` da `text\|html\|value\|title\|url\|count` | `ALLOWED_SECOND_WORD` en `cli.py` y los ficheros de herramientas |
| La fila de herramienta pega el resultado **entero**, sin plegar ni límite de líneas | `HarnessModel.swift:701` (`"🔧 \(n) ✓ \(r)"`) y `AgentChatView.swift:589` |
| Las nueve herramientas comparten **una** `AgentBrowserService` con `defaultSessionName = "gemma"` | `HarnessModel.registerBrowserTools` |
| …pero `read_webpage` pasa `sessioned: false`, así que **NO** añade `--session` y no toca la sesión que el panel transmite | `ReadWebpageTool.swift:59`, `AgentBrowserService.swift:58` |
| El bucle de turno concatena el resultado de la herramienta al prompt **como texto**; `ChatMessage.content` es un `String` y no hay bloques de contenido en ningún runtime | `Agent.swift:197,301`, `ModelRuntime.swift:7`, `ServerRuntime.swift:78-111` |
| El proveedor por omisión es `.onDevice` (GGUF) en iOS y `.cerebras`/`gpt-oss-120b` en macOS: **ninguno de los dos acepta imágenes** | `ModelProvider.swift:13,15,49`, `HarnessModel.swift:101` |
| No hay perfil persistente: `--profile`, `--state` y `--restore` están rechazados a propósito, así que **cada cierre tira las cookies** | `cli.py:44-62` |
| El relé no sabe de turnos ni de conversaciones: no hay campo de conversación ni en `/v1/browser/invoke` ni en la URL del stream | `app.py:154,197` |
| `freeze()` suelta el jpeg a propósito, y hay una prueba que lo exige | `BrowserPanelStateTests.swift:34` («§6.2(g): un panel congelado no deja imagen en el historial») |
| El CLI tiene **grabación de vídeo nativa**: `record start <path.webm\|.mp4> [url] [--fps] [--cursor] [--contact-sheet]`, captura a 30 fps | `agent-browser record --help` |
| **`ffmpeg` NO está en la imagen**, y `record` lo necesita | `agent-browser doctor` → `warn ffmpeg not found on PATH` |
| El i3 tiene **176,2 GB libres** en el directorio de estado | `agent-browser doctor` |
| El stream del CLI **ya acepta eventos de entrada de los clientes** | `agent-browser stream --help`: «Input events dispatch immediately, independent of frame delivery» |
| Hay ratón por coordenadas: `mouse move/down/up/wheel` | `agent-browser mouse --help` |
| **No hay audio** en el stream ni en `record` | `stream --help` y `record --help` |
| El prompt ya dice el reparto correcto (`web_search` encuentra, `read_webpage` lee, `browser_*` interactúa) | `Agent.swift:157` |
| El demonio tiene su propio plazo de inactividad de **30 min** | `AGENT_BROWSER_IDLE_TIMEOUT_MS=1800000` en el compose |

---

## Las decisiones, y de quién son

### Del usuario

| Decisión | Sus palabras |
|---|---|
| El agente ve la imagen | «obviamente tiene que ver la imagen. Los modelos que uso todos aceptan imágenes.» |
| Y además texto y ficha | «eso lo debería hacer con imagen y sin imagen para tener un mejor contexto» |
| Las filas de herramienta no llevan resumen interpretado | «no pongas ningún resumen, pon 32 objetos o lo que sea» |
| …salvo cuando la herramienta devuelve un dato concreto | «a menos que sea un tool que tenga una respuesta concreta» |
| 10 minutos de inactividad | «se cierra a los 15 minutos automáticamente, o mejor, a los 10 minutos» |
| El vídeo dura lo que la conversación, y como mucho un día | «solo durante esa conversación quiero verlo. Si yo cierro la app o algo así, se borra ese video» |
| Para qué es el vídeo | «quiero revisar si, por ejemplo, la gente hizo bien algo» |
| La búsqueda normal es headless | «sin hacer este screencast, sin abrir un navegador» |
| `web_search` actual se va | «elimina ese web search… porque ese web search debe ser con Agent Browser» |
| Sin control remoto | «está bien que no lo pueda controlar desde mi teléfono» |
| Audio, luego | «no es algo que me interese hacer ahora» |

### Mías, marcadas como tales

Ninguna de estas la aprobó el usuario; son decisiones de diseño que tomo yo para
que el constructor no tenga que adivinar, y son revisables.

1. **El plazo de 10 minutos lo cuenta el i3.** Razón arriba. Lo más probable es
   que baste con `AGENT_BROWSER_IDLE_TIMEOUT_MS=600000`, pero **hay que
   verificar qué cuenta el CLI como actividad**: si solo cuenta invocaciones del
   CLI y no la presencia de un visor, entonces un panel abierto que el usuario
   está mirando se cerraría a los 10 minutos aunque esté mirándolo, que es
   justo lo contrario de lo que se pide. Si resulta así, el plazo lo cuenta
   `relay.py` con su propio vigilante y el del demonio se deja alto.
2. **La imagen para el modelo va por su propio camino, no por el del panel.**
   El panel tiene un presupuesto de datos móviles y 10 fotogramas por segundo;
   el modelo necesita **una** imagen con detalle. Son necesidades distintas, así
   que la herramienta de visión pide su propia captura con su propia calidad, en
   vez de reutilizar el último fotograma del relé.
3. **El buscador de debajo es la página de resultados HTML de DuckDuckGo**
   (`https://duckduckgo.com/html/?q=…`), leída con `agent-browser read`. Razón:
   es la más ligera, no necesita clave de API ni cuota, y la leemos **como
   página**, que es exactamente lo que el usuario pidió. Riesgo asumido: si
   cambian el maquetado, la búsqueda se rompe; el arreglo es cambiar una URL y
   un parseo, no la arquitectura. Si resulta frágil en la práctica, la
   alternativa es Bing o un SearXNG en el i3, y el cambio no toca la app porque
   la decisión vive en el servicio.
4. **La búsqueda corre en una sesión propia, `gemma-search`.** Aislada de
   `gemma`, que es la que el panel transmite. `read_webpage` ya está aislada por
   otra vía (`sessioned: false`) y puede quedarse como está o pasar a declarar
   `gemma-search` explícitamente, que es más legible; lo segundo es preferible
   porque «no manda `--session`» es una propiedad fácil de perder en un
   refactor, mientras que un nombre escrito se ve.
5. **El vídeo se guarda en el i3, no en el teléfono.** Se deriva del contexto
   del usuario: si viviera en el teléfono, un cliente de navegador no podría
   reproducirlo nunca. Va atado al identificador de conversación, servido solo
   con el bearer, y borrado al cerrar la conversación o a las 24 horas, lo que
   pase antes.
6. **La línea de tiempo de acciones sale de la narración que el relé ya
   compone**, fechada. No hace falta un registro nuevo: el relé ya sabe
   traducir una acción a una frase en español («haciendo clic», «rellenando un
   campo») y ya tiene el reloj.
7. **Nada de esto se graba en el modo buscar.** Una búsqueda headless no
   produce vídeo ni fotograma: no hay nada que mirar y guardarlo solo
   acumularía ficheros.
8. **`web_search` se borra al final, no al principio.** Si se quita antes de que
   el camino nuevo funcione, el agente se queda sin ninguna búsqueda y el
   usuario lo nota en el mensaje siguiente.

---

## Lo que queda al constructor

Esto es lo que el plan tiene que decidir y detallar. No está decidido aquí a
propósito, porque depende de medir.

- **A qué resolución y calidad subir el panel.** Hay que medir el peso por
  fotograma y lo que aguanta un iPhone con datos móviles, y ajustar también el
  tope de fotogramas por segundo, que se fijó para un Mac por cable. Un punto de
  partida razonable es la mitad del ancho físico del panel en el teléfono, con
  calidad alrededor de 45-55, pero el número sale de la medición, no de aquí.
- **Cómo llega la imagen al modelo.** Qué herramienta, con qué nombre, qué
  devuelve, y cómo se presupuesta (cuántas miradas por turno antes de que el
  coste importe). Tiene que respetar el filtro de `stream.py` y no pasar nada
  por argv.
- **Cómo se expresa la intención de conducir.** Si el modelo lo declara con un
  parámetro de herramienta, si se infiere de qué herramientas usó, o si hay una
  herramienta explícita de «quédate abierto». Lo que no vale es que la app lo
  adivine leyendo el texto del usuario.
- **Dónde y cómo se guarda el vídeo**, con qué nombre de fichero, qué endpoint
  lo sirve, y quién lo borra. El borrado tiene que funcionar también si la app
  muere sin avisar: el i3 no puede depender de que alguien le diga «se cerró la
  conversación».
- **Qué cuenta como «dato concreto»** en cada una de las nueve herramientas,
  para la línea plegada. Son nueve casos; ocho probablemente no devuelven
  ninguno.
- **Cómo se pinta el fotograma fijo** del modo mirar en la conversación, y si
  comparte código con el panel o es otra fila.
- **Si el modo conducir necesita que el usuario pueda cerrar a mano.** No se
  pidió, pero un botón de cerrar es barato y es la única vía que no depende de
  que el modelo acierte.

---

## Riesgos

1. **El plazo de inactividad del CLI puede no contar lo que hace falta.** Es el
   primer riesgo a despejar, porque si cuenta mal, el panel se cierra en la cara
   del usuario mientras lo mira. Se mide antes de construir nada encima.
2. **La grabación escribe la pantalla del usuario en disco**, y eso revierte una
   propiedad deliberada del sistema anterior. El borrado no es una
   característica: es parte de la definición de «hecho».
3. **Subir la resolución puede romper el panel en datos móviles.** Hay que
   medirlo en el teléfono, no en el Mac.
4. **La página de resultados de DuckDuckGo puede cambiar.** Riesgo aceptado con
   los ojos abiertos; la mitigación es que la decisión vive en el servicio y se
   cambia sin tocar la app.
5. **La visión cuesta tokens.** Si el agente mira en cada paso del bucle, un
   turno de compra se vuelve caro. El plan tiene que poner un presupuesto.
6. **El modelo decidiendo cuándo quedarse abierto es nuevo**, y es la primera
   vez que una decisión del modelo deja un recurso vivo en el i3. El plazo del
   i3 es la red, y tiene que existir antes de que la intención funcione.

---

## Revisión del diseño: las ocho preguntas y sus respuestas (2026-11-08)

Un revisor leyó este documento como si tuviera que planificarlo sin poder
preguntar, y devolvió ocho preguntas. Cuatro las contestó el usuario; cuatro las
decido yo. Todas las respuestas están ya incorporadas arriba o aquí.

### Las que contestó el usuario

**1. ¿Qué modelo conduce el navegador, si ninguno de los dos por omisión acepta
imágenes?**

> «no te compliques mucho porque yo sólo voy a usar modelo que vean imagen. Lo
> de gpt-oss 120B es algo legacy que voy a retirar después.»

La herramienta de visión existe **solo cuando el proveedor seleccionado acepta
imágenes**. Con un proveedor que no ve, el agente lo dice y sigue con texto; no
se cambia de proveedor a espaldas del usuario y no se refactorizan todos los
runtimes ahora. Los bloques de contenido se añaden únicamente en el runtime que
los necesita.

El usuario preguntó además si Gemma 4 en local puede recibir imágenes, siendo
multimodal. Medido, y la respuesta tiene dos mitades:

- **En el Mac, el modelo sí puede.** El servidor que la app lanza es
  `mlx_vlm.server` (`ServerManager.swift:19`, `ServerProcess.swift:3`), un
  servidor de visión-lenguaje. Lo que lo impide está entero en el cliente:
  `ChatMessage.content` es un `String` y `ServerRuntime` lo envía como texto
  plano (`:78-111`). Habilitarlo es un cambio de cliente, no un límite del
  modelo, y es el camino más corto a tener visión con el modelo local.
- **En el iPhone está lejos.** `.onDevice` es GGUF por llama.cpp dentro de la
  app; la visión necesita el proyector `mmproj` y plomería en `LlamaContext`.
  `ModelLoadOptions.supportsImage` existe (`ModelRuntime.swift:55`) y **nadie lo
  lee**: es un resto de la época de LiteRT-LM. Queda anotado como trabajo
  posterior, no entra aquí.

**2. ¿Puede quedar una imagen del navegador en reposo, contra §6.2(g)?**

Decisión del usuario: **sí, pero muere con la conversación.** El fotograma fijo
del modo mirar y la portada del panel plegado se quedan visibles mientras la
conversación viva y se borran con ella, igual que el vídeo. **Nunca** se suben al
servicio de memoria ni a ningún historial persistente. La prueba
`BrowserPanelStateTests.swift:34` se reescribe para decir la regla nueva, no se
borra: `freeze()` sigue soltando el jpeg del panel **en vivo**, y lo que
sobrevive es un fotograma distinto, elegido a propósito y con caducidad.

**3. ¿Debe sobrevivir el login del sitio a los cierres?**

> «las cookies se borran en cada sesión, pero el navegador no se cierra para
> preguntarme, porque si él abre el navegador me muestra la escalera, se queda
> ahí esperando respuesta, y yo le digo OK cómprala; es la misma sesión, solo que
> el modelo estaba esperando instrucciones.»

**No hay perfil persistente**, y la contradicción que el revisor vio no existe:
el plazo de 10 minutos es para el **abandono**, no para el ir y venir normal.
Esperar la respuesta del usuario **es** la sesión siguiendo abierta, con sus
cookies intactas, así que «compra esa misma» funciona porque nada se cerró. El
login solo se pierde si el usuario tarda más de diez minutos en contestar, y ese
caso es el que debe perderlo.

Consecuencia que el plan tiene que decir en voz alta: una compra que empieza
después de un cierre por inactividad empieza **sin sesión**, y el agente debe
decirlo en vez de fingir que sigue dentro. `--profile`, `--state` y `--restore`
siguen rechazados; abrir esa puerta se decide junto a la puerta de compra.

**4. ¿Entra el despliegue, y dónde vive el compose?**

Decisión del usuario: **el compose del navegador se versiona como fichero propio
en el repositorio y se sigue desplegando aparte.** Deja de haber un fichero
suelto sin historial —hoy la nitidez, el plazo y la grabación vivirían fuera de
todo control de versiones— y no se toca el compose que levanta memoria y voz, que
es el que conviene no mover mientras el checkout del i3 tenga trabajo sin
commitear encima (ver `snapshot/main-sin-commitear-2026-11-08` en `gemma-memory`).

### Las que decido yo

Marcadas como mías, con el por qué. Revisables.

**9. El servidor es dueño de los modos, los plazos, la grabación y la identidad
de la sesión. La app dibuja.** El revisor preguntó si bastaba con un cambio
mínimo en Swift (que el coordinador se quede y reciba un «no congeles»). No
basta, y no por purismo: elegir el mínimo **es** el anti-objetivo que este
documento nombra, porque el día que el usuario abra esto desde el navegador
habría que escribirlo otra vez. `BrowserPanelCoordinator` pasa a ser lo que su
nombre promete —el que pinta el panel del turno— y deja de decidir cuándo se
congela.

**10. La grabación la arranca y la para el servidor, colgada de una noción de
conversación y turno que hoy no existe.** El revisor tiene razón en que no hay
campo de conversación ni en `/v1/browser/invoke` ni en la URL del stream. Hay que
añadirlo: es contrato de cable nuevo, y es la pieza que hace que **el modo voz
también grabe**, que es donde «quiero revisar si lo hizo bien» más importa,
porque ahí el usuario no vio nada en directo. Colgar la grabación de la presencia
de un visor sería lo fácil y dejaría el modo voz sin vídeo para siempre.

**11. El modo mirar sí abre panel en vivo mientras trabaja.** Se cierra al
terminar y deja el fijo y el vídeo. Razón: el usuario pidió ver, y ver en directo
cuesta lo mismo que no verlo una vez que el relé ya está ahí. Lo que distingue
mirar de conducir no es si se ve, es **si la sesión sobrevive al turno**.

**12. Una fila de panel por turno, aunque la sesión siga viva.** El panel en vivo
pertenece a la fila del turno más nuevo; las anteriores se plegan y quedan como
portada de su propio vídeo. Razón: el resumen y el vídeo son **por turno**, y una
sola fila larga borraría esa frontera — que es justo lo que
`relay.begin_viewer_session()` existe para mantener (`relay.py:195`). Varias filas
apuntando a una sesión viva es más fiel a lo que pasó.

### Corrección de este documento

El revisor encontró un error mío: la primera versión afirmaba que `read_webpage`
conduce hoy la sesión que el panel transmite. **No lo hace** — pasa
`sessioned: false`. Ya está corregido arriba, en el objetivo 7, en la tabla de
hechos y en la decisión 4. El riesgo es real pero pertenece al modo buscar, que
todavía no existe.
