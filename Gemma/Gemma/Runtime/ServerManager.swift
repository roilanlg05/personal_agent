import Foundation
import Observation

/// Lifecycle state of the local mlx-lm server. `.ready` means the model has actually
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
struct ServerConfig: Sendable {
    var venvBinURL: URL
    var modelId: String
    var host: String
    var port: Int
    var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    static let `default` = ServerConfig(
        venvBinURL: URL(fileURLWithPath: "/Users/hashdown/Projects/personal_agent/spike-mlx/.venv/bin/mlx_lm.server"),
        modelId: "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
        host: "127.0.0.1",
        port: 8080)
}

/// A running server process we can terminate; notifies via `onExit` if it dies on its own.
protocol ServerProcessHandle: AnyObject {
    func terminate()
    var onExit: (@Sendable () -> Void)? { get set }
    var stderrTail: String { get }
}

/// Spawns the server process. Real impl uses `Process`; tests use a fake.
protocol ServerProcessLauncher {
    func launch(_ config: ServerConfig) throws -> ServerProcessHandle
}

/// Probes server readiness and runs a minimal warm-up/keep-alive inference.
protocol ServerHealth {
    func probe(_ config: ServerConfig) async -> Bool
    func warm(_ config: ServerConfig) async throws
}

@MainActor
@Observable
final class ServerManager {
    private(set) var state: ServerState = .idle

    @ObservationIgnored private let config: ServerConfig
    @ObservationIgnored private let launcher: ServerProcessLauncher
    @ObservationIgnored private let health: ServerHealth
    @ObservationIgnored private let pollAttempts: Int
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored let keepAliveInterval: Duration

    @ObservationIgnored private var handle: ServerProcessHandle?
    @ObservationIgnored private var owned = false
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?

    init(config: ServerConfig = .default,
         launcher: ServerProcessLauncher = RealServerProcessLauncher(),
         health: ServerHealth = HTTPServerHealth(),
         pollAttempts: Int = 180,
         pollInterval: Duration = .seconds(1),
         keepAliveInterval: Duration = .seconds(75)) {
        self.config = config
        self.launcher = launcher
        self.health = health
        self.pollAttempts = pollAttempts
        self.pollInterval = pollInterval
        self.keepAliveInterval = keepAliveInterval
    }

    /// Idempotent-ish entry point; also used by the Retry button. Cancels any prior keep-alive.
    func start() async {
        keepAliveTask?.cancel(); keepAliveTask = nil

        // Attach path: a server is already serving on the port → don't spawn.
        if await health.probe(config) {
            owned = false
            await warmToReady()
            return
        }

        // Spawn path.
        state = .starting
        do {
            let h = try launcher.launch(config)
            h.onExit = { [weak self] in Task { @MainActor in self?.handleUnexpectedExit() } }
            handle = h
            owned = true
        } catch {
            state = .failed("No pude lanzar el server (\(error)). Binario: \(config.venvBinURL.path)")
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

    /// Manual fallback command shown in the UI on failure.
    var manualCommand: String {
        "\(config.venvBinURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path) && \(config.venvBinURL.path) --model \(config.modelId) --port \(config.port)"
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

    private func handleUnexpectedExit() {
        // Only meaningful if we still thought it was alive.
        switch state {
        case .ready, .loadingModel, .starting:
            keepAliveTask?.cancel(); keepAliveTask = nil
            handle = nil
            state = .failed("El server se cerró inesperadamente.")
        default:
            break
        }
    }
}
