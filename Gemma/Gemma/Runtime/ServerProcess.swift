import Foundation

/// The argv (after the executable) for `mlx_vlm.server`. Pure → unit-testable.
nonisolated func serverArguments(for config: ServerConfig) -> [String] {
    var args = ["--model", config.modelId, "--host", config.bindHost, "--port", String(config.port)]
    if let draft = config.draftModelId {
        args += ["--draft-model", draft]
        if let kind = config.draftKind { args += ["--draft-kind", kind] }
        if let block = config.draftBlockSize { args += ["--draft-block-size", String(block)] }
    }
    return args
}

/// The `--wired-limit-bytes` flag for the launcher, or empty when pageable. Pure → testable.
nonisolated func wiringArguments(for config: ServerConfig) -> [String] {
    config.wiredLimitBytes > 0 ? ["--wired-limit-bytes", String(config.wiredLimitBytes)] : []
}

/// Full argv for the venv python: the launcher script, optional wiring flag, then the mlx_vlm.server flags.
nonisolated func launchArguments(for config: ServerConfig) -> [String] {
    [config.launcherScriptURL.path] + wiringArguments(for: config) + serverArguments(for: config)
}

/// Single-quote a string for safe interpolation into a `/bin/sh` command.
/// Wraps in `'...'` and escapes embedded single quotes as `'\''`.
private func shQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Builds the `/bin/sh -c` watchdog script: run the server, kill it if the parent app
/// (pid `parentPID`) dies (crash/SIGKILL) or on SIGTERM (clean stop).
nonisolated func watchdogScript(binPath: String, args: [String], parentPID: Int32) -> String {
    let quotedCmd = ([binPath] + args).map(shQuote).joined(separator: " ")
    return """
    trap 'kill "$SRV" 2>/dev/null; exit 0' TERM INT
    \(quotedCmd) &
    SRV=$!
    while kill -0 \(parentPID) 2>/dev/null && kill -0 "$SRV" 2>/dev/null; do sleep 2; done
    kill "$SRV" 2>/dev/null
    """
}

/// Owns the spawned server process (python → `serve_mlx_vlm.py` → `mlx_vlm.server`). Captures a
/// tail of stderr for diagnostics and fires `onExit` if the process dies on its own.
nonisolated final class RealServerProcessHandle: ServerProcessHandle, @unchecked Sendable {
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

/// Spawns the server via `Process`: runs the venv python on `serve_mlx_vlm.py` (which optionally
/// wires memory, then runs `mlx_vlm.server`). Requires the App Sandbox to be OFF.
nonisolated final class RealServerProcessLauncher: ServerProcessLauncher {
    func launch(_ config: ServerConfig) throws -> ServerProcessHandle {
        let process = Process()
        // Spawn the server under a /bin/sh watchdog so it's killed even if THIS app
        // crashes or is SIGKILL'd (willTerminate never fires, but the watchdog — reparented
        // to launchd — notices the parent PID vanish and kills the server).
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", watchdogScript(
            binPath: config.pythonBinURL.path,
            args: launchArguments(for: config),
            parentPID: ProcessInfo.processInfo.processIdentifier)]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice   // discard stdout so its buffer can't block the child
        let handle = RealServerProcessHandle(process: process, stderrPipe: stderrPipe)
        try process.run()
        return handle
    }
}
