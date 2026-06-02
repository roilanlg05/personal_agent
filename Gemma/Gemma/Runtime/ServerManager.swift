import Foundation
import Observation

/// Lifecycle state of the local mlx_vlm server. `.ready` means the model has actually
/// served a pre-warm inference (not merely that the port is open).
enum ServerState: Equatable {
    case idle
    case starting       // process spawned, waiting for HTTP to come up
    case loadingModel   // HTTP up, running pre-warm (model loads)
    case ready          // pre-warm done → model hot, accepting chat
    case stopped        // owned process terminated
    case failed(String)
}

/// Where/how to run the server. Hardcoded defaults for M2a; a Settings UI is M2c.
nonisolated struct ServerConfig: Sendable {
    /// The venv Python that runs the wiring launcher (.venv-vlm/bin/python3.12).
    var pythonBinURL: URL
    /// The wiring launcher script (spike-mlx/serve_mlx_vlm.py): sets mx.set_wired_limit then runs mlx_vlm.server.
    var launcherScriptURL: URL
    var modelId: String
    var host: String
    var port: Int
    /// MTP speculative-decoding drafter (HF id or path). nil = no speculative decoding.
    var draftModelId: String? = nil
    /// Drafter family for mlx_vlm: "mtp" (Gemma 4 assistant) or "dflash". nil = omit flag.
    var draftKind: String? = nil
    /// Tokens drafted per verification round. nil = use the drafter's configured default.
    var draftBlockSize: Int? = nil
    /// MLX wired-memory limit in bytes. 0 = pageable (mmap, may cold-start);
    /// >0 = wire the model resident so macOS won't page it out (anti-cold-start). See spec §2.
    var wiredLimitBytes: UInt64 = 0
    var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    static let `default` = ServerConfig(
        pythonBinURL: URL(fileURLWithPath: "/Users/hashdown/Projects/personal_agent/spike-mlx/.venv-vlm/bin/python3.12"),
        launcherScriptURL: URL(fileURLWithPath: "/Users/hashdown/Projects/personal_agent/spike-mlx/serve_mlx_vlm.py"),
        modelId: "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
        host: "127.0.0.1",
        port: 8080,
        draftModelId: "guardiangate1775/gemma-4-26B-A4B-it-assistant-4bit",
        draftKind: "mtp",
        draftBlockSize: 2,
        wiredLimitBytes: 0)
}

/// A running server process we can terminate; notifies via `onExit` if it dies on its own.
nonisolated protocol ServerProcessHandle: AnyObject {
    func terminate()
    var onExit: (@Sendable () -> Void)? { get set }
    var stderrTail: String { get }
}

/// Spawns the server process. Real impl uses `Process`; tests use a fake.
nonisolated protocol ServerProcessLauncher {
    func launch(_ config: ServerConfig) throws -> ServerProcessHandle
}

/// Probes server readiness and runs a minimal warm-up/keep-alive inference.
nonisolated protocol ServerHealth {
    func probe(_ config: ServerConfig) async -> Bool
    func warm(_ config: ServerConfig) async throws
}

@MainActor
@Observable
final class ServerManager {
    private(set) var state: ServerState = .idle

    @ObservationIgnored private var config: ServerConfig
    @ObservationIgnored private let launcher: ServerProcessLauncher
    @ObservationIgnored private let health: ServerHealth
    @ObservationIgnored private let pollAttempts: Int
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored let keepAliveInterval: Duration
    /// Max probes (spaced by `pollInterval`) to wait for an owned server to go down on restart.
    @ObservationIgnored private let downPollAttempts: Int

    @ObservationIgnored private var handle: ServerProcessHandle?
    @ObservationIgnored private var owned = false
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isStarting = false

    init(config: ServerConfig = .default,
         launcher: ServerProcessLauncher = RealServerProcessLauncher(),
         health: ServerHealth = HTTPServerHealth(),
         pollAttempts: Int = 180,
         pollInterval: Duration = .seconds(1),
         keepAliveInterval: Duration = .seconds(75),
         downPollAttempts: Int = 25) {
        self.config = config
        self.launcher = launcher
        self.health = health
        self.pollAttempts = pollAttempts
        self.pollInterval = pollInterval
        self.keepAliveInterval = keepAliveInterval
        self.downPollAttempts = downPollAttempts
    }

