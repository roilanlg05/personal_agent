# Secretos y puerta de compra — documento de diseño

**Fecha:** 2026-11-06
**Estado:** propuesta de diseño, pendiente de aprobación del usuario.
**Depende de:** `feat/agent-browser`, mergeada a `main` (`6a87231`).

**Sub-proyecto 2 de 3.** El panel de streaming va primero («quiero que el
streaming sea lo primero que hagas»); los recibos van al final. Este documento
cubre **secretos y puerta de compra juntos** porque no son dos cosas: el campo
secreto existe solo para servir una compra, la cartera y la autorización ocurren
en la misma conversación seguida, y el código de compra es a la vez un secreto
que hay que proteger y la llave que abre la puerta.

Todo lo que este documento afirma sobre el CLI está **verificado contra el
binario real** `agent-browser` 0.41.2, no leído de documentación. El recon
completo está en `docs/superpowers/notes/2026-11-06-recon-contencion-y-confirmacion.md`.

---

## 1. Intención y por qué

El usuario quiere que Gemma compre por él en la web. Eso exige rellenar
formularios de pago, y choca con una restricción que él puso desde el principio:
**el modelo no puede ver el número de la tarjeta.**

El diseño resuelve eso sin pedirle al modelo que se porte bien. El modelo nunca
recibe el valor de un secreto; recibe un nombre. El valor viaja de un campo
nativo de la app al Llavero, y del Llavero a la página, por un camino que no pasa
por el modelo, ni por los argumentos de un proceso, ni por la salida que el
modelo lee.

La segunda tensión es la autorización. El usuario quiere confirmar hablando, y él
mismo encontró el agujero de la forma obvia de hacerlo. La cita es la bisagra de
todo el diseño de la puerta:

> «Si digo: si encuentras un precio más barato, no lo compras — ese *sí*
> dispararía esa orden de compra. Y ni siquiera podría el modelo negarse.»

Eso descarta buscar una palabra de confirmación dentro del habla libre. La puerta
tiene que ser un **estado** que no interpreta nada más, y la llave algo que no
aparezca por casualidad en una frase.

La tercera tensión la descubrió el recon: hay una diferencia enorme entre una
puerta que **la app** hace cumplir y una que el **CLI** hace cumplir. La primera
depende de que nuestro código no tenga un camino alternativo. La segunda no se
salta ni con el modelo confundido ni con una inyección de prompt desde la página
del comercio. El CLI trae la segunda de serie, y no lo sabíamos.

---

## 2. Objetivos

1. Gemma completa una compra rellenando el formulario de pago **sin que el modelo
   vea ningún dato de la tarjeta en ningún momento, por ninguna de las cuatro
   vías de fuga identificadas** (sección 6.4).
2. Los datos que ya sabe los rellena sola. Los que no sabe y no son secretos los
   pide **por el chat normal**, uno a uno.
3. Los datos de la tarjeta se piden en un **campo especial dentro del chat**.
4. El usuario elige, **por chat y no por botón**, si la tarjeta se guarda o se usa
   una vez. Si la guarda, le pone **un nombre que él elige**.
5. La compra siguiente empieza con Gemma preguntando **con qué tarjeta**,
   nombrando las guardadas por su nombre y sus cuatro últimos, más «otra».
6. Por debajo de un umbral Gemma compra sola. Por encima pide el **código de
   compra** y no compra sin él.
7. El código **nunca queda escrito** en la conversación, transcripciones,
   resúmenes, memoria ni logs.
8. **Funciona contra campos de Stripe Elements**, que viven en iframes de otro
   origen. Es el primer objetivo del usuario y por tanto un requisito, no un
   caso límite.

## 3. No objetivos

- **Un formulario emergente aparte.** El usuario lo descartó: «olvídate del
  formulario que te pedí para yo rellenar. Me va a pedir los datos por el chat.»
- **Botones para las decisiones.** «Me pregunta si quiero guardarla o no por
  chat, **no por un botón**.» La única pulsación es el «Aceptar» del campo
  secreto.
- **Un producto para otros.** Preguntado si lo usarían terceros: «los mostraré a
  mi abuela». Modelo de amenaza de un solo usuario en su propio Mac.
- **Apple Pay, PayPal o monederos del navegador.** Solo formularios de tarjeta.
- **Deshacer una compra.** El diseño evita que ocurra sin querer; no la revierte.
- **Contención de dominio a nivel de sistema operativo.** Sección 7.5.

## 4. Anti objetivos — qué haría fracasar esto aunque funcione

- **Que un secreto llegue al modelo por cualquiera de las cuatro vías.** No basta
  con tapar la obvia; las cuatro están verificadas y tres de ellas no son
  evidentes.
- **Que el código de compra acabe en la memoria del agente.** Es el riesgo más
  propio de este sistema. Gemma transcribe, resume y **consolida hechos en
  memoria**. Un código hablado atraviesa el STT y entra en ese pipeline como
  cualquier frase. Y hoy `main` tiene el defecto `e2f9e86`, que hace que el turno
  vivo llame a `save_memory`. Si el código acaba como hecho recordado, está
  comprometido y nada lo dice.
- **Que la puerta se abra con un «sí» suelto.** La corrección del propio usuario.
- **Que la contención parezca puesta y no lo esté.** Verificado: una política de
  acciones con la forma equivocada **se ignora en silencio y deja pasar todo**.
- **Que el modelo decida qué es secreto.** Si puede clasificar un campo como no
  secreto, puede equivocarse o ser inducido a equivocarse.
