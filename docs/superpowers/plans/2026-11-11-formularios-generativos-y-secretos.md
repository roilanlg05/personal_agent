# Formularios generativos y secretos — plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el agente pueda mostrar formularios nativos en el chat (campos mezclados, uno o varios) y usar secretos guardados por nombre —`browser_fill_secret`— sin que el valor pase nunca por el modelo.

**Architecture:** Un módulo `Forms` (tipos, bóveda en Keychain, intermediario `FormBroker`, redactor) más cuatro herramientas del agente y una tarjeta SwiftUI compartida iOS/macOS en el chat. El valor de un secreto solo sale del Keychain dentro de `browser_fill_secret`, que lo teclea por **entrada estándar** (`agent-browser batch`, no por argumentos de proceso) y solo en el sitio donde se guardó.

**Tech Stack:** Swift 6 / SwiftUI, XCTest, Keychain (`LlaveroDelSistema`), `agent-browser` CLI.

**Spec:** `docs/superpowers/specs/2026-11-11-formularios-generativos-y-secretos-design.md`

## Global Constraints

- Nombre de secreto: regex `^[a-z0-9_]{1,40}$`.
- Un formulario: de 1 a 12 campos; ids únicos; `kind` ∈ `text` `secret` `number` `choice` `multichoice` `confirm` `date`.
- `options` (lista de `{value,label}`) obligatorias y no vacías en `choice`/`multichoice`; prohibidas en los demás.
- `secret_name` obligatorio en `secret`; prohibido en los demás.
- Respuesta al modelo: `{"status":"submitted"|"cancelled"|"timeout","values":{id:valor}}`. El valor de un campo `secret` es EXACTAMENTE `"[secreto guardado: <secret_name>]"`.
- Plazo del formulario: 10 minutos. Un solo formulario abierto a la vez.
- Atadura al origen: `browser_fill_secret` solo teclea si el host de la página actual es igual al `origen` guardado o es subdominio suyo.
- El valor de un secreto NO se escribe en argumentos de proceso, ni en `ChatLogEntry`, ni en transcript, memoria, logs o resúmenes.
- Servicio del Keychain de la bóveda: `"lambert-dev-group.Gemma.boveda"` (se reutiliza `LlaveroDelSistema(servicio:)`, cuya clase de accesibilidad es `AfterFirstUnlockThisDeviceOnly`; **decisión mía que sustituye a «WhenUnlocked» del spec**, porque es la que el proyecto ya midió y fijó).
- Las pruebas usan `AlmacenEnMemoria` (`GemmaTests/TokenDeConducirTests.swift:11`), nunca el Keychain real.
- Textos al usuario y comentarios en español, como el resto del proyecto.
- Commits con pies de firma: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` y `Claude-Session: https://claude.ai/code/session_01HeKFqfCsoSqxyPw1xeK4WE`. Añadir ficheros por ruta, nunca `git add -A`.

## Review Focus

1. **Una página pide el secreto en otro sitio** (`evil.com` tras guardar el de `accounts.google.com`): `browser_fill_secret` debe negarse y no teclear nada. Pinned en Task 6.
2. **El eco de la página contiene el valor** (un campo no-contraseña lo muestra en el snapshot): el modelo recibe `[secreto: nombre]`, no el valor. Pinned en Task 3 y en Task 6.
3. **Formulario sin respuesta**: el turno no queda colgado; a los 10 min devuelve `status: "timeout"`. Pinned en Task 4.
4. **Dos formularios a la vez** (el modelo llama a `present_form` dos veces en una ronda): el segundo se rechaza con error, no se apila ni se pierde el primero. Pinned en Task 4.
5. **Secreto con nombre repetido**: guardar `gmail_password` otra vez lo reemplaza y el índice no duplica el nombre. Pinned en Task 2.

---

### Task 1: Tipos del formulario y su validación

**Files:**
- Create: `Gemma/Gemma/Forms/FormSpec.swift`
- Test: `Gemma/GemmaTests/FormSpecTests.swift`

