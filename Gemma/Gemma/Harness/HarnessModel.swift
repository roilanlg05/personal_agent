import Foundation
import Observation
import AppKit

@Observable
@MainActor
public final class HarnessModel {
    public var agentLog: [String] = []
    public var agentRunning: Bool = false
    public var showMemory: Bool = false
    var hasProactive: Bool = false

    @ObservationIgnored private var runtime: ModelRuntime & ToolCallingRuntime
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private(set) var settings: GenerationSettings
    /// HTTP client to the Memory Service (Docker). Built once in `ensureMemory()` from
    /// `UserDefaults` (`memoryBaseURL`, `memoryBearerToken`); shared with `MemoryToolbox`
    /// so tools (Save / Forget / Reflect / Expand) can reach it.
    @ObservationIgnored private(set) var memory: MemoryClient?
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
    @ObservationIgnored private let threadId = UUID().uuidString
    @ObservationIgnored private var turnIndex = 0

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

    /// Build the chat provider from settings. `keyLookup` returns the stored API key for a kind
    /// (injected for tests; production passes KeychainStore.shared.get).
    static func chatProvider(keyLookup: (ModelProvider.Kind) -> String?) -> ModelProvider {
        let kindRaw = UserDefaults.standard.string(forKey: SettingsKeys.chatProvider) ?? "local"
        let kind = ModelProvider.Kind(rawValue: kindRaw) ?? .local
        let model = UserDefaults.standard.string(forKey: SettingsKeys.chatModel)
        let key = kind.isLocalMLX ? nil : keyLookup(kind)
        return ModelProvider(kind: kind, model: model, apiKey: key)
    }

    /// Rebuild the chat runtime from current settings (called when chat settings change).
    func rebuildRuntime() {
        let provider = Self.chatProvider(keyLookup: { KeychainStore.shared.get(account: "apiKey.\($0.rawValue)") })
        self.runtime = RuntimeFactory.make(provider)
    }

