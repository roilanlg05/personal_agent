# Recon: contención de dominio y puerta de compra en agent-browser 0.41.2

**Fecha:** 2026-11-06
**Binario:** `/opt/homebrew/bin/agent-browser` → `agent-browser-darwin-arm64`, versión 0.41.2
**Motivo:** el conflicto `--allowed-domains` vs `state load` dejaba la spec de compras
bloqueada. Se buscaba un tercer camino.

Todo lo de aquí está **probado contra el binario instalado**, no leído de documentación.
Los demonios de prueba se cerraron y los restos se borraron.

---

## 1. El conflicto, confirmado y con su razón exacta

```
$ agent-browser --session probe1 --allowed-domains "example.com" --restore open about:blank --json
{"error":"--allowed-domains is not supported with --restore because saved state can
replay origins before agent-browser can verify they are in the allowlist","success":false}
```

La razón es concreta y no es un capricho: **el fichero de estado contiene orígenes**, y
cargarlo siembra cookies y `localStorage` para esos orígenes antes de que la lista blanca
pueda comprobarlos.

`trust-boundaries.md` del propio CLI lo amplía. `--allowed-domains` rechaza:

- sesiones CDP preexistentes
- auto-connect
- perfiles de Chrome
- plugins de proveedor de página directa
- **restauración de agent-browser y repetición de ficheros de estado**
- argumentos crudos de Chrome que seleccionen perfiles, restauren sesiones o abran páginas de inicio
- iOS y Safari

Y lo que sí hace cuando se puede usar: bloquea HTTP no permitido, WebSocket, EventSource y
`sendBeacon`; desactiva `RTCPeerConnection` (STUN/TURN y su DNS no pasan por la
interceptación HTTP de CDP); envuelve los workers dedicados y compartidos con un bootstrap
que **falla cerrado** si la CSP de la página prohíbe el wrapper; y en un Chrome lanzado
localmente desactiva además el UDP de WebRTC no proxificado.

El propio documento dice que esto es **contención a nivel de navegador** y recomienda
combinarla con control de salida del host o del contenedor cuando se quiera una frontera de
seguridad del sistema operativo.

---

## 2. El tercer camino existe: `--action-policy`

**`--action-policy` NO entra en conflicto con el estado persistente.** Probado:

```
$ agent-browser --session probe4 --action-policy /tmp/policy.json --restore open about:blank --json
{"success":true,"data":{"lifecycle":{...,"restoreStatus":"missing",...}},"error":null}
```

No hay rechazo. `restoreStatus: "missing"` solo porque no existía fichero de estado en esa
prueba; lo que importa es que la combinación se acepta.

Esto desbloquea la spec de compras: **sesión de Amazon ya iniciada Y contención, a la vez**,
con la contención aplicada sobre acciones en vez de sobre dominios.

### El esquema, averiguado empíricamente

La documentación no lo da. Se dedujo probando.

**El esquema real es una lista de denegación plana:**

```json
{"deny": ["navigate", "click", "fill", "screenshot", "download"]}
```

Probado:

```
$ echo '{"deny":["navigate"]}' > deny2.json
$ agent-browser --action-policy deny2.json open about:blank --json
{"success":false,"data":null,"error":"Action 'navigate' denied by policy: Action 'navigate' is denied by policy"}
```

### Categorías que el motor reconoce

| Categoría | ¿La reconoce? | Prueba |
|---|---|---|
| `navigate` | **sí** | `open about:blank` → denegado |
| `click` | **sí** | `click "#no-existe"` → denegado |
| `fill` | **sí** | `fill "#no-existe" x` → denegado |
| `screenshot` | **sí** | `screenshot s.png` → denegado |
| `download` | **sí** | `download "#no-existe" x.pdf` → denegado |
| `eval` | **NO** | `eval "1+1"` → devolvió `result: 2`, se ejecutó |
| `cookies` | **NO** | `cookies list` → devolvió la lista |

**`click` se deniega ANTES de resolver el selector.** El error llega sin que el CLI haya
buscado `#no-existe` en la página. La política es por tanto una puerta real previa a la
ejecución, no un filtro posterior.

**`eval` no se puede denegar con la política.** Es el comando más peligroso del CLI y
queda fuera del vocabulario que probé. Si hace falta cerrarlo, hay que hacerlo en nuestro
lado: no registrar la herramienta, o filtrarla en el invocador.

### Tres trampas que hay que programar en nuestro lado

Las tres se verificaron.

**(a) Fichero de política ausente → FALLA CERRADO.** Bien.

```
$ agent-browser --action-policy /ruta/NO_EXISTE.json open about:blank --json
{"success":false,"data":null,
 "error":"Action 'navigate' denied by policy: action policy failed to load:
          Failed to read policy file: No such file or directory (os error 2)"}
```

**(b) JSON inválido → FALLA CERRADO.** Bien.

```
$ echo 'no soy json' > garbage.json
$ agent-browser --action-policy garbage.json open about:blank --json
{"success":false,...,"error":"...Invalid policy JSON: expected ident at line 1 column 2..."}
```

**(c) JSON válido con la FORMA EQUIVOCADA → FALLA ABIERTO. Esta es la grave.**

```
$ echo '{"version":1,"rules":[{"action":"navigate","effect":"deny"}]}' > bad.json
$ agent-browser --action-policy bad.json open about:blank --json
{"success":true,...}      ← navegó. La política se ignoró en silencio.
```

