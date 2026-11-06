# Compras online — registro de decisiones

**Estado: NO es una spec aprobada.** Es el registro de las decisiones que el
usuario ya ha tomado sobre la compra online y el panel de streaming, más las
restricciones verificadas del CLI, para que no se pierdan antes de escribir la
spec. Cada decisión lleva quién la tomó. Lo que yo decido va marcado como mío y
el usuario puede revocarlo.

---

## 1. Recibos — escalera de captura

**Decisión del usuario (2026-11-06):** si hay posibilidad de descargar el
recibo, se descarga. Si no la hay, se tira captura de pantalla. Textual: «si
completa la compra y dan la posibilidad de descargar el recibo, se hace. Si no,
se tira captura de pantalla. O como lo tengas pensado.»

**Mi diseño, que amplía esa decisión en cuatro peldaños** (el usuario invitó
explícitamente a proponer). La escalera baja solo cuando el peldaño de arriba
no está disponible, y **siempre** se hace el peldaño 4, pase lo que pase en los
otros tres:

### Peldaño 1 — el fichero real del comercio

`agent-browser download <selector> <ruta>` hace clic en el elemento que dispara
la descarga y guarda el fichero en la ruta que le damos. Verificado en el
binario 0.41.2; acepta `@eN` además de selector CSS, así que el `snapshot` que
el agente ya tiene sirve para localizar el enlace.

```
agent-browser download "@e12" ~/Documents/Gemma/Recibos/2026-11-06-amazon-recibo.pdf
```

Es el peldaño preferido porque el fichero es el documento auténtico del
comercio: el que vale para una devolución, una garantía o la declaración.

### Peldaño 2 — PDF de la página de confirmación

`agent-browser pdf <ruta>` guarda la página actual como PDF. Verificado.

Este peldaño **no estaba en lo que pidió el usuario** y es mejor que la captura
por tres razones: coge la página entera y no solo lo que cabe en el viewport,
el texto queda seleccionable y buscable, y pesa menos que un PNG de página
completa. Para un billete de avión o una confirmación larga, la diferencia es
grande.

### Peldaño 3 — captura de pantalla

`agent-browser screenshot --full <ruta>` captura la página completa, no solo el
viewport. Verificado; acepta `--screenshot-format jpeg` y
`--screenshot-quality`.

Último recurso: una página que se niega a imprimirse bien, o un comercio cuya
confirmación es un lienzo. Siempre con `--full`.

### Peldaño 4 — los datos, en memoria, siempre

Pase lo que pase con los tres peldaños de arriba, de la página de confirmación
se extraen y se guardan en la memoria del agente, como datos estructurados y no
como fichero:

- número de pedido o de confirmación
- total cobrado, con su moneda
- últimos cuatro dígitos de la tarjeta usada
- comercio y fecha
- qué se compró
- la ruta del fichero capturado, si alguno de los peldaños 1 a 3 funcionó

**El porqué:** un fichero en disco no responde «¿cuánto llevo gastado este
mes?» ni «¿qué compré en Amazon en octubre?». El fichero es la prueba; estos
datos son lo que hace que el agente pueda razonar sobre sus propias compras.
Y son lo único que sobrevive si el usuario mueve o borra el fichero.

Este peldaño es también el que alimenta el **tope de gasto diario**: sin un
registro de lo gastado, el tope por día no se puede hacer cumplir.

### Dónde van los ficheros

`~/Documents/Gemma/Recibos/`, con nombre `AAAA-MM-DD-<comercio>-<pedido>.<ext>`.

Verificado: **la app no está en sandbox** — no hay
`com.apple.security.app-sandbox` en `Gemma.entitlements` ni
`ENABLE_APP_SANDBOX` en el proyecto — así que puede escribir en `~/Documents` y
el demonio que la app lanza hereda ese acceso. Si algún día se activa el
sandbox, esto se rompe y habría que pasar a la carpeta contenedora o pedir
acceso con `com.apple.security.files.user-selected.read-write`.

`Documents` y no `Application Support` a propósito: un recibo es del usuario y
tiene que poder encontrarlo sin que yo le diga dónde. Los almacenes internos de
la app (`gemma_notes.json`, `gemma_places.json`) sí viven en Application
Support, y está bien que sigan ahí.

### Lo que el agente le dice al usuario

Tras la compra, el agente responde con: el pedido, el total, la tarjeta por sus
últimos cuatro, y **qué peldaño consiguió** — «te descargué el recibo original»,
«no había descarga, te guardé la confirmación en PDF», «solo pude hacer
captura». Eso no es un detalle de cortesía: le dice al usuario si tiene un
documento que sirve para una devolución o solo una foto.

Si los tres peldaños fallan, el agente lo dice tal cual y da los datos del
peldaño 4. **Nunca** dice que guardó un recibo que no guardó: aplica el mismo
contrato de honestidad de cinco estados que las nueve herramientas del
navegador.

