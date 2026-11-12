# El mando compartido, subsistema B: las interfaces — Plan de implementación

> **RETIRADO el 2026-11-12** por `docs/superpowers/plans/2026-11-12-quitar-el-mando.md`. El usuario: «elimina ese control manual de raíz, solo necesito streaming del navegador abierto en mi mac hacia la app, sin controlarlo». Se conserva como historia; nada de lo que describe sobre la entrada del usuario existe ya en el código. Lo rescatado del servidor está en `feat/chrome-de-verdad` (3f814b5) y lo demás en la etiqueta `archivo/mando-subsistema-a` del repo gemma-memory.

> **Para agentes:** SUB-SKILL OBLIGATORIA: usa superpowers:subagent-driven-development
> (elegida por el usuario) para implementar este plan tarea a tarea. Los pasos usan
> casillas (`- [ ]`) para seguir el avance.

**Objetivo:** que el usuario pueda tomar el volante del navegador remoto desde su
teléfono, teclear su contraseña, y devolverlo — que es lo único que falta para que
el subsistema A sirva de algo.

**Arquitectura:** todo el trabajo es **del cliente**, más una pieza pequeña del
servidor. El subsistema A ya dejó el servidor listo: `relay.py:633` reenvía
`input_mouse`/`input_keyboard`/`input_touch` al demonio y atiende
`mando_tomar`/`mando_devolver` sin reenviarlos nunca, y `_publica_el_cambio_de_mando`
ya avisa a los visores de quién conduce. Lo que falta es un cliente que mande esos
mensajes, un mapa de un toque a una coordenada de la página, y una pieza del relé
que haga llegar las dimensiones que ese mapa necesita.

**Stack:** Swift 6 + SwiftUI + XCTest en la app (`personal_agent`); Python +
pytest en el servicio (`gemma-memory`, worktree `.worktrees/mando-subsistema-a`,
rama `feat/mando-subsistema-a`).

**Spec:** `docs/superpowers/specs/2026-11-08-mando-compartido-del-navegador-design.md`,
sección «B. Las tres interfaces» y la lista de seguridad de «Restricciones».

## Alcance: este plan es DOS TERCIOS del subsistema B del spec

El spec mete cinco cosas en B. Este plan hace tres y deja dos fuera, a propósito:

| Pieza del spec | Aquí |
| --- | --- |
| Que el panel exista **fuera de un turno** | **Ya hecho.** `BrowserPanelCoordinator` tiene `livePanelID`, `endTurn(survive:porque:)` y tope de inactividad. Era «lo primero de este subsistema» y aterrizó antes. |
| El teléfono y la computadora: mando + entrada | **Tareas 1-6.** Es el camino crítico. |
| El mapa toque → coordenada de la página | **Tareas 2-3.** |
| El puntero del ratón | **Tarea 7.** El spec dice que «sale casi gratis por el otro lado»; se comprueba, y si no sale gratis se para y se dice. |
| El cliente web (el dashboard del CLI) | **FUERA.** El spec manda **medirlo antes de escribir nada** («se mide contra lo que hace falta y solo si no sirve se escribe uno»). Medir no es implementar: va en su propio plan, después de este. |
| Avisar cuando la app está cerrada | **FUERA.** El spec lo llama «la pieza de B con más riesgo de crecer». La app **no tiene notificaciones de ningún tipo** hoy. Es un plan propio. |

Lo que entrega este plan, solo: el usuario abre el panel, toma el volante, ve que
es su turno, toca y escribe, y lo devuelve. **Con eso la Tarea 8 del subsistema A
—desplegar y medirlo en vivo— se puede hacer.** Sin esto, no.

## Restricciones globales

De la lista de seguridad del spec, las que gobiernan al cliente. Son requisitos de
cada tarea, no de una.

- **La entrada del visor no se registra, no se narra con su contenido y no entra en
  el contexto del modelo.** Un `input_keyboard` se narra como «el usuario está
  escribiendo», **nunca con la tecla**. Ni en `PanelLog`, ni en un mensaje de
  error, ni en un `print`, ni en el transcripto, ni en la memoria. Vale también
  para los valores intermedios: una cadena que contiene la tecla no viaja a
  ninguna función que registre.
- **El token de conducir no se guarda en claro en el cliente.** Hoy vive en
  `UserDefaults` vía `@AppStorage`, en el Mac y en el iPhone. Lo arregla la Tarea 6.
