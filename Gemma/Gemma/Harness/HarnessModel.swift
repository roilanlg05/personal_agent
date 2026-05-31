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
    @ObservationIgnored private var lastTurnEndedAt: Double = 0
    private static let wakeGapSeconds: Double = 180   // first turn or a gap > this = a "wake"

    /// Build the per-turn "wake context" appended to the system prompt: what the agent was
    /// reflecting on (if a cycle is pending) + pending follow-ups (only on a wake turn).
    nonisolated static func buildWakeContext(focus: String, followUps: [String], isWake: Bool) -> String {
        var parts: [String] = []
        if !focus.isEmpty {
            parts.append("(You were just reflecting on: \(focus). Mention it naturally only if it fits.)")
        }
        if isWake, !followUps.isEmpty {
            let list = followUps.map { "- \($0)" }.joined(separator: "\n")
            parts.append("Things the user left pending you can gently follow up on if it fits (don't force them):\n\(list)")
        }
        return parts.joined(separator: "\n\n")
    }
    @ObservationIgnored private var memoryEmbedder: Embedder?
    @ObservationIgnored private let threadId = UUID().uuidString
    @ObservationIgnored private var turnIndex = 0

    /// Consolidation engine (phase ops) — built once, reused. Not observed.
    @ObservationIgnored private var consolidationEngine: MemoryConsolidationEngine?
    /// Scheduler driving awake/sleep consolidation — observed so the UI banner reacts.
    private(set) var consolidationScheduler: ConsolidationScheduler?

    /// Owns the local mlx-lm server process lifecycle (M2a).
    let serverManager = ServerManager()

    public init() {
        self.settings = settingsStore.load()
        self.runtime = ServerRuntime()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopServer() }
        }
    }

    /// Launch/attach the server and start keeping it warm. Safe to call again (Retry).
    /// No-op under XCTest: the unit-test host launches this app, and we must NOT spawn the
    /// real 15GB mlx-lm server on every test run (it would load after the run and orphan).
    public func startServer() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
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
        // Build the consolidation engine + scheduler ONCE, then reuse across turns.
        if consolidationScheduler == nil {
            let engine = MemoryConsolidationEngine(store: store, embedder: memoryEmbedder, runtime: runtime)
            let sched = ConsolidationScheduler(runner: engine, isReady: { [weak self] in self?.serverManager.state == .ready },
                                               hasPendingCycle: { [weak self] in ((try? self?.memoryStore?.loadSleepCycle()) ?? nil) != nil })
            // Mirror short engine progress into the scheduler's summary so the
            // ".done" banner can show what changed.
            engine.onProgress = { [weak sched] mark in
                Task { @MainActor [weak sched] in sched?.lastSummary = mark }
            }
            MemoryToolbox.shared.reflectionRequest = { [weak sched] in sched?.requestLightReflection() }
            self.consolidationEngine = engine
            self.consolidationScheduler = sched
        }
        let retriever = MemoryRetriever(store: store, embedder: memoryEmbedder)
        return MemoryServices(retriever: retriever)
    }

    /// Manually kick off a full consolidation cycle (toolbar "Consolidar").
    func consolidateNow() { consolidationScheduler?.consolidateNow() }

    public func runAgentTurn(_ prompt: String) async {
        agentRunning = true; defer { agentRunning = false }
        agentLog.append("you: \(prompt)")
        let memory = ensureMemory()
        // Note activity ONLY at turn start: this cancels any in-flight consolidation so the
        // model is free for the turn, and re-arms the pause/idle timers (counted from turn
        // start). We deliberately do NOT note activity at turn end — otherwise a light
        // reflection the model requested mid-turn via the `reflect` tool would be cancelled
        // the instant the turn finished. With no end-of-turn cancel, that requested reflection
        // simply queues behind the turn's generations on the serial mlx-lm server and runs
        // once they finish (so it never competes with the turn's own answer). It is still
        // correctly cancelled at the START of the next turn, giving the user priority.
        consolidationScheduler?.noteUserActivity()
        let registry = ToolRegistry()
        registry.register(CurrentTimeTool())
        if memory != nil {
            registry.register(SaveMemoryTool()); registry.register(ForgetTool()); registry.register(ReflectTool())
        }
        let now = Date().timeIntervalSince1970
        let isWake = (lastTurnEndedAt == 0) || (now - lastTurnEndedAt > Self.wakeGapSeconds)
        let focus = ((try? memoryStore?.loadSleepCycle()) ?? nil)?.focus ?? ""
        let followUps = isWake ? (((try? memoryStore?.pendingFollowUps()) ?? nil)?.map { $0.body } ?? []) : []
        let wakeContext = Self.buildWakeContext(focus: focus, followUps: followUps, isWake: isWake)
        let agent = Agent(runtime: runtime, registry: registry, memory: memory, wakeContext: wakeContext)
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
        if memory != nil, let store = memoryStore {
            EpisodeRecorder.record(store: store, threadId: threadId, turnIndex: turnIndex,
                                   userText: prompt, assistantText: answer)
            turnIndex += 1
        }
        lastTurnEndedAt = Date().timeIntervalSince1970
    }
}