- **Que el umbral de 20 $ lo fije la página.** Si el total lo afirma el comercio,
  una página que mienta convierte una compra de 500 en una compra autónoma.

---

## 5. El flujo, tal como lo describió el usuario

El orden es suyo y lo corrigió dos veces hasta llegar aquí.

1. Gemma busca, añade al carrito y llega a la página de pago. *(El panel del
   sub-proyecto 1 lo muestra en vivo.)*
2. Rellena **lo que ya sabe**.
3. Lo que no sabe y no es secreto, **por el chat normal**, uno a uno: «¿A qué
   dirección de envío?» → responde → lo anota y rellena. «¿Código postal?» → etc.
4. **Antes de la tarjeta**, pregunta **a nombre de quién está**. Por chat normal:
   el titular **no es secreto**.
5. Sale **el campo especial** con número, caducidad y código de seguridad, los
   tres juntos. El usuario teclea y pulsa **Aceptar**.
6. Gemma rellena la página y pregunta **por chat**: «¿Te la guardo?»
7. Si sí, pregunta **por chat**: «¿Cómo la llamo?» El usuario da un nombre.
8. Presenta la autorización: comercio, total, tarjeta, gastado hoy. Por encima del
   umbral, **pide el código**.
9. El usuario da el código. Gemma compra.
10. Informa del pedido y de qué peldaño de recibo consiguió *(sub-proyecto 3)*.

Con una tarjeta ya guardada, el paso 5 desaparece y el flujo empieza con el
**selector dentro del chat**: «¿Con qué tarjeta pago? Capital One Quicksilver
···4242, Visa del banco ···8810, u otra.» Si elige «otra», vuelve el paso 5.

---

## 6. Los secretos

### 6.1 Decisiones del usuario

| Decisión | Sus palabras |
|---|---|
| Los datos se piden **por el chat**, uno a uno | «Me va a pedir los datos por el chat» |
| El dato de tarjeta entra en un **campo especial** y se recoge como secreto | «Me va a poner un campo especial donde voy a introducir el dato y ese dato lo va a recoger como una clave secreta» |
| Guardar o usar una vez, **por chat, no por botón** | «Me pregunta si quiero guardarla o no por chat, no por un botón» |
| Las guardadas se llaman por **nombres que él elige** | «Por los nicknames que yo le ponga. Por ejemplo, Capital One, Quicksilver» |
| El selector va **dentro del chat** | «No como una ventana aparte, sino dentro del mismo chat» |
| Credenciales y tarjeta **no se pegan en el chat** | decidido antes, en el log de compras |

### 6.2 La lista dura — decisión mía

El usuario dijo «datos personales que no quiero que sepa, **etc.**» y, preguntado
dos veces, no concretó el *etc.* Se fija un suelo seguro que él amplía:

**Siempre secretos, y el modelo no puede cambiarlo:** número de tarjeta,
caducidad, código de seguridad, contraseñas, códigos 2FA, y el código de compra.

**Nunca secretos, porque el flujo los necesita visibles:** el nombre del titular
(el usuario lo confirmó al pedir que se preguntara «por el chat normal»), el
nombre que da a una tarjeta, y los cuatro últimos dígitos.

**Lo demás lo amplía el usuario en Settings**, campo a campo.

Lo importante no es la lista: es **quién la aplica**. La clasificación está en
código, no en el prompt. El modelo **no tiene ninguna herramienta** con la que
pedir el valor de un secreto, así que no hay nada que decidir ni que inducirle a
decidir.

### 6.3 Dónde viven

**El Llavero de macOS.** Verificado que la app **no está en sandbox** —no hay
`com.apple.security.app-sandbox` en `Gemma.entitlements` ni `ENABLE_APP_SANDBOX`
en el proyecto—, así que no hace falta nada nuevo.

Cada tarjeta guardada: el nombre que le dio el usuario, los cuatro últimos **en
claro a propósito** (es lo que el selector muestra y lo que el agente puede
nombrar), el nombre del titular, y número, caducidad y CVC que **solo la capa de
relleno lee**.

El modelo recibe **solo el nombre y los cuatro últimos**. Suficiente para
preguntar «¿con qué tarjeta?» y para informar de con cuál pagó. Insuficiente para
todo lo demás.

Una tarjeta de **usar una vez** no se escribe en el Llavero: vive en memoria el
tiempo de la compra. Esa es la diferencia entera entre las dos opciones.

**El fichero de estado del navegador también es un secreto** —lleva las cookies
de sesión de la tienda, que valen tanto como la contraseña— y el CLI trae cifrado
de serie: `AGENT_BROWSER_ENCRYPTION_KEY` (64 hex, AES-256-GCM). La clave al
Llavero, la variable al entorno del demonio.

### 6.4 Las cuatro vías de fuga, y cómo se tapa cada una

Esta es la sección central del documento. **Las cuatro están verificadas en vivo**
y tres no son evidentes. Tapar solo la primera, que es lo que el diseño anterior
hacía, deja el secreto expuesto por las otras tres.

#### Vía 1 — los argumentos del proceso (`ps` los lee)

`browser_fill` manda el texto como argumento del CLI. Cualquier proceso del
sistema puede leerlo con `ps`.

**Tapón verificado: el modo stdin de `batch`.** El CLI acepta un array JSON de
comandos por entrada estándar, y lo documenta con este mismo caso de uso:

```
echo '[["fill", "#password", "secret"]]' | agent-browser batch --json --omit-command
```

La app construye el JSON en memoria y lo escribe en el stdin del hijo. **El
secreto nunca aparece en argv.**

#### Vía 2 — el eco del comando en la salida

