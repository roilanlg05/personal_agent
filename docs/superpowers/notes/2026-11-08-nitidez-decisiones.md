# Las decisiones de la rama de la nitidez y las filas plegadas

Rama `feat/nitidez-y-filas-plegadas`, 2026-11-08. Dos repositorios:
`personal_agent` (la app macOS/iOS) y `gemma-memory` (el servicio del navegador).

Plan: `docs/superpowers/plans/2026-11-08-nitidez-y-filas-plegadas.md`.
Spec del que sale: `docs/superpowers/specs/2026-11-08-navegador-visible-y-busqueda-design.md`.
Medición que justifica los valores: `docs/superpowers/notes/2026-11-08-medicion-nitidez-panel.md`.

Este fichero es el registro de ejecución tal y como se escribió, con las
decisiones que tomé por el camino, su motivo y lo que costarían si fueran
erróneas. Se guarda porque el espacio de trabajo del plan está en `.gitignore` y
se borra al cerrar la rama, y porque cuatro de estas decisiones desobedecen al
plan a propósito. Leerlo antes de replantear cualquier cosa del panel, de la
nitidez o de la fila de herramienta.

**Lo más importante que dejó esta rama, en tres líneas:**

1. Un censo hecho con un grep demasiado estrecho produjo el defecto más grave de
   la rama. El grep honesto para los estados de las herramientas está en el
   Ruling 12 y repetido en un comentario del código.
2. El acuse del visor del stream no es opcional: sin él, el panel es una foto
   congelada. Tres barridos de medición se tiraron por esto.
3. Cualquier cliente del stream podía pedir caudal ilimitado (`maxFps=0`). Lo
   cerró un implementador al que solo se le había pedido verificar otra cosa.

---

# SDD ledger — plan: docs/superpowers/plans/2026-11-08-nitidez-y-filas-plegadas.md

## Entorno

- **Dos worktrees**, uno por repositorio, los dos en la rama `feat/nitidez-y-filas-plegadas`:
  - `personal_agent/.worktrees/nitidez` (desde `b5334d9`) — la app y la nota de la medición.
  - `gemma-memory/.worktrees/nitidez` (desde `39efbe0`) — el servicio del navegador.
- Spec: `docs/superpowers/specs/2026-11-08-navegador-visible-y-busqueda-design.md` (legible, es la autoridad).
- Este plan es el subsistema **A** del spec. B (búsqueda), C (visión) y D (modos + vídeo) son planes aparte y dependen de este.
- Los implementadores **no ejecutan docker ni tocan el i3**. Las mediciones y el despliegue son del controlador.

## Escaneo previo del plan

| Qué se comprobó | Resultado |
|---|---|
| T1 → T2, `docker-compose.browser.yml` | T1 lo crea, T2 cambia sus tres claves de stream. Las pruebas de T1 **no** aseveran los valores de stream, así que T2 no las rompe. **Sin conflicto.** |
| T1 → T2, `browser/test_compose.py` | T1 lo crea con los auxiliares `_config()` y `_env_del_servicio()`; T2 añade una prueba que los usa. El bloque *Produces* de T1 **no los nombraba** → el implementador de T2 no sabría que existen. **Hallazgo 3.** |
| T1 ↔ T3 | Ningún fichero ni interfaz en común. **Sin conflicto.** |
| T2 ↔ T3 | Ningún fichero en común (T2: servicio + nota; T3: app). **Sin conflicto.** |
| T1 consigo mismo | Las pruebas parsean YAML, pero **PyYAML no está en `browser/requirements.txt` ni importable** (`ModuleNotFoundError: No module named 'yaml'`). La tarea no puede correr sus propias pruebas. **Hallazgo 1, bloqueante.** |
| T2 consigo mismo | Toca `gemma-memory` **y** crea una nota en `personal_agent`, pero su único comando de commit solo añade ficheros de `gemma-memory`: la nota nunca se commitearía. **Hallazgo 2.** |
| T2 consigo mismo (la prueba del caudal) | Fija un producto con un número medido escrito a mano. Es un candado de regresión sobre los fotogramas por segundo, que es su función, pero un revisor puede leerlo como tautología. **Hallazgo 5, anotado, no se cambia.** |
| T3 consigo mismo | La tabla de las nueve herramientas incluye `read_webpage`, pero ninguna prueba lo cubre: las pruebas cubren snapshot, get, open, las cinco acciones y web_search. **Hallazgo 4.** |
| T3 consigo mismo (resto) | Firmas coherentes: `summarize`, `detail`, `detailLimit` y los cuatro casos de `ToolRowSummary` se usan igual en las pruebas y en los pasos. **Sin conflicto.** |

## Rulings del escaneo previo

