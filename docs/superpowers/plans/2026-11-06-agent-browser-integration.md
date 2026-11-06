# Agent Browser Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dar al agente la capacidad de leer y conducir páginas web, invocando el CLI `agent-browser` de vercel-labs desde nueve herramientas nativas nuevas.

**Architecture:** Tres capas. `ProcessAgentBrowserInvoker` lanza el binario y devuelve la salida cruda (misma mecánica de procesos que `CLIShortcutRunner`, detrás del protocolo `AgentBrowserInvoking` para poder probar sin binario). `AgentBrowserService` construye los argumentos, añade `--json` y `--session gemma`, y decodifica el envelope uniforme `{success, data, error}` a un `AgentBrowserOutcome` de cuatro casos. Nueve `AgentTool` traducen ese outcome a los cinco `status` del contrato de honestidad del repositorio.

**Tech Stack:** Swift 6, XCTest, `Foundation.Process`, `JSONSerialization`, `ToolJSONOutput`. Sin dependencias nuevas de paquete. `agent-browser` 0.41.2 (Homebrew) como binario externo.

**Spec:** `docs/superpowers/specs/2026-11-06-agent-browser-integration-design.md`

## Global Constraints

- Todo el código nuevo va bajo `#if os(macOS)`, como `CLIShortcutRunner`. En iOS no hay lanzamiento de procesos.
- Los ficheros nuevos van en `Gemma/Gemma/NativeServices/` y `Gemma/GemmaTests/`. **No hay que editar `project.pbxproj`:** el proyecto usa `PBXFileSystemSynchronizedRootGroup`, los ficheros se recogen solos.
- La salida de toda herramienta se construye con `ToolJSONOutput`. Nunca interpolar JSON a mano.
- Descripciones de herramientas, parámetros y mensajes al modelo **en español**.
- El estado de éxito del CLI está en el campo `success` del JSON, **nunca** en el código de salida: `agent-browser` devuelve 0 también cuando falla.
- Nombre de sesión: `gemma`, constante, sobreescribible por la variable de entorno `AGENT_BROWSER_SESSION`.
- `data.lifecycle` del envelope se descarta antes de llegar al modelo.
- Los cinco `status` son los mismos en las nueve herramientas: `success`, `no_content`, `refused`, `not_available`, `error`.
- Las tres herramientas que devuelven texto de página (`read_webpage`, `browser_snapshot`, `browser_get`) incluyen `content_is_untrusted: true` y el aviso de inyección en su descripción.
- Cada fichero de pruebas define sus propios ayudantes privados `svc(_ stdout: String) -> AgentBrowserService` (envuelve un `MockAgentBrowserInvoker.succeeding`) y `parse(_ out: String) throws -> [String: Any]`, al estilo de `WebSearchHonestyTests`. El plan los usa sin repetirlos en cada tarea.
- Comando de pruebas: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/<Suite> 2>&1 | tail -20`
- `HarnessModelTests/test_defaultBaseURL` falla ya en `main`: es un fallo conocido, no lo introduce este trabajo.
- Límites de recorte: `read_webpage.content` 12 000 caracteres; `browser_snapshot.snapshot` y `browser_get html` 8 000.
- Plazos: `read` 45 s, `open` 60 s, `snapshot` 30 s, `wait` 40 s, el resto 30 s.

## Review Focus

Cinco clases de entrada que el spec implica y que ninguna tarea cubriría por sí sola. Cada línea tiene su prueba asignada a la tarea dueña del código.

1. **Texto que empieza por `--` en `browser_fill`.** Verificado en vivo: `fill '#a' '--json'` devuelve `success:true` con `filled:"#a"` y deja el campo **vacío**, porque el CLI se come `--json` como flag global. Un `--` separador no existe (se interpreta como selector). Un texto como `-abc` sí funciona. Esperable: que la herramienta rechace el texto en vez de reportar un relleno que no ocurrió. → Tarea 5.
2. **URL con esquema distinto de `http`/`https`** (`file:///etc/passwd`, `javascript:…`, `data:…`). Esperable: rechazo antes de invocar el CLI, no lectura del disco local. → Tareas 3 y 4.
3. **`stdout` vacío** (daemon muerto, binario terminado sin escribir). Esperable: `malformed` → `status: error`, nunca una caída ni un `success` inventado. → Tarea 2.
4. **Parámetro requerido ausente en el `argsJSON` del modelo** (`browser_fill` sin `text`, `browser_click` sin `selector`). Esperable: `status: error` con un mensaje que diga qué falta, sin invocar el CLI. → Tareas 3, 4, 5 y 6.
5. **`browser_wait` con cero criterios o con varios a la vez.** Esperable: `status: error` explicando que hace falta exactamente uno. → Tarea 6.

---

### Task 1: Lanzamiento del CLI y descubrimiento del binario

**Files:**
- Create: `Gemma/Gemma/NativeServices/AgentBrowserInvoker.swift`
- Test: `Gemma/GemmaTests/AgentBrowserInvokerTests.swift`

**Interfaces:**
- Consumes: nada.
- Produces:
```swift
public struct AgentBrowserInvocation: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
}

public enum AgentBrowserInvocationFailure: Error, Sendable, Equatable {
    case binaryNotFound(searchedPaths: [String])
    case timedOut(seconds: TimeInterval)
    case launchFailed(String)
}

public protocol AgentBrowserInvoking: Sendable {
    func invoke(arguments: [String], timeout: TimeInterval) async
        -> Result<AgentBrowserInvocation, AgentBrowserInvocationFailure>
}

public enum AgentBrowserBinary {
    /// Rutas fijas, en orden de preferencia.
    public static let candidatePaths: [String]
    /// `nil` si ninguna vía da un ejecutable. No consulta el `PATH` heredado a secas.
    public static func resolve(environment: [String: String],
                              isExecutable: (String) -> Bool) -> String?
}

public final class ProcessAgentBrowserInvoker: AgentBrowserInvoking, Sendable {
    public init(binaryPath: String? = nil)
}

/// Doble de prueba. Devuelve lo programado y guarda lo que recibió.
public final class MockAgentBrowserInvoker: AgentBrowserInvoking, @unchecked Sendable {
    public var nextResult: Result<AgentBrowserInvocation, AgentBrowserInvocationFailure>
    public private(set) var receivedArguments: [[String]]
    public init(nextResult: Result<AgentBrowserInvocation, AgentBrowserInvocationFailure>)
    /// Atajo: envuelve `stdout` en un `AgentBrowserInvocation` con código 0.
    public static func succeeding(stdout: String) -> MockAgentBrowserInvoker
}
```