Sin más, `batch` imprime cada comando junto a su resultado, con el secreto
dentro.

**Tapón: `--omit-command`**, que sustituye el array del comando por un `index`.
El propio CLI avisa de que eso **no basta**, y tiene razón:

> «This only removes command arrays and does not make output safe for secrets.
> Errors and response data are unchanged: `type` echoes typed text, and
> `get value`/`eval` may return input values.»

#### Vía 3 — el eco del secreto en la RESPUESTA

Verificado, y es la que el diseño anterior no veía. `keyboard type` devuelve el
texto tecleado:

```
$ printf '[["open","file:///tmp/t.html"],["click","#plain"],["keyboard","type","SECRETO123"]]' \
    | agent-browser batch --json --omit-command
[..., {"index":2,"result":{...,"typed":"SECRETO123"},"success":true}]
```

`keyboard inserttext` **no**:

```
$ printf '[["keyboard","inserttext","OTROSEC"]]' | agent-browser batch --json --omit-command
[{"index":0,"result":{"inserted":true,...},"success":true}]
```

**Dos tapones, los dos obligatorios:**

1. **Se usa `keyboard inserttext`, nunca `keyboard type` ni `fill` ni `type`**
   para un secreto. `inserttext` es un `Input.insertText` de CDP: dispara
   `beforeinput` e `input`, que es lo que escuchan los campos controlados por
   React como Stripe Elements, y es la misma vía que un pegado.
2. **La respuesta de una fila con secreto se descarta de todos modos.** De la
   salida de `batch` solo se conserva `index` y `success`. El `result` de esa fila
   no se registra, no se muestra y **no se le entrega al modelo**. Defensa en
   profundidad: si una versión futura del CLI empieza a devolver algo en
   `inserted`, ya está tapado.

#### Vía 4 — el `snapshot` que el modelo lee cada dos por tres

La peor, porque `snapshot` es una herramienta normal que el modelo llama
constantemente. Verificado: **el snapshot incluye el valor actual de los
campos.**

```
- heading "host" [level=1, ref=e1]
- textbox "plain field" [ref=e2]: SECRETO123      ← el valor, en el árbol
- Iframe [ref=e3]
  - link "Learn more" [ref=e4]
```

`agent-browser snapshot --help` **no tiene ninguna opción para omitir valores**
(`-i`, `-u`, `-c`, `-d`, `-s`, `--delta`, `--full`, y ninguna más).

**Tapón: lo redacta la app.** `browser_snapshot` y `browser_get` pasan por un
redactor antes de que su salida llegue al modelo. La regla, por el mismo
argumento de «regla y no lista» que el commit `6990231` aplicó al contenido no
confiable: **se redacta el valor de todo campo cuyo rol sea de entrada de texto,
no solo de los que creemos que son secretos.** Un campo de texto cuyo valor el
modelo necesite de verdad se pide explícitamente con `browser_get value`, que
también pasa por el redactor y que la app puede autorizar campo a campo.

Falla cerrado: un campo nuevo, un rol nuevo o un formulario que no esperábamos se
redacta por defecto.

#### Resumen de los cuatro tapones

| Vía | Dónde fuga | Tapón | Verificado |
|---|---|---|---|
| 1 | `argv`, visible en `ps` | modo stdin de `batch` | sí |
| 2 | eco del comando | `--omit-command` | sí |
| 3 | `result.typed` de la respuesta | `inserttext` + descartar el `result` | sí |
| 4 | el valor del campo en `snapshot` | redactor de la app sobre todo campo de texto | sí |

### 6.5 Stripe Elements vive en un iframe de otro origen, y se alcanza

El primer objetivo del usuario son tarjetas de prueba de Stripe, y Stripe
Elements monta sus campos en iframes de **otro origen**. Eso rompe dos cosas a la
vez: `document.querySelector` desde el frame principal no los ve, y `eval` **no
tiene `--frame`** (verificado: solo `-b` y `--stdin`; el único comando con
`--frame` es `webmcp`).

**Pero el camino existe y está verificado.** `snapshot` **sí atraviesa el iframe
cross-origin** y asigna refs a lo que hay dentro —en la prueba de arriba,
`example.com` embebido en una página `file://` dio `ref=e4` a su enlace—.

Así que la secuencia para un campo de Stripe es:

1. `snapshot` → da un `@eN` al campo que está dentro del iframe. **Sin secretos:
   solo refs y etiquetas.**
2. `click @eN` → pone el foco dentro del iframe. **Sin secretos: un ref.**
3. `keyboard inserttext <valor>` por stdin → `keyboard` actúa sobre **lo que
   tiene el foco**, así que el origen del iframe es indiferente.

Los pasos 1 y 2 no llevan secretos y pueden ir por la vía normal. Solo el 3 va
por el `batch` de stdin con el `result` descartado.

**Lo que el plan tiene que verificar contra la página real del usuario**, porque
el mecanismo es correcto pero el DOM de cada integración cambia: que el snapshot
dé refs a los tres campos de Stripe por separado, y que `inserttext` haga que
Stripe considere el campo completo y válido. Es una prueba en vivo, de las que ya
existen en `AgentBrowserLiveTests` con la puerta `GEMMA_LIVE_BROWSER=1`.

### 6.6 Quién dispara el campo secreto

El diseño anterior decía que la app lo dispara «cuando detecta que el formulario
pide un campo de la lista dura», y a la vez que el modelo no puede invocarlo. Eso
era una contradicción: **solo el modelo lee la página.**

**La resolución: el modelo puede PEDIRLO, no puede RECIBIR nada.**