- **Ruling 1 (PyYAML no entra; las pruebas parsean el compose a mano).** El Hallazgo 1 bloquea la Tarea 1 tal y como está escrita. Rechazo las dos salidas fáciles: añadir PyYAML a `browser/requirements.txt` metería una dependencia **de pruebas** en la imagen de producción —la que conduce un Chromium real—, y dejar la verificación solo en mi `docker compose config` perdería el candado de regresión, que es justo para lo que existe la prueba. Las pruebas parsean el fichero con un lector de líneas propio dentro de `test_compose.py`: el compose es un fichero que nosotros escribimos y cuyo formato controlamos, y para un candado sobre un fichero fijo un parseo de líneas es más robusto que una dependencia nueva. **Coste si me equivoco:** si alguien reformatea el `environment:` de lista a mapa, la prueba se pone roja por el motivo equivocado; se pone roja, que es lo que queremos que pase cuando alguien toca esto.
- **Ruling 2 (la Tarea 2 commitea en los dos repositorios, por separado).** El Hallazgo 2 es un defecto de mi plan: la nota de la medición vive en `personal_agent` y el comando de commit solo nombraba ficheros de `gemma-memory`. La tarea hace **dos** commits, uno por repositorio, y el de la nota va primero para que el commit del servicio pueda citarla. **Coste si me equivoco:** ninguno; la alternativa era que la medición se quedara sin commitear y el número del compose sin procedencia, que es exactamente lo que el plan dice evitar.
- **Ruling 3 (los auxiliares de prueba entran en el contrato de la Tarea 1).** `_config() -> dict` y `_env_del_servicio(nombre: str) -> dict[str, str]` se añaden al bloque *Produces* de la Tarea 1, porque la Tarea 2 construye sobre ellos y un implementador que no sabe que existen escribirá otros con otro nombre. **Coste si me equivoco:** ninguno.
- **Ruling 4 (`read_webpage` también lleva prueba).** Está en la tabla de veredictos de la Tarea 3, y una entrada de esa tabla es una decisión; sin prueba, nada impide que el implementador la ignore. **Coste si me equivoco:** una prueba más de una línea.
- **Ruling 5 (la prueba del caudal se queda como está).** Fija un producto con un número medido. No es tautología: su trabajo es ponerse roja el día que alguien suba los fotogramas por segundo sin volver a medir el peso del fotograma. Queda anotado aquí para que el revisor lo lea como candado y no como defecto. **Coste si me equivoco:** un revisor gasta una ronda discutiéndolo.

## Ejecución

- **Ruling 6 (el encargo se completa con el Apéndice A).** `scripts/task-brief` extrae solo el texto de la tarea, así que el encargo de la Tarea 1 salió **sin** el Apéndice A — justo el fichero que su Step 3 manda copiar literalmente. Lo añadí al final del `task-1-brief.md` en vez de mandar al implementador a leer el plan entero, que es lo que la skill prohíbe. **Coste si me equivoco:** ninguno; la alternativa era un implementador bloqueado en el Step 3 o, peor, inventándose el compose.
- Task 1: BASE `39efbe0` (gemma-memory). Implementador despachado (sonnet): tarea mecánica con el contenido exacto en el encargo. Step 6 (`docker compose config` + comparación con el i3) reservado para mí por la regla de no-docker.
- Task 1: implementador DONE, commit `2ae8d11`. 121 → 125 pruebas, las 4 nuevas vistas fallar primero.
- Task 1: **Step 6 hecho por mí** (es el paso del controlador). `docker compose -f docker-compose.browser.yml config` → exit 0, token resuelto no vacío, `BROWSER_STREAM_SESSION: gemma`. Y el fichero nuevo es **idéntico al que corre en el i3** en todo lo que no es comentario (`diff` ignorando comentarios y líneas vacías). El `.env` de prueba se creó con modo 600 y se borró al terminar.
- Task 1: revisión (sonnet) → **encargo ✅ / calidad necesita arreglos**. 0 Critical, 2 Important, 3 Minor.
- **Ruling 7 (el hueco de la prueba del `.env.example` es del encargo y se arregla igual).** El revisor señaló que `test_el_env_example_nombra_el_token_sin_traer_un_valor` pasa con `BROWSER_BEARER_TOKEN=abc123`, con `changeme` y con la línea comentada, y tiene razón: el encargo **dictaba esas aserciones literales**, así que el implementador hizo lo correcto escribiéndolas. El requisito real era «ningún valor de token» y mi encargo lo expresó mal. Se arregla contra la letra del encargo porque el spec —la autoridad— pide que el servicio falle cerrado, y una prueba que admite un token escrito en el ejemplo invita justo a lo contrario. **Coste si me equivoco:** ninguno; la prueba queda más estricta de lo que el encargo pedía, y eso no rompe nada.
- **Ruling 8 (el Minor de la colisión de despliegue entra en la ronda, no se aparca).** El revisor lo clasificó Minor; yo lo subo, porque toca una restricción declarada del plan («el repositorio y la producción no divergen») y porque es una trampa silenciosa: el compose nuevo vive en la raíz de `gemma-memory`, junto a otro `docker-compose.yml` que **ya** define un servicio `browser` en el puerto 8083, y `env_file: .env` se resuelve junto al compose —la raíz—, donde `.env` es el del servicio de memoria, no el del navegador. Falla cerrado (401), así que no es agujero; es una trampa para el yo del futuro, que es exactamente la clase de cosa que este plan existe para quitar. El arreglo son tres líneas de comentario en el encabezado. **Coste si me equivoco:** tres líneas de comentario de más.
- Task 1: minor (aparcado): `"8083:8083" in svc["ports"]` tolera puertos extra. Hipotético —nada en este plan ni en B/C/D añade puertos— y una igualdad estricta sobre la lista entera rompería el día que alguien añada uno por un motivo legítimo.
- Task 1: minor (anotado para B/C/D): el lector de YAML hecho a mano no soporta anclas, multilínea ni mapas anidados dentro de listas. El plan D añade un volumen para los vídeos; si lo declara como mapa, habrá que ampliarlo. Va como puntero al encargo de la Tarea 2 y al plan D.
- Task 1: fix round 1/5 despachada al mismo implementador (contexto intacto): Important 1 y 2 más dos menores (el aviso de comentarios en línea en el docstring, y el encabezado de la colisión de despliegue).
- **Ruling 9 (la medición de la Tarea 2 corre sobre el i3 con un override temporal, no editando el worktree).** El Step 1 de la Tarea 2 es mío y necesita cuatro arranques del servicio con configuraciones distintas. Editar el compose del worktree para medir habría tocado ficheros que el revisor estaba leyendo en ese momento, y habría dejado el árbol sucio a mitad de revisión. En su lugar, un `override-medicion.yml` dentro de `~/Projects/gemma-browser/` del i3, que se borra al terminar y restaura el compose normal. **Coste si me equivoco:** si el barrido se interrumpe a mitad, el i3 se queda con el override puesto; el guión lo borra en su último paso y lo compruebo al leer la medición.
- Error mío en el primer intento de medición: copié el guión al `/tmp` del **host** y lo invoqué desde `docker compose exec`, que corre dentro del contenedor y tiene su propio `/tmp`. Cuatro combinaciones fallaron con `No such file or directory` sin medir nada. Corregido pasando el guión por stdin (`python - < fichero`). El barrido restauró el compose normal al terminar, así que el i3 no quedó en un estado raro.

