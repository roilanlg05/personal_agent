# Medición: por qué el panel se veía «súper lento», y qué lo arregla

**Fecha:** 2026-11-08. **Pedido del usuario, textual:** «estuve viendo el canal de
YouTube de Auron Play a través de mi agente Gem en el teléfono y se veía súper
lento. Necesito que sea fluido, como si estuviera reproduciendo un video de
YouTube.»

## El resultado, primero

El panel iba a 7 fps **porque nosotros lo pusimos a 7**, y el 7 salió de una
premisa que ahora está medida como falsa. El techo real del i3 son **25 fps**, y
llegar a ellos no necesita cambiar el transporte: necesita cambiar dos constantes.

Verificado en vivo, de punta a punta, por Tailscale y a través del relé, con un
vídeo de YouTube reproduciéndose:

| lo que pide el visor | fps que recibe | KB/fotograma | Mbit/s |
|---|---|---|---|
| nada (lo que manda la app) | **24,18** | 46,3 | 9,17 |
| `maxFps=7` | 6,09 | 48,5 | 2,42 |

## La premisa falsa

El comentario que justificaba `DAEMON_MAX_FPS = 7` decía dos cosas:

> «una página de compras se mira, no se anima»

> «pasar de 10 a 7 no quita ningún fotograma de los que el usuario veía de verdad:
> solo acota el pico de una página que se anime sola»

Las dos son falsas para el uso que el usuario le da de verdad. Él mira vídeo de
YouTube por este panel. Un vídeo se anima, llega al tope, y el tope era 7. Los
«7,07 fps» medidos no eran un techo del sistema: eran el tope, entregado con
precisión. El razonamiento era correcto para el caso de uso que yo supuse y
equivocado para el que él tiene.

El presupuesto que gobernaba el 7 era **400 kB/s de enlace móvil**. Ese
presupuesto lo puse yo y el usuario nunca lo pidió. A 25 fps el pico es
25 × 54 715 B = **1,37 MB/s (~11 Mbit/s)**, que lo revienta por 3,4×.

## El techo del i3, medido

Dentro del contenedor, hablando con el demonio igual que el relé
(`ws://127.0.0.1:PORT/?pacing=ack&maxFps=N`), acusando cada fotograma, 10 s por
medida, contra un vídeo de YouTube reproduciéndose:

| tope pedido | fotogramas | fps logrados | KB/fotograma | Mbit/s |
|---|---|---|---|---|
| 7 | 57 | 7,07 | 47,0 | 2,72 |
| 15 | 119 | 14,87 | 49,8 | 6,07 |
| 30 | 202 | **25,18** | 48,2 | 9,95 |
| 60 | 203 | **25,27** | 47,9 | 9,92 |

**25 fps es el techo.** Pedir 30 y pedir 60 entregan lo mismo, así que pedir más
que 25 solo gastaría CPU comparando fotogramas que no existen. Por eso el tope
nuevo es 25 y no 30 ni 60.

**CPU:** 60% de un núcleo a 25 fps (`docker stats`). La máquina es un
**i3-13100, 4 núcleos / 8 hilos, de 2023** — no una caja débil, que es lo que yo
había supuesto antes de mirar `/proc/cpuinfo`.

**La cadena de acuses no es el cuello.** Con un solo fotograma en vuelo
(`pacing=ack`) el techo que impone la red es 1/RTT. RTT Mac→i3 por Tailscale:
`min/avg/max = 3,69 / 6,34 / 10,96 ms` sobre 10 paquetes → ~158 fps. Sobra. En red
móvil con 100 ms de RTT el techo bajaría a 10 fps, y **ahí sí** la cadena de acuses
sería el límite; es lo que habría que medir si el teléfono fuera por datos.

## Lo que se cambió

`browser/relay.py`: `DAEMON_MAX_FPS` y `DEFAULT_VIEWER_MAX_FPS`, de 7 a **25**. Se
suben los dos porque el visor no puede recibir más de lo que el relé le pide al
demonio: con el demonio en 7, subir solo el del visor no cambiaría nada.

**La nitidez no se toca:** 1080×608 q45 se quedan como estaban (ver
`2026-11-08-medicion-nitidez-panel.md`). Lo que se gastó fue caudal, no nitidez.

**La palanca para datos contados sigue existiendo y se probó:** un visor puede
pedir menos por el parámetro `maxFps` de la URL del socket, y se respeta hacia
abajo (medido: pedir 7 da 6,09 fps). Un cliente en red móvil debería pedirlo
explícitamente. Hoy la app de macOS no manda nada y por tanto coge los 25.