Hay una herramienta `request_secret(ref, tipo)` donde `tipo` es uno de la lista
dura. El modelo la llama cuando ve un campo de tarjeta en el snapshot. Entonces:

- La app comprueba que el `ref` existe y que su rol y etiqueta son compatibles con
  el `tipo` declarado. Si no cuadran, falla.
- La app renderiza el campo secreto en el chat.
- El usuario teclea y pulsa Aceptar.
- El modelo recibe **«el campo se completó»** y nada más. Ni el valor, ni una
  referencia que pueda reusar en otro sitio, ni el relleno: la app rellena por la
  vía de 6.4.

El modelo conduce la página, que es lo que tiene que hacer. No toca el valor,
que es lo que no puede hacer.

### 6.7 El campo especial en el chat

Un bloque dentro de la conversación, visualmente distinto —candado, borde
propio—, porque la diferencia entre «esto lo ve Gemma» y «esto no» tiene que ser
obvia de un vistazo.

1. **El valor no pasa por el modelo.** Al Aceptar va de la vista al Llavero.
2. **El bloque no queda en el historial.** Una vez enviado queda «metiste el
   número de tarjeta», no el campo con el dato. Decisión mía: si persiste, el
   secreto vuelve a pantalla en cada scroll y el historial se guarda en disco.
3. **Nunca aparece sin que la app lo haya validado** (6.6).

---

## 7. Contención y puerta

### 7.1 El conflicto que bloqueaba el diseño, y su salida

```
$ agent-browser --allowed-domains "example.com" --restore open about:blank --json
{"error":"--allowed-domains is not supported with --restore because saved state
can replay origins before agent-browser can verify they are in the allowlist",
"success":false}
```

Para comprar se quiere la sesión ya iniciada **y** contención. Parecía una
elección forzosa. **La salida es `--action-policy`, verificada: no choca con el
estado persistente.**

Es contención sobre **acciones** en vez de dominios. El esquema no está
documentado; se averiguó probando, y es una lista plana:

```json
{"deny": ["navigate", "click", "fill", "screenshot", "download"]}
```

Categorías que el motor reconoce, cada una verificada con su comando:
`navigate`, `click`, `fill`, `screenshot`, `download`. Que **no** reconoce:
`eval`, `cookies` —se ejecutaron igual estando en la lista—. `eval` no importa:
no está registrado como herramienta (`HarnessModel.swift`, nueve tools, sin
`eval`), así que el modelo no puede llamarlo.

Detalle que importa: **`click` se deniega antes de resolver el selector**. Es una
puerta previa a la ejecución, no un filtro posterior.

### 7.2 Las tres trampas, y la prueba de humo obligatoria

| Caso | Comportamiento |
|---|---|
| Fichero ausente | **falla cerrado** |
| JSON inválido | **falla cerrado** |
| **JSON válido con la forma equivocada** | **FALLA ABIERTO, en silencio** |

```
$ echo '{"version":1,"rules":[{"action":"navigate","effect":"deny"}]}' > bad.json
$ agent-browser --action-policy bad.json open about:blank --json
{"success":true,...}      ← navegó. Política ignorada, sin un solo aviso.
```

Lo mismo con `--confirm-actions zzz_no_existe`: aceptado, sin error, sin puerta.

**Por tanto, y no es negociable: la app verifica su propia contención por el
efecto, al arrancar cada sesión de compra.** Pide una acción que debe estar
denegada y una que debe pedir confirmación, y comprueba que el CLI responde
`denied by policy` y `confirmation_required`. Si cualquiera pasa, **se aborta la
compra**. Escribir el fichero y confiar es exactamente el modo de fallo que el
CLI permite.

La política la escribe la app con la forma `{"deny":[...]}` y nada más. El modelo
nunca la escribe ni la nombra.

### 7.3 `--confirm-actions` da un cuello de botella, no un clasificador

Corrige una afirmación demasiado optimista de la versión anterior.

```
agent-browser confirm/deny - Approve or deny pending actions
Pending confirmations auto-deny after 60 seconds.
```

Verificado en vivo: con `--confirm-actions click`, **cada** clic devuelve
`confirmation_required` y un `confirmation_id`, y no se ejecuta hasta un
`confirm` explícito.

**La categoría no distingue objetivos.** Un checkout tiene treinta clics y el CLI
los gatea todos igual, así que la app va a auto-confirmar casi todos. La pregunta
«¿cuál es el clic de la compra?» **vuelve a nuestro código**, y hay que decirlo
en vez de dejar creer que el CLI la responde.

**Lo que sí da, y vale mucho:** ningún clic ocurre sin que la app lo haya visto y
dicho sí. Es un cuello de botella que no se puede rodear —ni por un modelo
confundido, ni por una inyección de prompt desde la página—, y encima **falla
cerrado a los 60 s** sin que lo programemos. La clasificación es nuestra; la
garantía de que nada pasa por detrás es del CLI. Esa división es la correcta.

### 7.4 La política es pegajosa, así que la compra corre en su propia sesión

Verificado: **la política sobrevive a que se quite el flag.** Solo otra política
la reemplaza.

```
--session p open about:blank                   → success   (sin política)
--session p --action-policy pol.json …         → denied
--session p open about:blank                   → denied     ← flag ausente, sigue denegando
--session p --action-policy vacia.json …       → success    ← solo {"deny":[]} la relaja
```

Si la compra instalase su política sobre la sesión compartida (hoy
`AgentBrowserService.defaultSessionName`), la navegación normal se quedaría
restringida hasta que alguien escribiese `{"deny":[]}`.