### Riesgo que esto abre, y cómo se acota

Un recibo lleva datos personales: dirección de envío, los cuatro últimos
dígitos, a veces el nombre completo. El propio `trust-boundaries.md` del CLI
avisa de que capturas y vídeos pueden recoger secretos sin querer (campos
autorrellenados, tokens en la barra de direcciones).

Tres reglas, mías:

1. La captura se hace **solo en la página de confirmación**, nunca durante el
   checkout. En el checkout el número de tarjeta está en pantalla.
2. El fichero no se manda a ningún sitio. Se guarda en disco y en la memoria va
   la **ruta**, no el contenido.
3. Si el usuario pide el recibo por voz, el agente lee los datos del peldaño 4.
   No abre el fichero ni lo describe.

---

## 2. Streaming — restricciones verificadas que afectan a la compra

Del recon en vivo del binario (detalle completo en el fichero de recon del
streaming):

- Los frames del panel **pueden contener el número de tarjeta** mientras se
  teclea en el checkout. Decisión pendiente: o no persistir frames nunca, o
  pausar el stream durante la fase de pago, o ambas. Mi inclinación: ambas.
- El stream emite mensajes `command` y `result` indocumentados que hacen eco de
  cada comando ejecutado sobre la sesión, **con sus parámetros**. El `params` de
  un `fill` de secreto llegaría ahí. Hay que filtrar por acción antes de pintar
  o registrar nada.

## 3. Conflicto real del CLI que la spec de compras tiene que resolver

`--allowed-domains` (contención a nivel de navegador: bloquea HTTP no
permitido, WebSocket, EventSource, `sendBeacon`, y desactiva
`RTCPeerConnection`) **se rechaza** cuando también se usan: restauración de
agent-browser, repetición de ficheros de estado (`state load`), perfiles de
Chrome, sesiones CDP preexistentes y auto-connect. El CLI lo rechaza porque no
puede instalar contención equivalente antes de que corran los scripts de la
página.

Es decir: **sesión persistente y contención de dominio son mutuamente
excluyentes.** Para una compra en Amazon se quiere lo primero (seguir con la
sesión iniciada) y lo segundo (que el checkout no pueda salir del dominio del
comercio). Hay que elegir, o encontrar un tercer camino —por ejemplo, iniciar
sesión en una sesión con estado y hacer el pago en otra sin él, si el comercio
lo permite, que probablemente no.

Sin resolver. Va a la spec de compras como pregunta abierta.

## 4. Decisiones del usuario ya tomadas, que no se vuelven a preguntar

- **Confirmación hablada, no botón.** El usuario quiere decir «sí, cómpralo» en
  vez de pulsar algo.
- **Pero no se busca un «sí» dentro de su respuesta libre.** Corrección
  explícita del usuario: «si digo, si encuentras un precio más barato, no lo
  compras — ese "sí" dispararía esa orden de compra. Y ni siquiera podría el
  modelo negarse.» El diseño es un **código hablado aleatorio por compra**
  («confirmo cuatro-siete-dos»), un estado modal que no interpreta nada más, y
  **fallo cerrado**: cualquier cosa no reconocida, o dos minutos sin respuesta,
  cancela.
- **La puerta la hace cumplir la app, no el modelo.** Una promesa del modelo no
  es un control.
- **Topes por compra y por día**, forzados al acuñar el permiso de gasto.
- **Primer objetivo: el sitio de desarrolladores de su propia empresa**, con
  tarjetas de prueba de Stripe.
- **Las credenciales y la tarjeta no se pegan en el chat** — entran en un campo
  nativo de Settings. Las contraseñas van al almacén de autenticación del CLI
  vía `--password-stdin`; la tarjeta al Keychain de macOS, y se teclea con
  `eval --stdin` para que nunca aparezca en argv. El modelo nombra una
  **referencia** (`fill_secret(campo, referencia)`) y nunca ve el valor.
- **Vía oficial para la autenticación sin que el secreto pase por el modelo:**
  `cookies set --curl <fichero>`, que autodetecta formato JSON, cURL o cabecera
  `Cookie` cruda, y cuyos mensajes de error nunca hacen eco del valor.
  `state save` / `state load` persiste cookies y localStorage; **el fichero de
  estado es un secreto** con la misma disciplina que un fichero de cookies.

## 5. Orden de trabajo acordado

1. **Streaming** — el panel en el chat. El usuario lo puso primero, textual:
   «Quiero que el streaming sea lo primero que hagas.»
2. Manejo de secretos — Settings nativo, Keychain, `cookies set --curl`.
3. Puerta de compra — código hablado, modal, fallo cerrado, topes.
4. Recibos — la escalera de cuatro peldaños de este documento, contra el sitio
   de pruebas con Stripe.