## Tarea 1 — re-revisión acotada (ronda 1)
Revisor `acadb60f1bd8ccf38` (haiku) sobre `2ae8d11..e7abb56`:
- Important 1 (parser que no verifica consumo total): ADDRESSED. Mutante → 1 failed.
- Important 2 (`.env.example` podría llevar valor): ADDRESSED. Verificado con `od`.
- Minor 1 (docstring del contrato del lector YAML): ADDRESSED.
- Minor 2 (encabezado del compose): ADDRESSED. YAML válido.
- Aparcado (`"8083:8083" in svc["ports"]` tolera puertos extra): NO tocado, correcto.
Ninguna rotura nueva. Ningún hallazgo abierto.
Nota del revisor: corrió solo `test_compose.py` (5 passed), no la suite `browser/` de 126
que cita el implementador. Esa suite la corrí yo tras el arreglo: 126 passed.

Task 1: complete — commits `2ae8d11` (implementación) y `e7abb56` (arreglos).

## Tarea 2 — Step 1 (medición, controlador)

**Ruling 10 — la página de la medición no puede ser Amazon, y no por elección mía.**
El plan manda medir sobre «una página real y densa (una página de resultados de
Amazon, que es el caso del usuario)». Medido en el i3 el 2026-11-08, el Chromium
del contenedor NO alcanza ninguna tienda: body del `open` en caracteres —
amazon.es 357 («Lo sentimos, se ha producido un error»), pccomponentes.com 270
(«Performing security verification»), decathlon.es 694 («you have been
blocked»), ebay.es 155 («SORRY»). es.wikipedia.org sí: 38 907.
Decido medir sobre `commons.wikimedia.org/wiki/Category:Table_tennis`, una
rejilla de miniaturas con texto: el análogo estructural más cercano que el i3
alcanza, y caro para un JPEG por bordes y detalle.
*Coste si me equivoco:* los bytes medios de una rejilla de Commons podrían
quedar por debajo de los de una rejilla de Amazon, y los valores elegidos
resultarían algo optimistas respecto al presupuesto de 400 kB/s. Mitigación: el
guion mide también el máximo, no solo la media, y la nota dejará escrito contra
qué página se midió para que se pueda repetir el día que Amazon sea alcanzable.

**Ruling 11 — el primer barrido era inválido y lo descarto.**
Sus dos datos (640×360 q20 → 5 781 B; 900×506 q45 → 45 611 B) se midieron sobre
la página de error de Amazon de 357 caracteres, con `n=1` fotograma. No son una
línea base de nada. Causa de `n=1`: el demonio solo emite fotograma cuando la
página CAMBIA, y una página de error de una pantalla no cambia al pulsar
PageDown. Arreglo: un motor en paralelo que alterna PageDown/PageUp cada 0,45 s
mientras el bucle lee el socket, más un cortafuegos que aborta la medición si el
body baja de 5 000 caracteres (detecta la página de bloqueo).
*Coste si me equivoco:* ninguno; descartar una medición falsa no puede dañar.

**HALLAZGO PARA EL USUARIO, fuera del alcance de esta tarea.** El caso real que
él pidió —«entra en Amazon y busca un par de raquetas»— no funciona hoy: Amazon
le sirve su página antibots al Chromium del i3. Esto explica por qué el agente
«entró, buscó y dio las mejores valoradas» sin que él viera nada útil. Es un
problema de detección de bots (huella del navegador, user-agent, IP), no de
nitidez. Hay que llevarlo al plan B/D del spec, no aquí.