- [ ] **Step 1: Write the failing tests** in `Gemma/GemmaTests/AgentBrowserInvokerTests.swift`

```swift
func test_candidatePaths_prefers_homebrew_arm_before_usr_local() {
    let paths = AgentBrowserBinary.candidatePaths
    let brew = paths.firstIndex(of: "/opt/homebrew/bin/agent-browser")
    let local = paths.firstIndex(of: "/usr/local/bin/agent-browser")
    XCTAssertNotNil(brew); XCTAssertNotNil(local)
    XCTAssertLessThan(brew!, local!)
}

func test_resolve_prefers_the_environment_override() {
    let found = AgentBrowserBinary.resolve(
        environment: ["AGENT_BROWSER_PATH": "/custom/ab"],
        isExecutable: { $0 == "/custom/ab" || $0 == "/opt/homebrew/bin/agent-browser" })
    XCTAssertEqual(found, "/custom/ab")
}

func test_resolve_ignores_an_override_that_is_not_executable() {
    let found = AgentBrowserBinary.resolve(
        environment: ["AGENT_BROWSER_PATH": "/custom/ab"],
        isExecutable: { $0 == "/opt/homebrew/bin/agent-browser" })
    XCTAssertEqual(found, "/opt/homebrew/bin/agent-browser")
}

func test_resolve_returns_nil_when_nothing_is_executable() {
    XCTAssertNil(AgentBrowserBinary.resolve(environment: [:], isExecutable: { _ in false }))
}

func test_invoker_without_a_binary_reports_binaryNotFound_with_the_paths_it_tried() async {
    let invoker = ProcessAgentBrowserInvoker(binaryPath: "/nonexistent/agent-browser")
    let result = await invoker.invoke(arguments: ["--version"], timeout: 5)
    guard case .failure(.binaryNotFound(let paths)) = result else {
        return XCTFail("got: \(result)")
    }
    XCTAssertFalse(paths.isEmpty)
}

/// Usa `/bin/echo` como binario para probar la fontanería sin depender de agent-browser.
func test_invoker_returns_stdout_and_exit_code() async throws {
    let invoker = ProcessAgentBrowserInvoker(binaryPath: "/bin/echo")
    let result = await invoker.invoke(arguments: ["hola", "mundo"], timeout: 10)
    let run = try XCTUnwrap(try? result.get())
    XCTAssertEqual(run.exitCode, 0)
    XCTAssertEqual(run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "hola mundo")
}

/// Más de 64 KiB: si las tuberías no se vacían mientras el hijo vive, esto no termina.
func test_invoker_reads_output_larger_than_the_pipe_buffer() async throws {
    let invoker = ProcessAgentBrowserInvoker(binaryPath: "/bin/sh")
    let result = await invoker.invoke(
        arguments: ["-c", "yes abcdefghij | head -c 300000"], timeout: 30)
    let run = try XCTUnwrap(try? result.get())
    XCTAssertGreaterThan(run.standardOutput.count, 200_000)
}

func test_invoker_times_out_and_reports_it() async {
    let invoker = ProcessAgentBrowserInvoker(binaryPath: "/bin/sleep")
    let result = await invoker.invoke(arguments: ["5"], timeout: 0.3)
    guard case .failure(.timedOut) = result else { return XCTFail("got: \(result)") }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/AgentBrowserInvokerTests 2>&1 | tail -20`
Expected: FAIL — no compila, `AgentBrowserBinary` no existe.

- [ ] **Step 3: Implement `AgentBrowserInvoker.swift`**