    /// Idempotent-ish entry point; also used by the Retry button. Cancels any prior keep-alive.
    func start() async {
        // Re-entrancy guard: set synchronously before the first suspension point so a concurrent
        // second start() (same MainActor) entering while the first is suspended returns immediately —
        // only ONE spawn/attach happens. Cleared on return so a later Retry still works.
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        keepAliveTask?.cancel(); keepAliveTask = nil

        // Retry hygiene: tear down any process WE own before re-probing, so a Retry can't
        // re-attach to its own still-running orphan with owned=false (permanent port/RAM leak).
        if owned { handle?.terminate() }
        handle = nil
        owned = false

        // Attach path: a server is already serving on the port → don't spawn.
        if await health.probe(config) {
            owned = false
            await warmToReady()
            return
        }

        // Spawn path.
        state = .starting
        do {
            generation += 1
            let gen = generation
            let h = try launcher.launch(config)
            h.onExit = { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.handleUnexpectedExit(generation: gen) }
            }
            handle = h
            owned = true
        } catch {
            state = .failed("No pude lanzar el server (\(error)). Binario: \(config.pythonBinURL.path)")
            return
        }

        var up = false
        for _ in 0..<pollAttempts {
            if await health.probe(config) { up = true; break }
            try? await Task.sleep(for: pollInterval)
        }
        guard up else {
            state = .failed("El server no respondió a tiempo.\n\(handle?.stderrTail ?? "")")
            return
        }
        await warmToReady()
    }

    func stop() {
        keepAliveTask?.cancel(); keepAliveTask = nil
        if owned { handle?.terminate() }
        handle = nil
        state = .stopped
    }

    /// Change the MLX wired-memory limit and restart the server so it takes effect.
    /// No-op if the limit is unchanged (avoids a needless ~20s reload).
    func setWiredLimit(_ bytes: UInt64) async {
        guard bytes != config.wiredLimitBytes else { return }
        config.wiredLimitBytes = bytes
        await restart()
    }

    /// Stop the owned server, WAIT for it to actually go down, then start fresh.
    /// The wait matters: stop() only sends SIGTERM and returns immediately, but the old server
    /// keeps answering for ~40-250ms. Without waiting, start()'s probe would attach to the dying
    /// server (owned=false) instead of spawning the new one — and once it exits there'd be no
    /// server at all. Waiting also frees the port so the new server can bind it.
    /// If we didn't own the server (attached to an external one), skip the wait — stop() left it
    /// running and start() will just re-attach.
    private func restart() async {
        let wasOwned = owned
        stop()
        if wasOwned { await waitForServerDown() }
        await start()
    }

    /// Poll until the server stops answering on the port (bounded by `downPollAttempts`).
    private func waitForServerDown() async {
        for _ in 0..<downPollAttempts {
            if !(await health.probe(config)) { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Manual fallback command shown in the UI on failure.
    var manualCommand: String {
        let dir = config.launcherScriptURL.deletingLastPathComponent()   // …/spike-mlx
        let argv = ([config.pythonBinURL.path] + launchArguments(for: config)).joined(separator: " ")
        return "cd \(dir.path) && \(argv)"
    }

    // MARK: - internals

    private func warmToReady() async {
        state = .loadingModel
        do {
            try await health.warm(config)
            state = .ready
            startKeepAlive()
        } catch {
            state = .failed("El warm-up falló: \(error)")
        }
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        let health = self.health
        let config = self.config
        let interval = self.keepAliveInterval
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                do {
                    try await health.warm(config)
                } catch {
                    await MainActor.run { self?.state = .failed("El server dejó de responder: \(error)") }
                    break
                }
            }
        }
    }

    private func handleUnexpectedExit(generation: Int) {
        // Ignore stale callbacks from a process superseded by a later start() (Retry).
        guard generation == self.generation else { return }
        // Only meaningful if we still thought it was alive.
        switch state {
        case .ready, .loadingModel, .starting:
            keepAliveTask?.cancel(); keepAliveTask = nil
            handle = nil
            owned = false
            state = .failed("El server se cerró inesperadamente.")
        default:
            break
        }
    }
}
