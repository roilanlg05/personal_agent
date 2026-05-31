import Foundation

/// The argv (after the executable) for `mlx_lm.server`. Pure → unit-testable.
func serverArguments(for config: ServerConfig) -> [String] {
    ["--model", config.modelId, "--host", config.host, "--port", String(config.port)]
}

/// Owns a spawned `mlx_lm.server` process. Captures a tail of stderr for diagnostics and
/// fires `onExit` if the process dies on its own.
final class RealServerProcessHandle: ServerProcessHandle, @unchecked Sendable {
    private let process: Process
    private let stderrPipe: Pipe
    private let lock = NSLock()
    private var _stderrTail = ""
    var onExit: (@Sendable () -> Void)?

    var stderrTail: String { lock.lock(); defer { lock.unlock() }; return _stderrTail }

    /// `stderrPipe` is the SAME pipe wired to `process.standardError` by the launcher.
    init(process: Process, stderrPipe: Pipe) {
        self.process = process
        self.stderrPipe = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8), let self else { return }
            self.lock.lock()
            self._stderrTail = String((self._stderrTail + s).suffix(4000))
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in self?.onExit?() }
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminationHandler = nil   // expected shutdown — don't fire onExit
        stderrPipe.fileHandleForReading.readabilityHandler = nil  // stop draining stderr
        process.terminate()                // SIGTERM
    }
}

/// Spawns `mlx_lm.server` via `Process`. Requires the App Sandbox to be OFF (Task 1).
final class RealServerProcessLauncher: ServerProcessLauncher {
    func launch(_ config: ServerConfig) throws -> ServerProcessHandle {
        let process = Process()
        process.executableURL = config.venvBinURL
        process.arguments = serverArguments(for: config)
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice   // discard stdout so its buffer can't block the child
        let handle = RealServerProcessHandle(process: process, stderrPipe: stderrPipe)
        try process.run()
        return handle
    }
}