Una política con una clave mal escrita, una categoría mal escrita, o una estructura
anidada que el CLI no entiende, **no da ningún aviso y deja pasar todo**. No hay
validación de esquema ni de vocabulario.

Consecuencia para el diseño: **la app tiene que validar su propio fichero de política
antes de confiar en él.** Como mínimo:

1. Escribir la política con `{"deny": [...]}` y nada más.
2. Al arrancar la sesión, hacer una prueba de humo: pedir una acción que la política
   debe denegar y comprobar que devuelve `denied by policy`. Si pasa, la contención no
   está puesta y hay que abortar.
3. No aceptar nunca una política escrita por el modelo.

---

## 3. Hallazgo mayor: el CLI trae una puerta de confirmación nativa

Esto cambia el diseño de la puerta de compra, y a mejor.

De la ayuda del binario:

```
agent-browser confirm/deny - Approve or deny pending actions

Usage:
  agent-browser confirm <confirmation-id>
  agent-browser deny <confirmation-id>

When --confirm-actions is set, certain action categories return a
confirmation_required response with a confirmation ID. Use confirm/deny
to approve or reject the action.

Pending confirmations auto-deny after 60 seconds.
```

Lo que significa:

- Con `--confirm-actions click`, un `click` **no se ejecuta**: devuelve
  `confirmation_required` y un identificador.
- La acción solo ocurre si alguien llama `agent-browser confirm <id>`.
- **Se auto-deniega a los 60 segundos.** Falla cerrado por diseño, sin que lo programemos.

**Por qué esto es más fuerte que un modal en la app:** el punto de aplicación queda
*por debajo* del modelo. Con un modal nuestro, el modelo pide, la app pregunta, la app
ejecuta — y la garantía depende de que nuestro código no tenga un camino alternativo.
Con `--confirm-actions`, el clic en «Pagar» **no puede ocurrir** sin un `confirm`
explícito, venga de donde venga la petición. Un modelo confundido, o una inyección de
prompt desde la propia página, no tiene cómo saltárselo.

El código de compra hablado se convierte entonces en lo que acuña el `confirm`: la app
verifica el código y solo entonces llama `agent-browser confirm <id>`.

### Trampa verificada en `--confirm-actions`

**Una categoría desconocida se acepta en silencio y no confirma nada.**

```
$ agent-browser --session probe2 --confirm-actions "zzz_no_existe" open about:blank --json
{"success":true,"data":{...,"launched":true,...},"error":null}
```

Ni aviso ni error. Si escribimos mal el nombre de la categoría, la puerta simplemente
no existe y nada lo dice. Misma disciplina que con la política: **prueba de humo al
arrancar la sesión** — provocar una acción que debe pedir confirmación y comprobar que
devuelve `confirmation_required`. Si no lo devuelve, abortar.

---

## 4. Dos hallazgos laterales que sirven

**(a) El fichero de estado se puede cifrar, y de serie.**

```
State Encryption:
  Set AGENT_BROWSER_ENCRYPTION_KEY (64-char hex) for AES-256-GCM encryption.
  Generate a key: openssl rand -hex 32
```

El registro de decisiones ya dice que «el fichero de estado es un secreto». Esto lo
resuelve sin inventar nada: la clave al Llavero, la variable al entorno del demonio.

**(b) `auth login` ya implementa el modelo referencia-no-valor que el usuario quiere para
la tarjeta.**

```
Login Options:
  --credential-provider <p> Resolve credentials from configured plugin <p>
  --item <ref>              Provider-specific vault item reference
...
Login behavior:
  Plugin credentials are resolved just-in-time and are not saved locally.
```

El modelo nombra un `<ref>`; el valor se resuelve justo a tiempo y no se guarda. Es
exactamente la forma de `fill_secret(campo, referencia)` que ya estaba decidida, y
conviene mirar si el camino de la tarjeta puede reusar este mecanismo en vez de inventar
otro.

---

## 5. Qué decide esto, y qué sigue abierto

### Decidido por el recon

El conflicto `--allowed-domains` / `state load` **ya no bloquea la spec**. El camino es:

- Sesión persistente con `state load` / `--restore`, cifrada con
  `AGENT_BROWSER_ENCRYPTION_KEY`.
- Contención por `--action-policy` en vez de por dominio.
- Puerta de compra por `--confirm-actions`, que es un punto de aplicación por debajo del
  modelo y se auto-deniega a los 60 s.
- Contención de dominio real, si se quiere, a nivel de sistema operativo, que es lo que
  el propio `trust-boundaries.md` recomienda.

### Abierto

1. **El vocabulario completo de categorías.** Confirmadas: `navigate`, `click`, `fill`,
   `screenshot`, `download`. Descartadas: `eval`, `cookies`. Faltan por probar: `type`,
   `press`, `upload`, `pdf`, `dialog`, `network`, `auth`, `state`. Se prueban una a una
   con el método de arriba cuando se escriba la spec.
2. **`eval` no es denegable por política.** Hay que cerrarlo en nuestro lado.
3. **Perder `--allowed-domains` tiene un coste real:** sin él, la página del comercio sí
   puede abrir WebSocket, EventSource y `sendBeacon` a donde quiera. La política de
   acciones controla lo que *nosotros* hacemos, no lo que la página hace por su cuenta.
   Si eso importa, la respuesta es control de salida en el host, no el CLI.