**Interfaces:**
- Produces:
  - `struct FormField: Codable, Equatable, Sendable { id, label: String; kind: Kind; required: Bool; options: [Option]?; secretName: String?; placeholder: String?; help: String? }` con `enum Kind: String, Codable, CaseIterable { text, secret, number, choice, multichoice, confirm, date }` y `struct Option: Codable, Equatable, Sendable { value, label: String }`. Claves JSON en snake_case: `secret_name`.
  - `struct FormSpec: Codable, Equatable, Sendable { title: String; description: String?; submitLabel: String?; fields: [FormField] }` (`submit_label` en JSON).
  - `enum FormSpecError: Error, Equatable { case sinCampos, demasiadosCampos, idsRepetidos, nombreDeSecretoInvalido(String), faltanOpciones(String), opcionesNoPermitidas(String), faltaNombreDeSecreto(String), nombreDeSecretoNoPermitido(String), jsonInvalido }`
  - `static func FormSpec.parse(title: String, description: String?, submitLabel: String?, fieldsJSON: String) throws -> FormSpec` — valida todo lo de *Global Constraints*.
  - `enum FormStatus: String, Codable { submitted, cancelled, timeout }` y `struct FormResponse: Codable, Equatable, Sendable { status: FormStatus; values: [String: String] }` con `var json: String`.

- [ ] **Step 1: Write the failing tests** (`FormSpecTests`): `test_acepta_un_formulario_valido_de_campos_mezclados` (un `text`, un `secret` con `secret_name:"gmail_password"`, un `choice` con 2 opciones); `test_rechaza_cero_campos`; `test_rechaza_trece_campos` (12 sí, 13 no); `test_rechaza_ids_repetidos`; `test_rechaza_nombres_de_secreto_fuera_de_la_regex` (`"Gmail"`, `"a-b"`, `""`, 41 caracteres); `test_choice_sin_opciones_falla_y_text_con_opciones_falla`; `test_secret_sin_secret_name_falla_y_text_con_secret_name_falla`; `test_json_que_no_es_una_lista_falla_con_jsonInvalido`; `test_la_respuesta_serializa_el_literal_del_secreto` (la constante `FormResponse.textoDeSecretoGuardado(_ nombre: String) -> String == "[secreto guardado: gmail_password]"`).
- [ ] **Step 2: Run** `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/FormSpecTests` → FAIL (tipos no definidos).
- [ ] **Step 3: Implement** los tipos y `FormSpec.parse` en `FormSpec.swift`. `JSONDecoder` con `keyDecodingStrategy = .convertFromSnakeCase`; la validación cruzada va en `parse`, no en `init(from:)`.
- [ ] **Step 4: Run** el mismo comando → PASS.
- [ ] **Step 5: Commit** `git add Gemma/Gemma/Forms/FormSpec.swift Gemma/GemmaTests/FormSpecTests.swift` · `feat(forms): tipos del formulario y su validación`.

### Task 2: Bóveda de secretos

**Files:**
- Create: `Gemma/Gemma/Forms/SecretVault.swift`
- Test: `Gemma/GemmaTests/SecretVaultTests.swift`

**Interfaces:**
- Consumes: `AlmacenDeSecretos` (`leer(cuenta:)`, `escribir(_:cuenta:) -> Bool`, `borrar(cuenta:)`), `LlaveroDelSistema(servicio:)`.
- Produces:
  - `struct SecretoGuardado: Codable, Equatable, Sendable { name, etiqueta, origen: String }` (sin el valor).
  - `final class SecretVault: Sendable { init(almacen: any AlmacenDeSecretos = LlaveroDelSistema(servicio: "lambert-dev-group.Gemma.boveda")) }`
  - `func guarda(name: String, value: String, etiqueta: String, origen: String) -> Bool`
  - `func valor(de name: String) -> String?`
  - `func lista() -> [SecretoGuardado]`
  - `func origen(de name: String) -> String?`
  - `func borra(name: String)`
  - `func valoresActuales() -> [String]` (para el redactor; no vacíos).
  - `static func origenPermite(guardado: String, paginaActual: String) -> Bool` — host igual o subdominio (`mail.google.com` permitido por `google.com`; `evilgoogle.com` NO; `google.com.evil.com` NO). Trabaja con hosts, ya sin esquema.

Diseño de almacenamiento (decisión mía): una cuenta `secreto.<name>` con JSON `{value, etiqueta, origen}` y una cuenta `indice` con la lista de nombres, porque `AlmacenDeSecretos` no sabe listar.