**Lo que hace soportable el coste:** el demonio emite **por cambio**. Una página
quieta no manda fotogramas y no cuesta nada; los 11 Mbit/s solo corren mientras
algo se mueve en la pantalla. Es un pico, no un caudal permanente.

### Pruebas

`test_el_caudal_del_panel_cabe_en_un_enlace_movil` afirmaba
`DEFAULT_VIEWER_MAX_FPS * 54_715 <= 400_000`, que es exactamente lo que clavaba el
tope en 7. Se sustituye por `test_el_tope_de_fps_no_pasa_del_techo_medido_del_i3`,
que defiende lo que sí hay que defender: que nadie pida más de los 25 que el i3
puede producir. Y se añade `test_un_movil_puede_pedir_menos_caudal_que_el_tope`,
porque subir el tope sin dejar salida al móvil sería un cambio a medias.

`test_un_maxfps_mayor_que_el_tope_se_recorta_al_tope` tenía el valor **10**
escrito a mano. Con el tope en 7, 10 estaba por encima y la prueba probaba algo;
con el tope en 25, 10 está por debajo y la prueba **habría seguido verde sin
probar nada**. Ahora calcula el valor del propio tope (`tope + 1`).

144 pruebas verdes. Imagen reconstruida en el i3 (`docker compose up -d --build
browser`), `healthz` 200, respaldos en `relay.py.antes-de-fluidez` y
`test_app.py.antes-de-fluidez`.

## Dos hallazgos que no son los fps

### 1. El vídeo de YouTube no arranca solo

Autoplay está bloqueado en este navegador. Medido: con la página del vídeo cargada
y sin tocar nada, el demonio emite **2 fotogramas en 10 segundos, de tamaño
idéntico** (51,1 KB mínimo = máximo) con cualquier tope pedido — 7, 15, 30 y 60
dan los mismos 2. La página está congelada, no el stream.

Arranca con `agent-browser press k` (atajo de YouTube). `click video` falla con
«Element 'video' is outside the viewport».

**Consecuencia:** parte de lo que el usuario describió como «súper lento» puede
haber sido esto y no los fps. Un vídeo parado se ve más lento que un vídeo a 7
fps. **El agente tiene que saber arrancar la reproducción**, y hoy no lo sabe: no
hay nada en el prompt ni en las herramientas que lo diga. Pendiente, con dueño sin
asignar.

### 2. `open` dijo éxito y la página no cambió

Durante la primera medición: lancé
`agent-browser --session gemma open "https://www.youtube.com/watch?v=dQw4w9WgXcQ"`,
devolvió **`rc=0`**, y al consultar `get url` después la página seguía siendo
`https://www.youtube.com/@AuronPlay/videos` — la que el usuario tenía cargada **dos
horas antes**. Repetido el `open` por separado, funcionó y devolvió el título
correcto.

Esto es **exactamente** lo que el usuario había reportado y yo descarté dos veces:

> «creo que las pestañas del navegador no se están cerrando. Porque pidiéndole
> diferentes cosas y en diferentes momentos me abre la ventana que tenía cargada
> anteriormente. Por ejemplo, le pedí que me buscara en YouTube el canal de Auron
> Play y me abrió TikTok en el mismo lugar donde estaba antes, como si la pestaña
> nunca se hubiese cerrado.»

Primero diagnostiqué mal (sobre el fotograma de apertura), él me corrigió, y
entonces retiré **el diagnóstico y el fenómeno juntos**, tratándolo como un
malentendido. El fenómeno es real y lo he visto yo. Lo que está medido y lo que no:

- **Medido:** `open` puede devolver `rc=0` sin navegar. El CLI no tiene subcomando
  `tabs` (`Unknown command: tabs`), así que no es una pestaña nueva: es la misma
  página que no se movió.
- **No medido:** por qué. Hipótesis sin comprobar: una carrera entre el `open` y
  algo que renavega (¿otro cliente?, ¿un `--restore` de estado guardado?), o un
  `open` que se da por bueno antes de que la navegación cuaje. **No se escribe
  ningún arreglo hasta tener la causa.**

Esto necesita su propia investigación. Es un defecto del camino de navegación, no
de la fluidez.

## Método, para repetirlo

El guion de medición dentro del contenedor está en el scratchpad de la sesión
(`medir_fps.py`) y el de punta a punta (`medir_e2e.py`) también. Los dos acusan
cada fotograma: **sin mandar `{"type":"ack","seq":N}` la medida sale `n=1`**, que es
el error que ya se cometió en la rama de la nitidez. El reloj arranca con el primer
fotograma recibido, no al conectar, para no contar el tiempo de arranque del
screencast.

El token del servicio entra **por el entorno, nunca por argv**: `ps` lee argv.
