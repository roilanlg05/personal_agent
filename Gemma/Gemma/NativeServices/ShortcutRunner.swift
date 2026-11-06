import Foundation

/// Cómo acabó la ejecución de un atajo.
public enum ShortcutRunOutcome: String, Sendable {
    /// El atajo terminó. Puede traer salida o no, según lo que produzca.
    case ok
    /// El usuario canceló desde la app Atajos.
    case cancelled
    /// Atajos informó de un error (nombre inexistente, acción fallida...).
    case failed
    /// No llegó respuesta en el plazo previsto.
    case timedOut = "timeout"
    /// La app Atajos no está disponible en este dispositivo.
    case notAvailable = "not_available"
}

public struct ShortcutRunResult: Sendable, Equatable {
    public let outcome: ShortcutRunOutcome
    public let output: String?
    public let errorMessage: String?

    public init(outcome: ShortcutRunOutcome, output: String? = nil, errorMessage: String? = nil) {
        self.outcome = outcome
        self.output = output
        self.errorMessage = errorMessage
    }
}

/// Ejecuta atajos de la app Atajos.
public protocol ShortcutRunning: Sendable {
    /// Nombres de los atajos disponibles, o `nil` si la plataforma no permite
    /// enumerarlos.
    ///
    /// En iOS no existe API pública para listar los atajos del usuario: allí devuelve
    /// `nil`, y quien llama debe asumir que no puede validar el nombre por adelantado.
    /// En macOS se obtiene con `shortcuts list`.
    func listAvailableNames() async -> [String]?

    /// Ejecuta el atajo y devuelve lo que ocurrió, incluida su salida de texto.
    func run(name: String, input: String?) async -> ShortcutRunResult
}

// MARK: - Callback de Atajos

/// Respuesta que la app Atajos devuelve a Gemma al terminar un atajo.
///
/// Se transporta por el esquema `gemma://shortcut-callback`, que la app ya tiene
/// registrado. Atajos añade a la URL de éxito un parámetro `result` con la salida
/// textual del atajo (si el atajo produce alguna).
public struct ShortcutCallback: Sendable, Equatable {
    public let token: String
    public let outcome: ShortcutRunOutcome
    public let output: String?
    public let errorMessage: String?

    /// Nombre del host que identifica estos callbacks dentro del esquema `gemma://`.
    public static let host = "shortcut-callback"

    public init?(url: URL) {
        guard url.scheme == "gemma", url.host == ShortcutCallback.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let items = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        // Sin token no se puede saber a qué ejecución pertenece la respuesta.
        guard let token = items["token"], !token.isEmpty else { return nil }

        self.token = token
        switch items["status"] {
        case "success": self.outcome = .ok
        case "cancel": self.outcome = .cancelled
        default: self.outcome = .failed
        }
        let result = items["result"]
        self.output = (result?.isEmpty ?? true) ? nil : result
        let error = items["errorMessage"]
        self.errorMessage = (error?.isEmpty ?? true) ? nil : error
    }

    public var result: ShortcutRunResult {
        ShortcutRunResult(outcome: outcome, output: output, errorMessage: errorMessage)
    }
}

