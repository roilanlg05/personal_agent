# Formularios generativos y secretos del agente — diseño

Fecha: 2026-11-11. Estado: BORRADOR para aprobación del usuario. Sustituye, en el proyecto 2 de la
serie, al mando compartido del navegador (subsistema B), que se elimina en el proyecto 3.

## Para qué sirve

El agente necesita pedirle cosas al usuario que no pueden ir por el chat: contraseñas, códigos,
datos de pago, y también cosas que no son secretas pero se piden mejor con una pantalla que con
una frase (elegir una opción, confirmar una compra, rellenar varios datos a la vez). Hoy la única
forma de que el usuario teclee una contraseña es "tomar el volante" del navegador remoto, que se
construyó en nueve rondas de revisión y que el usuario ya no quiere ("lo mismo para ambos, Chromes
reales con sesión"; el control remoto se elimina de raíz).

Este diseño pone en su lugar dos piezas:

1. **Un módulo de interfaz generativa**: el agente describe un formulario (campos de varios tipos,
   uno o muchos a la vez) y la app lo dibuja nativo dentro del chat, en iOS y en macOS. La
   respuesta vuelve al agente.
2. **Una bóveda de secretos**: los campos marcados como secretos se guardan en el Keychain del
   aparato con un NOMBRE, y el agente los usa por nombre —`browser_fill_secret(ref, "gmail_password")`—
   sin que el valor pase nunca por el modelo.

## Metas

- El agente puede mostrar un formulario con 1..N campos de tipos mezclados y recibir las respuestas.
- Un secreto se escribe una vez, se guarda con nombre, y el agente lo puede teclear en una página sin
  verlo. El valor no aparece en el contexto del modelo, en las herramientas, en el transcript, en la
  memoria a largo plazo, en los logs ni en los resúmenes.
- Funciona igual en iOS y en macOS (la misma vista SwiftUI).
- Sirve de base para la **puerta de compra** (un campo de tipo confirmación) sin construir otra cosa.

## No metas

- No es un sistema de plantillas web ni renderiza HTML del modelo: el agente manda datos (un
  esquema), no vistas.
- No sincroniza secretos entre aparatos (cada aparato tiene su Keychain). Ver "Qué queda al
  constructor".
- No sustituye al gestor de contraseñas del usuario ni autocompleta nada por su cuenta.
- No resuelve CAPTCHA ni segundo factor automático: el código del teléfono lo escribe el usuario en
  un formulario.

## Antimetas (lo que lo haría fracasar aunque compile)

- Que el valor de un secreto llegue al modelo por cualquier camino (resultado de herramienta, snapshot
  de la página, mensaje de error, eco del formulario).
- Que una página maliciosa o una inyección de prompt consiga que el agente teclee un secreto en un
  sitio que no es el suyo.
- Que un formulario sin respuesta deje el turno colgado para siempre.

## Esquema del formulario (lo que manda el agente)

`present_form(title, description?, submit_label?, fields[])`. Cada campo:

| clave | tipo | notas |
|---|---|---|
| `id` | texto | único dentro del formulario; es la clave de la respuesta |
| `label` | texto | lo que ve el usuario |
| `kind` | `text` `secret` `number` `choice` `multichoice` `confirm` `date` | v1 |
| `required` | bool | por defecto `true` |
| `options` | lista de `{value,label}` | solo `choice`/`multichoice` |
| `secret_name` | texto | solo `secret`: nombre con el que se guarda (`^[a-z0-9_]{1,40}$`) |
| `placeholder`, `help` | texto | opcionales |

Respuesta al modelo: `{status: "submitted"|"cancelled"|"timeout", values: {id: valor}}`. Para un campo
`secret` el valor es el literal `"[secreto guardado: <secret_name>]"`, nunca el contenido.

## Piezas

- `FormSpec` / `FormResponse` (tipos `Codable`, validación de esquema: ids únicos, nombres de secreto
  válidos, `options` obligatorias donde toca, tope de 12 campos).
- `FormBroker` (actor): `presenta(spec) async -> FormResponse`. Guarda una continuación por formulario,
  publica el formulario pendiente a la interfaz y la reanuda al enviar, cancelar o caducar. Un solo
  formulario abierto por turno; plazo de 10 minutos (decisión mía, ajustable).
- `FormCardView` (SwiftUI, compartida): tarjeta dentro del chat. `SecureField` para los `secret`.
  Nuevo `role == "form"` en `ChatLogEntry`. Al enviar, la tarjeta queda como "enviado" sin valores.
- `SecretVault`: Keychain por aparato, servicio propio, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
  API: `guarda(name, value, origen)`, `valor(name)`, `lista() -> [(name, label, origen)]`,
  `borra(name)`. El `origen` es el host de la página donde se pidió.
- Herramientas del agente: `present_form`, `list_secrets` (solo nombre/etiqueta/origen),
  `browser_fill_secret(ref, secret)`, `forget_secret(name)`.
- `Redactor`: antes de devolver CUALQUIER resultado de herramienta al modelo, sustituye las apariciones
  literales de los valores de la bóveda por `[secreto: nombre]`.

## Reglas de seguridad

1. **Atadura al origen.** `browser_fill_secret` solo teclea si el host de la página actual coincide con
   el `origen` guardado con el secreto (o un subdominio suyo). Si no, falla con un mensaje al modelo
   ("ese secreto pertenece a accounts.google.com"). Es la defensa contra la inyección de prompt:
   una página no puede hacer que el agente teclee la contraseña de Gmail en otro sitio.
2. **El valor solo sale del Keychain en el instante de teclear**, dentro de la herramienta, y no se
   guarda en ninguna variable que sobreviva a la llamada.
3. **Transcript y memoria**: la respuesta del formulario NO se archiva como mensaje del usuario. Solo
   se archiva el resumen "el usuario envió el formulario «título»" sin valores.
4. **Redacción de resultados**: ver `Redactor`. Cubre el valor literal; no cubre codificaciones
   (base64, partido en trozos). Hueco declarado.
5. **Argumentos del proceso.** `agent-browser fill <selector> <texto>` recibe el texto por argv, sin
   opción de entrada estándar (comprobado el 2026-11-11). El valor es visible en la lista de procesos
   del mismo usuario durante la llamada. Hueco declarado; lo cierra investigar si `agent-browser`
   ofrece `batch`/stdin, o teclear por CDP directamente.
6. El valor viaja de la app al servicio del navegador (cuando es remoto) en el cuerpo de una petición
   autenticada por token, dentro de Tailscale. No hay registro de cuerpos.

## Flujo de ejemplo

1. El agente abre `accounts.google.com` y ve un campo de contraseña.
2. Llama a `present_form` con un campo `secret` (`secret_name: "gmail_password"`). El host actual
   (`accounts.google.com`) se registra como `origen`.
3. El usuario escribe y envía. La bóveda guarda el valor. El modelo recibe
   `{status: submitted, values: {pw: "[secreto guardado: gmail_password]"}}`.
4. El agente llama a `browser_fill_secret("@e4", "gmail_password")`. La app comprueba el origen, teclea
   y devuelve "campo rellenado".
5. En otra sesión, `list_secrets` le dice que `gmail_password` existe y es de `accounts.google.com`: no
   vuelve a pedirla.

## Qué queda al constructor

- Cómo se dibuja la tarjeta (estilo, accesibilidad, teclado de iOS y de macOS).
- El orden de campos y la validación de `number`/`date` en la interfaz.
- Si `forget_secret` pide confirmación (mi inclinación: sí, con un `confirm`).
- Compartir secretos entre el iPhone y la Mac: **fuera de v1**. Con el agente corriendo en el iPhone y
  el secreto guardado en la Mac, hay que decidir si se escribe dos veces o se sincroniza por iCloud
  Keychain. Hasta entonces: un secreto vive donde se escribió.

## Decisiones mías que hay que revisar

- Plazo del formulario: 10 minutos.
- Un formulario abierto por turno.
- Atadura al origen obligatoria (el usuario no lo pidió, lo añado por seguridad).
- `kind` limitado a siete tipos en v1.
- El transcript no guarda los valores ni los de campos no secretos (más simple y más seguro).