- [ ] **Step 1: Write the failing tests**: `test_guarda_y_lee_el_valor`; `test_lista_no_contiene_valores` (el JSON de `lista()` no contiene el valor); `test_guardar_dos_veces_el_mismo_nombre_reemplaza_y_no_duplica_el_indice` (**Review Focus 5**); `test_borra_quita_valor_e_indice`; `test_guarda_devuelve_false_si_el_almacen_rechaza` (doble que devuelve `false`); `test_origenPermite_exacto_subdominio_y_rechazos` con las cuatro entradas de arriba; `test_valoresActuales_omite_vacios`.
- [ ] **Step 2: Run** `-only-testing:GemmaTests/SecretVaultTests` → FAIL.
- [ ] **Step 3: Implement** `SecretVault`. Validar `name` contra la regex de *Global Constraints* y devolver `false`/`nil` si no cumple.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(forms): bóveda de secretos en el Keychain`.

### Task 3: Redactor y su enganche en el bucle del agente

**Files:**
- Create: `Gemma/Gemma/Forms/SecretRedactor.swift`
- Modify: `Gemma/Gemma/Agent/Agent.swift:1312` (la línea `result = await tool.run(argsJSON: tc.args)`)
- Test: `Gemma/GemmaTests/SecretRedactorTests.swift`, y un caso en `Gemma/GemmaTests/AgentTests.swift`

**Interfaces:**
- Consumes: `SecretVault.valoresActuales()`, `SecretVault.lista()` (para etiquetar con el nombre).
- Produces: `enum SecretRedactor { static func limpia(_ texto: String, vault: SecretVault) -> String }` — sustituye cada aparición literal de cada valor (el más largo primero) por `[secreto: <name>]`. `Agent` gana una propiedad `var bóveda: SecretVault?` (nil = sin redacción) inyectada en el `init`, con valor por defecto `nil` para no romper llamadores.

- [ ] **Step 1: Write the failing tests**: `test_sustituye_el_valor_por_su_nombre`; `test_sustituye_todas_las_apariciones`; `test_el_valor_mas_largo_gana_sobre_uno_contenido` (valores `abc` y `abcdef`); `test_valor_vacio_no_sustituye_nada`; `test_sin_secretos_devuelve_el_texto_intacto`; en `AgentTests`, siguiendo el patrón de los tests existentes con un runtime y una herramienta falsos (ver `test_la_tercera_lectura_identica_trae_el_aviso_y_no_retira_las_herramientas`): `test_el_resultado_de_una_herramienta_llega_al_modelo_sin_el_valor_del_secreto` — la herramienta falsa devuelve un texto con el valor y el siguiente prompt al runtime NO lo contiene (**Review Focus 2**).
- [ ] **Step 2: Run** `-only-testing:GemmaTests/SecretRedactorTests -only-testing:GemmaTests/AgentTests` → FAIL.
- [ ] **Step 3: Implement** `SecretRedactor` y aplicar `result = SecretRedactor.limpia(result, vault:)` justo después de `tool.run` cuando `bóveda != nil`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Mutación**: quitar la línea de enganche en `Agent.swift` → el test del `AgentTests` tiene que ponerse rojo. Restaurar por texto y comprobar con `git diff`.
- [ ] **Step 6: Commit** `feat(forms): el redactor limpia los resultados de herramienta`.

### Task 4: FormBroker

**Files:**
- Create: `Gemma/Gemma/Forms/FormBroker.swift`
- Test: `Gemma/GemmaTests/FormBrokerTests.swift`

**Interfaces:**
- Consumes: `FormSpec`, `FormResponse`.
- Produces: `@MainActor @Observable final class FormBroker`:
  - `init(plazo: Duration = .seconds(600), dormir: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })`
  - `private(set) var pendiente: PendingForm?` con `struct PendingForm: Identifiable, Equatable { let id: String; let spec: FormSpec }`
  - `func presenta(_ spec: FormSpec) async throws -> FormResponse` — lanza `FormBrokerError.yaHayUnoAbierto` si hay otro; suspende hasta enviar/cancelar/plazo.
  - `func envia(id: String, valores: [String: String])`, `func cancela(id: String)` — ignoran ids que no son el pendiente.
  - `func cancelaTodo()` (para fin de turno / reinicio).

- [ ] **Step 1: Write the failing tests**: `test_presenta_se_reanuda_al_enviar_con_los_valores`; `test_cancela_devuelve_status_cancelled`; `test_el_plazo_devuelve_timeout_sin_esperar_de_verdad` (inyectar `dormir` que vuelve al instante; **Review Focus 3**); `test_un_segundo_presenta_mientras_hay_uno_abierto_lanza_yaHayUnoAbierto_y_no_toca_el_primero` (**Review Focus 4**); `test_envia_con_un_id_que_no_es_el_pendiente_se_ignora`; `test_tras_resolver_pendiente_vuelve_a_nil_y_se_puede_presentar_otro`; `test_cancelaTodo_reanuda_con_cancelled`.
- [ ] **Step 2: Run** `-only-testing:GemmaTests/FormBrokerTests` → FAIL.
- [ ] **Step 3: Implement** con una `CheckedContinuation` guardada y una `Task` de plazo que compite; reanudar **una sola vez** (mismo cuidado que `ReanudaUnaSolaVez` en `BrowserMando.swift`).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(forms): intermediario de formularios con plazo`.