/// Casa cada respuesta de Atajos con la llamada que la está esperando.
///
/// Ejecutar un atajo en iOS es un viaje de ida y vuelta entre apps: Gemma abre una URL,
/// el sistema pasa a Atajos y, al terminar, Atajos abre una URL de vuelta. Este actor
/// mantiene un testigo por ejecución para emparejar la vuelta con la ida, con un plazo
/// máximo por si el usuario se queda en Atajos o nunca vuelve.
public actor ShortcutCallbackBroker {
    public static let shared = ShortcutCallbackBroker()

    private var pending: [String: CheckedContinuation<ShortcutRunResult, Never>] = [:]

    public init() {}

    /// Crea un testigo único para una ejecución.
    public func makeToken() -> String {
        UUID().uuidString
    }

    /// Espera la respuesta de Atajos para ese testigo.
    public func awaitCallback(token: String, timeout: TimeInterval) async -> ShortcutRunResult {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.resume(token: token, with: ShortcutRunResult(outcome: .timedOut))
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ShortcutRunResult, Never>) in
            pending[token] = continuation
        }
        timeoutTask.cancel()
        return result
    }

    /// Entrega una URL recibida por la app. Devuelve `true` si alguien la esperaba.
    ///
    /// Una respuesta que llega tarde (tras agotarse el plazo) no encuentra a nadie
    /// esperando y se descarta sin efecto.
    public func deliver(url: URL) -> Bool {
        guard let callback = ShortcutCallback(url: url) else { return false }
        return resume(token: callback.token, with: callback.result)
    }

    @discardableResult
    private func resume(token: String, with result: ShortcutRunResult) -> Bool {
        guard let continuation = pending.removeValue(forKey: token) else { return false }
        continuation.resume(returning: result)
        return true
    }
}

// MARK: - iOS (y respaldo en macOS): ejecución por esquema URL

/// Ejecuta atajos abriendo `shortcuts://x-callback-url/run-shortcut`.
///
/// Es la única vía en iOS. El sistema pasa a la app Atajos mientras el atajo corre y
/// vuelve a Gemma al terminar; no hay forma de evitar ese salto.
public final class URLSchemeShortcutRunner: ShortcutRunning, Sendable {
    private let urlOpener: any AppURLOpening
    private let broker: ShortcutCallbackBroker
    private let timeout: TimeInterval

    public init(
        urlOpener: any AppURLOpening = SystemAppURLOpener(),
        broker: ShortcutCallbackBroker = .shared,
        timeout: TimeInterval = 30
    ) {
        self.urlOpener = urlOpener
        self.broker = broker
        self.timeout = timeout
    }

    /// iOS no permite enumerar los atajos del usuario.
    public func listAvailableNames() async -> [String]? { nil }

    /// Construye la URL de ejecución. Función pura, para poder comprobarla.
    public static func callbackURL(name: String, input: String?, token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"

        var items = [URLQueryItem(name: "name", value: name)]
        if let input, !input.isEmpty {
            // Atajos espera el par `input=text` + `text=<contenido>`.
            items.append(URLQueryItem(name: "input", value: "text"))
            items.append(URLQueryItem(name: "text", value: input))
        }
        items.append(contentsOf: [
            URLQueryItem(name: "x-success", value: "gemma://\(ShortcutCallback.host)?token=\(token)&status=success"),
            URLQueryItem(name: "x-cancel", value: "gemma://\(ShortcutCallback.host)?token=\(token)&status=cancel"),
            URLQueryItem(name: "x-error", value: "gemma://\(ShortcutCallback.host)?token=\(token)&status=error")
        ])
        components.queryItems = items
        return components.url
    }

    public func run(name: String, input: String?) async -> ShortcutRunResult {
        let token = await broker.makeToken()
        guard let url = Self.callbackURL(name: name, input: input, token: token) else {
            return ShortcutRunResult(
                outcome: .failed,
                errorMessage: "No se pudo construir la URL para el atajo '\(name)'."
            )
        }
        guard await urlOpener.canOpenURL(url) else {
            return ShortcutRunResult(
                outcome: .notAvailable,
                errorMessage: "La app Atajos no está disponible en este dispositivo."
            )
        }

        // Quedar a la espera ANTES de abrir la URL: en iOS el regreso puede ser
        // inmediato si el atajo no hace nada que tarde.
        async let pending = broker.awaitCallback(token: token, timeout: timeout)
        guard await urlOpener.openURL(url) else {
            _ = await broker.deliver(
                url: URL(string: "gemma://\(ShortcutCallback.host)?token=\(token)&status=error&errorMessage=No%20se%20pudo%20abrir%20Atajos")!
            )
            return await pending
        }
        return await pending
    }
}

// MARK: - macOS: ejecución por la herramienta de línea de comandos

