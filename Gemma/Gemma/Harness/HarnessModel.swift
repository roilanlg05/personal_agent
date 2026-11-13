#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public struct ChatLogEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public var role: String // "you", "gemma", "tool", "system", "error"
    public var text: String
    public var thought: String?
    public var isThoughtExpanded: Bool = false

    public init(id: String = UUID().uuidString, role: String, text: String, thought: String? = nil, isThoughtExpanded: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.thought = thought
        self.isThoughtExpanded = isThoughtExpanded
    }
}

@Observable
@MainActor
public final class HarnessModel {
    public var agentLog: [ChatLogEntry] = []
    public var agentRunning: Bool = false
    public var showMemory: Bool = false
    var hasProactive: Bool = false
    private(set) var turnMemoryPersistence: BrainConversationCoordinator.Persistence?

    @ObservationIgnored private var currentTurnTask: Task<Void, Never>?
    @ObservationIgnored private var activeTextTurnID: UUID?
    @ObservationIgnored private var recentConversation = RecentConversation()
    @ObservationIgnored private let brainCue = BrainCuePrefetch()

    @ObservationIgnored private var runtime: ModelRuntime & ToolCallingRuntime
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private(set) var settings: GenerationSettings
    /// HTTP client to the Memory Service (Docker). Built once in `ensureMemory()` from
    /// `UserDefaults` (`memoryBaseURL`, `memoryBearerToken`); shared with `MemoryToolbox`
    /// so tools (Save / Forget / Reflect / LoadMessages) can reach it.
    @ObservationIgnored private(set) var memory: MemoryClient?
    /// In-app voice: records mic audio, sends it to the i3 voice service, plays the reply.
    @ObservationIgnored let voice = VoiceController(recorder: AudioRecorder())
    /// Always-listening "Hey Jarvis". Built lazily (loads ONNX models) so a load failure doesn't crash init.
    @ObservationIgnored private(set) var wake: WakeListener?
    @ObservationIgnored private var episode = ChatSession.Episode(lastActivity: UserDefaults.standard.double(forKey: "lastTurnEndedAt"))

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
    /// The chat thread id voice turns join (same episode as typed chat).
    var currentThreadId: String { episode.id }
    var wakeDetector: WakeDetecting? {
        ensureWake()
        return wake?.detector
    }

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
        #if os(iOS)
        let defaultKind = ModelProvider.Kind.onDevice
        #else
        let defaultKind = ModelProvider.Kind.defaultKind
        #endif
        let kindRaw = UserDefaults.standard.string(forKey: SettingsKeys.chatProvider) ?? defaultKind.rawValue
        let kind = ModelProvider.Kind(rawValue: kindRaw) ?? defaultKind
        let model = UserDefaults.standard.string(forKey: SettingsKeys.chatModel)
        let key = kind.isLocalMLX ? nil : keyLookup(kind)
        return ModelProvider(kind: kind, model: model, apiKey: key)
    }

    var currentProviderKind: ModelProvider.Kind {
        #if os(iOS)
        let defaultKind = ModelProvider.Kind.onDevice
        #else
        let defaultKind = ModelProvider.Kind.defaultKind
        #endif
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.chatProvider) ?? defaultKind.rawValue
        return ModelProvider.Kind(rawValue: raw) ?? defaultKind
    }

    var isMissingApiKey: Bool {
        guard !chatUsesLocalServer else { return false }
        let kind = currentProviderKind
        guard !kind.isLocalMLX else { return false }
        let key = KeychainStore.shared.get(account: "apiKey.\(kind.rawValue)")
        return key == nil || key?.isEmpty == true
    }

    /// Rebuild the chat runtime from current settings (called when chat settings change).
    func rebuildRuntime() {
        let provider = Self.chatProvider(keyLookup: { KeychainStore.shared.get(account: "apiKey.\($0.rawValue)") })
        self.runtime = RuntimeFactory.make(provider)
        self.isPreheated = false
        preheatRuntime()
    }

    public init() {
        var cfg = ServerConfig.default
        cfg.wiredLimitBytes = Self.wiredLimitBytes(
            keepResident: UserDefaults.standard.bool(forKey: SettingsKeys.keepModelResident))
        self.serverManager = ServerManager(config: cfg)
        self.settings = settingsStore.load()
        self.runtime = RuntimeFactory.make(Self.chatProvider(keyLookup: { KeychainStore.shared.get(account: "apiKey.\($0.rawValue)") }))
        #if os(macOS)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopServer() }
        }
        #elseif os(iOS)
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopServer() }
        }
        #endif
        voice.appendLine = { [weak self] line in self?.agentLog.append(ChatLogEntry(role: "system", text: line)) }
        voice.threadId = { [weak self] in self?.currentThreadId ?? "voice" }
        voice.beginActiveEpisode = { [weak self] in
            guard let self else { return "voice" }
            self.cancelDictationCue()
            return self.beginEpisode(at: Date().timeIntervalSince1970).id
        }
        voice.onActiveTurn = { [weak self] episodeID, userText, assistantText in
            guard let self, self.currentThreadId == episodeID else { return }
            self.recentConversation.start(threadID: episodeID)
            self.recentConversation.append(ChatMessage(role: .user, content: userText), threadID: episodeID)
            self.recentConversation.append(ChatMessage(role: .assistant, content: assistantText), threadID: episodeID)
            self.noteConversationActivity(at: Date().timeIntervalSince1970)
        }
        ensureVoice()
        if UserDefaults.standard.bool(forKey: "useWakeWord") {
            ensureWake()
            Task { @MainActor in
                await self.wake?.enable()
            }
        }
        preheatRuntime()
    }

    private var isPreheating: Bool = false
    private var isPreheated: Bool = false

    /// Pre-warm local model on launch so user gets instant zero-cold-start replies
    public func preheatRuntime() {
        guard !isPreheating && !isPreheated else { return }
        isPreheating = true
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.isPreheating = false }
            if let llama = self.runtime as? LlamaCppRuntime {
                do {
                    try await llama.preheat()
                    self.isPreheated = true
                } catch {
                    print("[LlamaRuntime] Aviso precalentamiento: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Returns true when at least one side (chat or consolidation) uses the local mlx model,
    /// meaning the 15 GB mlx server must be running. Pure static for testability.
    nonisolated static func needsLocalModel(chat: String, consolidation: String) -> Bool {
        chat == ModelProvider.Kind.local.rawValue || consolidation == ModelProvider.Kind.local.rawValue
    }

    /// True when the given chat-provider raw value uses the local mlx server (nil → cloud default).
    /// The chat prompt is gated on the local server only in this case. Pure static for testability.
    nonisolated static func usesLocalServer(_ chatProviderRaw: String?) -> Bool {
        (chatProviderRaw ?? ModelProvider.Kind.defaultKind.rawValue) == ModelProvider.Kind.local.rawValue
    }

    /// Whether the current chat provider relies on the local mlx server (drives the prompt's
    /// readiness gate in `AgentChatView`). Cloud chat never waits on the local server.
    var chatUsesLocalServer: Bool {
        Self.usesLocalServer(UserDefaults.standard.string(forKey: SettingsKeys.chatProvider))
    }

    /// Spawn/keep-warm the local mlx server only when a side uses local; otherwise stop it.
    /// No-op under XCTest (mirrors startServer()).
    func refreshLocalModelLifecycle() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let chat = UserDefaults.standard.string(forKey: SettingsKeys.chatProvider) ?? ModelProvider.Kind.defaultKind.rawValue
        let cons = UserDefaults.standard.string(forKey: SettingsKeys.consolidationProvider) ?? ModelProvider.Kind.defaultKind.rawValue
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

    private func makeGenerationOptions(contextTokens: Int) -> GenerationOptions {
        let maxTokens = UserDefaults.standard.object(forKey: "modelMaxTokens") as? Int ?? max(settings.maxOutputTokens, 2048)
        let temp = UserDefaults.standard.object(forKey: "modelTemperature") as? Double ?? 0.2
        return GenerationOptions(maxTokens: maxTokens, contextTokens: contextTokens, temperature: temp,
                          topP: settings.topP, topK: settings.topK,
                          systemPrompt: settings.systemPrompt.isEmpty ? nil : settings.systemPrompt)
    }

    /// Build (or rebuild) the `MemoryClient` from `UserDefaults` settings. The Settings UI
    /// (Task 14) will surface these keys; today users may override via `defaults write`.
    ///
    /// Keys:
    /// - `memoryBaseURL` (String, default `http://localhost:8081`)
    /// - `memoryBearerToken` (String, default empty)
    ///
    /// Mirrors the client into `MemoryToolbox.shared.memory` so the memory tools
    /// (Save / Forget / Reflect / LoadMessages) can reach the same instance.
    func ensureMemory() {
        guard settings.memoryEnabled ?? true else {
            cancelDictationCue()
            self.memory = nil
            MemoryToolbox.shared.memory = nil
            MemoryToolbox.shared.reflectionRequest = nil
            return
        }
        var urlString = UserDefaults.standard.string(forKey: "memoryBaseURL") ?? "http://localhost:8081"
        #if os(iOS)
        if urlString == "http://localhost:8081" || urlString == "http://192.168.1.50:8081" || urlString.isEmpty {
            urlString = "http://100.91.174.81:8081"
            UserDefaults.standard.set(urlString, forKey: "memoryBaseURL")
        }
        #endif
        var token = UserDefaults.standard.string(forKey: "memoryBearerToken") ?? ""
        if token.isEmpty {
            token = "replace-me-with-a-long-random-string"
            UserDefaults.standard.set(token, forKey: "memoryBearerToken")
        }
        guard let baseURL = URL(string: urlString) else {
            cancelDictationCue()
            self.memory = nil
            MemoryToolbox.shared.memory = nil
            return
        }
        if memory?.baseURL == baseURL, memory?.bearerToken == token { return }
        cancelDictationCue()
        let client = MemoryClient(baseURL: baseURL, bearerToken: token)
        self.memory = client
        MemoryToolbox.shared.memory = client
        MemoryToolbox.shared.reflectionRequest = { [weak client] in
            Task { _ = try? await client?.reflect() }
        }
    }

    /// Resolve the voice base URL: the explicit `voiceBaseURL` if set, otherwise the Memory host
    /// on port 8082 (voice + memory live on the same i3, so voice auto-follows the Memory URL —
    /// avoids the localhost default failing when Memory points at the i3).
    nonisolated static func voiceURLString(explicit: String, memory: String) -> String {
        let e = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return e }
        guard var comps = URLComponents(string: memory) else { return "http://localhost:8082" }
        comps.port = 8082
        return comps.string ?? "http://localhost:8082"
    }

    /// Build the wake listener (loads the ONNX models). On failure, leaves `wake == nil` (toggle stays off).
    func ensureWake() {
        guard wake == nil else { return }
        guard let detector = try? WakeWordDetector() else {
            agentLog.append(ChatLogEntry(role: "system", text: "voice: wake word no disponible (no pude cargar el modelo)."))
            return
        }
        self.wake = WakeListener(detector: detector) { [weak self] wav, isPassive in
            guard let self else { return }
            Task { @MainActor in
                await self.voice.send(wav, isPassive: isPassive)                       // POST -> append you:/gemma: -> start playback
                while self.voice.state != .idle {               // wait for playback to FINISH before re-arming
                    try? await Task.sleep(for: .milliseconds(150))
                }
                self.wake?.notePlaybackFinished()               // re-arm (also covered by WakeListener's 30s watchdog)
            }
        }
        // Disable wake listener when the user says a termination phrase ("that's all", "ok", "gracias", etc.)
        self.voice.onStopRequested = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.wake?.disable()
                UserDefaults.standard.set(false, forKey: "useWakeWord")
                self.agentLog.append(ChatLogEntry(role: "gemma", text: "escucha desactivada. Dime 'Hey Gemma' cuando me necesites de nuevo."))
            }
        }
        // Mutual exclusion with manual tap-to-talk: don't act on the wake word while a voice turn is active.
        self.wake?.isVoiceBusy = { [weak self] in self?.voice.state != .idle }
    }

    /// Build (or rebuild) the voice client from `UserDefaults`. Reuses the memory bearer token
    /// (the i3 voice service shares it). `voiceBaseURL` (optional) overrides; empty → derive from
    /// `memoryBaseURL` on port 8082.
    func ensureVoice() {
        let explicit = UserDefaults.standard.string(forKey: "voiceBaseURL") ?? ""
        let memory = UserDefaults.standard.string(forKey: "memoryBaseURL") ?? "http://localhost:8081"
        let token = UserDefaults.standard.string(forKey: "memoryBearerToken") ?? ""
        guard let baseURL = URL(string: Self.voiceURLString(explicit: explicit, memory: memory)) else { return }
        voice.configure(baseURL: baseURL, token: token)
    }

    /// Push the consolidation provider config to the i3 (key included, over the authed channel).
    func pushConsolidationConfig() {
        ensureMemory()
        guard let client = memory else { return }
        let kindRaw = UserDefaults.standard.string(forKey: SettingsKeys.consolidationProvider) ?? ModelProvider.Kind.defaultKind.rawValue
        let kind = ModelProvider.Kind(rawValue: kindRaw) ?? .defaultKind
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

    public func startAgentTurn(_ prompt: String) {
        currentTurnTask?.cancel()
        currentTurnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runAgentTurn(prompt)
        }
    }

    public func cancelAgentTurn() {
        cancelDictationCue()
        currentTurnTask?.cancel()
        currentTurnTask = nil
        agentRunning = false
        agentLog.append(ChatLogEntry(role: "system", text: "⏹ Generación detenida"))
    }

    private func noteConversationActivity(at time: Double) {
        episode.noteActivity(now: time)
        UserDefaults.standard.set(time, forKey: "lastTurnEndedAt")
    }

    private func beginEpisode(at time: Double) -> (id: String, index: Int) {
        let previous = episode.id
        let started = episode.begin(now: time)
        if previous != started.id {
            cancelDictationCue()
            recentConversation.start(threadID: started.id)
        }
        return started
    }

    func restoreConversation(_ threadID: String) {
        guard !threadID.isEmpty, threadID != episode.id else { return }
        cancelDictationCue()
        currentTurnTask?.cancel()
        currentTurnTask = nil
        activeTextTurnID = nil
        agentRunning = false
        agentLog.removeAll()
        turnMemoryPersistence = nil
        let now = Date().timeIntervalSince1970
        episode.restore(threadID: threadID, now: now)
        recentConversation = RecentConversation()
        recentConversation.start(threadID: threadID)
        noteConversationActivity(at: now)
    }

    func updateDictationCue(_ partial: String) {
        guard let memory, settings.memoryEnabled ?? true else { return }
        let now = Date().timeIntervalSince1970
        guard !ChatSession.shouldStartNewChat(lastActivity: episode.lastActivity, now: now) else { return }
        brainCue.submit(partial: partial, threadID: episode.id, client: memory)
    }

    func cancelDictationCue() { brainCue.cancel() }

    public func runAgentTurn(_ prompt: String) async {
        guard !Task.isCancelled else { return }
        let textTurnID = UUID()
        activeTextTurnID = textTurnID
        let provider = Self.chatProvider(keyLookup: { KeychainStore.shared.get(account: "apiKey.\($0.rawValue)") })
        if !(self.runtime is LlamaCppRuntime && provider.kind == .onDevice) {
            self.runtime = RuntimeFactory.make(provider)
        }
        let runtime = self.runtime
        surfaceProactive()
        agentRunning = true
        defer {
            if activeTextTurnID == textTurnID {
                activeTextTurnID = nil
                agentRunning = false
            }
        }
        agentLog.append(ChatLogEntry(role: "you", text: prompt))
        turnMemoryPersistence = nil
        ensureMemory()
        let client = memory
        let registry = ToolRegistry.native(memoryAvailable: client != nil)
        let now = Date().timeIntervalSince1970
        let lastConversationActivity = episode.lastActivity
        let (episodeID, transcriptIndex) = beginEpisode(at: now)
        let operationID = brainCue.consume(final: prompt, threadID: episodeID, client: client)
        recentConversation.start(threadID: episodeID)
        let priorConversation = recentConversation
        recentConversation.append(ChatMessage(role: .user, content: prompt), threadID: episodeID)
        let wakeContext: String = {
            guard lastConversationActivity > 0 else {
                return "Last interaction with user: none recorded (first interaction or new session)."
            }
            let elapsedSec = now - lastConversationActivity
            let timeDesc: String
            if elapsedSec < 120 {
                timeDesc = "about 1-2 minutes ago (just now, ongoing conversation)"
            } else if elapsedSec < 3600 {
                let mins = max(1, Int(round(elapsedSec / 60)))
                timeDesc = "\(mins) minute\(mins == 1 ? "" : "s") ago"
            } else if elapsedSec < 86400 {
                let hours = Int(round(elapsedSec / 3600))
                timeDesc = "\(hours) hour\(hours == 1 ? "" : "s") ago"
            } else {
                let days = Int(round(elapsedSec / 86400))
                timeDesc = "\(days) day\(days == 1 ? "" : "s") ago"
            }
            return "Last interaction with user: \(timeDesc)."
        }()
        noteConversationActivity(at: now)
        let coordinator = BrainConversationCoordinator(client: client, threadID: episodeID,
                                                       transcriptIndex: transcriptIndex, operationID: operationID)
        let prepared: BrainConversationCoordinator.PreparedTurn
        do {
            let limit = provider.kind.isLocalMLX ? min(settings.contextLength, provider.kind.nativeContextTokens) : provider.kind.nativeContextTokens
            let options = makeGenerationOptions(contextTokens: limit)
            prepared = try await coordinator.prepare(prompt: prompt, options: options,
                priorConversation: priorConversation, wakeContext: wakeContext, registry: registry)
        } catch is CancellationError {
            return
        } catch {
            if activeTextTurnID == textTurnID {
                agentLog.append(ChatLogEntry(role: "error", text: "\(error)"))
            }
            return
        }
        guard !Task.isCancelled, activeTextTurnID == textTurnID, currentThreadId == episodeID else { return }
        turnMemoryPersistence = prepared.persistence
        var answer = ""
        var finalAssistantText = ""
        var currentThought = ""
        var activeGemmaIdx: Int? = nil

        do {
            for try await event in prepared.run(runtime: runtime) {
                guard !Task.isCancelled, activeTextTurnID == textTurnID, currentThreadId == episodeID else { break }
                switch event {
                case .thought(let th):
                    currentThought += th
                    if let idx = activeGemmaIdx {
                        agentLog[idx].thought = currentThought
                    } else {
                        agentLog.append(ChatLogEntry(role: "gemma", text: "", thought: currentThought))
                        activeGemmaIdx = agentLog.count - 1
                    }
                case .token(let t):
                    answer += t
                    let stripped = GemmaToolCallParser.strip(answer)
                    let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && trimmed != "<|" && !trimmed.hasPrefix("<|") {
                        if let idx = activeGemmaIdx {
                            agentLog[idx].text = stripped
                        } else {
                            agentLog.append(ChatLogEntry(role: "gemma", text: stripped, thought: currentThought.isEmpty ? nil : currentThought))
                            activeGemmaIdx = agentLog.count - 1
                        }
                    }
                case .toolCallStarted(let n, _):
                    if let idx = activeGemmaIdx {
                        // A tool call has started: any text streamed prior to this tool call
                        // was an internal tool invocation fragment and must never remain as user answer.
                        if agentLog[idx].thought?.isEmpty ?? true {
                            agentLog.remove(at: idx)
                        } else {
                            agentLog[idx].text = ""
                        }
                    }
                    agentLog.append(ChatLogEntry(role: "tool", text: "🔧 \(n)…"))
                    activeGemmaIdx = nil
                    currentThought = ""
                    answer = ""
                    finalAssistantText = ""
                case .toolCallFinished(let n, let r):
                    agentLog.append(ChatLogEntry(role: "tool", text: "🔧 \(n) ✓ \(r)"))
                    activeGemmaIdx = nil
                    currentThought = ""
                    answer = ""
                    finalAssistantText = ""
                case .completed(let res):
                    let chosen = !res.text.isEmpty ? res.text : answer
                    let stripped = GemmaToolCallParser.strip(chosen)
                    finalAssistantText = stripped
                    if let idx = activeGemmaIdx {
                        agentLog[idx].text = stripped
                    } else if !stripped.isEmpty {
                        agentLog.append(ChatLogEntry(role: "gemma", text: stripped))
                    }
                case .failed(let m):
                    agentLog.append(ChatLogEntry(role: "error", text: m))
                }
            }
        } catch is CancellationError {
            if activeTextTurnID == textTurnID, let idx = activeGemmaIdx {
                let current = agentLog[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
                if current.isEmpty && (agentLog[idx].thought?.isEmpty ?? true) {
                    agentLog.remove(at: idx)
                }
            }
        } catch {
            if activeTextTurnID == textTurnID {
                agentLog.append(ChatLogEntry(role: "error", text: "\(error)"))
            }
        }
        guard !Task.isCancelled, activeTextTurnID == textTurnID, currentThreadId == episodeID else { return }
        recentConversation.append(ChatMessage(role: .assistant, content: finalAssistantText), threadID: episodeID)
        noteConversationActivity(at: Date().timeIntervalSince1970)
        let persistence = await coordinator.complete(prepared, assistantText: finalAssistantText)
        if !Task.isCancelled, activeTextTurnID == textTurnID {
            turnMemoryPersistence = persistence
        }
    }
}
