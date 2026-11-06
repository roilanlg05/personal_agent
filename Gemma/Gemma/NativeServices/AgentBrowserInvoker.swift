import Foundation

#if os(macOS)

/// Resultado crudo de una ejecución del CLI `agent-browser`: lo que salió, sin interpretar.
public struct AgentBrowserInvocation: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Por qué no se pudo obtener una ejecución. Un código de salida distinto de cero NO es
/// un fallo de lanzamiento: llega como `AgentBrowserInvocation` y lo interpreta quien llama.
public enum AgentBrowserInvocationFailure: Error, Sendable, Equatable {
    /// No hay ejecutable. Lleva todas las rutas que se probaron, para el mensaje de error.
    case binaryNotFound(searchedPaths: [String])
    /// El proceso superó el plazo y se terminó.
    case timedOut(seconds: TimeInterval)
    /// El sistema no pudo lanzar el proceso.
    case launchFailed(String)
}

/// Lanza el CLI y devuelve su salida cruda. Punto de sustitución para las pruebas.
public protocol AgentBrowserInvoking: Sendable {
    func invoke(arguments: [String], timeout: TimeInterval) async
        -> Result<AgentBrowserInvocation, AgentBrowserInvocationFailure>
}

// MARK: - Descubrimiento del binario

/// Localiza `agent-browser`.
///
/// Una app lanzada desde Finder no hereda el `PATH` de la terminal y no ve
/// `/opt/homebrew/bin`, así que la búsqueda es explícita y no depende del `PATH` heredado.
public enum AgentBrowserBinary {
    /// Variable de entorno que permite fijar la ruta a mano.
    public static let overrideVariable = "AGENT_BROWSER_PATH"

    /// Rutas fijas, en orden de preferencia: Homebrew en Apple Silicon, luego Intel.
    public static let candidatePaths: [String] = [
        "/opt/homebrew/bin/agent-browser",
        "/usr/local/bin/agent-browser",
        "/usr/bin/agent-browser"
    ]

    /// Primera vía que dé un ejecutable: la variable de entorno y después las rutas fijas.
    /// `nil` si ninguna sirve. Pura: el respaldo por shell vive en el invocador.
    public static func resolve(environment: [String: String],
                               isExecutable: (String) -> Bool) -> String? {
        if let override = environment[overrideVariable], !override.isEmpty,
           isExecutable(override) {
            return override
        }
        return candidatePaths.first(where: isExecutable)
    }

    /// Rutas que `resolve` habría mirado, en orden. Para informar al usuario.
    static func searchedPaths(environment: [String: String]) -> [String] {
        var paths: [String] = []
        if let override = environment[overrideVariable], !override.isEmpty {
            paths.append(override)
        }
        return paths + candidatePaths
    }
}

// MARK: - Invocador real

/// Ejecuta `agent-browser` como proceso hijo.
public final class ProcessAgentBrowserInvoker: AgentBrowserInvoking, Sendable {
    private let explicitPath: String?
    private let environment: [String: String]
    private let isExecutable: @Sendable (String) -> Bool
    private let shellLookup: @Sendable () async -> String?

    /// Los cierres inyectables existen para controlar el descubrimiento en pruebas;
    /// en producción se usan los valores por defecto.
    /// - Parameters:
    ///   - binaryPath: ruta preferida. Si no es ejecutable NO aborta: se sigue con el
    ///     descubrimiento normal y la ruta queda la primera en `searchedPaths`.
    ///   - shellLookup: último recurso (`command -v` en un shell de login); devuelve la ruta o `nil`.
    public init(binaryPath: String? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                isExecutable: @escaping @Sendable (String) -> Bool = {
                    FileManager.default.isExecutableFile(atPath: $0)
                },
                shellLookup: @escaping @Sendable () async -> String? = {
                    await ProcessAgentBrowserInvoker.defaultShellLookup()
                }) {
        self.explicitPath = binaryPath
        self.environment = environment
        self.isExecutable = isExecutable
        self.shellLookup = shellLookup
    }

    public func invoke(arguments: [String], timeout: TimeInterval) async
        -> Result<AgentBrowserInvocation, AgentBrowserInvocationFailure> {
        guard let binary = await locateBinary() else {
            var searched = AgentBrowserBinary.searchedPaths(environment: environment)
            if let explicitPath { searched.insert(explicitPath, at: 0) }
            return .failure(.binaryNotFound(searchedPaths: searched))
        }
        return await Self.run(executable: binary, arguments: arguments,
                              environment: Self.childEnvironment(from: environment),
                              timeout: timeout)
    }

    private func locateBinary() async -> String? {
        if let explicitPath, isExecutable(explicitPath) { return explicitPath }
        if let found = AgentBrowserBinary.resolve(environment: environment,
                                                  isExecutable: isExecutable) {
            return found
        }
        if let viaShell = await shellLookup(), isExecutable(viaShell) { return viaShell }
        return nil
    }

    /// Entorno del hijo: el del padre con las rutas de Homebrew delante en el `PATH`,
    /// y sin la comprobación de versión del CLI (no debe tocar la red en cada llamada).
    static func childEnvironment(from base: [String: String]) -> [String: String] {
        var env = base
        let prefix = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = base["PATH"].map { "\(prefix):\($0)" } ?? prefix
        env["AGENT_BROWSER_NO_VERSION_CHECK"] = "1"
        return env
    }