**Decisión mía: la compra corre en su propia sesión, con su propio fichero de
estado cifrado.** Coste: cookies separadas, así que el usuario inicia sesión en la
tienda una vez dentro de la sesión de compra. A cambio, la navegación normal no
se toca y la política de compra no puede quedarse pegada donde no debe.

### 7.5 El coste de perder `--allowed-domains`, dicho claro

`--action-policy` controla **lo que nosotros hacemos**, no lo que la página hace.
Sin `--allowed-domains`, la página del comercio puede abrir WebSocket,
EventSource y `sendBeacon` donde quiera.

Es un no objetivo consciente. La respuesta correcta es control de salida en el
host o el contenedor, que es lo que recomienda el `trust-boundaries.md` del propio
CLI. Otro proyecto, y el usuario debe saber que queda abierto.

---

## 8. La autorización

### 8.1 Decisiones del usuario

| Decisión | Sus palabras |
|---|---|
| Por debajo de 20, **el modelo compra solo** | «El LM puede elegir si comprarlo o no por menos de $20» |
| Por encima, **pide el código** | «Por más, me va a pedir el código. Y yo se lo voy a decir» |
| El código es **fijo y suyo** | «Yo voy a tener un código de compra que voy a tener que darle a la aplicación» |
| El código se **caza y se sustituye por X** | «Ese pedazo donde digo el código, lo vas a estar cazando. Por si aparece el código, simplemente lo sustituyas en la conversación como X» |
| El tope diario **existe como campo, vacío por defecto** | «No le pongas número, pero sí pon para poner un número. Por defecto va vacío» |

### 8.2 El importe no lo puede afirmar la página

La puerta vive debajo del modelo, pero **su disparador no**. Si el total de 20 $
lo afirma el comercio y el modelo lo repite, una página que mienta —«total: 5 €»—
convierte una compra de 500 en una compra autónoma. Y la sección 7.3 ya cuenta la
inyección de prompt desde la página como amenaza real.

**Decisión mía:** el importe que decide la puerta lo extrae **la app**, con un
parseador determinista sobre el texto de la página de pago, **no el modelo**. Y:

- Si la extracción **falla o es ambigua** → se pide el código, pase lo que pase.
- Si el importe extraído y el que el modelo dice **no coinciden** → se pide el
  código, y el aviso va al usuario.

Falla cerrado en los dos casos. Lo que el umbral **no** puede hacer es protegerte
de un comercio que te cobre más de lo que muestra: eso lo detiene el límite de la
tarjeta o el banco, no esta app, y conviene no pretender lo contrario.

### 8.3 El código fijo: qué gana, qué pierde, y las tres reglas

El usuario eligió un código fijo sobre el aleatorio por compra que se había
decidido antes. Se le dijo el coste y lo mantuvo, así que se construye lo que
pidió; el coste queda registrado para que la decisión siga siendo informada.

**Gana sobre un «sí» suelto, y es mucho:** prueba que es *él*, y no se dispara por
una frase casual —su propia preocupación—.

**Pierde contra el aleatorio:** se puede **reusar** (quien lo oiga una vez lo
tiene siempre), y **no se ata a una compra concreta** (con dos autorizaciones en
cola, abre la que esté preguntando).

**Las tres reglas, mías, y sin ellas el diseño no vale:**

1. **El turno del código no se guarda en ninguna parte.** Ni transcripción, ni
   resumen, ni memoria, ni log, ni telemetría. El verificador consume el texto y
   lo tira.
2. **Se guarda como hash en el Llavero.** Irrecuperable: solo se puede comprobar
   un candidato.
3. **Tres fallos y se bloquea.** Se desbloquea a mano en Settings.

**Formato — decisión del usuario:** **exactamente cuatro dígitos**, que él
configura en la app. Textual: «es un código de cuatro dígitos, el cual va a estar
configurado en la aplicación, por lo que el cazador va a saber qué buscar
exactamente en el texto».

Que lo configure él cambia el cazador a mejor: el cazador **sabe qué busca**. No
tiene que adivinar qué parte de una frase es un código, que era el punto frágil
del diseño anterior. Extrae cada secuencia de cuatro dígitos del texto, la hashea
y la compara con el hash del Llavero. Una coincidencia se sustituye por `X`.

**La cautela honesta sobre el hash, y es importante:** cuatro dígitos son diez
mil posibilidades. Un hash rápido de un espacio de diez mil se agota en
microsegundos, así que el hash **no** protege el código de quien ya pueda leer el
elemento del Llavero. Lo que sí protege, y es lo que se compra con él: que el
código no quede en claro en un fichero de configuración, en una copia de
seguridad, en un volcado de `UserDefaults` ni en una captura de la pantalla de
Settings.

**Para que el agotamiento no sea gratis, el hash lleva sal y una derivación
lenta** (PBKDF2 o scrypt, con un coste calibrado a unos 100 ms por intento en el
Mac del usuario). Diez mil intentos a 100 ms son unos dieciséis minutos, que no
es seguridad pero sí es un tope de velocidad real frente a un script. El coste se
paga una vez por verificación y por cada candidato que el cazador extrae, así que
el plan debe medirlo: un turno con muchos números no puede volverse lento. Si la
medición dice que sí, el cazador cachea el resultado por candidato dentro del
turno.

**Daño colateral del cazador, aceptado:** cualquier secuencia de cuatro dígitos
que coincida con el código se tapa, venga de donde venga. Si el código es `2026`,
la fecha `2026` también se tapa. Es molesto y es la dirección correcta del error:
tapar de más no abre ninguna puerta, tapar de menos sí. Se documenta en Settings
con una línea para que el usuario no elija un número que escriba todos los días.

