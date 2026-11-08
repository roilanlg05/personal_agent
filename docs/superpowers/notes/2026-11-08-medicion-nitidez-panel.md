# La nitidez del panel, medida

Fecha de la medición: **2026-11-08**. La hizo el controlador contra el servicio
del navegador que corre en el i3 (`~/Projects/gemma-browser/`, contenedor
`gemma-browser-browser-1`), porque los implementadores no tocan docker ni el i3.

Esta nota existe porque los tres valores de nitidez del panel estaban puestos a
ojo. El usuario se quejó textualmente: «la resolución es como la de 600 algo. O
sea, se ve bien borroso». El tope de 10 fotogramas por segundo se había fijado
cuando el único cliente era un Mac por cable; ahora hay un iPhone con datos
móviles, y nadie había medido qué caudal pide el panel.

## La página sobre la que se midió, y por qué no es Amazon

El caso real del usuario es una página de resultados de Amazon. **El i3 no la
alcanza.** Sondeadas seis tiendas desde el Chromium del contenedor, con el largo
del texto del `body` como prueba:

| sitio | caracteres del body | qué sirve |
|---|---|---|
| `amazon.es/s?k=…` | 357 | «Lo sentimos. Se ha producido un error al intentar procesar tu solicitud» |
| `pccomponentes.com/buscar` | 270 | «Performing security verification» |
| `decathlon.es/search` | 694 | «Sorry, you have been blocked» |
| `ebay.es/sch` | 155 | «SORRY. Something went wrong on our end» |
| `idealo.es` | 256 | «Sorry! Something has gone wrong» |
| **`es.aliexpress.com/w/…`** | **12 038** | **la página de resultados de verdad, 171 etiquetas `<img>`** |

Se midió por tanto sobre
`https://es.aliexpress.com/w/wholesale-raqueta-ping-pong.html`: una rejilla real
de fotografías de producto con precios y texto encima, que es exactamente la
forma del caso del usuario y es caro para un JPEG por bordes y detalle.

**Esto es un hallazgo aparte y más grave que la nitidez**, y queda anotado aquí
porque es donde se descubrió: cinco de las seis tiendas sondeadas le sirven su
página antibots al navegador del i3. Explica por qué el agente «entró en Amazon,
buscó y dio las mejores valoradas» sin que el usuario viera nada útil: estaba
leyendo una página de error de 357 caracteres. Es un problema de huella del
navegador (user-agent, flags de automatización, IP), no de nitidez, y pertenece a
los planes B y D del spec `2026-11-08-navegador-visible-y-busqueda-design.md`.

## El acuse del visor no es opcional

Los tres primeros barridos dieron **un solo fotograma** por combinación, y estuve
a punto de anotar que el demonio «manda un fotograma y se calla». Era falso, y la
causa es una propiedad del protocolo que conviene no volver a olvidar:

El relé habla con el demonio con `pacing=ack` y el demonio mantiene **como máximo
un fotograma en vuelo**. El acuse del visor es el **único** momento en que el relé
acusa al demonio (`browser/relay.py:436` y `:692`, «el único sitio del relé que
acusa al demonio»). Un cliente del stream que lea el socket y no mande
`{"type":"ack","seq":N}` por cada fotograma deja la cadena parada tras el primero
y ve una foto congelada. La app sí acusa; mi guion de medición no lo hacía.

Cualquier cliente futuro del stream —otra app, un visor web, una prueba— tiene
que acusar.

## La medición

25 fotogramas por combinación, con la página movida sin parar (se alternan
PageDown y PageUp cada 0,45 s, para no quedarse clavado al final del documento,
donde PageDown ya no cambia nada y el demonio, que emite por cambio, deja de
mandar). `press` está en la lista de permitidos del servicio; `scroll` no, y no
se abrió la lista para poder medir.

Los «fps logrados» son los fotogramas por segundo realmente conseguidos entre el
primero y el último, con el tope del visor en 10. No llegan a 10 porque el
demonio emite por cambio y con un solo fotograma en vuelo: el techo práctico de
esta cadena, con la página cambiando entera sin parar, está entre 5 y 7.