### Task 5: Herramientas `present_form`, `list_secrets`, `forget_secret`

**Files:**
- Create: `Gemma/Gemma/Forms/FormTools.swift`
- Test: `Gemma/GemmaTests/FormToolsTests.swift`

**Interfaces:**
- Consumes: `FormSpec.parse`, `FormBroker.presenta`, `SecretVault`, `AgentBrowserService.run(command:sessioned:timeout:)` (para `["get","url"]`), `AgentBrowserToolOutput.parseArguments`.
- Produces (todas `AgentTool`):
  - `PresentFormTool(broker: FormBroker, vault: SecretVault, service: AgentBrowserService?)`, `name = "present_form"`. Parámetros (`AgentToolParam` solo admite string/integer/number/boolean): `title` (string, req), `description` (string), `submit_label` (string), `fields` (string, req: **una lista JSON** de campos). Si el formulario tiene algún campo `secret`: obtiene el host de la página actual con `get url`; sin página abierta devuelve error "abre primero la página donde se usará el secreto". Tras `submitted`, guarda cada secreto con `vault.guarda(name:value:etiqueta:origen:)` y sustituye su valor en la respuesta por `FormResponse.textoDeSecretoGuardado`.
  - `ListSecretsTool(vault:)`, `name = "list_secrets"`: devuelve JSON con `name`, `etiqueta`, `origen`.
  - `ForgetSecretTool(vault:)`, `name = "forget_secret"`, parámetro `name`.
  - Los errores usan `AgentBrowserToolOutput.invalidArguments(_:)` para hablar el mismo contrato JSON que las demás.