**Ruling 10 (corregido) — se mide sobre AliExpress España, no sobre Commons.**
Segunda ronda de sondeo: `es.aliexpress.com/w/wholesale-raqueta-ping-pong.html`
SÍ entra y sirve su página de resultados de verdad — 12 038 caracteres de body y
**171 etiquetas `<img>`**. Es exactamente la forma del caso del usuario: rejilla
de fotografías de producto con precio y texto encima. Mejor proxy que la rejilla
de Commons (4 118 caracteres, 46 imágenes) y, a diferencia de ella, es una
tienda real. Queda descartado medir sobre Commons.
Añadido al sondeo: `idealo.es` también bloquea (256 caracteres, 0 imágenes).
Tiendas que el i3 alcanza, de las sondeadas: **solo AliExpress**.
*Coste si me equivoco:* la rejilla de AliExpress podría ser más o menos cara que
la de Amazon; la nota deja escrita la página exacta para poder repetir la medida.

## Tarea 3 — implementación
Implementador `a437b3330d83160a1` (sonnet). Base `a8c3b08`, commit **`f99d0e3`**.
Dice: 8 fallos preexistentes antes y 8 después, 9 pruebas nuevas verdes, build de
iOS OK. Informe en `task-3-report.md`.
Tres dudas declaradas, que pasan al revisor para que las juzgue:
1. Copió `Gemma/Gemma/Frameworks/llama.xcframework` del checkout principal para
   poder compilar (está gitignorado). Dice que no entra en el commit.
2. Se inventó la etiqueta «elementos» para `browser_get` con `count`, porque el
   encargo no la fijaba.
3. No miró la vista en pantalla.
Revisor acotado despachado: `aec01d3368ee549cc` (sonnet) sobre `a8c3b08..f99d0e3`.

## Tarea 3 — revisión (revisor `aec01d3368ee549cc`, sonnet, sobre `a8c3b08..f99d0e3`)
Cumplimiento del pliego: CUMPLE. Calidad: NO LISTA — 1 Important, 4 Minor.
Pruebas verificadas por el revisor: 8 fallos únicos, exactamente los preexistentes
de `main`; `ToolLogRowTests` 9/9 verdes. `llama.xcframework` verificado FUERA del
commit y del índice (`git ls-files` da 0, el diff tiene 4 ficheros).

**Ruling 12 — el pliego se equivocaba y lo desobedezco: la polaridad del estado
se enumera por FALLO, no por éxito.**
El pliego dice literalmente «no success = failure». Medido sobre el repositorio:
`grep -rhoE '"status" *: *"[a-z_]+"' --include='*.swift' Gemma/Gemma` da **68
estados distintos**, de los cuales `"success"` son 11. Los retornos correctos
usan mayoritariamente otra cosa: `"ok"` 12, `"not_found"` 24, `"deleted"` 8,
`"created"` 5, `"updated"` 5, más `"remembered"`, `"saved"`, `"found"`, `"done"`,
`"empty"`, `"no_results"`… Con la regla del pliego, `search_memory` devolviendo
`"ok"` pintaba una fila ROJA que decía «la herramienta falló sin dar motivo».
Eso es una mentira en la pantalla del usuario, y es peor que el defecto que la
tarea venía a arreglar: el usuario se quejaba de ver demasiado, no de ver mal.
Decisión: conjunto enumerado de 19 estados de fallo + prefijo `invalid_`; la
AUSENCIA de `status` no es fallo; el JSON ilegible sí lo sigue siendo. Los
estados que piden algo al usuario (`permission_required`, `ambiguous`, `conflict`)
quedan en neutro, sin inventar un tercer color.
*Coste si me equivoco:* un fallo duro nuevo que nadie añada al conjunto saldrá
en gris en vez de en rojo — el usuario lo leerá igual, porque el motivo sigue
escrito en la fila. La equivocación simétrica (pintar un acierto en rojo) es la
que engaña, y es la que esto cierra. El prefijo `invalid_` cubre la familia que
más crece.

Ronda de arreglos 1 despachada al mismo implementador (`a437b3330d83160a1`),
con los 4 hallazgos, las 10 pruebas que faltan y **verificación por mutante
obligatoria**: ninguna de sus 9 pruebas usaba un estado distinto de
success/error, y por eso el Important pasó en verde.

**Ruling 13 — el `n=1` era mío, no del servicio. Retiro la acusación.**
Tres barridos dieron `n=1`. Llegué a escribir que «el demonio manda un fotograma
y se calla», lo cual habría sido un defecto grave del panel. Es falso. El relé
habla con el demonio con `pacing=ack` y **el acuse del VISOR es el único momento
en que el relé acusa al demonio** (`relay.py:436` y `:692`, «el único sitio del
relé que acusa al demonio»). El demonio mantiene como máximo un fotograma en
vuelo. Mi guion de medición leía el socket y nunca mandaba
`{"type":"ack","seq":N}`, así que la cadena se quedaba parada tras el primero.
La app sí acusa; el panel funciona. Arreglado el guion.
*Coste si me equivoco:* ninguno en el código; el coste ya se pagó en tres
barridos tirados. La lección es la que vale: el acuse del visor no es opcional,
y cualquier cliente futuro del stream que lo omita verá una foto congelada.