#if os(macOS)
/// Ejecuta atajos con `/usr/bin/shortcuts`.
///
/// En macOS esto es mejor que el esquema URL en todo: no cambia de app, permite
/// enumerar los atajos existentes y devuelve la salida directamente.
public final class CLIShortcutRunner: ShortcutRunning, Sendable {
    private let executableURL: URL
    private let timeout: TimeInterval

    public init(executablePath: String = "/usr/bin/shortcuts", timeout: TimeInterval = 60) {
        self.executableURL = URL(fileURLWithPath: executablePath)
        self.timeout = timeout
    }

    public func listAvailableNames() async -> [String]? {
        guard let output = await runProcess(arguments: ["list"]) , output.status == 0 else { return nil }
        let names = output.standardOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names
    }

    public func run(name: String, input: String?) async -> ShortcutRunResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemma-shortcuts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var arguments = ["run", name]
        if let input, !input.isEmpty {
            let inputURL = directory.appendingPathComponent("input.txt")
            guard (try? input.write(to: inputURL, atomically: true, encoding: .utf8)) != nil else {
                return ShortcutRunResult(outcome: .failed, errorMessage: "No se pudo preparar la entrada del atajo.")
            }
            arguments.append(contentsOf: ["--input-path", inputURL.path])
        }
        let outputURL = directory.appendingPathComponent("output.txt")
        arguments.append(contentsOf: ["--output-path", outputURL.path])

        guard let process = await runProcess(arguments: arguments) else {
            return ShortcutRunResult(outcome: .timedOut, errorMessage: "El atajo '\(name)' no terminó a tiempo.")
        }
        guard process.status == 0 else {
            let message = process.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return ShortcutRunResult(
                outcome: .failed,
                errorMessage: message.isEmpty ? "El atajo '\(name)' falló." : message
            )
        }

        let output = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ShortcutRunResult(outcome: .ok, output: (output?.isEmpty ?? true) ? nil : output)
    }

    private struct ProcessOutput {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Lanza el proceso y espera, con plazo máximo. `nil` si se agotó el plazo.
    ///
    /// Las tuberías se vacían mientras el proceso sigue vivo. Si se esperara a que
    /// terminara para leerlas, una salida mayor que el búfer de la tubería (unos 64 KiB)
    /// bloquearía al hijo al escribir y nunca terminaría: pasa con `shortcuts list` en
    /// una biblioteca grande o con un atajo que devuelve mucho texto.
    private func runProcess(arguments: [String]) async -> ProcessOutput? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ProcessOutput(status: 1, standardOutput: "", standardError: error.localizedDescription)
        }

        let outData = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }
        let errData = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }

        let finishedInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await Self.waitForExit(process); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, self.timeout) * 1_000_000_000))
                return Task.isCancelled
            }
            let first = await group.next() ?? false
            // Cancela al perdedor para no dejar una espera dormida tras cada ejecución.
            group.cancelAll()
            return first
        }

        guard finishedInTime else {
            process.terminate()
            return nil
        }

        let out = String(data: await outData.value, encoding: .utf8) ?? ""
        let err = String(data: await errData.value, encoding: .utf8) ?? ""
        return ProcessOutput(status: process.terminationStatus, standardOutput: out, standardError: err)
    }

    /// Espera la salida del proceso sin bloquear ningún hilo del ejecutor.
    private static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = SingleUseFlag()
            process.terminationHandler = { _ in
                if resumed.testAndSet() { continuation.resume() }
            }
            // Si ya había terminado antes de instalar el manejador, este no se llama.
            if !process.isRunning, resumed.testAndSet() {
                continuation.resume()
            }
        }
    }
}

#endif

/// Ejecutor adecuado para la plataforma actual.
public enum ShortcutRunnerFactory {
    public static func make() -> any ShortcutRunning {
        #if os(macOS)
        return CLIShortcutRunner()
        #else
        return URLSchemeShortcutRunner()
        #endif
    }
}
