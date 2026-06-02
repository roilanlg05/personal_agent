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
    @ObservationIgnored private var transcriptStore: TranscriptStore?
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

    /// Owns the local mlx_vlm server process lifecycle (M2a). Built in init() so its initial
    /// ServerConfig reflects the persisted "keep model resident" toggle (M2c-1).
    let serverManager: ServerManager

    /// MLX wired-memory limit when "keep model resident" is ON. 16 GiB — covers model+draft
    /// (~15.3 GB) under the no-sudo cap (~17.76 GiB), leaving working-set for compute. See spec §2.
    nonisolated static let residentWiredLimitBytes: UInt64 = 17_179_869_184

    /// Pure mapping toggle → wired bytes. 0 = pageable.
    nonisolated static func wiredLimitBytes(keepResident: Bool) -> UInt64 {
        keepResident ? residentWiredLimitBytes : 0
    }

    public init() {
        var cfg = ServerConfig.default
        cfg.wiredLimitBytes = Self.wiredLimitBytes(
            keepResident: UserDefaults.standard.bool(forKey: SettingsKeys.keepModelResident))
        self.serverManager = ServerManager(config: cfg)
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

    /// Apply the "keep model resident" toggle: restart the server with/without a wired limit.
    /// No-op under XCTest (same guard as startServer — must not spawn the 15GB server in tests).
    public func applyKeepModelResident(_ on: Bool) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { await serverManager.setWiredLimit(Self.wiredLimitBytes(keepResident: on)) }
    }

    func inspectorStore() -> MemoryStore? { memoryStore }

    private func makeGenerationOptions(history: [ChatMessage] = []) -> GenerationOptions {
        GenerationOptions(maxTokens: settings.maxOutputTokens, temperature: settings.temperature,
                          topP: settings.topP, topK: settings.topK,
                          systemPrompt: settings.systemPrompt.isEmpty ? nil : settings.systemPrompt,
                          history: history)
    }

    private func ensureMemory() -> MemoryServices? {
        guard settings.memoryEnabled ?? true else { return nil }
        if memoryStore == nil {
            memoryEmbedder = try? NLContextualEmbedder()
            let dim = memoryEmbedder?.dimension ?? 512
            memoryStore = try? MemoryStore(url: try? MemoryStore.defaultURL(), embeddingDim: dim)
        }
        guard let store = memoryStore else { return nil }
        if transcriptStore == nil { transcriptStore = TranscriptStore(dbQueue: store.dbQueue) }
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.embedder = memoryEmbedder
        MemoryToolbox.shared.transcriptStore = transcriptStore
        // Build the consolidation engine + scheduler ONCE, then reuse across turns.
        if consolidationScheduler == nil {
            // Share the turn runtime: all consolidation phases run thinking-OFF (the runtime's
            // default), same as turns, so there is nothing to override. Safe to share —
            // ServerRuntime is stateless.
            let engine = MemoryConsolidationEngine(store: store, embedder: memoryEmbedder, runtime: runtime,
                                                   transcriptStore: transcriptStore ?? TranscriptStore(dbQueue: store.dbQueue))
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
        //
        // Capture whether a consolidation was ACTIVELY running before we cancel it: only such a
        // turn truly "interrupts" a cycle. We use this to gate the reflection-focus line below so
        // it surfaces once (on the interrupting turn) rather than nagging on every subsequent
        // pending-but-idle turn while the cycle merely waits to resume.
        let wasConsolidating: Bool = {
            switch consolidationScheduler?.state {
            case .reflecting, .sleeping: return true
            default: return false
            }
        }()
        consolidationScheduler?.noteUserActivity()
        let registry = ToolRegistry()
        registry.register(CurrentTimeTool())
        if memory != nil {
            registry.register(ForgetTool()); registry.register(ReflectTool()); registry.register(ExpandContextTool())
        }
        let now = Date().timeIntervalSince1970
        let isWake = (lastTurnEndedAt == 0) || (now - lastTurnEndedAt > Self.wakeGapSeconds)
        // Focus is gated to the turn that interrupted an active cycle (see wasConsolidating
        // above): on a merely pending-but-idle cycle we pass "" so buildWakeContext omits the line.
        let focus = wasConsolidating ? (((try? memoryStore?.loadSleepCycle()) ?? nil)?.focus ?? "") : ""
        let followUps = isWake ? (((try? memoryStore?.pendingFollowUps()) ?? nil)?.map { $0.body } ?? []) : []
        let wakeContext = Self.buildWakeContext(focus: focus, followUps: followUps, isWake: isWake)
        let history: [ChatMessage] = {
            guard let ts = transcriptStore else { return [] }
            let rows = (try? ts.recent(threadId: threadId,
                                       maxTurns: ConversationWindow.defaultMaxTurns,
                                       maxChars: ConversationWindow.defaultMaxChars)) ?? []
            return ConversationWindow.messages(from: rows)
        }()
        let agent = Agent(runtime: runtime, registry: registry, memory: memory, wakeContext: wakeContext)
        var answer = ""
        var streamingIdx: Int? = nil   // index of the live "gemma: …" line being streamed into
        do {
            for try await event in agent.run(prompt: prompt, options: makeGenerationOptions(history: history)) {
                switch event {
                case .token(let t):
                    answer += t
                    // Render tokens live: append the assistant line on the first token, then grow it.
                    if let i = streamingIdx { agentLog[i] = "gemma: \(answer)" }
                    else { agentLog.append("gemma: \(answer)"); streamingIdx = agentLog.count - 1 }
                case .toolCallStarted(let n, _): agentLog.append("🔧 \(n)…")
                case .toolCallFinished(let n, let r): agentLog.append("🔧 \(n) ✓ \(r)")
                case .completed:
                    // If nothing streamed (e.g. dummy runtime / empty answer), show it once now.
                    if streamingIdx == nil, !answer.isEmpty { agentLog.append("gemma: \(answer)") }
                case .failed(let m): agentLog.append("[error: \(m)]")
                }
            }
        } catch { agentLog.append("[error: \(error)]") }
        if let ts = transcriptStore {
            let now = Date().timeIntervalSince1970
            try? ts.append(threadId: threadId, turnIndex: turnIndex, role: "user", text: prompt, now: now)
            if !answer.isEmpty {
                // +1ms so the assistant row always sorts strictly after its user turn (recent()
                // orders by createdAt; equal timestamps would tie and fall back to undefined rowid order).
                try? ts.append(threadId: threadId, turnIndex: turnIndex, role: "assistant", text: answer, now: now + 0.001)
            }
            turnIndex += 1
        }
        lastTurnEndedAt = Date().timeIntervalSince1970
    }
}