- **Ningún secreto por `argv`.** `ps` lee el argv de cualquier proceso.
- **La lista de permitidos del relé no se toca.** El cliente manda solo
  `mando_tomar`, `mando_devolver`, `input_mouse`, `input_keyboard`, `input_touch` y
  `ack`. Si algo parece necesitar otro tipo, **se para y se pregunta**: abrir la
  lista por necesidad es exactamente lo que el spec prohíbe.
- **Tope de 4096 bytes por mensaje del visor** (`relay.py:641`, `MAX_MENSAJE_VISOR`).
  Lo que lo pasa se descarta **en silencio**, así que un mensaje del cliente que lo
  supere desaparece sin error. Un pegado largo se parte en varios
  `input_keyboard`.
- **Hay un límite de caudal de entrada** por visor en el servidor. El cliente no
  puede inundar: un gesto continuo se muestrea, no se manda por cada píxel.
- **Dirección segura fija:** ante una dimensión ausente, ilegible o absurda, **no
  se manda entrada**. Un toque mal mapeado pulsa otra cosa en la página del
  usuario, y eso es peor que un toque perdido.
- **La base de pruebas de la app son 5 fallos** preexistentes:
  `AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`,
  `ContactAliasStoreTests` (×2),
  `ForgetToolTests.test_forget_calls_endpoint_and_returns_count`,
  `ReminderCRUDToolTests.test_update_mueve_la_hora`.
  Contarlos: `xcodebuild … test 2>&1 | grep -E "^Test case" | grep "' failed" | sed 's/ on .*//' | sort -u`
  **La del servicio son 297 passed / 0 failed.**
- **Mutación obligatoria.** Antes de dar una prueba por buena, neutraliza la línea
  de producción de la que depende, corre la suite **entera**, comprueba que se pone
  roja, y restaura **verificando que la restauración restauró** (compara hashes).
  Este proyecto ha producido **diez** pruebas que pasaban por el motivo equivocado
  y **tres** mutaciones que mentían. El informe de cada tarea lleva su tabla.
- **Pregunta por cada aserción: ¿esto se cumple con la característica borrada?** Si
  sí, la prueba no prueba nada. Afirmar un estado en **reposo** no prueba la
  transición que lo produce (`nil`, `0`, la cadena y la lista vacías son los valores
  por omisión). Y **todo estrechamiento de una condición vuelve vacua cada prueba
  del lado negativo de la condición vieja**.

## Foco de revisión

Cinco cosas que el spec implica, que ninguna tarea exige por su cuenta, y que
muerden al usuario. Cada una tiene su prueba en la tarea que posee el código.

1. **Un toque cuando el volante NO es del usuario.** El relé lo descarta en
   silencio (`_reenvia_entrada` compara el portador), así que el usuario toca y no
   pasa nada **sin que nada se lo diga**. La interfaz tiene que impedir el gesto,
   no confiar en que el servidor lo tire. → Tarea 5.
2. **El volante se pierde mientras el usuario escribe** (vence el plazo, o el
   agente lo recupera). A medio teclear una contraseña. La pantalla tiene que
   decirlo **inmediatamente** y dejar de capturar. → Tarea 5.
3. **Un fotograma sin dimensiones**, o con dimensiones que no cuadran con el JPEG
   recibido. Hoy es el caso **normal**, porque el relé no las manda: el cliente
   tiene que funcionar antes de la Tarea 2 y después. → Tareas 2 y 3.
4. **El socket se cae con el volante tomado.** `BrowserRelayClient` reintenta; al
   reconectar, ¿sigue siendo suyo el mando? El servidor dice que no (el portador es
   la conexión), así que la interfaz no puede seguir mostrando «es tu turno». →
   Tarea 4.
5. **Una tecla en un registro.** Es la restricción que no se negocia y la más fácil
   de romper por accidente, porque todo el camino del panel ya está instrumentado
   con `PanelLog`. → Tareas 1 y 5.

---

### Tarea 1: Los codificadores de entrada, medidos contra el demonio

**Ficheros:**
- Crear: `Gemma/Gemma/Harness/BrowserInputEvents.swift`
- Prueba: `Gemma/GemmaTests/BrowserInputEventsTests.swift`
- Nota: `docs/superpowers/notes/2026-11-08-protocolo-de-entrada-del-demonio.md`

**Por qué mide primero:** `relay.py:678-684` reenvía el mensaje al demonio
**verbatim**, y valida **solo el `type`** — a propósito, para no acoplar el relé al
protocolo del demonio. Consecuencia: **el cliente tiene que acertar la forma
exacta, y nadie se la va a validar.** Un campo mal nombrado se descarta en el
demonio sin error visible.