**Bytes de un fotograma sobre la rejilla de AliExpress** (medidos con `n=1`, que
para el PESO de un fotograma sigue siendo un dato válido: es un JPEG real de la
página real a esa configuración; lo que falta es el ritmo):

| tamaño | calidad | bytes del fotograma |
|---|---|---|
| 640 × 360 | 20 | 14 044 |
| 900 × 506 | 45 | 40 934 |
| 1080 × 608 | 45 | 50 670 |
| 1080 × 608 | 60 | 58 729 |

A 10 fps serían 140, 409, 507 y 587 kB/s. Con el presupuesto de 400 kB/s del
plan, solo la línea base cabe — pero el ritmo real no es 10 fps, porque los
fotogramas se emiten por cambio y con un solo fotograma en vuelo. El barrido
con acuse dará el ritmo de verdad, y es ese el que decide.

## Tarea 3 — re-revisión acotada (ronda 1): CERRADA
Revisor `a0c32e00692b59138` (haiku) sobre `f99d0e3..5957d17`. Los cuatro hallazgos
ADDRESSED. Important 1 verificado en sus cuatro comprobaciones: conjunto de 19
estados + prefijo `invalid_` idéntico a la instrucción; sin `status` no es fallo;
JSON ilegible SIGUE siendo fallo (no se pasó de rosca al invertir la polaridad);
`{"status":"no_results","count":0}` en `web_search` da `.count(0,"resultados")`.
Minor 2 correcto en sus dos ramas (normal y `finished` huérfano), con `closeRow`
buscando hacia atrás. **Mutante repetido por el revisor en una copia fuera del
repositorio: 5 pruebas ROJAS, 14 verdes — el mismo resultado que el
implementador.** Recuento: 8 fallos, los preexistentes de `main`; `ToolLogRowTests`
19/19. Ninguna rotura nueva.
Dato fuera de alcance que anota el revisor: si un `finished` nunca llega, la fila
«…» se queda. Correcto que quede: es información verdadera.

Task 3: complete — commits `f99d0e3` (implementación) y `5957d17` (arreglos).

## Interrupción: disco lleno (ENOSPC)
El Mac se quedó con 1,4 GiB libres y Bash dejó de arrancar (Claude Code no podía
crear el fichero de salida). El implementador de la Tarea 2 quedó BLOCKED sin
tocar nada —se portó bien: no editó a ciegas y no borró nada—, y su transcript se
perdió al limpiar, así que la Tarea 2 se re-despacha de cero sobre la misma base.

**Ruling 14 — qué se borró y qué no.** El usuario autorizó borrar «lo que no
necesitemos, verificando que no lo necesitamos». Verificado y borrado (17,6 GB,
1,4 → 19 GiB): cachés de Sparkle/ShipIt de cuatro actualizadores de aplicaciones
(6,7 GB de payloads de actualizaciones ya descargadas), `DerivedData` entero
(9 GB en seis carpetas de Gemma, una por ruta de checkout; se regenera y no había
ningún build corriendo, comprobado con `pgrep`), y las cachés de swiftpm, pip,
Homebrew y dotslash.
**NO borrado: `iOS DeviceSupport` (12 GB).** Es justo lo que hace falta para
probar en el teléfono, que es lo que queda pendiente, y hay dos versiones de
dispositivo sin que yo pueda verificar cuál está muerta. No se borra lo que no se
puede verificar.
*Coste si me equivoco:* el primer build tras esto es lento (DerivedData frío) y
el primer `swift package resolve` vuelve a descargar. Nada perdido.

## Tarea 2 — re-despacho
Implementador nuevo `af246ef6b038938be` (sonnet) sobre la base `e7abb56`, con los
valores elegidos ya en el encargo: compose 1080/608/45 y los DOS topes de fps a 7.

## Tarea 2 — implementación
Implementador `af246ef6b038938be` (sonnet). Base `e7abb56`, commit **`1d41dec`**.
pytest: rojo antes (2 failed, 126 passed) → verde después (**128 passed**).
Mutantes propios: `QUALITY=46` → `test_compose` rojo; `DEFAULT_VIEWER_MAX_FPS=8`
→ `test_app` rojo. Ambos restaurados, 128 passed.
Decisión suya que va más allá del pliego y que apruebo: la prueba del caudal usa
el **máximo** medido (54 715) en vez de la media, y añade una afirmación de que
`DAEMON_MAX_FPS <= DEFAULT_VIEWER_MAX_FPS`. El plan decía «bytes medios × fps»;
el máximo es la cifra honesta para un presupuesto de enlace, porque el pico es
lo que tira el panel al suelo, no el promedio. La afirmación del orden de los
dos topes es un candado contra un futuro en que alguien baje solo uno.
Revisor despachado: `ac863427f65ffaf25` (sonnet) sobre `e7abb56..1d41dec`.

## Cloudflare, no las tiendas — corrección de mi propio hallazgo
El usuario corrigió mi afirmación: él SÍ había visto la página de Amazon desde el
teléfono, y a cambio Cloudflare le bloqueó ChatGPT y Claude AI. Medido otra vez,
esta vez sin martillear (15 s entre peticiones) y leyendo también el **título**,
que es lo que lo delata:

| sitio | título | qué es |
|---|---|---|
| amazon.es búsqueda | «Amazon.es : raquetas ping pong» (18 720 chars) | **entra** |
| pccomponentes | `Just a moment...` | desafío de Cloudflare |
| claude.ai | `Just a moment...` | desafío de Cloudflare |
| chatgpt.com | `Just a moment...` + «**Verification successful.** Waiting for chatgpt.com to respond» | desafío **superado**, leí demasiado pronto |
| decathlon.es | `Attention Required! \| Cloudflare` | bloqueo duro |
| ebay / idealo | error propio del sitio, sin Cloudflare | otra cosa |

**Ruling 15 — retiro el hallazgo «cinco de seis tiendas bloquean al i3».** Era
falso en dos sentidos: Amazon entra (lo que vi fue su página de estrangulamiento,
provocada por pedir la misma URL cuatro veces en pocos minutos durante el
barrido), y lo que bloquea no son «las tiendas» sino **Cloudflare**, que es un
intermediario y cuyo desafío ChatGPT demostró que el navegador PASA si se le da
tiempo. La nota de la medición tiene esa afirmación mía y hay que corregirla
antes de cerrar la rama.
*Coste si me equivoco:* dejar escrito en una nota del repositorio que el
navegador no puede comprar en Amazon habría enterrado una capacidad que sí
existe, y habría mandado los planes B y D a resolver un problema inventado.

## Tarea 2 — revisión: APROBADA
Revisor `ac863427f65ffaf25` (sonnet) sobre `e7abb56..1d41dec`. Cumplimiento
CONFORME, calidad APROBADA: 0 Critical, 0 Important, 2 Minor. Los cinco valores
exactos; los dos topes bajan; las cinco constantes citan la nota y `03ba854`;
aritmética del comentario correcta. **Repitió los dos mutantes del implementador
y añadió dos propios** (`DAEMON_MAX_FPS=10` y `MAX_HEIGHT=609`): los cuatro
rojos en la prueba correcta, los otros 127 verdes. 128 passed.
Minor 1 (el 54 715 de `test_app.py` no está atado al compose) y Minor 2 (la frase
«tres de cada diez fotogramas» suena permanente) cerrados en `b427ace`.

**Ruling 16 — no despacho re-revisor para `b427ace`.** Verifiqué yo mismo que el
diff es solo comentarios: filtrando las líneas que no son comentario ni vacías,
el diff queda **vacío**; 128 pruebas verdes. Un re-revisor sobre un cambio de
comentarios es un asiento de revisión gastado en nada.
*Coste si me equivoco:* un comentario podría decir algo falso y nadie lo
cazaría; los leí, y la revisión final de rama los vuelve a ver.

Task 2: complete — commits `1d41dec` (implementación) y `b427ace` (los 2 Minor).

## Step 7 de la Tarea 2 — desplegado al i3
Respaldo primero (`docker-compose.yml.antes-de-nitidez` y
`browser/relay.py.antes-de-nitidez` en `~/Projects/gemma-browser/`), luego los
dos ficheros copiados y `docker compose up -d --build browser` **con el servicio
nombrado**, nunca un `down` a secas. Verificado en vivo: contenedor `healthy`,
`/healthz` 200, y el entorno del contenedor trae `MAX_WIDTH=1080`,
`MAX_HEIGHT=608`, `QUALITY=45`. El veredicto del ojo lo da el usuario.

## La nota corregida
`b44d421` en `personal_agent`: la nota de la medición decía que el i3 no alcanza
Amazon y que «cinco de las seis tiendas sondeadas le sirven su página antibots».
Las dos afirmaciones eran falsas (Ruling 15). Corregido con la re-medición, la
tabla de títulos, y el resultado del experimento de paciencia: **el desafío de
Cloudflare NO se pasa esperando** —pccomponentes sigue en `Just a moment...` a
los 45 s, chatgpt a los 30— y el «Verification successful» que servía chatgpt.com
es texto de la propia página de desafío, no un estado alcanzado. Ese experimento
se quedó sin medir sus dos últimos sitios porque mi propia reconstrucción del
contenedor mató el proceso, que corría dentro de él; lo que hay medido basta para
la conclusión y la nota dice que faltan.

## Revisión final de rama
Despachada a `ad8c4ad84a4a8f489` (**opus**, el más capaz, como manda la skill)
sobre los dos repositorios a la vez, con los diffs completos empaquetados y con
el encargo explícito de juzgar los rulings que desobedecen al plan.

## Revisión final de rama — hallazgos
Revisor `ad8c4ad84a4a8f489` (opus) sobre los dos repositorios. **Veredicto: no
mergear.** 1 Critical, 6 Important, 6 Minor. Aritmética de la nota y del compose
cuadra entera; secretos limpios; 14 de mis 15 rulings correctos. Informe en
`final-findings.md`.