- [ ] **Step 1: Write the failing tests** (broker con `dormir` instantáneo y un navegador falso): `test_present_form_con_un_secreto_lo_guarda_con_el_origen_de_la_pagina_y_el_resultado_no_lleva_el_valor` (el resultado string NO contiene el valor; sí `[secreto guardado: gmail_password]`; `vault.origen(de:) == "accounts.google.com"`); `test_present_form_con_secreto_y_sin_pagina_abierta_devuelve_error`; `test_present_form_con_campos_invalidos_devuelve_el_error_de_validacion`; `test_present_form_cancelado_no_guarda_nada`; `test_present_form_sin_secretos_no_consulta_la_pagina`; `test_list_secrets_no_contiene_valores`; `test_forget_secret_borra`.
- [ ] **Step 2: Run** `-only-testing:GemmaTests/FormToolsTests` → FAIL.
- [ ] **Step 3: Implement** las tres herramientas. Para el test usar un `AgentBrowserInvoking` falso que responde a `get url`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(forms): present_form, list_secrets y forget_secret`.

### Task 6: Entrada estándar en el invocador y `browser_fill_secret`

**Files:**
- Modify: `Gemma/Gemma/NativeServices/AgentBrowserInvoker.swift` (protocolo `AgentBrowserInvoking`, `ProcessAgentBrowserInvoker.run`), `Gemma/Gemma/NativeServices/HTTPAgentBrowserInvoker.swift`, `Gemma/Gemma/NativeServices/AgentBrowserService.swift`
- Create: `Gemma/Gemma/Forms/BrowserFillSecretTool.swift`
- Test: `Gemma/GemmaTests/BrowserFillSecretToolTests.swift`, ampliar `Gemma/GemmaTests/AgentBrowserInvokerTests.swift`

**Interfaces:**
- Produces:
  - `AgentBrowserInvoking.invoke(arguments: [String], timeout: TimeInterval, stdin: Data?) async -> Result<…>` con una extensión que mantiene `invoke(arguments:timeout:)` llamando con `stdin: nil` (no rompe a los llamadores ni a los dobles de prueba existentes).
  - `ProcessAgentBrowserInvoker` escribe `stdin` al proceso hijo y cierra la tubería.
  - `HTTPAgentBrowserInvoker.invoke(…stdin:)` con `stdin != nil` devuelve `.failure(.launchFailed("browser_fill_secret solo está disponible con el navegador local de la Mac por ahora"))` (decisión mía: la ruta remota necesita un cambio en el servicio del i3 que queda fuera de este plan).
  - `AgentBrowserService.run(command:sessioned:timeout:stdin:)`.
  - `BrowserFillSecretTool(service: AgentBrowserService, vault: SecretVault)`, `name = "browser_fill_secret"`, parámetros `selector` (string, req) y `secret` (string, req).

Comportamiento de la herramienta: (1) `vault.origen(de:)` o error "no existe ese secreto"; (2) `get url` → host actual; (3) `SecretVault.origenPermite` o error "ese secreto pertenece a <origen>" **sin teclear nada** (**Review Focus 1**); (4) ejecuta `batch --json --omit-command` con `stdin = [["fill", selector, valor]]` serializado como JSON (la serie de `--session` va delante como siempre); (5) pasa el resultado por `SecretRedactor.limpia` y responde `success` sin el valor.

- [ ] **Step 1: Write the failing tests**: en `AgentBrowserInvokerTests`, `test_el_invocador_pasa_la_entrada_estandar_al_hijo_y_no_la_pone_en_los_argumentos` (binario falso que escribe en su salida lo que lee de stdin y sus `$@`; la entrada llega; los argumentos NO la contienen). En `BrowserFillSecretToolTests` (invocador falso que graba `arguments` y `stdin`): `test_teclea_por_stdin_y_los_argumentos_no_contienen_el_valor`; `test_se_niega_en_un_origen_distinto_y_no_ejecuta_batch` (`evil.com` vs `accounts.google.com`); `test_permite_un_subdominio`; `test_secreto_inexistente_devuelve_error`; `test_el_eco_del_valor_en_la_salida_se_redacta`; `test_el_resultado_no_contiene_el_valor`.
- [ ] **Step 2: Run** `-only-testing:GemmaTests/BrowserFillSecretToolTests -only-testing:GemmaTests/AgentBrowserInvokerTests` → FAIL.
- [ ] **Step 3: Implement** el cambio de protocolo (extensión por defecto), el stdin en `Process`, el rechazo en el HTTP y la herramienta.
- [ ] **Step 4: Run** → PASS, y `-only-testing:GemmaTests/HTTPAgentBrowserInvokerTests` sin regresiones.
- [ ] **Step 5: Mutaciones** (restaurar por texto tras cada una): (a) en la herramienta, pasar el valor en `command` en vez de `stdin` → rojo; (b) quitar la comprobación `origenPermite` → rojo; (c) quitar `SecretRedactor.limpia` → rojo.
- [ ] **Step 6: Commit** `feat(forms): browser_fill_secret tecleando por entrada estándar y atado al origen`.

### Task 7: Tarjeta del chat y cableado

**Files:**
- Create: `Gemma/Gemma/Forms/FormDraft.swift`, `Gemma/Gemma/Forms/FormCardView.swift`
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift` (`ChatLogEntry` gana `formID: String?`; `HarnessModel` posee `let formularios = FormBroker()` y `let boveda = SecretVault()`; registrar las cuatro herramientas en `registerBrowserTools`/`runAgentTurn`; observar `formularios.pendiente` y añadir una `ChatLogEntry(role: "form", formID:)`), `Gemma/Gemma/Harness/AgentChatView.swift` (nuevo `case "form"` junto al de `browserPanel`, ~línea 601), `Gemma/Gemma/Agent/Agent.swift` (pasar la bóveda al `Agent`).
- Test: `Gemma/GemmaTests/FormDraftTests.swift`

**Interfaces:**
- Produces:
  - `struct FormDraft { init(spec: FormSpec); var values: [String: String]; mutating func set(_ id: String, _ value: String); var errores: [String: String]; var puedeEnviar: Bool; var paraEnviar: [String: String] }` — lógica pura: `required` no vacío, `number` parseable, `confirm` ∈ `{"true","false"}`, `multichoice` como valores separados por `\n`, `choice` ∈ opciones, `date` en `yyyy-MM-dd`.
  - `struct FormCardView: View { let spec: FormSpec; let enviado: Bool; onEnviar: ([String:String]) -> Void; onCancelar: () -> Void }` — `SecureField` para `secret`, `Picker`/`Toggle`/`DatePicker` según `kind`; tras enviar queda como «enviado» sin valores.