El protocolo **no está en la guía vendorizada** (`docs/agent-browser/core-skill-0.41.2.md`):
se comprobó. El CLI **sí está instalado localmente**, así que se mide de ahí
(ayuda, `references/`, el binario). Es el mismo camino por el que se midió que
`click` no devuelve la URL.

⚠️ **No abras una sesión del CLI contra el servidor doméstico para medir.** El
navegador comparte un solo perfil de Chrome: una sesión paralela se queda el
`SingletonLock` y la del agente deja de abrir páginas **en silencio, con todos los
indicadores en verde**. Ya pasó una vez y costó un diagnóstico entero.

**Interfaces:**
- Produce: `BrowserInputEvents`, con tres funciones estáticas puras que devuelven
  el `String` JSON exacto que espera el demonio:
  `mouse(tipo:x:y:boton:) -> String`, `keyboard(tipo:tecla:texto:) -> String`,
  `touch(tipo:x:y:) -> String`. La forma de los parámetros la fija la medición.
- Produce: `BrowserInputEvents.cabeEnElTope(_ json: String) -> Bool`, el tope de
  4096 bytes del relé.

- [ ] **Paso 1: Medir y escribir la nota**

Qué espera el demonio para cada uno de los tres tipos, campo por campo, **con la
fuente de cada dato** (qué comando, qué fichero, qué línea). Si un campo no se
puede averiguar sin hablar con el servidor, **dilo en la nota** y no lo inventes.

- [ ] **Paso 2: Escribir las pruebas que fallan**

Por intención, con los valores exactos que diga la medición:
  - Cada uno de los tres tipos produce el JSON que la nota documenta.
  - El `type` es exactamente uno de los tres de `_ENTRADAS_REENVIABLES`; cualquier
    otro no se puede construir.
  - Un mensaje de tecla normal **cabe** en 4096 bytes; un texto largo **no**, y
    `cabeEnElTope` lo dice.
  - **Ninguna función del fichero llama a nada de `PanelLog`.** Se afirma leyendo
    el fuente, igual que `AgentBrowserRegistrationTests` clava la llamada a
    `registerBrowserTools`: es frágil a propósito.

- [ ] **Paso 3: Correr y ver el rojo**
- [ ] **Paso 4: Implementar `BrowserInputEvents`**

Puro, sin estado, sin registro. La serialización usa el mismo serializador
determinista que el resto del proyecto (`ToolJSONOutput` ordena las claves desde
`dd9059c`; si no encaja aquí, di por qué y ordena igual).

- [ ] **Paso 5: Verde, y la tabla de mutaciones**
- [ ] **Paso 6: Commit**

---

### Tarea 2: El relé manda lo que el cliente necesita para deshacer las escalas

**Ficheros:**
- Modificar: `browser/stream.py` (`_decode_frame`, `wire_messages`)
- Prueba: `browser/test_stream.py`

**Trabajo en el worktree** `gemma-memory/.worktrees/mando-subsistema-a`, rama
`feat/mando-subsistema-a`. Base de pruebas: **297 passed / 0 failed**.

**El problema, medido:** `stream.py:222-227` manda al visor
`{"type":"frame","seq":…,"jpeg":…,"captured_at":…}` y **nada más**. Las
dimensiones existen un paso antes —`_decode_frame` lee `msg["metadata"]` y se
queda **solo con el `timestamp`** (`stream.py:79-87`)— y se tiran.

Sin ellas el cliente no puede mapear un toque: tiene el tamaño en píxeles del JPEG
que decodifica, pero **no** el del viewport en el que la página mide sus
coordenadas.

**Lo que el spec ya corrigió y hay que respetar:** la fórmula del propio spec era
errónea. `metadata.deviceWidth/deviceHeight` es **el viewport** (medido: 1280×720),
**no** el recorte (1080×608). Así que el cliente necesita las dos cosas, y el
recorte lo sabe del JPEG.

**Interfaces:**
- Produce: el mensaje `frame` del cable gana los campos que el mapa de la Tarea 3
  consume. **Cuáles exactamente los decide esta tarea a partir de lo que el
  demonio manda de verdad** — `deviceWidth`/`deviceHeight` y el desplazamiento del
  scroll son los candidatos, y hay que mirar qué llega antes de fijarlos.

