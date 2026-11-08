import Foundation

/// Resultado de una orden al navegador, ya interpretado.
public enum AgentBrowserOutcome: Sendable, Equatable {
    /// `success: true`. `data` es el objeto `data` reserializado **sin** `lifecycle`.
    case ok(data: Data)
    /// `success: false`; el mensaje es el campo `error` del CLI.
    case refused(message: String)
    /// No se pudo ejecutar el CLI (falta el binario, plazo vencido, fallo al lanzar).
    case unavailable(reason: String, isMissingBinary: Bool)
    /// La salida no es el envelope esperado. Conserva el texto crudo para diagnosticar.
    case malformed(rawOutput: String)
}

/// Arma los argumentos del CLI `agent-browser`, lo invoca y decodifica su envelope JSON
/// uniforme `{"success":…, "data":…, "error":…}`.
public struct AgentBrowserService: Sendable {
    /// Nombre de sesión por omisión: el navegador del agente persiste entre llamadas.
    public static let defaultSessionName = "gemma"
    /// Variable de entorno que permite cambiar el nombre de sesión.
    public static let sessionVariable = "AGENT_BROWSER_SESSION"

    private let invoker: any AgentBrowserInvoking
    private let sessionName: String

    /// Multiplataforma: el invocador es HTTP puro (o un doble de prueba), sin proceso local.
    public init(invoker: any AgentBrowserInvoking,
                sessionName: String = AgentBrowserService.environmentSessionName()) {
        self.invoker = invoker
        self.sessionName = sessionName
    }

    #if os(macOS)
    /// Solo macOS: usa el `agent-browser` local (`ProcessAgentBrowserInvoker`). En iOS no hay
    /// binario que lanzar, así que este inicializador no existe.
    public init(sessionName: String = AgentBrowserService.environmentSessionName()) {
        self.init(invoker: ProcessAgentBrowserInvoker(), sessionName: sessionName)
    }
    #endif

    /// `AGENT_BROWSER_SESSION` si está definida y no vacía; si no, `defaultSessionName`.
    public static func environmentSessionName() -> String {
        if let value = ProcessInfo.processInfo.environment[sessionVariable], !value.isEmpty {
            return value
        }
        return defaultSessionName
    }

    /// Añade `--json` al final y `--session <nombre>` al principio cuando `sessioned`.
    ///
    /// Orden de decisión (no admite atajos): fallo de invocación -> `.unavailable`;
    /// stdout que no es un objeto JSON con la clave `success` -> `.malformed`;
    /// `success == false` -> `.refused`; solo entonces `.ok`.
    /// El código de salida NO cuenta: el CLI sale con 0 aunque la orden falle.
    public func run(command: [String], sessioned: Bool, timeout: TimeInterval) async
        -> AgentBrowserOutcome {
        var arguments = command + ["--json"]
        if sessioned { arguments = ["--session", sessionName] + arguments }

        let invocation: AgentBrowserInvocation
        switch await invoker.invoke(arguments: arguments, timeout: timeout) {
        case .failure(let failure):
            return Self.unavailable(for: failure)
        case .success(let value):
            invocation = value
        }

        let raw = invocation.standardOutput
        guard let bytes = raw.data(using: .utf8),
              let envelope = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let success = envelope["success"] as? Bool else {
            return .malformed(rawOutput: raw)
        }

        guard success else {
            let message = (envelope["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .refused(message: message ?? "El navegador rechazó la orden sin dar motivo.")
        }

        var data = envelope["data"] as? [String: Any] ?? [:]
        data.removeValue(forKey: "lifecycle")
        guard let encoded = try? JSONSerialization.data(withJSONObject: data) else {
            return .malformed(rawOutput: raw)
        }
        return .ok(data: encoded)
    }

    /// Lee el objeto `data` de un `.ok`. `[:]` si no es un objeto JSON.
    public static func fields(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func unavailable(for failure: AgentBrowserInvocationFailure) -> AgentBrowserOutcome {
        switch failure {
        case .binaryNotFound(let searchedPaths):
            return .unavailable(
                reason: "No se encontró agent-browser. Rutas probadas: \(searchedPaths.joined(separator: ", ")).",
                isMissingBinary: true)
        case .timedOut(let seconds):
            return .unavailable(reason: "agent-browser superó el plazo de \(Int(seconds)) s.",
                                isMissingBinary: false)
        case .launchFailed(let detail):
            return .unavailable(reason: "No se pudo lanzar agent-browser: \(detail)",
                                isMissingBinary: false)
        }
    }
}