**El Critical, y es mío.** Hice el censo de estados con
`grep -rhoE '"status" *: *"[a-z_]+"'`, que solo ve los literales dentro de un
objeto. Las nueve herramientas del navegador construyen el estado en
`AgentBrowserToolOutput.resolve`, con `status = "refused"` y `"not_available"`.
El censo honesto es
`grep -rhoE '(status|"status")[ :=]+"[a-z_]+"' ... | grep -oE '"[a-z_]+"$'`
y da **70** estados, no 68: se me perdieron `refused`, `not_available`,
`calling`, `partial`, `pending`, `started`.
Escenario: `browser_open` rechazado devuelve `{"url":…,"status":"refused",…}`,
cae en la rama `.host` y pinta `✓ browser_open www.amazon.es` — **fila idéntica
al éxito** con el navegador sin abrir nada. Verificado por mí antes de arreglar.
El Ruling 12 (invertir la polaridad) era correcto en dirección pero incompleto, y
su coste declarado («el motivo sigue escrito en la fila») NO se cumplía ahí.

**Ruling 17 — me retracto de dos cosas que le dije al implementador en la ronda
anterior**, porque la revisión final trajo evidencia que yo no tenía:
- *El `message` de un estado sin entrada en la tabla NO se enseña.* Le había
  pedido `.value(message)`; vuelve a `.ok`. Los `message` de este repositorio
  están redactados para el modelo: el revisor encontró
  `✓ check_schedule Ese hueco choca con 1 cosa(s). Dile al usuario con qué choca
  y pregúntale qué quiere hacer.` Eso es el prompt del agente impreso en la cara
  del usuario.
- *Sí hace falta un tercer estado visual.* Había escrito «no inventes un tercer
  estado: neutro basta». Con tilde verde salían `permission_required` (10),
  `ambiguous` (14), `conflict` (3), `confirmation_required`, `location_unknown`,
  `no_forecast`, `unknown`, `needs_criteria`, `needs_time`. Escenario: el usuario
  deniega Contactos y la fila dice `✓ send_message`. Y hay incoherencia en un
  mismo fichero: `GetWeatherTool` emite `place_not_found` (rojo) y
  `location_unknown` (verde) desde dos `catch` seguidos. Conjunto nuevo
  `needsYouStatuses` con esos nueve, icono naranja, y frase fija «necesita algo
  de ti» — NO su `message`, por lo de arriba.
*Coste si me equivoco:* el tercer estado añade una categoría que alguien tendrá
que mantener; el conjunto se queda corto antes que largo, y un estado nuevo que
pida algo saldrá neutro, que es el fallo benigno.

**Ruling 18 — el tope de fotogramas lo decide el servicio, no la app.**
`BrowserRelayClient.swift:56` pedía `maxFps: Int = 10` y ese valor por omisión
era el de producción, así que el `DEFAULT_VIEWER_MAX_FPS = 7` que acabábamos de
medir era **inerte** y el presupuesto lo sostenía solo `DAEMON_MAX_FPS`. En vez
de cambiarle el número a la app, le quito la decisión: no manda `maxFps` y lo
decide el relé, que es su dueño legítimo porque el número sale de su medición.
Dos dueños del mismo número es exactamente cómo se llegó a la divergencia.
*Coste si me equivoco:* si el relé no tratara bien un `maxFps` ausente, el visor
caería a un tope inesperado; por eso le encargué al servicio que lo verifique y
lo deje probado por su lado.

**Ruling 19 — despacho las dos rondas de arreglos en paralelo.** La regla dice
nunca dos implementadores a la vez, por conflictos. Aquí son **dos repositorios
distintos sin un solo fichero en común** (Swift en `personal_agent`, Python y
compose en `gemma-memory`), así que el riesgo que la regla previene no existe.
*Coste si me equivoco:* ninguno medible; si se pisaran, lo vería en el diff.

**El hallazgo 7 del revisor (de proceso) es un falso positivo:** dice que falta
en el ledger el resultado del revisor de la Tarea 2, el commit `b427ace` y el
Step 7. Están los tres — los escribí después de que él leyera el fichero.

## Ronda de arreglos de la revisión final — la app
Implementador `a9df8f7494c5d9fee` (sonnet). Commit **`6fc33de`**, los 5 arreglos
juntos. 8 fallos (los preexistentes); `ToolLogRowTests` 19 → **25**;
`BrowserRelayClientTests` +2. Retiró 1 prueba: la del mensaje largo de estado
no-fallo, que afirmaba justo lo que el Ruling 17 revierte. Correcto retirarla.
**Cuatro mutantes, los cuatro rojos y restaurados**:
`refused` fuera del conjunto → roja; `.valueOrCount` leyendo solo `count` → roja
(el 32); `ambiguous` al camino neutro → roja; `socketURL` añadiendo siempre
`maxFps` → roja. Nota honesta suya: con el mutante 1, la prueba de
`not_available` se quedó verde porque ese estado seguía en el conjunto — es
cierto y está bien dicho.
MINOR 8: ningún comentario de este repositorio citaba el SHA. Nada que arreglar.