- [ ] **Step 1: Write the failing tests** (`FormDraftTests`): requerido vacío bloquea; `number` con texto no parsea; `choice` fuera de opciones bloquea; `confirm` por defecto `"false"`; `puedeEnviar` solo con cero errores; `paraEnviar` incluye todos los ids.
- [ ] **Step 2: Run** `-only-testing:GemmaTests/FormDraftTests` → FAIL.
- [ ] **Step 3: Implement** `FormDraft`, `FormCardView`, y el cableado. La tarjeta **no** se vuelve a pintar con valores tras enviar.
- [ ] **Step 4: Run** `-only-testing:GemmaTests/FormDraftTests` y compilar iOS: `xcodebuild build -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'generic/platform=iOS'` → `BUILD SUCCEEDED`.
- [ ] **Step 5: Commit** `feat(forms): tarjeta del chat y cableado en HarnessModel`.

### Task 8: Reglas del prompt y cierre

**Files:**
- Modify: `Gemma/Gemma/Agent/BrowserRules.swift` (texto de `text`), `Gemma/Gemma/NativeServices/BrowserInteractionTools.swift` (descripción de `browser_fill`: remitir a `browser_fill_secret`)
- Test: `Gemma/GemmaTests/AgentTests.swift` (junto al test `test_las_reglas_del_navegador_autorizan_crear_una_cuenta_propia`)

- [ ] **Step 1: Write the failing test** `test_las_reglas_mandan_los_secretos_por_formulario`: `BrowserRules.text` contiene `present_form`, `browser_fill_secret` y `list_secrets`, y NO contiene la frase vieja de pedirle al usuario que tome el control.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** el texto: «Para una contraseña, un código o cualquier dato secreto, usa `present_form` con un campo `secret`; luego `browser_fill_secret`. Antes mira `list_secrets`: si el secreto ya existe para ese sitio, no lo vuelvas a pedir. Nunca pidas un secreto por el chat.»
- [ ] **Step 4: Run** la suite completa de macOS con la receta del proyecto (`grep -oE "' (passed|failed|skipped) on '"` sobre la salida y comparar con `Executed N tests` de Xcode). Base antes de este plan: 1441 aprobadas / 4 fallidas conocidas (`AgentSystemPromptTests.test_system_prompt_has_no_save_memory_instruction`, dos de `ContactAliasStoreTests`, `ReminderCRUDToolTests.test_update_mueve_la_hora`) / 15 omitidas. Resultado esperado: solo suben las aprobadas.
- [ ] **Step 5: Revisión adversarial con Codex** (`/codex:adversarial-review`) si el límite de uso ya volvió; si no, declarar el hueco en el commit.
- [ ] **Step 6: Prueba a mano en la Mac** con Chrome real: el agente abre un login, `present_form` aparece, se envía, `browser_fill_secret` rellena; comprobar con `ps` durante la llamada que el valor no está en los argumentos.
- [ ] **Step 7: Commit** `feat(forms): reglas del prompt para secretos y formularios`.

---

## Self-review

- **Cobertura del spec:** esquema (T1), bóveda (T2), redactor (T3), broker/plazo/uno a la vez (T4), `present_form`/`list_secrets`/`forget_secret` (T5), `browser_fill_secret` + atadura al origen + cierre del hueco del argv (T6), tarjeta SwiftUI y `role == "form"` (T7), reglas del prompt (T8). Sin tarea: sincronización entre aparatos (fuera de v1 por el spec).
- **Cambios respecto al spec, a revisar:** el hueco 5 del spec (valor por argv) **se cierra** usando `agent-browser batch` por stdin (verificado: `batch` lee un JSON de stdin); el Keychain usa `AfterFirstUnlockThisDeviceOnly`; `browser_fill_secret` solo funciona con el navegador local de la Mac (la ruta HTTP/i3 devuelve un error claro).
- **Consistencia de nombres:** `SecretVault.guarda/valor/lista/origen(de:)/borra/valoresActuales/origenPermite`, `FormResponse.textoDeSecretoGuardado`, `SecretRedactor.limpia`, `FormBroker.presenta/envia/cancela/cancelaTodo` se usan igual en todas las tareas.
- **Proporción:** el plan cabe en un documento del tamaño del spec; los cuerpos los escribe el implementador.