`resolve` mira, en orden: `AGENT_BROWSER_PATH` del diccionario de entorno, luego cada ruta de `candidatePaths` (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`), y devuelve la primera que `isExecutable` acepte. El respaldo por `/bin/sh -lc "command -v agent-browser"` va en `ProcessAgentBrowserInvoker` (necesita lanzar un proceso), no en `resolve`, que se mantiene pura.

`invoke` copia la estructura de `CLIShortcutRunner.runProcess` (`ShortcutRunner.swift`): `Pipe` para salida y error vaciadas en `Task.detached` **antes** de esperar, espera del proceso con `terminationHandler` más una continuación de un solo uso (con la comprobación de `!process.isRunning` para la carrera de "ya terminó"), y plazo máximo con `withTaskGroup` que llama a `terminate()` al expirar. Entorno: el del padre con `PATH` prefijado por `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` y `AGENT_BROWSER_NO_VERSION_CHECK=1`.

- [ ] **Step 4: Run them to verify they pass**

Run: el mismo comando del paso 2.
Expected: PASS, 8 pruebas.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/NativeServices/AgentBrowserInvoker.swift Gemma/GemmaTests/AgentBrowserInvokerTests.swift
git commit -m "feat(browser): lanzamiento del CLI agent-browser y descubrimiento del binario"
```

---

### Task 2: `AgentBrowserService` — argumentos y envelope

**Files:**
- Create: `Gemma/Gemma/NativeServices/AgentBrowserService.swift`
- Test: `Gemma/GemmaTests/AgentBrowserServiceTests.swift`

**Interfaces:**
- Consumes: `AgentBrowserInvoking`, `MockAgentBrowserInvoker`, `AgentBrowserInvocationFailure` (Tarea 1).
- Produces:
```swift
public enum AgentBrowserOutcome: Sendable, Equatable {
    /// `success: true`. `data` es el objeto `data` reserializado **sin** `lifecycle`.
    case ok(data: Data)
    /// `success: false`; el mensaje es el campo `error` del CLI.
    case refused(message: String)
    case unavailable(reason: String, isMissingBinary: Bool)
    case malformed(rawOutput: String)
}

public struct AgentBrowserService: Sendable {
    public static let defaultSessionName = "gemma"
    public init(invoker: any AgentBrowserInvoking = ProcessAgentBrowserInvoker(),
                sessionName: String = AgentBrowserService.defaultSessionName)
    /// Añade `--json` al final y `--session <nombre>` al principio cuando `sessioned`.
    public func run(command: [String], sessioned: Bool, timeout: TimeInterval) async
        -> AgentBrowserOutcome
    /// Lee el objeto `data` de un `.ok`. `[:]` si no es un objeto JSON.
    public static func fields(_ data: Data) -> [String: Any]
}
```

- [ ] **Step 1: Write the failing tests** in `Gemma/GemmaTests/AgentBrowserServiceTests.swift`

```swift
private func service(_ stdout: String) -> (AgentBrowserService, MockAgentBrowserInvoker) {
    let mock = MockAgentBrowserInvoker.succeeding(stdout: stdout)
    return (AgentBrowserService(invoker: mock, sessionName: "gemma"), mock)
}

func test_sessioned_command_carries_the_session_and_json_flags() async {
    let (svc, mock) = service(#"{"success":true,"data":{},"error":null}"#)
    _ = await svc.run(command: ["open", "https://a.test"], sessioned: true, timeout: 5)
    XCTAssertEqual(mock.receivedArguments.first,
                   ["--session", "gemma", "open", "https://a.test", "--json"])
}

func test_unsessioned_command_omits_the_session_flag() async {
    let (svc, mock) = service(#"{"success":true,"data":{},"error":null}"#)
    _ = await svc.run(command: ["read", "https://a.test"], sessioned: false, timeout: 5)
    XCTAssertEqual(mock.receivedArguments.first, ["read", "https://a.test", "--json"])
}

func test_success_strips_lifecycle_from_data() async throws {
    let (svc, _) = service(#"{"success":true,"data":{"title":"T","lifecycle":{"reused":true}},"error":null}"#)
    guard case .ok(let data) = await svc.run(command: ["get", "title"], sessioned: true, timeout: 5)
    else { return XCTFail("esperaba .ok") }
    let fields = AgentBrowserService.fields(data)
    XCTAssertEqual(fields["title"] as? String, "T")
    XCTAssertNil(fields["lifecycle"], "lifecycle es ruido para el modelo")
}

/// La trampa: el CLI devuelve 0 también cuando falla.
func test_failure_with_exit_code_zero_is_refused_not_ok() async {
    let mock = MockAgentBrowserInvoker(nextResult: .success(
        AgentBrowserInvocation(exitCode: 0,
            standardOutput: #"{"success":false,"data":null,"error":"Unknown ref: e999"}"#,
            standardError: "")))
    let svc = AgentBrowserService(invoker: mock, sessionName: "gemma")
    guard case .refused(let message) = await svc.run(command: ["click", "@e999"], sessioned: true, timeout: 5)
    else { return XCTFail("un success:false nunca es .ok") }
    XCTAssertEqual(message, "Unknown ref: e999")
}

func test_failure_without_an_error_message_still_refuses() async {
    let (svc, _) = service(#"{"success":false,"data":null,"error":null}"#)
    guard case .refused(let message) = await svc.run(command: ["click", "@e1"], sessioned: true, timeout: 5)
    else { return XCTFail("esperaba .refused") }
    XCTAssertFalse(message.isEmpty)
}

// Review Focus 3
func test_empty_stdout_is_malformed() async {
    let (svc, _) = service("")
    guard case .malformed = await svc.run(command: ["snapshot"], sessioned: true, timeout: 5)
    else { return XCTFail("esperaba .malformed") }
}

func test_json_without_the_success_key_is_malformed() async {
    let (svc, _) = service(#"{"data":{"title":"T"}}"#)
    guard case .malformed = await svc.run(command: ["snapshot"], sessioned: true, timeout: 5)
    else { return XCTFail("esperaba .malformed") }
}

func test_non_json_stdout_is_malformed_and_keeps_the_raw_output() async {
    let (svc, _) = service("agent-browser: command not found")
    guard case .malformed(let raw) = await svc.run(command: ["snapshot"], sessioned: true, timeout: 5)
    else { return XCTFail("esperaba .malformed") }
    XCTAssertTrue(raw.contains("not found"))
}

func test_missing_binary_is_unavailable_and_flagged_as_missing() async {
    let mock = MockAgentBrowserInvoker(nextResult: .failure(.binaryNotFound(searchedPaths: ["/a"])))
    let svc = AgentBrowserService(invoker: mock, sessionName: "gemma")
    guard case .unavailable(_, let isMissing) = await svc.run(command: ["open", "x"], sessioned: true, timeout: 5)
    else { return XCTFail("esperaba .unavailable") }
    XCTAssertTrue(isMissing)
}

func test_timeout_is_unavailable_but_not_a_missing_binary() async {
    let mock = MockAgentBrowserInvoker(nextResult: .failure(.timedOut(seconds: 30)))
    let svc = AgentBrowserService(invoker: mock, sessionName: "gemma")
    guard case .unavailable(_, let isMissing) = await svc.run(command: ["open", "x"], sessioned: true, timeout: 5)
    else { return XCTFail("esperaba .unavailable") }
    XCTAssertFalse(isMissing)
}

func test_session_name_comes_from_the_environment_override() {
    XCTAssertEqual(AgentBrowserService.defaultSessionName, "gemma")
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/AgentBrowserServiceTests 2>&1 | tail -20`
Expected: FAIL — `AgentBrowserService` no existe.

- [ ] **Step 3: Implement `AgentBrowserService.swift`**

El orden de decisión de `run` es el del spec §6.2 y no admite atajos: fallo de invocación → `.unavailable`; `stdout` que no parsea como objeto JSON **con la clave `success`** → `.malformed`; `success == false` → `.refused`; sólo entonces `.ok`. El código de salida del proceso no entra en la decisión. El inicializador por omisión toma el nombre de sesión de `AGENT_BROWSER_SESSION` si está definida.

- [ ] **Step 4: Run them to verify they pass**

Run: el mismo comando del paso 2.
Expected: PASS, 11 pruebas.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/NativeServices/AgentBrowserService.swift Gemma/GemmaTests/AgentBrowserServiceTests.swift
git commit -m "feat(browser): servicio que arma los comandos y decodifica el envelope JSON"
```

---

### Task 3: Salida compartida de las herramientas y `read_webpage`

**Files:**
- Create: `Gemma/Gemma/NativeServices/AgentBrowserToolOutput.swift`
- Create: `Gemma/Gemma/NativeServices/ReadWebpageTool.swift`
- Test: `Gemma/GemmaTests/ReadWebpageToolTests.swift`

**Interfaces:**
- Consumes: `AgentBrowserService`, `AgentBrowserOutcome`, `MockAgentBrowserInvoker` (Tareas 1-2).
- Produces:
```swift
public enum AgentBrowserToolOutput {
    /// Aviso de inyección indirecta. Va al final de la descripción de toda
    /// herramienta que devuelva texto de página.
    public static let untrustedContentNotice: String
    /// Frase del contrato de honestidad, común a las nueve descripciones.
    public static let honestyNotice: String
    /// Traduce un outcome no-exitoso al JSON de estado. `nil` cuando es `.ok`.
    public static func failureJSON(_ outcome: AgentBrowserOutcome,
                                   extra: [String: Any?]) -> String?
    /// JSON de `status: error` para un argumento que falta o es inválido.
    public static func invalidArguments(_ message: String) -> String
    public static func truncate(_ text: String, limit: Int) -> (text: String, truncated: Bool)
    /// `true` sólo para `http` y `https`.
    public static func isAllowedWebURL(_ url: String) -> Bool
    /// `true` si el argumento sería absorbido por el parseador de flags del CLI.
    public static func looksLikeCLIFlag(_ text: String) -> Bool
}

public final class ReadWebpageTool: AgentTool, Sendable {
    public static let name = "read_webpage"   // params: url (req), outline (bool), filter (string)
    public init(service: AgentBrowserService)
}
```

- [ ] **Step 1: Write the failing tests** in `Gemma/GemmaTests/ReadWebpageToolTests.swift`

```swift
private func tool(_ stdout: String) -> ReadWebpageTool {
    ReadWebpageTool(service: AgentBrowserService(
        invoker: MockAgentBrowserInvoker.succeeding(stdout: stdout), sessionName: "gemma"))
}
private func parse(_ out: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], "got: \(out)")
}