- [ ] **Paso 1: Escribir las pruebas que fallan**
  - Un fotograma con `metadata` completo lleva las dimensiones al cable.
  - Un fotograma **sin** `metadata`, o con dimensiones ausentes, no finitas, cero o
    negativas, **sigue llegando** (el JPEG es lo importante) y las dimensiones van
    **ausentes, no inventadas**. Es la dirección segura: el cliente de la Tarea 3
    no manda entrada sin ellas.
  - El mensaje **no** gana ningún campo nuevo que venga de la página (título, URL,
    texto): eso es contenido de la página y tiene su propio camino.

- [ ] **Paso 2: Correr y ver el rojo**
- [ ] **Paso 3: Implementar**
- [ ] **Paso 4: Verde, y la tabla de mutaciones**

⚠️ Esta tarea **estrecha una condición** (el fotograma pasa de «siempre tres
campos» a «tres o cinco»). Por el patrón medido en este proyecto, **revisa todas
las pruebas existentes que afirman la forma del mensaje `frame`**: las que
afirmaban «no lleva más que esto» pueden volverse vacuas o rojas. Las rojas se
ven; las vacuas no.

- [ ] **Paso 5: Commit**

---

### Tarea 3: El mapa de un punto de la pantalla a una coordenada de la página

**Ficheros:**
- Crear: `Gemma/Gemma/Harness/BrowserInputMapper.swift`
- Prueba: `Gemma/GemmaTests/BrowserInputMapperTests.swift`

**Las tres escalas**, que es lo que hace esto difícil y por qué va en su propio
fichero puro:

1. **viewport → recorte del servidor.** El demonio escala el screencast (medido:
   1280×720 → 1080×608, misma proporción, así que hoy es escala y no recorte —
   **compruébalo, no lo heredes**).
2. **recorte → el JPEG que llega.** Es el mismo, salvo que algo cambie por debajo.
   El cliente lo sabe del tamaño de la imagen decodificada, **nunca de una
   constante**.
3. **JPEG → la vista en la pantalla.** SwiftUI dibuja la imagen en un marco que
   depende del teléfono, de la rotación y de si el panel está expandido.

**Interfaces:**
- Consume: los campos que la Tarea 2 añade al mensaje `frame`.
- Produce: `BrowserInputMapper.paginaDesde(punto:tamañoDeLaVista:tamañoDeLaImagen:dimensionesDelCable:) -> CGPoint?`,
  pura y estática. **`nil` cuando no se puede mapear con certeza**, y `nil`
  significa «no mandes nada».

- [ ] **Paso 1: Escribir las pruebas que fallan**
  - El centro de la vista cae en el centro de la página.
  - Las cuatro esquinas caen en las cuatro esquinas, **al píxel**.
  - Con la imagen dibujada en una vista de **otra proporción** (hay bandas), un
    punto **sobre la banda** devuelve `nil`, no una coordenada fuera de la página.
  - Sin dimensiones del cable → `nil`.
  - Dimensiones absurdas (cero, negativas, no finitas, o una imagen más grande que
    el viewport) → `nil`.
  - **El `nil` y el acierto comparten mutación**: la prueba que exige `nil` no vale
    sola, porque una función que devuelve `nil` para todo la pasa.

- [ ] **Paso 2: Correr y ver el rojo**
- [ ] **Paso 3: Implementar**

La aritmética la determinan las pruebas. Lo que el comentario tiene que llevar
escrito: **de dónde sale cada una de las tres escalas**, y que la del medio se lee
de la imagen y no de una constante — porque la constante es exactamente el error
que el spec ya cometió una vez.

- [ ] **Paso 4: Verde, y la tabla de mutaciones**
- [ ] **Paso 5: Commit**

---

### Tarea 4: El cliente toma el mando, lo devuelve, y sabe de quién es

**Ficheros:**
- Modificar: `Gemma/Gemma/Harness/BrowserRelayClient.swift` (hoy su único `send`
  está en `:207` y es un acuse)
- Modificar: `Gemma/Gemma/Harness/BrowserPanelState.swift`
- Prueba: `Gemma/GemmaTests/BrowserRelayClientTests.swift`,
  `Gemma/GemmaTests/BrowserPanelStateTests.swift`

**Interfaces:**
- Consume: `BrowserInputEvents` (Tarea 1).
- Produce: `BrowserRelayClient.tomaElMando()`, `.devuelveElMando()`,
  `.manda(entrada: String)` — la entrada ya codificada, para que el cliente no
  sepa de protocolos.
- Produce: `BrowserPanelState.quienConduce: QuienConduce` (`.agente`, `.yo`,
  `.otroVisor`), que la vista de la Tarea 5 consume.

