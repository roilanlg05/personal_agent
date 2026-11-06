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

    /// Lanza el proceso y espera, con plazo máximo.
    ///
    /// Misma estructura que `CLIShortcutRunner.runProcess`: las tuberías se vacían mientras
    /// el hijo sigue vivo (una salida mayor que el búfer de ~64 KiB lo bloquearía al
    /// escribir y nunca terminaría), la espera no bloquea ningún hilo del ejecutor, y al
    /// agotarse el plazo se termina el proceso.
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

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        let outData = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }
        let errData = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }

        // Se marca antes de terminar el proceso: terminarlo hace que la espera de salida
        // también acabe, y de otro modo no habría forma fiable de saber cuál ganó.
        let timeoutFlag = SingleUseFlag()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await waitForExit(process) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled, timeoutFlag.testAndSet() else { return }
                // Se termina aquí y no después del grupo: el grupo no devuelve hasta que
                // acaban todos sus hijos y la espera de salida no es cancelable, así que
                // el plazo no cortaría nada hasta que el proceso acabara por su cuenta.
                process.terminate()
            }
            _ = await group.next()
            // Cancela la espera dormida si el proceso acabó antes del plazo.
            group.cancelAll()
        }

        // `testAndSet` es `true` solo si el plazo nunca llegó a marcar la bandera.
        guard timeoutFlag.testAndSet() else {
            return .failure(.timedOut(seconds: timeout))
        }

        let out = String(decoding: await outData.value, as: UTF8.self)
        let err = String(decoding: await errData.value, as: UTF8.self)
        return .success(AgentBrowserInvocation(exitCode: process.terminationStatus,
                                               standardOutput: out, standardError: err))
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

// MARK: - Doble de prueba

/// Doble de prueba. Devuelve lo programado y guarda lo que recibió.
public final class MockAgentBrowserInvoker: AgentBrowserInvoking, @unchecked Sendable {
    public var nextResult: Result<AgentBrowserInvocation, AgentBrowserInvocationFailure>
    public private(set) var receivedArguments: [[String]] = []

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
        return nextResult
    }
}

#endif