func test_success_returns_the_content_and_marks_it_untrusted() async throws {
    let out = await tool(#"{"success":true,"data":{"content":"Hola mundo","status":200,"finalUrl":"https://a.test/","truncated":false},"error":null}"#)
        .run(argsJSON: #"{"url":"https://a.test"}"#)
    let json = try parse(out)
    XCTAssertEqual(json["status"] as? String, "success")
    XCTAssertEqual(json["content"] as? String, "Hola mundo")
    XCTAssertEqual(json["final_url"] as? String, "https://a.test/")
    XCTAssertEqual(json["content_is_untrusted"] as? Bool, true)
}

func test_empty_content_is_no_content_not_success() async throws {
    let out = await tool(#"{"success":true,"data":{"content":"   ","status":200},"error":null}"#)
        .run(argsJSON: #"{"url":"https://a.test"}"#)
    XCTAssertEqual(try parse(out)["status"] as? String, "no_content")
}

func test_missing_content_key_is_no_content() async throws {
    let out = await tool(#"{"success":true,"data":{"status":204},"error":null}"#)
        .run(argsJSON: #"{"url":"https://a.test"}"#)
    XCTAssertEqual(try parse(out)["status"] as? String, "no_content")
}

func test_cli_refusal_is_refused_with_its_message() async throws {
    let out = await tool(#"{"success":false,"data":null,"error":"HTTP 404"}"#)
        .run(argsJSON: #"{"url":"https://a.test"}"#)
    let json = try parse(out)
    XCTAssertEqual(json["status"] as? String, "refused")
    XCTAssertEqual(json["message"] as? String, "HTTP 404")
    XCTAssertNil(json["content"], "un fallo no lleva contenido")
}

func test_missing_binary_is_not_available_with_install_instructions() async throws {
    let svc = AgentBrowserService(
        invoker: MockAgentBrowserInvoker(nextResult: .failure(.binaryNotFound(searchedPaths: ["/a"]))),
        sessionName: "gemma")
    let out = await ReadWebpageTool(service: svc).run(argsJSON: #"{"url":"https://a.test"}"#)
    let json = try parse(out)
    XCTAssertEqual(json["status"] as? String, "not_available")
    XCTAssertTrue((json["message"] as? String ?? "").contains("brew install agent-browser"))
}

func test_malformed_output_is_error() async throws {
    let out = await tool("basura").run(argsJSON: #"{"url":"https://a.test"}"#)
    XCTAssertEqual(try parse(out)["status"] as? String, "error")
}

func test_content_over_the_limit_is_truncated_and_says_so() async throws {
    let long = String(repeating: "a", count: 20_000)
    let out = await tool(#"{"success":true,"data":{"content":"\#(long)"},"error":null}"#)
        .run(argsJSON: #"{"url":"https://a.test"}"#)
    let json = try parse(out)
    XCTAssertEqual((json["content"] as? String)?.count, 12_000)
    XCTAssertEqual(json["truncated"] as? Bool, true)
}

func test_cli_truncation_flag_is_propagated() async throws {
    let out = await tool(#"{"success":true,"data":{"content":"corto","truncated":true},"error":null}"#)
        .run(argsJSON: #"{"url":"https://a.test"}"#)
    XCTAssertEqual(try parse(out)["truncated"] as? Bool, true)
}

func test_outline_and_filter_reach_the_cli() async {
    let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"content":"x"},"error":null}"#)
    let t = ReadWebpageTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
    _ = await t.run(argsJSON: #"{"url":"https://a.test","outline":true,"filter":"horario"}"#)
    let args = mock.receivedArguments.first ?? []
    XCTAssertEqual(args.first, "read")
    XCTAssertTrue(args.contains("--outline"))
    XCTAssertEqual(args.firstIndex(of: "--filter").map { args[$0 + 1] }, "horario")
    XCTAssertFalse(args.contains("--session"), "read no necesita sesión")
}

// Review Focus 4
func test_missing_url_is_an_argument_error_without_invoking_the_cli() async throws {
    let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{},"error":null}"#)
    let t = ReadWebpageTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
    let json = try parse(await t.run(argsJSON: #"{}"#))
    XCTAssertEqual(json["status"] as? String, "error")
    XCTAssertTrue(mock.receivedArguments.isEmpty, "no se invoca el CLI sin URL")
}

// Review Focus 2
func test_non_http_schemes_are_refused_without_invoking_the_cli() async throws {
    for url in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,<b>x</b>", "ftp://a.test"] {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{},"error":null}"#)
        let t = ReadWebpageTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        let json = try parse(await t.run(argsJSON: #"{"url":"\#(url)"}"#))
        XCTAssertEqual(json["status"] as? String, "error", "\(url) → got: \(json)")
        XCTAssertTrue(mock.receivedArguments.isEmpty, "\(url) no debe llegar al CLI")
    }
}

func test_description_declares_the_states_and_the_untrusted_warning() {
    let d = ReadWebpageTool.description
    for needle in ["no_content", "refused", "not_available", "error", "DATOS"] {
        XCTAssertTrue(d.contains(needle), "falta '\(needle)' en: \(d)")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/ReadWebpageToolTests 2>&1 | tail -20`
Expected: FAIL — `ReadWebpageTool` no existe.

- [ ] **Step 3: Implement `AgentBrowserToolOutput.swift` y `ReadWebpageTool.swift`**

`looksLikeCLIFlag` devuelve `true` si el texto empieza por `-` **y** coincide exactamente con uno de los flags que el CLI reconoce (`--json`, `--session`, `--timeout`, `-i`, `-s`, `-u`, `-c`, `--full`, `--delta`, `--outline`, `--filter`, `--raw`, `--new-tab`, `--clear`). Verificado en vivo: un texto como `-abc` sí llega entero al navegador; `--json` se lo come el parseador.

`read_webpage` construye `["read", url]` más `--outline` y `--filter <t>` cuando vienen, invoca con `sessioned: false` y plazo 45 s, y mapea: `content` vacío o ausente → `no_content`; si no, `success` con `content` recortado a 12 000, `final_url`, `http_status`, `truncated` y `content_is_untrusted: true`.

La descripción incluye `AgentBrowserToolOutput.honestyNotice` y `untrustedContentNotice`, y dice para qué sirve frente a `web_search`: *`web_search` encuentra la URL, `read_webpage` lee la página entera*.

- [ ] **Step 4: Run them to verify they pass**

Run: el mismo comando del paso 2.
Expected: PASS, 12 pruebas.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/NativeServices/AgentBrowserToolOutput.swift Gemma/Gemma/NativeServices/ReadWebpageTool.swift Gemma/GemmaTests/ReadWebpageToolTests.swift
git commit -m "feat(browser): read_webpage — el agente lee el contenido completo de una URL"
```

---

### Task 4: Navegación — `browser_open`, `browser_snapshot`, `browser_close`

**Files:**
- Create: `Gemma/Gemma/NativeServices/BrowserNavigationTools.swift`
- Test: `Gemma/GemmaTests/BrowserNavigationToolsTests.swift`

**Interfaces:**
- Consumes: `AgentBrowserService`, `AgentBrowserToolOutput` (Tareas 2-3).
- Produces:
```swift
public final class BrowserOpenTool: AgentTool, Sendable {      // name "browser_open";  url (req)
    public init(service: AgentBrowserService) }
public final class BrowserSnapshotTool: AgentTool, Sendable {  // name "browser_snapshot"; interactive_only (bool, def. true), selector (string, opt)
    public init(service: AgentBrowserService) }
public final class BrowserCloseTool: AgentTool, Sendable {     // name "browser_close"; sin parámetros
    public init(service: AgentBrowserService) }
```

- [ ] **Step 1: Write the failing tests** in `Gemma/GemmaTests/BrowserNavigationToolsTests.swift`

```swift
func test_open_returns_the_title_and_url() async throws {
    let out = await BrowserOpenTool(service: svc(#"{"success":true,"data":{"title":"Ejemplo","url":"https://a.test/"},"error":null}"#))
        .run(argsJSON: #"{"url":"https://a.test"}"#)
    let json = try parse(out)
    XCTAssertEqual(json["status"] as? String, "success")
    XCTAssertEqual(json["title"] as? String, "Ejemplo")
    XCTAssertEqual(json["url"] as? String, "https://a.test/")
}

func test_open_uses_the_gemma_session() async {
    let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"title":"T","url":"u"},"error":null}"#)
    _ = await BrowserOpenTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        .run(argsJSON: #"{"url":"https://a.test"}"#)
    XCTAssertEqual(mock.receivedArguments.first,
                   ["--session", "gemma", "open", "https://a.test", "--json"])
}

// Review Focus 2
func test_open_refuses_non_http_schemes_without_invoking_the_cli() async throws { /* file://, javascript:, data: */ }
// Review Focus 4
func test_open_without_url_is_an_argument_error() async throws { }

func test_snapshot_returns_the_tree_and_the_refs_marked_untrusted() async throws {
    let out = await BrowserSnapshotTool(service: svc(#"{"success":true,"data":{"snapshot":"- link \"Más\" [ref=e1]","refs":{"e1":{"name":"Más","role":"link"}},"origin":"https://a.test/"},"error":null}"#))
        .run(argsJSON: #"{}"#)
    let json = try parse(out)
    XCTAssertEqual(json["status"] as? String, "success")
    XCTAssertTrue((json["snapshot"] as? String ?? "").contains("ref=e1"))
    XCTAssertEqual(json["element_count"] as? Int, 1)
    XCTAssertEqual(json["content_is_untrusted"] as? Bool, true)
}

func test_snapshot_defaults_to_interactive_only() async {
    let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"snapshot":"x","refs":{}},"error":null}"#)
    _ = await BrowserSnapshotTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma")).run(argsJSON: #"{}"#)
    XCTAssertTrue((mock.receivedArguments.first ?? []).contains("-i"))
}

func test_snapshot_full_tree_when_asked_and_scopes_to_a_selector() async {
    let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"snapshot":"x","refs":{}},"error":null}"#)
    _ = await BrowserSnapshotTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        .run(argsJSON: #"{"interactive_only":false,"selector":"#main"}"#)
    let args = mock.receivedArguments.first ?? []
    XCTAssertFalse(args.contains("-i"))
    XCTAssertEqual(args.firstIndex(of: "-s").map { args[$0 + 1] }, "#main")
}

func test_empty_snapshot_is_no_content() async throws {
    let out = await BrowserSnapshotTool(service: svc(#"{"success":true,"data":{"snapshot":"","refs":{}},"error":null}"#))
        .run(argsJSON: #"{}"#)
    XCTAssertEqual(try parse(out)["status"] as? String, "no_content")
}

func test_long_snapshot_is_truncated_at_8000_with_a_hint() async throws {
    // 8 000 caracteres y truncated:true; el mensaje sugiere acotar con `selector`.
}

func test_snapshot_without_an_open_page_is_refused() async throws {
    let out = await BrowserSnapshotTool(service: svc(#"{"success":false,"data":null,"error":"No active page"}"#))
        .run(argsJSON: #"{}"#)
    let json = try parse(out)
    XCTAssertEqual(json["status"] as? String, "refused")
    XCTAssertEqual(json["message"] as? String, "No active page")
}

func test_close_reports_success_and_takes_no_parameters() async throws {
    let out = await BrowserCloseTool(service: svc(#"{"success":true,"data":{},"error":null}"#)).run(argsJSON: #"{}"#)
    XCTAssertEqual(try parse(out)["status"] as? String, "success")
    XCTAssertTrue(BrowserCloseTool.parameters.isEmpty)
}

func test_all_three_descriptions_declare_the_states() { }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/BrowserNavigationToolsTests 2>&1 | tail -20`
Expected: FAIL — las tres clases no existen.

- [ ] **Step 3: Implement `BrowserNavigationTools.swift`**

Las tres comparten el ayudante de Tarea 3. `browser_open` valida el esquema con `isAllowedWebURL` antes de invocar; plazo 60 s. `browser_snapshot` arma `["snapshot"]` más `-i` (salvo `interactive_only:false`) y `-s <sel>`; plazo 30 s; `element_count` sale del número de claves de `data.refs`. `browser_close` es `["close"]` con plazo 30 s. La descripción de `browser_snapshot` explica el bucle: *mira, actúa sobre una referencia `@eN`, vuelve a mirar; una navegación invalida las referencias*.

- [ ] **Step 4: Run them to verify they pass**

Run: el mismo comando del paso 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/NativeServices/BrowserNavigationTools.swift Gemma/GemmaTests/BrowserNavigationToolsTests.swift
git commit -m "feat(browser): browser_open, browser_snapshot y browser_close"
```

---

### Task 5: Interacción — `browser_click`, `browser_fill`, `browser_press`

**Files:**
- Create: `Gemma/Gemma/NativeServices/BrowserInteractionTools.swift`
- Test: `Gemma/GemmaTests/BrowserInteractionToolsTests.swift`

**Interfaces:**
- Consumes: `AgentBrowserService`, `AgentBrowserToolOutput` (Tareas 2-3).
- Produces:
```swift
public final class BrowserClickTool: AgentTool, Sendable { // "browser_click"; selector (req)
    public init(service: AgentBrowserService) }
public final class BrowserFillTool: AgentTool, Sendable {  // "browser_fill";  selector (req), text (req)
    public init(service: AgentBrowserService) }
public final class BrowserPressTool: AgentTool, Sendable { // "browser_press"; key (req)
    public init(service: AgentBrowserService) }
```

- [ ] **Step 1: Write the failing tests** in `Gemma/GemmaTests/BrowserInteractionToolsTests.swift`

```swift
func test_click_passes_the_ref_through() async {
    let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{},"error":null}"#)
    _ = await BrowserClickTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        .run(argsJSON: #"{"selector":"@e3"}"#)
    XCTAssertEqual(mock.receivedArguments.first, ["--session", "gemma", "click", "@e3", "--json"])
}

func test_click_on_an_unknown_ref_is_refused_with_the_cli_message() async throws {
    let out = await BrowserClickTool(service: svc(#"{"success":false,"data":null,"error":"Unknown ref: e999"}"#))
        .run(argsJSON: #"{"selector":"@e999"}"#)
    let json = try parse(out)
    XCTAssertEqual(json["status"] as? String, "refused")
    XCTAssertEqual(json["message"] as? String, "Unknown ref: e999")
}

func test_fill_sends_selector_then_text() async {
    let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"filled":"@e2"},"error":null}"#)
    _ = await BrowserFillTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        .run(argsJSON: #"{"selector":"@e2","text":"hola"}"#)
    XCTAssertEqual(mock.receivedArguments.first,
                   ["--session", "gemma", "fill", "@e2", "hola", "--json"])
}

func test_fill_accepts_text_that_merely_starts_with_a_dash() async {
    // "-abc" llega entero al navegador (verificado en vivo): debe invocarse el CLI.
}

// Review Focus 1
func test_fill_refuses_text_that_the_cli_would_eat_as_a_flag() async throws {
    let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"filled":"@e2"},"error":null}"#)
    let t = BrowserFillTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
    let json = try parse(await t.run(argsJSON: #"{"selector":"@e2","text":"--json"}"#))
    XCTAssertEqual(json["status"] as? String, "refused")
    XCTAssertTrue(mock.receivedArguments.isEmpty,
                  "el CLI se comería --json como flag y rellenaría el campo vacío reportando éxito")
}

// Review Focus 4
func test_fill_without_text_is_an_argument_error() async throws { }
func test_click_without_selector_is_an_argument_error() async throws { }

func test_fill_with_empty_text_clears_the_field_and_is_allowed() async {
    // `fill <sel> ""` es la forma de vaciar un campo: debe llegar al CLI.
}

func test_press_passes_the_key_combo() async {
    let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{},"error":null}"#)
    _ = await BrowserPressTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        .run(argsJSON: #"{"key":"Control+a"}"#)
    XCTAssertEqual(mock.receivedArguments.first, ["--session", "gemma", "press", "Control+a", "--json"])
}

func test_fill_description_forbids_passwords() {
    XCTAssertTrue(BrowserFillTool.description.lowercased().contains("contraseñ"))
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/BrowserInteractionToolsTests 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Implement `BrowserInteractionTools.swift`**

Las tres usan plazo 30 s. `browser_fill` comprueba `looksLikeCLIFlag` sobre `text` **y** sobre `selector` antes de invocar, y devuelve `refused` con un mensaje que explica la limitación del CLI. Distingue "`text` ausente" (error de argumentos) de "`text` vacío" (vaciar el campo, válido). La descripción de `browser_fill` prohíbe explícitamente usarla para contraseñas o tokens y dice que hay que pedírselos al usuario.

- [ ] **Step 4: Run them to verify they pass**

Run: el mismo comando del paso 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/NativeServices/BrowserInteractionTools.swift Gemma/GemmaTests/BrowserInteractionToolsTests.swift
git commit -m "feat(browser): browser_click, browser_fill y browser_press"
```

---

### Task 6: Comprobación — `browser_wait` y `browser_get`

**Files:**
- Create: `Gemma/Gemma/NativeServices/BrowserInspectionTools.swift`
- Test: `Gemma/GemmaTests/BrowserInspectionToolsTests.swift`

**Interfaces:**
- Consumes: `AgentBrowserService`, `AgentBrowserToolOutput` (Tareas 2-3).
- Produces:
```swift
public final class BrowserWaitTool: AgentTool, Sendable {
    // "browser_wait"; text | url_pattern | selector | milliseconds — exactamente uno
    public init(service: AgentBrowserService) }
public final class BrowserGetTool: AgentTool, Sendable {
    // "browser_get"; what (req: text|html|value|title|url|count), selector (opt)
    public init(service: AgentBrowserService) }
```

- [ ] **Step 1: Write the failing tests** in `Gemma/GemmaTests/BrowserInspectionToolsTests.swift`

```swift
func test_wait_for_text_uses_the_text_flag() async {
    let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{},"error":null}"#)
    _ = await BrowserWaitTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        .run(argsJSON: #"{"text":"Listo"}"#)
    XCTAssertEqual(mock.receivedArguments.first,
                   ["--session", "gemma", "wait", "--text", "Listo", "--json"])
}

func test_wait_for_url_pattern_and_for_a_selector_and_for_milliseconds() async {
    // --url "**/panel" | el selector posicional | el número posicional
}

// Review Focus 5
func test_wait_without_any_criterion_is_an_argument_error() async throws {
    let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{},"error":null}"#)
    let t = BrowserWaitTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
    let json = try parse(await t.run(argsJSON: #"{}"#))
    XCTAssertEqual(json["status"] as? String, "error")
    XCTAssertTrue(mock.receivedArguments.isEmpty)
}

func test_wait_with_two_criteria_is_an_argument_error() async throws {
    let json = try parse(await waitTool().run(argsJSON: #"{"text":"Listo","selector":"@e1"}"#))
    XCTAssertEqual(json["status"] as? String, "error")
    XCTAssertTrue((json["message"] as? String ?? "").contains("exactamente uno"))
}

func test_wait_timeout_from_the_cli_is_refused_not_error() async throws {
    let out = await BrowserWaitTool(service: svc(#"{"success":false,"data":null,"error":"Timeout 25000ms exceeded waiting for text \"Listo\""}"#))
        .run(argsJSON: #"{"text":"Listo"}"#)
    let json = try parse(out)
    XCTAssertEqual(json["status"] as? String, "refused")
    XCTAssertTrue((json["message"] as? String ?? "").contains("Timeout"))
}

func test_get_text_returns_the_value_marked_untrusted() async throws {
    let out = await BrowserGetTool(service: svc(#"{"success":true,"data":{"text":"Hola"},"error":null}"#))
        .run(argsJSON: #"{"what":"text","selector":"@e1"}"#)
    let json = try parse(out)
    XCTAssertEqual(json["status"] as? String, "success")
    XCTAssertEqual(json["value"] as? String, "Hola")
    XCTAssertEqual(json["content_is_untrusted"] as? Bool, true)
}

func test_get_url_and_title_need_no_selector() async {
    let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"url":"https://a.test/"},"error":null}"#)
    _ = await BrowserGetTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        .run(argsJSON: #"{"what":"url"}"#)
    XCTAssertEqual(mock.receivedArguments.first, ["--session", "gemma", "get", "url", "--json"])
}

func test_get_count_returns_a_number() async throws {
    let out = await BrowserGetTool(service: svc(#"{"success":true,"data":{"count":7},"error":null}"#))
        .run(argsJSON: #"{"what":"count","selector":"li"}"#)
    XCTAssertEqual(try parse(out)["value"] as? Int, 7)
}

func test_get_empty_text_is_no_content() async throws {
    let out = await BrowserGetTool(service: svc(#"{"success":true,"data":{"text":""},"error":null}"#))
        .run(argsJSON: #"{"what":"text","selector":"@e1"}"#)
    XCTAssertEqual(try parse(out)["status"] as? String, "no_content")
}

// Review Focus 4
func test_get_with_an_unknown_what_is_an_argument_error() async throws {
    let json = try parse(await getTool().run(argsJSON: #"{"what":"cookies"}"#))
    XCTAssertEqual(json["status"] as? String, "error")
}

func test_get_html_is_truncated_at_8000() async throws { }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/BrowserInspectionToolsTests 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Implement `BrowserInspectionTools.swift`**

`browser_wait`: cuenta cuántos de los cuatro criterios llegaron; distinto de uno → error de argumentos con la palabra "exactamente uno". Plazo 40 s, por encima de los 25 s internos del CLI, para que el mensaje de expiración sea el del CLI (que dice qué se esperaba) y no el nuestro. `browser_get`: `what` se valida contra la lista cerrada; el valor se lee de la clave homónima de `data` (`text`, `html`, `value`, `title`, `url`, `count`); `html` se recorta a 8 000; cadena vacía → `no_content`.

- [ ] **Step 4: Run them to verify they pass**

Run: el mismo comando del paso 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/NativeServices/BrowserInspectionTools.swift Gemma/GemmaTests/BrowserInspectionToolsTests.swift
git commit -m "feat(browser): browser_wait y browser_get"
```

---

### Task 7: Registro en el agente y línea de prompt

**Files:**
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift` (bloque de `registry.register(...)` de `runAgentTurn`, junto a `registry.register(WebSearchTool())`)
- Modify: el prompt del sistema del agente (`Gemma/Gemma/Agent/Agent.swift`, donde se arma el texto estático)
- Test: `Gemma/GemmaTests/AgentBrowserRegistrationTests.swift`

**Interfaces:**
- Consumes: las nueve clases de las Tareas 3-6.
- Produces: nada que consuman tareas posteriores.

- [ ] **Step 1: Write the failing tests** in `Gemma/GemmaTests/AgentBrowserRegistrationTests.swift`

```swift
@MainActor
func test_the_nine_browser_tools_are_registered() {
    let registry = HarnessModel.browserToolRegistry()   // ver paso 3
    for name in ["read_webpage", "browser_open", "browser_snapshot", "browser_click",
                 "browser_fill", "browser_press", "browser_wait", "browser_get", "browser_close"] {
        XCTAssertNotNil(registry.tool(named: name), "falta \(name)")
    }
}

@MainActor
func test_every_browser_tool_has_a_valid_function_spec() {
    // name no vacío, description no vacía, jsonSchema con "type": "object"
}

func test_system_prompt_points_web_search_at_read_webpage() {
    let prompt = Agent.systemPromptText
    XCTAssertTrue(prompt.contains("read_webpage"))
    XCTAssertTrue(prompt.contains("browser_snapshot"))
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/AgentBrowserRegistrationTests 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Register the tools and extend the prompt**

En `HarnessModel`, extraer el registro de las nueve a un método estático `browserToolRegistry() -> ToolRegistry` (para poder probarlo sin arrancar un turno) y llamarlo desde `runAgentTurn` justo tras `registry.register(WebSearchTool())`, dentro de `#if os(macOS)`. Las nueve comparten **una sola** instancia de `AgentBrowserService`.

Añadir al prompt del sistema la línea del spec §6.4: `web_search` encuentra URLs, `read_webpage` lee la página completa, y el bucle `browser_open` → `browser_snapshot` → actuar → `browser_snapshot` para lo interactivo.

- [ ] **Step 4: Run the whole suite**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' 2>&1 | tail -25`
Expected: PASS salvo `HarnessModelTests/test_defaultBaseURL`, que ya fallaba en `main`.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Harness/HarnessModel.swift Gemma/Gemma/Agent/Agent.swift Gemma/GemmaTests/AgentBrowserRegistrationTests.swift
git commit -m "feat(browser): registrar las nueve herramientas de navegador y guiar al modelo en el prompt"
```

---

### Task 8: Prueba de integración en vivo y actualización del grafo

**Files:**
- Create: `Gemma/GemmaTests/AgentBrowserLiveTests.swift`
- Modify: `graphify-out/` (salida de `graphify update .`)

**Interfaces:**
- Consumes: todo lo anterior.
- Produces: nada.

- [ ] **Step 1: Write the live test, skipped unless asked for**

```swift
/// Invoca el binario de verdad. Desactivada por omisión:
///   GEMMA_LIVE_BROWSER=1 xcodebuild test … -only-testing:GemmaTests/AgentBrowserLiveTests
final class AgentBrowserLiveTests: XCTestCase {
    private func requireLive() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GEMMA_LIVE_BROWSER"] == "1",
                          "Prueba en vivo: pon GEMMA_LIVE_BROWSER=1")
    }

    func test_read_webpage_reads_example_dot_com() async throws {
        try requireLive()
        let out = await ReadWebpageTool(service: AgentBrowserService()).run(argsJSON: #"{"url":"https://example.com"}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "success", "got: \(out)")
        XCTAssertTrue((json["content"] as? String ?? "").contains("documentation"))
    }

    func test_open_snapshot_and_close_round_trip() async throws {
        try requireLive()
        let service = AgentBrowserService()
        // open https://example.com → status success
        // snapshot → status success y el árbol contiene "ref=e"
        // close → status success
    }
}
```

- [ ] **Step 2: Run it both ways**

Run (apagada): `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/AgentBrowserLiveTests 2>&1 | tail -10`
Expected: las pruebas se saltan (skipped).

Run (encendida): `GEMMA_LIVE_BROWSER=1 xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/AgentBrowserLiveTests 2>&1 | tail -15`
Expected: PASS contra el binario real.

- [ ] **Step 3: Update the knowledge graph**

Run: `graphify update .`

- [ ] **Step 4: Commit**

```bash
git add Gemma/GemmaTests/AgentBrowserLiveTests.swift graphify-out
git commit -m "test(browser): prueba de integración en vivo contra el binario y grafo actualizado"
```

**Cuidado:** no usar `git add -A` en este repositorio. Barre los snapshots `graphify-out/<fecha>/graph.json`, y alguno supera los 100 MB del límite de GitHub.