    public init() {
        var cfg = ServerConfig.default
        cfg.wiredLimitBytes = Self.wiredLimitBytes(
            keepResident: UserDefaults.standard.bool(forKey: SettingsKeys.keepModelResident))
        self.serverManager = ServerManager(config: cfg)
        self.settings = settingsStore.load()
        self.runtime = RuntimeFactory.make(Self.chatProvider(keyLookup: { KeychainStore.shared.get(account: "apiKey.\($0.rawValue)") }))
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopServer() }
        }
    }

    /// Returns true when at least one side (chat or consolidation) uses the local mlx model,
    /// meaning the 15 GB mlx server must be running. Pure static for testability.
    nonisolated static func needsLocalModel(chat: String, consolidation: String) -> Bool {
        chat == ModelProvider.Kind.local.rawValue || consolidation == ModelProvider.Kind.local.rawValue
    }

    /// Spawn/keep-warm the local mlx server only when a side uses local; otherwise stop it.
    /// No-op under XCTest (mirrors startServer()).
    func refreshLocalModelLifecycle() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let chat = UserDefaults.standard.string(forKey: SettingsKeys.chatProvider) ?? "local"
        let cons = UserDefaults.standard.string(forKey: SettingsKeys.consolidationProvider) ?? "local"
        if Self.needsLocalModel(chat: chat, consolidation: cons) {
            Task { await serverManager.start() }
        } else {
            serverManager.stop()
        }
    }

    /// Launch/attach the server and start keeping it warm. Safe to call again (Retry).
    /// No-op under XCTest: the unit-test host launches this app, and we must NOT spawn the
    /// real 15GB mlx-lm server on every test run (it would load after the run and orphan).
    /// Spawn decision is gated on `needsLocalModel`: if both chat and consolidation are cloud,
    /// the server is stopped instead of started (default settings = both local → unchanged).
    public func startServer() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        refreshLocalModelLifecycle()
        // Sync the consolidation provider config to the i3 at launch (same XCTest guard above).
        pushConsolidationConfig()
    }

    /// Terminate the owned server (called on app quit).
    public func stopServer() { serverManager.stop() }

    /// Apply the "keep model resident" toggle: restart the server with/without a wired limit.
    /// No-op under XCTest (same guard as startServer — must not spawn the 15GB server in tests).
    public func applyKeepModelResident(_ on: Bool) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { await serverManager.setWiredLimit(Self.wiredLimitBytes(keepResident: on)) }
    }

    /// The current Memory Service client, exposed for the inspector views. Nil until
    /// `ensureMemory()` has been called at least once with valid settings.
    func memoryClient() -> MemoryClient? { memory }

    private func makeGenerationOptions(history: [ChatMessage] = []) -> GenerationOptions {
        GenerationOptions(maxTokens: settings.maxOutputTokens, temperature: settings.temperature,
                          topP: settings.topP, topK: settings.topK,
                          systemPrompt: settings.systemPrompt.isEmpty ? nil : settings.systemPrompt,
                          history: history)
    }

    /// Build (or rebuild) the `MemoryClient` from `UserDefaults` settings. The Settings UI
    /// (Task 14) will surface these keys; today users may override via `defaults write`.
    ///
    /// Keys:
    /// - `memoryBaseURL` (String, default `http://localhost:8081`)
    /// - `memoryBearerToken` (String, default empty)
    ///
    /// Mirrors the client into `MemoryToolbox.shared.memory` so the four memory tools
    /// (Save / Forget / Reflect / Expand) can reach the same instance.
    func ensureMemory() {
        guard settings.memoryEnabled ?? true else {
            self.memory = nil
            MemoryToolbox.shared.memory = nil
            MemoryToolbox.shared.reflectionRequest = nil
            return
        }
        let urlString = UserDefaults.standard.string(forKey: "memoryBaseURL") ?? "http://localhost:8081"
        let token = UserDefaults.standard.string(forKey: "memoryBearerToken") ?? ""
        guard let baseURL = URL(string: urlString) else {
            self.memory = nil
            MemoryToolbox.shared.memory = nil
            return
        }
        let client = MemoryClient(baseURL: baseURL, bearerToken: token)
        self.memory = client
        MemoryToolbox.shared.memory = client
        MemoryToolbox.shared.reflectionRequest = { [weak client] in
            Task { _ = try? await client?.reflect() }
        }
    }

    /// Push the consolidation provider config to the i3 (key included, over the authed channel).
    func pushConsolidationConfig() {
        ensureMemory()
        guard let client = memory else { return }
        let kindRaw = UserDefaults.standard.string(forKey: SettingsKeys.consolidationProvider) ?? "local"
        let kind = ModelProvider.Kind(rawValue: kindRaw) ?? .local
        let model = UserDefaults.standard.string(forKey: SettingsKeys.consolidationModel)
        let provider = ModelProvider(kind: kind, model: model,
                                     apiKey: kind.isLocalMLX ? nil : KeychainStore.shared.get(account: "apiKey.\(kind.rawValue)"))
        Task {
            try? await client.setModelConfig(provider: kind.rawValue,
                                              baseURL: provider.baseURL.absoluteString,
                                              model: provider.model, apiKey: provider.apiKey)
        }
    }

    /// Manually kick off a reflection cycle (toolbar "Consolidar"). Service-driven now.
    func consolidateNow() {
        guard let client = memory else { return }
        Task { _ = try? await client.reflect() }
    }

    /// Compose agent-initiated chat lines from pending clarifications + due reminders. Empty when
    /// there's nothing to say (the agent never speaks for chit-chat).
    nonisolated static func proactiveMessages(clarifications: [String], dueReminders: [String]) -> [String] {
        var out: [String] = []
        for r in dueReminders { out.append("gemma: ⏰ Recordatorio: \(r)") }
        for c in clarifications { out.append("gemma: ❓ \(c)") }
        return out
    }

    /// Post the agent's pending clarifications + due reminders into the chat. No-op for M3a:
    /// the Memory Service does not yet expose dedicated endpoints for pending clarifications /
    /// due reminders. Will be re-enabled when those endpoints land.
    func surfaceProactive() {
        // TODO(m3a-follow-up): expose /v1/proactive (clarifications + due reminders) on the
        // service so the harness can surface them again without GRDB access.
    }

    public func runAgentTurn(_ prompt: String) async {
        surfaceProactive()
        agentRunning = true; defer { agentRunning = false }
        agentLog.append("you: \(prompt)")
        ensureMemory()
        let client = memory
        let registry = ToolRegistry()
        registry.register(CurrentTimeTool())
        if client != nil {
            registry.register(ForgetTool()); registry.register(ReflectTool()); registry.register(ExpandContextTool())
            registry.register(SaveMemoryTool())
            registry.register(CheckScheduleTool()); registry.register(CreateEventTool())
            registry.register(QueryScheduleTool()); registry.register(CancelEventsTool())
        }
        let now = Date().timeIntervalSince1970
        let isWake = (lastTurnEndedAt == 0) || (now - lastTurnEndedAt > Self.wakeGapSeconds)
        _ = isWake // followUps / focus are service-driven now (no per-turn HTTP for them in M3a)
        // M3a: focus / pendingFollowUps surfaces would require dedicated endpoints. The
        // service still consolidates in the background; for now wake-context is silent until
        // those endpoints land. Recall (the main signal) still rides the user prompt tail.
        let wakeContext = ""
        // Build recallTail via HTTP. recall() returns .empty on transport failure (see
        // MemoryClient.recall), so an offline service degrades to "no recall" instead of crashing.
        var recallTail = ""
        if let client {
            let bundle = (try? await client.recall(query: prompt)) ?? .empty
            recallTail = bundle.injectionBlock()
        }
        // Fetch the short-term conversation window over HTTP. Falls back to empty on failure.
        let history: [ChatMessage] = await {
            guard let client else { return [] }
            let turns = (try? await client.conversationWindow(threadId: threadId)) ?? []
            return turns.map { ChatMessage(role: $0.role == "assistant" ? .assistant : .user, content: $0.text) }
        }()
        let agent = Agent(runtime: runtime, registry: registry, recallTail: recallTail, wakeContext: wakeContext)
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
        // Append both turns to the transcript over HTTP. Failures are silent (service-down
        // shouldn't crash a successful turn — the user can see Gemma's reply).
        if let client {
            try? await client.appendTranscript(threadId: threadId, role: "user", text: prompt, turnIndex: turnIndex)
            if !answer.isEmpty {
                try? await client.appendTranscript(threadId: threadId, role: "assistant", text: answer, turnIndex: turnIndex)
            }
            turnIndex += 1
            // Signal the service to arm its consolidation timers. Fire-and-forget.
            try? await client.consolidationTurnEnd(threadId: threadId)
        }
        lastTurnEndedAt = Date().timeIntervalSince1970
    }
}