## El estrangulamiento de Amazon, medido con el caso real del usuario
El usuario: «la primera vez pude acceder a Amazon, la segunda, la tercera y de
ahí para allá, no. Me decía, sorry, ha pasado un error.» Reproducido: cinco
búsquedas distintas seguidas, **3 fallaron y 2 pasaron**, y no en orden (fallan
la 1, 2 y 3; pasan la 4 y la 5). No es bloqueo, es estrangulamiento errático, y
no depende del término.
**Causa medida:** el Chromium del contenedor se identifica como
`Mozilla/5.0 (X11; Linux x86_64) … HeadlessChrome/156.0.0.0 Safari/537.36`.
`HeadlessChrome` escrito en la propia cabecera. Y dos pistas más:
`Accept-Language: en-US` pidiéndole a `amazon.es`, y `Sec-Ch-Ua` diciendo
`"Chromium"` en vez de `"Google Chrome"`.
**Lo que el CLI ofrece** (medido en la imagen, `agent-browser 0.41.2`):
`AGENT_BROWSER_USER_AGENT` como variable de entorno; `AGENT_BROWSER_ARGS` para
flags de Chrome (`--lang`); `AGENT_BROWSER_PROFILE` y `AGENT_BROWSER_STATE` para
un perfil persistente; `AGENT_BROWSER_PROXY`; `AGENT_BROWSER_PLUGINS`, con un
plugin `stealth` (`launch.mutate`) que **NO está instalado en la imagen** (solo
hay `agent-browser@0.41.2`, `corepack`, `npm`).
**Decisión del usuario (2026-11-08):** cerrar esta rama primero, y después
atacar la huella como **sub-proyecto propio** — «lo que haga falta para que no
bloquee»: perfil de Chrome persistente, cookies que sobrevivan, proxy si hace
falta. Con su spec y su plan, no como ajuste.

## El puntero del ratón — petición nueva del usuario
«Me gustaría ver el puntero del mouse en el navegador.» Medido: el CLI **no lo
ofrece en el streaming**. Su `--cursor` es solo de `record` (vídeo), y el
screencast viene de CDP, que no dibuja el cursor. Dos caminos posibles: que la
app lo dibuje con las coordenadas de cada acción, o inyectar un cursor falso con
`AGENT_BROWSER_INIT_SCRIPTS`. Va al plan D del spec, con el vídeo del turno.
(Ojo: `--init-script` está en la lista de flags RECHAZADOS de `cli.py` porque
ejecuta JavaScript llegando por red; como variable de entorno del contenedor es
otra cosa — es configuración del servidor, no entrada del cliente. La distinción
es correcta y hay que conservarla.)

## Veredicto del usuario sobre la Tarea 3
«Ya corrí, esta vez me gustó cómo quedó todo.» La fila plegada aprobada por su
ojo, que es lo que el plan pedía para cerrarla. Antes de esto él estaba corriendo
la app VIEJA: la nitidez se había desplegado al i3 (y la notó) pero las filas
plegadas son cambio de la app y no estaban instaladas. Compilada e instalada en
su iPhone 18 Pro (`00008160-0009349A36C0000A`) desde este worktree.

## Ronda de arreglos de la revisión final — el servicio
Implementador `a94d087371f8d5cb2` (sonnet). Commit **`e443aed`**. pytest 128 →
**143**, todo verde. Cuatro mutantes en rojo y restaurados.

**Encontró tres agujeros que yo NO encargué, y son reales.** Le pedí solo
«verifica que un `maxFps` ausente cae en el tope por omisión». Al mirarlo:
- `maxFps=0` daba streaming **SIN TOPE** (intervalo 0,0).
- `maxFps` entre 10 y 120 pasaba tal cual → 547 kB/s con el fotograma máximo
  medido, por encima del presupuesto de 400 kB/s.
- `maxFps=abc` no caía en el tope: FastAPI rechazaba el handshake entero.
Arreglo: `relay.viewer_max_fps` sanea en la frontera de red — inválido, 0,
negativo o fuera de 1..120 da 7; mayor que 7 se recorta a 7; menor se respeta.
Cualquier cliente del stream podía pedir caudal ilimitado. Mérito suyo: el
encargo no lo pedía.

**Dos correcciones que me hizo, las dos buenas:**
1. El compose de la raíz NO usa `BROWSER_BEARER_TOKEN=${MEMORY_BEARER_TOKEN}`,
   como yo le dije: usa `${BROWSER_BEARER_TOKEN}`, su propio secreto. Mi
   afirmación venía de la cabecera de la Tarea 1, que describe un estado pasado.
   No lo tocó, y su prueba fija el valor real.
2. El «9 % de q60» no estaba en su repositorio sino en mi nota. Corregido por mí
   en `f5a0c15`: son **7,7 %** sobre las medias (55 566 / 51 594); el 9,1 % sale
   solo de comparar máximo con máximo, que no es la comparación que la frase
   hace. En una nota cuyo argumento entero es que los números se miden, un
   porcentaje a ojo era el peor sitio para dejarlo.
Nota honesta suya sobre su propio mutante 3: la cota de rango de anchura queda
tapada por la aserción de igualdad `== 1080`, que la caza antes, así que ese
mutante no la aísla. Pasa al re-revisor para que diga si la cota aporta.

## Re-revisión de las dos rondas
Despachada a `a4fe077106ea00103` (sonnet) sobre los dos repositorios, con la
tabla de valores de `maxFps` a verificar uno por uno (`0`, `-1`, `abc`, `""`,
ausente, `8`, `120`, `999`, `3`) y tres mutantes a repetir. Lo que más quiero
verificado es el saneado de la frontera de red, porque es un cambio de
comportamiento que yo no encargué.