### 8.4 El cazador: dónde va, y qué camino de voz lo hace posible

**Decisión del usuario, que cambia este apartado entero.** Se le planteó que decir
el código por voz exigía construir reconocimiento en el dispositivo en el Mac, y
respondió que no hace falta: el audio del código **puede ir a un servicio de STT
en la nube**, porque es un código que solo usa él con su gente. Lo que **no**
acepta es que el código se mezcle con la memoria. Textual: «no me importa que ese
código vaya a Internet… pero sí necesito que no se mezcle con los datos en la
memoria, por eso tiene que estar entre el STT y el transcribe que usa el modelo y
la memoria». Y quiere **los dos caminos**: decirlo o escribirlo.

Eso convierte el requisito en uno solo, y muy preciso:

> El cazador va **inmediatamente después del STT y antes del primer consumidor
> del texto**. Antes del modelo, del `TranscriptStore`, de los resúmenes, de la
> consolidación y de cualquier log. Si va después de alguno, el código ya se
> filtró en el que se saltó.

El reconocimiento puede estar donde sea. Lo que importa es **en qué máquina
existe el texto por primera vez**, porque el cazador tiene que correr ahí.

#### Los tres caminos de voz, y dónde nace el texto en cada uno

Verificado leyendo el código y las specs del repo:

| Camino | Estado hoy | Dónde existe el texto primero | ¿Cabe el cazador antes del modelo? |
|---|---|---|---|
| `POST /v1/voice/turn` | **es lo que hay** | dentro del i3, y el i3 ya llamó al agente | **no** |
| Scribe por lotes en el i3 (plan `docs/superpowers/plans/2026-06-09-elevenlabs-stt.md`) | plan escrito, sin implementar | dentro del i3, igual | **no** |
| Realtime STT fase 1 (spec `docs/superpowers/specs/2026-06-10-realtime-stt-phase1-design.md`) | spec aprobada, sin plan | **en la app**, antes de llamar al agente | **sí** |

El primero es el que está vivo, y es el que no sirve. `VoiceClient.turn` sube el
WAV a `POST /v1/voice/turn` y recibe audio de vuelta más las cabeceras
`X-STT-Text` y `X-Reply-Text`: el i3 hace STT, llama al agente y sintetiza, todo
en la misma petición. Cuando la app ve el texto, el modelo ya lo leyó y el
`TranscriptStore` del i3 ya pudo guardarlo. **No hay punto de inserción en la
app.** Cambiar el motor de STT a Scribe no lo mueve: el motor cambia dentro del
i3 y el orden sigue siendo el mismo.

El tercero sí sirve, y gratis. La spec de realtime fase 1 ya decide que **la app
abre el websocket directamente contra ElevenLabs** y que el agente y el TTS se
invocan después, **con texto**. Es decir: el transcrito nace en la app, antes del
agente. El cazador es entonces código de la app, en el camino entre el
`committed_transcript` del websocket y la llamada al agente. Eso es exactamente
lo que el usuario pidió, y no hace falta inventar nada para conseguirlo.

#### Lo que este sub-proyecto construye

**Escribir el código funciona desde el primer día, y es el camino obligatorio de
todas formas.** El usuario quiere los dos caminos, y el de teclado es además el
degradado del de voz: cuando el STT no está disponible, falla a teclear. Se
construye aquí, completo, con el cazador aplicado al texto del chat.

**Para el camino de voz, dos opciones, y la decisión es de secuencia, no de
diseño:**

- **(A) Esperar a realtime STT fase 1.** Coste para este sub-proyecto: cero. El
  cazador se escribe una vez, en la app, y se engancha al transcrito cuando ese
  camino exista. Es la opción limpia si el usuario va a construir realtime de
  todas formas, que es lo que la spec de junio dice.
- **(B) Un endpoint de solo transcripción en el i3**, si quiere voz antes.
  `POST /v1/voice/transcribe`: recibe el WAV, corre el STT, **devuelve el texto y
  nada más** — no llama al agente, no toca el `TranscriptStore`, no escribe log
  del cuerpo ni del resultado. El modal del código usa ese endpoint en vez de
  `/v1/voice/turn`, y el cazador corre en la app sobre la respuesta. Es una
  adición pequeña a `gemma-memory/voice/app.py`, que ya tiene el motor de STT
  separado detrás del protocolo `STTEngine`.

**Recomendación mía:** construir el camino de teclado ahora y (A) después, porque
(B) añade un endpoint que realtime fase 1 vuelve redundante. Si el usuario quiere
voz ya, (B) es correcto y pequeño.

**Regla que vale para los dos caminos y que el plan no puede ablandar:** el modal
del código **nunca** usa `POST /v1/voice/turn`. Ese endpoint lleva el texto al
agente por construcción, y el modal no puede permitírselo.

#### Las tres propiedades del cazador

**(a) Caza en todos los turnos, no solo en el modal.** Si el usuario dice o
escribe el código un martes cualquiera, también se tapa. Un cazador que solo mira
dentro del modal deja pasar el caso del despiste, que es justo cuando hace falta.
Esto es posible porque el código lo configura él: el cazador tiene algo concreto
que buscar en todo momento.

**(b) Funciona contra el hash, nunca contra el valor.** Extrae cada secuencia de
cuatro dígitos, la deriva con la sal del Llavero y compara. El código no sale del
Llavero ni para redactar.