    /// `command -v agent-browser` en un shell de login, que sí carga el `PATH` del usuario.
    public static func defaultShellLookup() async -> String? {
        let result = await run(executable: "/bin/sh",
                               arguments: ["-lc", "command -v agent-browser"],
                               environment: ProcessInfo.processInfo.environment,
                               timeout: 5)
        guard case .success(let run) = result, run.exitCode == 0 else { return nil }
        let path = run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    /// Acumula lo que va saliendo de una tubería y recuerda si llegó EOF.
    private final class PipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var reachedEOF = false

        func attach(to handle: FileHandle) {
            handle.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                lock.lock()
                if chunk.isEmpty { reachedEOF = true } else { data.append(chunk) }
                lock.unlock()
                // Sin esto el manejador se dispararía sin parar tras el EOF.
                if chunk.isEmpty { handle.readabilityHandler = nil }
            }
        }

        var isAtEOF: Bool { lock.lock(); defer { lock.unlock() }; return reachedEOF }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// Tiempo que se espera, tras salir el hijo, a que lleguen los últimos bytes.
    private static let drainGrace: TimeInterval = 0.5
    /// Tiempo que se da al hijo para morir con SIGTERM antes de enviarle SIGKILL.
    private static let killGrace: TimeInterval = 2

    private enum Outcome { case exited, timedOut }

    /// Lanza el proceso y espera, con plazo máximo para TODA la llamada.
    ///
    /// Misma idea que `CLIShortcutRunner.runProcess` (tuberías vaciadas mientras el hijo
    /// vive, espera sin bloquear hilos del ejecutor), pero sin ninguna espera no acotada:
    /// - La salida se recoge con `readabilityHandler` y no con `readDataToEndOfFile`, que
    ///   solo vuelve cuando se cierran TODOS los extremos de escritura. Si el CLI deja un
    ///   demonio con las tuberías heredadas, el EOF no llega nunca aunque él haya salido.
    ///   Tras la salida del hijo se espera `drainGrace` al EOF y se devuelve lo recogido.
    /// - Al vencer el plazo se devuelve `.timedOut` en ese mismo instante, sin esperar a la
    ///   muerte del hijo (un `withTaskGroup` esperaría a un hijo que ignore SIGTERM). Se
    ///   envía SIGTERM y, si sigue vivo tras `killGrace`, SIGKILL.
    private static func run(executable: String, arguments: [String],
                            environment: [String: String], timeout: TimeInterval) async
        -> Result<AgentBrowserInvocation, AgentBrowserInvocationFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let out = PipeCollector()
        let err = PipeCollector()
        out.attach(to: outPipe.fileHandleForReading)
        err.attach(to: errPipe.fileHandleForReading)

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(.launchFailed(error.localizedDescription))
        }

        let outcome: Outcome = await withCheckedContinuation { continuation in
            // Quien llegue primero (salida o plazo) reanuda; el otro no hace nada.
            let decided = SingleUseFlag()
            let deadline = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled, decided.testAndSet() else { return }
                process.terminate()
                let pid = process.processIdentifier
                Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(killGrace * 1_000_000_000))
                    if process.isRunning { kill(pid, SIGKILL) }
                }
                continuation.resume(returning: .timedOut)
            }
            let onExit: @Sendable () -> Void = {
                Task {
                    // Los últimos bytes pueden llegar un instante después de la salida.
                    let limit = ContinuousClock.now + .seconds(drainGrace)
                    while !(out.isAtEOF && err.isAtEOF), ContinuousClock.now < limit {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                    guard decided.testAndSet() else { return }
                    deadline.cancel()
                    continuation.resume(returning: .exited)
                }
            }
            process.terminationHandler = { _ in onExit() }
            // Si ya había terminado antes de instalar el manejador, este no se llama.
            if !process.isRunning { onExit() }
        }

        // Se desengancha pase lo que pase: tras un plazo vencido no debe seguir acumulando.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        switch outcome {
        case .timedOut:
            return .failure(.timedOut(seconds: timeout))
        case .exited:
            return .success(AgentBrowserInvocation(exitCode: process.terminationStatus,
                                                   standardOutput: out.text,
                                                   standardError: err.text))
        }
    }
}

// MARK: - Doble de prueba

/// Doble de prueba. Devuelve lo programado y guarda lo que recibió.
public final class MockAgentBrowserInvoker: AgentBrowserInvoking, @unchecked Sendable {
    public var nextResult: Result<AgentBrowserInvocation, AgentBrowserInvocationFailure>
    public private(set) var receivedArguments: [[String]] = []
    /// Plazo recibido en cada llamada, en el mismo orden que `receivedArguments`.
    public private(set) var receivedTimeouts: [TimeInterval] = []

    public init(nextResult: Result<AgentBrowserInvocation, AgentBrowserInvocationFailure>) {
        self.nextResult = nextResult
    }

    /// Atajo: envuelve `stdout` en un `AgentBrowserInvocation` con código 0.
    public static func succeeding(stdout: String) -> MockAgentBrowserInvoker {
        MockAgentBrowserInvoker(nextResult: .success(
            AgentBrowserInvocation(exitCode: 0, standardOutput: stdout, standardError: "")))
    }

    public func invoke(arguments: [String], timeout: TimeInterval) async
        -> Result<AgentBrowserInvocation, AgentBrowserInvocationFailure> {
        receivedArguments.append(arguments)
        receivedTimeouts.append(timeout)
        return nextResult
    }
}

#endif