- [ ] **Paso 1: Escribir las pruebas que fallan**
  - `tomaElMando()` manda exactamente `{"type":"mando_tomar"}`.
  - El mensaje `mando` del servidor mueve `quienConduce`. **Los tres valores**, y
    «otro visor» no es lo mismo que «el agente»: el botón de la Tarea 5 se
    comporta distinto.
  - **Al reconectar, `quienConduce` vuelve a `.agente`** sin esperar al servidor.
    El portador del mando es la **conexión**, así que un socket nuevo nunca lo
    tiene — seguir pintando «es tu turno» tras una reconexión es mentirle al
    usuario mientras teclea. *(Foco de revisión 4.)*
  - `manda(entrada:)` no manda nada si el socket está caído, y **no registra el
    contenido**.

- [ ] **Paso 2: Correr y ver el rojo**
- [ ] **Paso 3: Implementar**
- [ ] **Paso 4: Verde, y la tabla de mutaciones**
- [ ] **Paso 5: Commit**

---

### Tarea 5: La interfaz: el botón, de quién es el turno, el toque y el teclado

**Ficheros:**
- Modificar: `Gemma/Gemma/Harness/BrowserPanelView.swift`
- Prueba: `Gemma/GemmaTests/BrowserPanelViewTests.swift`

**Interfaces:**
- Consume: `BrowserPanelState.quienConduce` (Tarea 4),
  `BrowserInputMapper.paginaDesde(...)` (Tarea 3), `BrowserInputEvents` (Tarea 1).
- Produce: funciones **puras y estáticas** para lo que se puede probar sin pintar,
  igual que el fichero ya hace con `textoSinImagen` y `cuenta`:
  `BrowserPanelView.textoDelBoton(quienConduce:) -> String` y
  `BrowserPanelView.capturaLosGestos(quienConduce:) -> Bool`.

**Lo que el usuario pidió, textual, y que esta tarea tiene que respetar:** quiere
poder seguir **escribiendo en el chat** mientras el navegador está a la vista. Un
teclado que se traga todas las teclas del teléfono mientras el panel existe le
quita eso. La captura se activa **solo** cuando el volante es suyo.

- [ ] **Paso 1: Escribir las pruebas que fallan**
  - El botón dice «Tomar el volante» con el agente conduciendo, y «Devolverlo»
    cuando es del usuario.
  - Con **otro visor** al volante, el botón **no** ofrece tomarlo: el servidor lo
    rechazaría y ofrecerlo es prometer lo que no se puede dar.
  - `capturaLosGestos` es `false` salvo cuando conduce el usuario. *(Foco de
    revisión 1: el relé descarta la entrada ajena **en silencio**, así que el
    usuario tocaría sin efecto y sin aviso.)*
  - **Cuando `quienConduce` deja de ser `.yo`, la captura se apaga en el mismo
    cambio de estado**, sin esperar nada. *(Foco de revisión 2: puede estar a medio
    teclear una contraseña.)*
  - Un gesto sobre una zona que `paginaDesde` no sabe mapear **no manda nada**.
  - **Ninguna ruta de la vista pasa la tecla a `PanelLog` ni a ningún registro.**
    Se afirma leyendo el fuente. *(Foco de revisión 5.)*

- [ ] **Paso 2: Correr y ver el rojo**
- [ ] **Paso 3: Implementar**

El muestreo de un gesto continuo es decisión del implementador, con el número
razonado en el comentario: hay un límite de caudal en el servidor y una inundación
**hambrea los acuses de los fotogramas y congela el panel de todos los visores**.

- [ ] **Paso 4: Verde, y la tabla de mutaciones**
- [ ] **Paso 5: Commit**

---

### Tarea 6: El token de conducir no se guarda en claro

**Ficheros:**
- Modificar: `Gemma/Gemma/Settings/SettingsKeys.swift:16` (la clave
  `browserBearerToken`), `Gemma/Gemma/Settings/SettingsView.swift:87` (el
  `@AppStorage`) y `:179` (el campo), y los **dos** lectores:
  `Gemma/Gemma/Harness/HarnessModel.swift:483` y `:546`
- Crear: el almacén nuevo (fichero propio; el llavero del sistema es el camino
  obvio en las dos plataformas)
- Prueba: `Gemma/GemmaTests/` — la del almacén nuevo

**Ojo con lo que ya hay:** el campo de ajustes **ya** se pinta como secreto
(`SettingsCredentialField(esSecreto: true)`), así que la interfaz dice la verdad y
el almacén miente. Eso es peor que no decir nada, porque el usuario cree que está
guardado a salvo.