**(c) Normaliza números dichos en palabras.** «Cuatro seis cinco cinco» es una
transcripción normal de 4655, y un servicio de STT en la nube la devuelve así con
frecuencia. Sin normalizar, **el código dicho en palabras pasa limpio** y las
tres reglas de 8.3 no sirven. Hay que cubrir las dos formas del español: cifra a
cifra («cuatro seis cinco cinco») y como cantidad («cuatro mil seiscientos
cincuenta y cinco»), y la mezcla de las dos, que es como habla la gente.

El camino felíz —el usuario escribe `4655` en el chat— nunca ejercita (b) ni (c).
Son tests obligatorios.

### 8.5 El tope diario, y el grifo que queda abierto

Como lo pidió: **campo en Settings, vacío por defecto, sin tope.**

Y se registra lo que significa, porque se le dijo y lo mantuvo: **vacío, más
«menos de 20 ella sola», es un grifo abierto.** Diez compras de 19 son 190 sin
que pregunte una vez. El umbral de 20 no protege de la repetición; solo el tope
diario lo hace.

**Mitigación mía:** cada compra autónoma deja **línea en el chat y notificación
del sistema**. No frena el grifo. Impide que pase callada.

**Y Settings lo dice donde el usuario lo lea**, junto al campo vacío: «sin tope:
el agente puede repetir compras por debajo del umbral». Un campo vacío que no
explica lo que implica es una trampa para el yo del futuro. El usuario confirmó
el campo inerte sabiendo esto (ver 10.2).

El tope, cuando el usuario ponga un número, se hace cumplir **al acuñar el
permiso de gasto**, no en el prompt. Y necesita saber lo gastado hoy, que es el
peldaño 4 de los recibos. **Sin registro de compras, el tope diario no se puede
hacer cumplir** — ver la sección 11.

### 8.6 La moneda — decisión mía por defecto

El usuario dijo «20 $» y los ejemplos han ido en euros. Un umbral en una moneda y
una compra en otra es ambiguo, y el error cae siempre del lado de comprar sin
preguntar.

**Por defecto, revocable:** el umbral y el tope se fijan en **una sola moneda**
que el usuario elige en Settings, y **cualquier compra en otra moneda pide el
código**, pase lo que pase con el importe. Falla cerrado. La alternativa
—convertir— exige un tipo de cambio en vivo, y uno equivocado abre la puerta.

### 8.7 La fuga por el panel de streaming se decide en el sub-proyecto 1

Ya está decidida allí y aquí no se repite: el panel va **en vivo también durante
el pago** (decisión explícita del usuario, para depurar), **los frames nunca se
escriben a disco**, el panel **suelta su último frame y se colapsa a una
etiqueta** al congelarse, y de los mensajes `command` se muestra **solo `action`,
nunca `params`**, para cualquier acción conocida o no.

Lo único que este sub-proyecto aporta: las filas de secreto van por el `batch` de
stdin, y el eco `command`/`result` del stream las verá igual. El filtro por acción
del panel ya lo cubre, pero el plan debe **comprobarlo con `inserttext`
concretamente**, porque es una acción que el panel no ha visto nunca.

---

## 9. Qué queda al constructor

1. **La forma del estado modal de autorización** y cómo encaja en el bucle de
   `Agent.run`, que ya tiene presupuesto diferenciado para navegador
   (`maxBrowserIterations = 10`). Una autorización que espera al usuario no es una
   iteración de herramienta.
2. **Dónde vive la cartera** y su interfaz con el Llavero. No negociable: el
   modelo solo recibe nombre y cuatro últimos.
3. **El parseador determinista del importe** de la sección 8.2, y qué considera
   ambiguo.
4. **El vocabulario restante de categorías de acción.** Confirmadas: `navigate`,
   `click`, `fill`, `screenshot`, `download`. Descartadas: `eval`, `cookies`.
   Faltan: `type`, `press`, `upload`, `pdf`, `dialog`, `network`, `auth`, `state`.
   Se prueban una a una con el método del recon.
5. **La forma exacta del redactor de `snapshot`** de la vía 4, y cómo se autoriza
   un `browser_get value` campo a campo.
6. **Cómo se renderiza el campo secreto** y cómo se sustituye por el resumen.
7. **El punto de enganche del cazador en el camino de voz**, según la opción de
   secuencia que el usuario elija en 10.1: el `committed_transcript` del
   websocket de realtime STT fase 1, o la respuesta de un endpoint de solo
   transcripción en el i3. El cazador se escribe una vez y recibe texto; lo que
   el constructor decide es de dónde le llega ese texto, y que **nunca** llegue
   de `POST /v1/voice/turn`.
8. **La calibración de la derivación lenta del código** (8.3): el coste por
   intento, medido en el Mac del usuario, y el cacheo por candidato dentro del
   turno si la medición dice que un turno con muchos números se vuelve lento.

### Clases de entrada que el plan debe cubrir con tests

Cada una es una forma de que esto falle abierto, y ninguna la toca el camino
felíz:

- La política tiene la forma equivocada → **la prueba de humo lo detecta y la
  compra se aborta**. Sin esto, toda la contención es decorativa.
- Una categoría de `--confirm-actions` mal escrita → la prueba de humo lo detecta.
- Un secreto se rellena → **no aparece en `argv`** (comprobable listando los
  argumentos del hijo), **ni en el eco del comando**, **ni en el `result`**, **ni
  en el siguiente `snapshot`**. Cuatro tests, uno por vía.
- `keyboard type` **no se usa nunca** para un secreto. Test que falla si alguien
  lo reintroduce.
- Un campo dentro de un **iframe cross-origin** recibe el valor. Prueba en vivo,
  contra la página real de Stripe del usuario.
