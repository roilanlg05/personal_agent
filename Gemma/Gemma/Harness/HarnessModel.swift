import Foundation
import Observation
import AppKit

@Observable
@MainActor
public final class HarnessModel {
    public var agentLog: [String] = []
    public var agentRunning: Bool = false
    public var showMemory: Bool = false

    @ObservationIgnored private var runtime: ModelRuntime & ToolCallingRuntime
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private(set) var settings: GenerationSettings
    @ObservationIgnored private var memoryStore: MemoryStore?
    @ObservationIgnored private var memoryEmbedder: Embedder?

    /// Owns the local mlx-lm server process lifecycle (M2a).
    let serverManager = ServerManager()

    public init() {
        self.settings = settingsStore.load()
        self.runtime = ServerRuntime()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.serverManager.stop() }
        }
    }

    /// Launch/attach the server and start keeping it warm. Safe to call again (Retry).
    public func startServer() {
        Task { await serverManager.start() }
    }

    /// Terminate the owned server (called on app quit).
    public func stopServer() { serverManager.stop() }

    func inspectorStore() -> MemoryStore? { memoryStore }

    private func makeGenerationOptions() -> GenerationOptions {
        GenerationOptions(maxTokens: settings.maxOutputTokens, temperature: settings.temperature,
                          topP: settings.topP, topK: settings.topK,
                          systemPrompt: settings.systemPrompt.isEmpty ? nil : settings.systemPrompt)
    }

    private func ensureMemory() -> MemoryServices? {
        guard settings.memoryEnabled ?? true else { return nil }
        if memoryStore == nil {
            memoryEmbedder = try? NLContextualEmbedder()
            let dim = memoryEmbedder?.dimension ?? 512
            memoryStore = try? MemoryStore(url: try? MemoryStore.defaultURL(), embeddingDim: dim)
        }
        guard let store = memoryStore else { return nil }
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.embedder = memoryEmbedder
        let retriever = MemoryRetriever(store: store, embedder: memoryEmbedder)
        let consolidator = MemoryConsolidator(runtime: runtime, store: store, embedder: memoryEmbedder)
        return MemoryServices(retriever: retriever, consolidator: consolidator)
    }

    public func runAgentTurn(_ prompt: String) async {
        agentRunning = true; defer { agentRunning = false }
        agentLog.append("you: \(prompt)")
        let memory = ensureMemory()
        let registry = ToolRegistry()
        registry.register(CurrentTimeTool())
        if memory != nil { registry.register(RememberTool()); registry.register(ForgetTool()) }
        let agent = Agent(runtime: runtime, registry: registry, memory: memory)
        var answer = ""
        do {
            for try await event in agent.run(prompt: prompt, options: makeGenerationOptions()) {
                switch event {
                case .token(let t): answer += t
                case .toolCallStarted(let n, _): agentLog.append("🔧 \(n)…")
                case .toolCallFinished(let n, let r): agentLog.append("🔧 \(n) ✓ \(r)")
                case .completed: agentLog.append("gemma: \(answer)")
                case .failed(let m): agentLog.append("[error: \(m)]")
                }
            }
        } catch { agentLog.append("[error: \(error)]") }
    }
}