**Por qué está en este plan y no en otro:** es una restricción de seguridad del
spec que **no se negocia**, y lo que la hace urgente es exactamente lo que hacen
las tareas 1-5. Hasta hoy ese token servía para **mirar**; en cuanto el cliente
pueda conducir, **sirve para conducir un Chrome que después de la prueba en vivo
tendrá la sesión de Google del usuario dentro**. El spec lo dice con estas
palabras: «el proyecto convierte un token de solo mirar en un token de conducir un
Chrome con sesiones abiertas».

`UserDefaults` no es un sitio para eso: se respalda, se sincroniza y se lee sin
desbloquear nada.

- [ ] **Paso 1: Escribir las pruebas que fallan**
  - El token se guarda y se recupera por el almacén nuevo.
  - **No queda nada en `UserDefaults`**, y un token que ya estuviera ahí **se migra
    y se borra del sitio viejo**. Sin esto, el arreglo no arregla nada para el
    usuario, que ya tiene el suyo guardado en claro.
  - El token **no aparece en ningún registro ni en ninguna descripción de error**.

- [ ] **Paso 2: Correr y ver el rojo**
- [ ] **Paso 3: Implementar**
- [ ] **Paso 4: Verde, y la tabla de mutaciones**
- [ ] **Paso 5: Commit**

**Lo que esta tarea NO hace, y son dos cosas:**

- **El ticket de un solo uso** que sustituye al `?token=` de la URL. Es otra
  restricción del spec, es trabajo de servidor y de cliente a la vez, y **está
  esperando una decisión del usuario**. No la tomes tú.
- **Los otros secretos de los ajustes.** El token del servicio de memoria tiene el
  mismo defecto y el mismo almacén. El spec nombra solo el de conducir, que es el
  que cambia de categoría con este plan. Si el almacén nuevo sirve para los dos
  —y debería—, **dilo en el informe** y que lo decida el controlador; no amplíes el
  alcance por tu cuenta.

---

### Tarea 7: El puntero del ratón

**Ficheros:**
- Modificar: `Gemma/Gemma/Harness/BrowserPanelView.swift`
- Prueba: `Gemma/GemmaTests/BrowserPanelViewTests.swift`

**De dónde sale:** el usuario lo pidió aparte. El CLI **no** lo ofrece en el
stream (su `--cursor` es solo de `record`, y el screencast viene de CDP, que no
dibuja cursor). El spec dice que con lo anterior construido «sale casi gratis por
el otro lado»: el cliente **ya sabe dónde está el puntero porque es él quien lo
mueve**, y las acciones del agente ya viajan al panel como narración.

**Comprueba que de verdad sale gratis.** Si resulta que la narración no trae
coordenadas —y por la Tarea 1 del subsistema A probablemente no las trae, porque
la narración es deliberadamente sin contenido—, entonces **el puntero del agente
no se puede dibujar sin un dato nuevo en el cable**, y eso es otra tarea. **Párate
y dilo** en vez de inventar un camino.

- [ ] **Paso 1: Escribir la prueba que falla**
  - La posición del puntero del **usuario** sale del último punto mapeado, y es
    `nil` antes del primero.
  - Si el puntero del **agente** no es alcanzable, la prueba que se escribe es la
    que fija que **no se dibuja nada inventado**.

- [ ] **Paso 2: Correr y ver el rojo**
- [ ] **Paso 3: Implementar**
- [ ] **Paso 4: Verde, y la tabla de mutaciones**
- [ ] **Paso 5: Commit**

---

## Lo que este plan NO hace, a propósito

- **El cliente web.** El spec manda medir primero el dashboard que ya trae el CLI.
  Plan propio.
- **Las notificaciones cuando la app está cerrada.** La app no tiene ninguna hoy.
  Plan propio, y el spec avisa de que es la pieza con más riesgo de crecer.
- **El ticket de un solo uso** que saca el token de la URL. Espera decisión del
  usuario.
- **Gobernar el camino del navegador LOCAL con la máquina de estados.** El spec lo
  pide («o el proyecto deja una puerta sin cerrar justo al lado de la que cierra»),
  pero es trabajo del agente y del arnés, no de las interfaces. Queda anotado aquí
  para que no se pierda.
- **La detección de muros por contenido** (nivel 2: DataDome, Amazon). Aparcada con
  su coste en el libro de cuentas del subsistema A.
