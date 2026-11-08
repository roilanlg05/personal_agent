import Foundation
// Portabilidad: este fichero SOLO importa Foundation, a propósito. Un cliente
// de iOS lo reusará tal cual. No decodifica la imagen: el JPEG sube en bytes.

/// Lo que el relé del i3 puede decirle al visor. Seis casos, ninguno con sitio
/// para parámetros de acciones: ni programando mal se podría transportar un secreto.
public nonisolated enum BrowserRelayEvent: Equatable, Sendable {
    case frame(seq: Int, jpeg: Data, capturedAt: Date)
    case narration(String)
    case host(String)
    case state(live: Bool, collapsed: Bool)
    case summary(String)
    case closed(reason: String)
}

/// Visor del WebSocket `/v1/browser/stream`. Acusa cada frame (el relé no acusa
/// al demonio hasta que se lo acusan a él) y reconecta con retroceso exponencial
/// cuando el relé cierra, porque el relé no se reengancha solo.
public actor BrowserRelayClient {
    /// Retroceso: 1, 2, 4, 8, 16, 30 s (tope). Sin esto, un `closed` inmediato
    /// (servicio del navegador caído) sería una tormenta de reconexiones.
    public static let maxReconnectDelay: TimeInterval = 30
    /// Fallos CONSECUTIVOS sin recibir ni un frame antes de rendirse (~2 min de espera total).
    public static let maxReconnectAttempts = 8

    public static func reconnectDelay(attempt: Int) -> TimeInterval {
        let exponent = max(0, min(attempt - 1, 10))
        return min(maxReconnectDelay, TimeInterval(1 << exponent))
    }

    private let baseURL: URL
    private let bearerToken: String
    private let maxFps: Int
    private let session: URLSession
    private var loop: Task<Void, Never>?
    private var continuation: AsyncStream<BrowserRelayEvent>.Continuation?
    private var generation = 0

    public init(baseURL: URL, bearerToken: String, maxFps: Int = 10, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.maxFps = maxFps
        self.session = session
    }

    // MARK: puras

    public static func socketURL(baseURL: URL, maxFps: Int) -> URL? {
        guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        switch parts.scheme?.lowercased() {
        case "http", "ws": parts.scheme = "ws"
        case "https", "wss": parts.scheme = "wss"
        default: return nil
        }
        let base = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.path = base + "/v1/browser/stream"
        parts.queryItems = [URLQueryItem(name: "maxFps", value: String(maxFps))]
        return parts.url
    }

    public static func decode(_ text: String) -> BrowserRelayEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "frame":
            guard let seq = (object["seq"] as? NSNumber)?.intValue,
                  let b64 = object["jpeg"] as? String,
                  // El relé puede pasar base64 envuelto en líneas; sin esto el panel quedaría negro.
                  let jpeg = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                  let seconds = (object["captured_at"] as? NSNumber)?.doubleValue else { return nil }
            return .frame(seq: seq, jpeg: jpeg, capturedAt: Date(timeIntervalSince1970: seconds))
        case "narration":
            return (object["text"] as? String).map { .narration($0) }
        case "host":
            return (object["host"] as? String).map { .host($0) }
        case "state":
            guard let live = object["live"] as? Bool, let collapsed = object["collapsed"] as? Bool else { return nil }
            return .state(live: live, collapsed: collapsed)
        case "summary":
            return (object["text"] as? String).map { .summary($0) }
        case "closed":
            return .closed(reason: (object["reason"] as? String) ?? "")
        default:
            return nil
        }
    }

    public static func ackPayload(seq: Int) -> String {
        "{\"type\":\"ack\",\"seq\":\(seq)}"
    }

    // MARK: ciclo de vida

    /// Un solo consumidor a la vez: pedir otro flujo termina el anterior.
    public func events() -> AsyncStream<BrowserRelayEvent> {
        endCurrent()
        generation += 1
        let mine = generation
        let (stream, cont) = AsyncStream<BrowserRelayEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation = cont
        loop = Task { [weak self] in
            await self?.run(cont)
            await self?.finishIfCurrent(generation: mine)
        }
        // Cancelar al consumidor cancela el bucle, y éste cierra el socket.
        cont.onTermination = { [weak self] _ in
            Task { await self?.terminated(generation: mine) }
        }
        return stream
    }

    public func stop() {
        endCurrent()
    }

    private func endCurrent() {
        loop?.cancel()
        loop = nil
        continuation?.finish()
        continuation = nil
    }

    private func terminated(generation g: Int) {
        guard g == generation else { return }
        loop?.cancel()
        loop = nil
        continuation = nil
    }

    private func finishIfCurrent(generation g: Int) {
        guard g == generation else { return }
        continuation?.finish()
        continuation = nil
        loop = nil
    }

    // MARK: bucle

    private func run(_ cont: AsyncStream<BrowserRelayEvent>.Continuation) async {
        guard let url = Self.socketURL(baseURL: baseURL, maxFps: maxFps) else {
            cont.yield(.closed(reason: "URL del relé inválida"))
            return
        }
        var failures = 0
        while !Task.isCancelled {
            let gotFrame = await runOnce(url: url, cont)
            if Task.isCancelled { return }
            failures = gotFrame ? 1 : failures + 1
            if failures > Self.maxReconnectAttempts { return }
            do { try await Task.sleep(for: .seconds(Self.reconnectDelay(attempt: failures))) }
            catch { return }
        }
    }

    /// Una conexión. Devuelve si llegó al menos un frame (conexión sana).
    private func runOnce(url: URL, _ cont: AsyncStream<BrowserRelayEvent>.Continuation) async -> Bool {
        var request = URLRequest(url: url)
        // El token va SOLO en la cabecera del handshake, nunca en la URL.
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.resume()
        var gotFrame = false
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do { message = try await socket.receive() }
                catch {
                    if !Task.isCancelled { cont.yield(.closed(reason: "fallo de recepción")) }
                    break
                }
                guard case .string(let text) = message, let event = Self.decode(text) else { continue }
                if case .frame(let seq, _, _) = event {
                    gotFrame = true
                    try? await socket.send(.string(Self.ackPayload(seq: seq)))
                }
                cont.yield(event)
                if case .closed = event { break }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
        socket.cancel(with: .goingAway, reason: nil)
        return gotFrame
    }
}
