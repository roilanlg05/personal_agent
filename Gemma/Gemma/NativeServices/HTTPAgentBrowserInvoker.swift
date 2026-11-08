import Foundation

#if os(macOS)

/// Conduce `agent-browser` en el servidor doméstico (el i3) en vez de lanzar un proceso local.
///
/// Reenvía el `argv` tal cual a `POST <base>/v1/browser/invoke` y devuelve el `stdout` que el
/// servicio le dé, sin interpretarlo: el envelope del CLI es asunto de `AgentBrowserService`.
/// Por eso las herramientas de navegador no cambian al pasar de un invocador a otro.
///
/// Todo lo que no sea una ejecución del CLI (transporte caído, 401, 400 del servicio, cuerpo
/// ilegible) es `.launchFailed` con un motivo que nombra el i3, igual que hoy un binario
/// ausente: el turno del agente no se rompe y el usuario sabe dónde mirar.
///
/// Seguridad: el token viaja en la cabecera `Authorization`, nunca en la URL. El `argv` puede
/// llevar texto del usuario, así que ni el cuerpo ni el `argv` aparecen en ningún mensaje de error.
public struct HTTPAgentBrowserInvoker: AgentBrowserInvoking, Sendable {
    /// Segundos que se suman al plazo del CLI: el viaje de red va aparte del trabajo del navegador.
    static let networkMargin: TimeInterval = 15

    private let baseURL: URL
    private let bearerToken: String
    private let session: URLSession

    public init(baseURL: URL, bearerToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.session = session
    }

    private struct RequestBody: Encodable {
        let arguments: [String]
        let timeout: TimeInterval
    }

    private struct ResponseBody: Decodable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private struct ErrorBody: Decodable { let detail: String? }

    public func invoke(arguments: [String], timeout: TimeInterval) async
        -> Result<AgentBrowserInvocation, AgentBrowserInvocationFailure> {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/browser/invoke"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout + Self.networkMargin
        do {
            request.httpBody = try JSONEncoder().encode(RequestBody(arguments: arguments, timeout: timeout))
        } catch {
            return .failure(.launchFailed("No pude preparar la petición al navegador del i3."))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if (error as? URLError)?.code == .timedOut { return .failure(.timedOut(seconds: timeout)) }
            return .failure(.launchFailed(
                "No pude hablar con el navegador del i3 (\(baseURL.host ?? "sin host")): "
                + "\(error.localizedDescription) Revisa que el servicio esté arriba y Tailscale conectado."))
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure(.launchFailed("El i3 respondió algo que no es HTTP."))
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.launchFailed(Self.describe(status: http.statusCode, body: data)))
        }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            return .failure(.launchFailed("El i3 respondió 200 pero con un cuerpo que no entiendo."))
        }
        return .success(AgentBrowserInvocation(exitCode: decoded.exitCode,
                                               standardOutput: decoded.stdout,
                                               standardError: decoded.stderr))
    }

    private static func describe(status: Int, body: Data) -> String {
        let detail = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.detail
        switch status {
        case 401:
            return "El i3 rechazó el token del navegador (401). Revisa el token en Ajustes."
        case 400:
            return "El servicio del navegador en el i3 rechazó la orden (400): \(detail ?? "sin motivo")."
        default:
            return "El navegador del i3 respondió \(status)" + (detail.map { ": \($0)" } ?? ".")
        }
    }
}

#endif