- El usuario dice el código **fuera** del modal → se sustituye por `X` igual.
- El usuario dice el código **en palabras** → se normaliza, se caza, se sustituye.
- Un turno con el código **no deja rastro** en `TranscriptStore`, resúmenes,
  memoria ni logs. Es un test de ausencia y se escribe como tal.
- El STT **no está disponible** → el modal pide **teclear**. El camino de teclado
  es el degradado, y existe siempre.
- El modal del código **nunca** llama a `POST /v1/voice/turn`. Test que falla si
  alguien lo cablea ahí, porque ese endpoint lleva el texto al agente por
  construcción.
- El cazador corre **antes** del primer consumidor del texto. Test de orden: con
  un doble del agente, de la memoria y del log, ninguno ve el código, y los tres
  ven la `X`.
- Tres códigos mal → bloqueado, y el cuarto correcto **no** compra.
- `confirmation_required` y nadie confirma → **a los 60 s el CLI auto-deniega** y
  el agente lo reporta como **no comprado**, no como comprado.
- El importe extraído por la app y el que dice el modelo **no coinciden** → pide
  el código.
- Una compra en otra moneda que la del umbral → pide el código.
- El modelo intenta rellenar un campo secreto con un literal → **no hay
  herramienta**; la llamada falla.
- El modelo pide una referencia de tarjeta inexistente → error, **no** un relleno
  silencioso con otra tarjeta.

---

## 10. Las tres decisiones del usuario sobre este documento

Las tres preguntas que este documento le hizo, con su respuesta y lo que cada una
obliga.

### 10.1 El código: voz y teclado, con el cazador justo después del STT

**Respondió:** el audio del código puede ir a un servicio de STT en la nube —no le
importa que ese código viaje a Internet, porque solo lo usa él con su gente— pero
**no puede mezclarse con los datos de la memoria**, así que el cazador tiene que
estar **entre el STT y el transcrito que usan el modelo y la memoria**. Y quiere
**los dos caminos**: decirlo o escribirlo.

**Obliga:** lo de la sección 8.4. Se construye el camino de teclado completo, que
es además el degradado del de voz. El camino de voz necesita que el transcrito
nazca en la app, lo que el camino actual (`POST /v1/voice/turn`) no da y realtime
STT fase 1 sí. La decisión que queda es de secuencia: esperar a realtime, o añadir
un endpoint de solo transcripción al i3 para tener voz antes.

**Lo que esta respuesta cancela:** ya no hace falta implementar la rama de macOS
de `SpeechDictationManager` con reconocimiento en el dispositivo. Era la salida
que el documento proponía cuando se creía que el audio no podía salir del Mac.

### 10.2 El tope diario: campo inerte por ahora

**Respondió:** campo inerte por ahora.

**Obliga:** el campo existe en Settings y por defecto va vacío, como pidió antes,
pero **no se hace cumplir** en este sub-proyecto. Lo que sí funciona desde el
primer día es el **umbral por compra** —por debajo decide ella, por encima pide el
código—, que no necesita saber lo gastado hoy.

**Y el grifo de 8.5 queda abierto, dicho sin suavizar:** umbral vacío más «menos
de 20 ella sola» significa que diez compras de 19 pasan sin preguntar una vez. La
mitigación de 8.5 —línea en el chat y notificación del sistema por cada compra
autónoma— no cierra el grifo; solo impide que corra callado. El cierre llega con
el peldaño 4 de los recibos, en el sub-proyecto 4.

**Settings debe decirlo donde el usuario lo lea**, junto al campo vacío: «sin
tope: el agente puede repetir compras por debajo del umbral». Un campo vacío que
no explica lo que implica es una trampa para el yo del futuro.

### 10.3 El formato: exactamente cuatro dígitos, configurados en la app

**Respondió:** cuatro dígitos, configurados en la aplicación, «por lo que el
cazador va a saber qué buscar exactamente en el texto».

**Obliga:** lo de la sección 8.3. El cazador compara contra algo concreto en vez
de adivinar, que es más fuerte; en cambio cuatro dígitos son diez mil
posibilidades, así que el hash necesita sal y derivación lenta para que agotarlo
no sea gratis, y el daño colateral —tapar un `2026` que no era el código— se
acepta porque falla del lado seguro.

## 11. Dependencias

- **El panel de streaming va primero**, por orden del usuario.
- **Acoplamiento no evitable con los recibos**: el tope diario necesita el
  peldaño 4. Ver la decisión 2 de la sección 10.
- **Arrastra un defecto abierto de `main`** que importa aquí más que en ningún
  otro sitio: `e2f9e86` reintrodujo `save_memory` en el prompt del turno vivo. Un
  turno vivo que escribe memoria es exactamente el camino por el que el código de
  compra acabaría recordado. Está en
  `docs/superpowers/notes/2026-11-06-defectos-preexistentes-en-main.md`.
  **Conviene arreglarlo antes de construir el cazador, no después.**
- **El pivote de arquitectura queda aparcado.** El usuario planteó sacar el
  cerebro de la app a un proceso propio que corra en Linux o Windows. Este diseño
  se apoya en el **Llavero de macOS**, que no existe fuera de Apple. Si el pivote
  se hace, esa pieza se queda en el dispositivo como proveedora de capacidad y el
  cerebro la llama; el resto del diseño no cambia. No se diseña aquí.

  La decisión 10.1 **quitó la otra dependencia de Apple que este documento tenía**:
  ya no hace falta `SFSpeechRecognizer`, porque el STT puede ser un servicio de
  red. Eso deja el diseño del código de compra casi portable, lo que juega a favor
  del pivote.