| anchura × altura | calidad | media (B) | mediana (B) | máximo (B) | fps logrados | caudal real (media × fps) |
|---|---|---|---|---|---|---|
| 640 × 360 | 20 | 13 689 | 14 124 | 14 597 | 5,11 | 70 kB/s |
| 900 × 506 | 45 | 38 737 | 37 840 | 42 536 | 5,67 | 220 kB/s |
| 1080 × 608 | 45 | 51 594 | 52 559 | 54 715 | 6,38 | **329 kB/s** |
| 1080 × 608 | 60 | 55 566 | 57 076 | 59 703 | 6,93 | 385 kB/s |

## Los valores elegidos, y el cálculo que los elige

**Presupuesto: 400 kB/s**, el tope que fijó el plan para que el panel no se quede
atrás en cuanto el usuario sale de la wifi.

El caudal real medido cabe en el presupuesto en las cuatro combinaciones, pero
**el caudal real no es la cifra con la que hay que decidir**. Los 5–7 fps
logrados salen de una página que cambia por scroll; una página que se anima sola
—un carrusel, un vídeo— empuja al demonio hasta su tope. La cifra que decide es
el **pico**: tope de fotogramas × fotograma más grande.

A 10 fps, con el máximo medido:

| anchura × altura | calidad | pico a 10 fps | ¿cabe en 400 kB/s? |
|---|---|---|---|
| 640 × 360 | 20 | 146 kB/s | sí |
| 900 × 506 | 45 | 425 kB/s | **no** |
| 1080 × 608 | 45 | 547 kB/s | **no** |
| 1080 × 608 | 60 | 597 kB/s | **no** |

A 10 fotogramas por segundo **no cabe ninguna mejora de nitidez**. El plan ya
había previsto este resultado y dicho qué hacer con él: «la respuesta correcta es
bajar los fotogramas, no renunciar a la nitidez: una página de compras se mira,
no se anima». Eso es lo que se hace.

**Valores elegidos:**

| clave | valor | de dónde sale |
|---|---|---|
| `AGENT_BROWSER_STREAM_MAX_WIDTH` | **1080** | 2,85× los píxeles de 640×360; es la queja del usuario, que era de resolución |
| `AGENT_BROWSER_STREAM_MAX_HEIGHT` | **608** | la misma proporción 16:9 |
| `AGENT_BROWSER_STREAM_QUALITY` | **45** | q60 cuesta un 9 % más de bytes por una mejora que no se ve en una rejilla de productos; el salto grande de calidad es 20 → 45 |
| `DAEMON_MAX_FPS` | **7** | 400 000 ÷ 54 715 (el fotograma más grande medido) = 7,31 → 7 |
| `DEFAULT_VIEWER_MAX_FPS` | **7** | el mismo |

**El caudal que sale de esos valores:**

- pico (7 × 54 715 máximo) = **383 kB/s**, por debajo del tope de 400
- típico (7 × 51 594 media) = **361 kB/s**
- el caudal medido de verdad en esa combinación fue 329 kB/s, y bajar el tope de
  10 a 7 no lo toca, porque los 6,38 fps logrados ya estaban por debajo de 7:
  **la nitidez sube 2,85× en píxeles sin que el usuario pierda un solo fotograma
  de los que de verdad veía.** El tope de 7 solo recorta el pico de una página
  que se anime sola, que es justo el caso que había que acotar.

Se bajan **los dos** topes, no solo el del visor. El salto demonio → relé es
localhost dentro del contenedor y es gratis, así que bastaría estrangular al
visor; pero dejar el demonio a 10 haría que el i3 codificara en JPEG tres
fotogramas de cada diez para tirarlos en el relé. Es CPU quemada para nadie.

## Cómo repetir esta medición

El guion vive en el scratchpad de la sesión, no en el repositorio: es una
herramienta de medida de un día, no parte del servicio. Lo que hay que conservar
es el método, que está arriba. Lo esencial, por si hay que reescribirlo:

1. Levantar el servicio con un `override` de compose que fije las tres claves.
2. Esperar a que el contenedor esté `healthy`.
3. Dentro del contenedor: `open` de la página, esperar a que pinte, y **abortar
   la medición si el `body` baja de 5 000 caracteres** — es el cortafuegos que
   detecta una página de bloqueo y evita medir sobre una página de error, que es
   lo que invalidó los dos primeros barridos.
4. Conectar al stream como visor, **acusar cada fotograma**, y mover la página en
   paralelo mientras se leen 25 fotogramas.
5. El token del servicio viaja por variable de entorno, **nunca por argv**: `ps`
   lee el argv de cualquier proceso.
6. Al final, quitar el override y volver a levantar el compose normal.
