#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public struct ChatLogEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public var role: String // "you", "gemma", "tool", "system", "error", "browserPanel", "form"
    public var text: String
    public var thought: String?
    public var isThoughtExpanded: Bool = false
    /// Solo para `role == "browserPanel"`: id del panel en `HarnessModel.browserPanels`.
    public var panelID: String?
    /// Solo para `role == "tool"`: nombre de la herramienta, su resultado crudo
    /// (nil mientras corre) y si la fila está abierta. El resultado no va en `text`.
    public var toolName: String?
    public var toolDetail: String?
    public var isToolExpanded: Bool = false
    /// Solo para `role == "form"`: id del formulario en `FormBroker` (`PendingForm.id`). El título
    /// del formulario va en `text`. La fila NUNCA lleva valores: ni los tecleados ni los enviados.
    public var formID: String?
    /// Solo para `role == "form"`: `"pendiente"`, `"enviado"` o `"cancelado"` (incluye plazo vencido
    /// y fin de turno). Es lo único que la tarjeta recuerda del desenlace.
    public var formEstado: String?

    public init(id: String = UUID().uuidString, role: String, text: String, thought: String? = nil, isThoughtExpanded: Bool = false, panelID: String? = nil, toolName: String? = nil, toolDetail: String? = nil, isToolExpanded: Bool = false, formID: String? = nil, formEstado: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.thought = thought
        self.isThoughtExpanded = isThoughtExpanded
        self.panelID = panelID
        self.toolName = toolName
        self.toolDetail = toolDetail
        self.isToolExpanded = isToolExpanded
        self.formID = formID
        self.formEstado = formEstado
    }
}

@Observable
@MainActor
public final class HarnessModel {
    public var agentLog: [ChatLogEntry] = []
    public var agentRunning: Bool = false
    public var showMemory: Bool = false
    var hasProactive: Bool = false

    @ObservationIgnored private var currentTurnTask: Task<Void, Never>?
    /// Paneles de navegador del chat (uno por turno). Inyectable para poder probar el cierre
    /// del panel sin abrir un socket real; por omisión usa el relé del i3 si está configurado.
    @ObservationIgnored public private(set) var browserPanels: BrowserPanelCoordinator

    @ObservationIgnored private var runtime: ModelRuntime & ToolCallingRuntime
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private(set) var settings: GenerationSettings
    /// HTTP client to the Memory Service (Docker). Built once in `ensureMemory()` from
    /// `UserDefaults` (`memoryBaseURL`) + el llavero (el token, vía `TokenDeMemoria`); shared with
    /// `MemoryToolbox` so tools (Save / Forget / Reflect / LoadMessages) can reach it.
    @ObservationIgnored private(set) var memory: MemoryClient?
    /// De dónde salen los secretos de este modelo (hoy: el token del servicio de memoria, que la
    /// voz comparte). **Inyectable, y no es un adorno de diseño: es lo que impide que una prueba
    /// toque la entrada de producción del llavero.** `init` llama a `ensureVoice()`, que lee el
    /// token; tres ficheros de prueba construyen un `HarnessModel`, y el host de las pruebas es la
    /// propia app, así que sin esto una corrida leería el token real del usuario —y un acceso al
    /// llavero desde el binario de pruebas puede además abrir un diálogo y colgar la corrida de
    /// todos. Esas tres pruebas pasan un `AlmacenEnMemoria`.
    @ObservationIgnored let almacenDeSecretos: any AlmacenDeSecretos
    /// Intermediario de los formularios que pide el agente (`present_form`). Uno por modelo: la
    /// tarjeta del chat observa su `pendiente`.
    @ObservationIgnored let formularios = FormBroker()
    /// Bóveda de secretos del usuario. Con el llavero real usa SU servicio propio
    /// (`SecretVault.servicioDelLlavero`, distinto del de los tokens); con un almacén inyectado
    /// (las pruebas) usa ese mismo almacén, de modo que una prueba NUNCA toca el Keychain real.
    @ObservationIgnored let boveda: SecretVault
    /// In-app voice: records mic audio, sends it to the i3 voice service, plays the reply.
    @ObservationIgnored let voice = VoiceController(recorder: AudioRecorder())
    /// Always-listening "Hey Jarvis". Built lazily (loads ONNX models) so a load failure doesn't crash init.
    @ObservationIgnored private(set) var wake: WakeListener?
    @ObservationIgnored var lastTurnEndedAt: Double = UserDefaults.standard.double(forKey: "lastTurnEndedAt")
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
    /// The active episode thread id. Persisted in UserDefaults so it survives app restarts.
    /// Starts as a UUID (never "main") so each installation has its own scoped thread from day one.
    @ObservationIgnored private var threadId: String = {
        if let saved = UserDefaults.standard.string(forKey: "activeThreadId"), !saved.isEmpty {
            return saved
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "activeThreadId")
        return fresh
    }()
    /// The chat thread id voice turns join (same episode as typed chat).
    var currentThreadId: String { threadId }
    var wakeDetector: WakeDetecting? {
        ensureWake()
        return wake?.detector
    }
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

    /// La búsqueda de API keys que usa producción: el almacén nuevo (`LlaveroDelSistema` vía
    /// `ClaveDeProveedor`), **nunca** `UserDefaults`.
    ///
    /// Está aquí, en un solo sitio, porque los lectores de la key son **cinco** en este fichero
    /// (`isMissingApiKey`, `rebuildRuntime`, `init`, `pushConsolidationConfig`, `runAgentTurn`) y
    /// uno de ellos corre en cada arranque. Con la expresión repetida cinco veces, el que se
    /// quedara sin cambiar dejaría la key vieja viva en el llavero de ficheros y el arreglo a
    /// medias, con todo verde.
    nonisolated static func clavesDelAlmacen(_ almacen: any AlmacenDeSecretos)
    -> (ModelProvider.Kind) -> String? {
        { kind in ClaveDeProveedor.leer(proveedor: kind.rawValue, almacen: almacen) }
    }

    /// Build the chat provider from settings. `keyLookup` returns the stored API key for a kind
    /// (injected for tests; production passes `Self.clavesDelAlmacen(almacenDeSecretos)`).
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
        let key = ClaveDeProveedor.leer(proveedor: kind.rawValue, almacen: almacenDeSecretos)
        return key == nil || key?.isEmpty == true
    }

    /// Rebuild the chat runtime from current settings (called when chat settings change).
    func rebuildRuntime() {
        let provider = Self.chatProvider(keyLookup: Self.clavesDelAlmacen(almacenDeSecretos))
        self.runtime = RuntimeFactory.make(provider)
        self.isPreheated = false
        preheatRuntime()
    }

    public init(browserPanels: BrowserPanelCoordinator? = nil,
                almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido,
                boveda: SecretVault? = nil) {
        self.almacenDeSecretos = almacen
        self.boveda = boveda ?? (almacen is LlaveroDelSistema ? SecretVault() : SecretVault(almacen: almacen))
        self.browserPanels = browserPanels ?? BrowserPanelCoordinator(stream: { Self.makeRelayStream() })
        var cfg = ServerConfig.default
        cfg.wiredLimitBytes = Self.wiredLimitBytes(
            keepResident: UserDefaults.standard.bool(forKey: SettingsKeys.keepModelResident))
        self.serverManager = ServerManager(config: cfg)
        self.settings = settingsStore.load()
        Self.migrateMemoryBaseURLIfNeeded()
        self.runtime = RuntimeFactory.make(Self.chatProvider(keyLookup: Self.clavesDelAlmacen(almacen)))
        observaFormularios()
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

    private func makeGenerationOptions(history: [ChatMessage] = []) -> GenerationOptions {
        let maxTokens = UserDefaults.standard.object(forKey: "modelMaxTokens") as? Int ?? max(settings.maxOutputTokens, 2048)
        let temp = UserDefaults.standard.object(forKey: "modelTemperature") as? Double ?? 0.2
        return GenerationOptions(maxTokens: maxTokens, temperature: temp,
                          topP: settings.topP, topK: settings.topK,
                          systemPrompt: settings.systemPrompt.isEmpty ? nil : settings.systemPrompt,
                          history: history)
    }

    /// Clave de la migración de una sola vez de `memoryBaseURL` en iOS. Lleva versión en el
    /// nombre porque una migración futura necesitará su propia bandera, no reutilizar esta.
    static let memoryURLMigrationKey = "memoryBaseURLMigratedToTailscale.v1"

    /// Las dos direcciones que un iPhone NO puede alcanzar y que quedaron guardadas de
    /// cuando la app era de escritorio: `localhost` es el propio teléfono, y la IP de LAN
    /// solo vale dentro de casa. Se sustituyen UNA VEZ por la del i3 en Tailscale.
    static let unreachableMemoryHostsOnPhone = ["http://localhost:8081", "http://192.168.1.50:8081"]

    /// Migración de una sola vez: corre al construir el modelo, NUNCA desde Ajustes.
    ///
    /// Antes esto vivía dentro de `ensureMemory()`, y de ahí salió una avería fea: Ajustes
    /// llama a `ensureMemory()` en CADA PULSACIÓN de tecla, y la versión antigua reescribía
    /// los ajustes cuando el campo estaba vacío. Resultado: borrabas el campo para poner un
    /// token nuevo y la app te lo volvía a escribir entero, así que cambiarlo era imposible
    /// — no un fastidio, imposible. Un ajuste solo se escribe donde el usuario lo escribe.
    ///
    /// Por eso aquí **el campo vacío no se toca**: vacío significa «lo he borrado yo», y la
    /// respuesta correcta es quedarse sin memoria y decirlo, no inventar un servidor.
    static func migrateMemoryBaseURLIfNeeded(defaults: UserDefaults = .standard) {
        #if os(iOS)
        guard !defaults.bool(forKey: memoryURLMigrationKey) else { return }
        defaults.set(true, forKey: memoryURLMigrationKey)
        let guardado = (defaults.string(forKey: "memoryBaseURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard unreachableMemoryHostsOnPhone.contains(guardado) else { return }
        defaults.set("http://100.91.174.81:8081", forKey: "memoryBaseURL")
        #endif
    }

    /// Lee la dirección del servicio de memoria y su token de lo GUARDADO, **sin escribir
    /// nada**. `nil` cuando el campo de la URL está vacío o no es una URL http(s) con host:
    /// en los dos casos la respuesta es quedarse sin cliente de memoria, que es visible,
    /// en vez de fabricar uno contra un servidor que nadie pidió.
    ///
    /// El token vacío **sí** devuelve cliente: el servidor contesta 401 y eso se ve. Meterle
    /// un token por omisión a espaldas del usuario es lo que hacía que el placeholder débil
    /// reapareciera solo cada vez que alguien intentaba quitarlo.
    ///
    /// LA URL SALE DE `UserDefaults`; EL TOKEN, DEL LLAVERO. No es asimetría por descuido: la
    /// dirección del i3 no es un secreto y el token lo es todo —con él se lee y se escribe la
    /// memoria personal entera del usuario—. Ver `TokenDeMemoria`. Migrar es trabajo de
    /// `migrar`, no de esta función: **leer no escribe**, que es la regla que cerró la avería del
    /// campo que se volvía a escribir solo.
    static func memorySettings(defaults: UserDefaults = .standard,
                               almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido)
    -> (url: URL, token: String)? {
        let raw = (defaults.string(forKey: "memoryBaseURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host != nil else { return nil }
        return (url, TokenDeMemoria.leer(almacen: almacen))
    }

    /// Construye (o reconstruye) el `MemoryClient` desde `UserDefaults`.
    ///
    /// Claves:
    /// - `memoryBaseURL` (String de `UserDefaults`; vacía o inválida → sin memoria)
    /// - el token del servicio de memoria, **del llavero** (`TokenDeMemoria`, no de
    ///   `UserDefaults`; vacío → se usa vacío y el servidor da 401)
    ///
    /// Espeja el cliente en `MemoryToolbox.shared.memory` para que las herramientas de
    /// memoria (Save / Forget / Reflect / LoadMessages) alcancen la misma instancia.
    func ensureMemory() {
        guard settings.memoryEnabled ?? true else {
            self.memory = nil
            MemoryToolbox.shared.memory = nil
            MemoryToolbox.shared.reflectionRequest = nil
            return
        }
        guard let (baseURL, token) = Self.memorySettings(almacen: almacenDeSecretos) else {
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
        // Lo que antes solo vivía en el contenedor de la app (notas, atajos, alias,
        // lugares, alarmas) vive ahora en el servicio de memoria. En cuanto hay cliente,
        // se sube lo pendiente y se trae lo que haya en el servidor.
        //
        // `memoryBaseURL` y `memoryBearerToken` NO se espejan, y no es un olvido: son la
        // dirección del servidor y su contraseña. Guardarlos en el servidor sería un
        // círculo — sin ellos no hay forma de llegar al servidor para leerlos. Lo mismo
        // vale para cualquier ajuste que describa solo a este aparato (el host del modelo
        // local, el interruptor de la palabra de activación): son configuración del
        // dispositivo, no datos del usuario.
        // La clave es la dirección del servidor: si el usuario la cambia en Ajustes, se
        // vuelve a hidratar desde el servidor nuevo en vez de seguir con lo del viejo.
        MirrorSyncer.shared.start(serverKey: baseURL.absoluteString)
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

    /// Build (or rebuild) the voice client from `UserDefaults` (las URLs) y del llavero (el
    /// token). Reuses the memory bearer token (the i3 voice service shares it, así que es el
    /// MISMO secreto y sale del mismo sitio: ver `TokenDeMemoria`). `voiceBaseURL` (optional)
    /// overrides; empty → derive from `memoryBaseURL` on port 8082.
    func ensureVoice() {
        guard let (baseURL, token) = Self.voiceSettings(almacen: almacenDeSecretos) else { return }
        voice.configure(baseURL: baseURL, token: token)
    }

    /// La dirección del servicio de voz y su token, de lo GUARDADO y **sin escribir nada**.
    ///
    /// Es `static` y toma sus dos fuentes por parámetro por el mismo motivo que `memorySettings`:
    /// así la decisión «de dónde sale el token» se puede medir sin construir un `HarnessModel`
    /// (que en el host de las pruebas observa notificaciones de la app) y **sin tocar la entrada
    /// de producción del llavero**. El token es el del servicio de memoria: el i3 lo comparte
    /// entre memoria y voz, así que es el mismo secreto y sale del mismo sitio (`TokenDeMemoria`).
    nonisolated static func voiceSettings(defaults: UserDefaults = .standard,
                                          almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido)
    -> (url: URL, token: String)? {
        let explicit = defaults.string(forKey: "voiceBaseURL") ?? ""
        let memory = defaults.string(forKey: "memoryBaseURL") ?? "http://localhost:8081"
        guard let baseURL = URL(string: voiceURLString(explicit: explicit, memory: memory)) else { return nil }
        return (baseURL, TokenDeMemoria.leer(almacen: almacen))
    }

    /// Push the consolidation provider config to the i3 (key included, over the authed channel).
    func pushConsolidationConfig() {
        ensureMemory()
        guard let client = memory else { return }
        let kindRaw = UserDefaults.standard.string(forKey: SettingsKeys.consolidationProvider) ?? ModelProvider.Kind.defaultKind.rawValue
        let kind = ModelProvider.Kind(rawValue: kindRaw) ?? .defaultKind
        let model = UserDefaults.standard.string(forKey: SettingsKeys.consolidationModel)
        let provider = ModelProvider(kind: kind, model: model,
                                     apiKey: kind.isLocalMLX ? nil
                                        : ClaveDeProveedor.leer(proveedor: kind.rawValue,
                                                                almacen: almacenDeSecretos))
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

    /// Solo pruebas: sustituye `runAgentTurn` para probar `startAgentTurn` sin modelo ni red.
    @ObservationIgnored var turnRunnerOverride: (@MainActor (String) async -> Void)?

    public func startAgentTurn(_ prompt: String) {
        // Hablarle al agente es actividad: reinicia el reloj de inactividad del panel vivo.
        browserPanels.noteUserActivity()
        currentTurnTask?.cancel()
        // Determinista: el panel del turno anterior se cierra por orden, no por la carrera
        // con la cancelación (si perdiera, el turno nuevo se quedaría sin panel).
        // Interrumpir para decir algo es lo mismo que detener: el turno que se abandona no acabó
        // por su pie, así que su panel se congela aunque el navegador siga abierto. Esto NO toca
        // el panel vivo de un turno anterior (con `activeID == nil` es un no-op): que el usuario
        // hable de otra cosa no debe cortarle el video. Por eso aquí NO va `retireLivePanel()`.
        browserPanels.endTurn(survive: false, porque: "el usuario mandó otro mensaje")
        cierraFormularioAbierto()
        // Hasta que el turno nuevo se declare, ninguno es vigente: el abandonado ya no puede abrir
        // un formulario que ocupe el hueco del siguiente.
        formularios.turnoVigente = nil
        currentTurnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let runner = self.turnRunnerOverride { await runner(prompt) } else { await self.runAgentTurn(prompt) }
        }
    }

    public func cancelAgentTurn() {
        currentTurnTask?.cancel()
        currentTurnTask = nil
        // Detener es una orden explícita: congela aunque el navegador siga abierto.
        browserPanels.endTurn(survive: false, porque: "el usuario pulsó detener")
        cierraFormularioAbierto()
        formularios.turnoVigente = nil
        agentRunning = false
        agentLog.append(ChatLogEntry(role: "system", text: "⏹ Generación detenida"))
    }

    /// Flujo del relé del i3 para un panel nuevo, o `nil` sin `browserBaseURL` válida (sin
    /// dependencias de plataforma: sirve igual en macOS y en iOS). `BrowserRelayClient` es un actor y su `events()`
    /// es `async`, así que se puentea: un `Task` reenvía los eventos y, al terminar el flujo
    /// (cierre del panel), se cancela y se llama a `stop()` para no dejar el socket abierto.
    ///
    /// `abreElSocket` se reenvía tal cual a `BrowserRelayClient`, que ya tenía ese costurón: con
    /// `nil` (producción) abre el socket de verdad. Pasarlo por aquí es lo que hace OBSERVABLE
    /// que el token con el que se firma el handshake sea el del llavero y no el que quedara en
    /// claro en `UserDefaults`; sin él esa propiedad solo se podría leer, no medir.
    static func makeRelayStream(defaults: UserDefaults = .standard,
                                almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido,
                                abreElSocket: (@Sendable (URL, String) -> SocketDelVisor)? = nil)
        -> AsyncStream<BrowserRelayEvent>? {
        let raw = (defaults.string(forKey: SettingsKeys.browserBaseURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host != nil else { return nil }
        // Del LLAVERO, no de `UserDefaults`: este token autoriza el visor y al agente, y lo que vive
        // en `UserDefaults` se respalda, se sincroniza y se lee sin desbloquear nada. La
        // migración del sitio viejo NO se hace aquí (ver `TokenDeConducir.leer`): leer no escribe.
        let token = TokenDeConducir.leer(almacen: almacen)
        let client = BrowserRelayClient(baseURL: url, bearerToken: token,
                                        abreElSocket: abreElSocket)
        let (stream, continuation) = AsyncStream<BrowserRelayEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let forwarder = Task {
            for await event in await client.events() {
                continuation.yield(event)
            }
            continuation.finish()
        }
        continuation.onTermination = { razon in
            // El único momento en que la app suelta su visor. Saber si llegó por `.cancelled`
            // (alguien retiró el panel) o por `.finished` (el cliente del relé se rindió o el
            // relé cerró) distingue las dos familias de causa sin tener que adivinarlo después.
            PanelLog.note("el flujo del relé termina (\(razon)): se cierra el socket del visor")
            forwarder.cancel()
            Task { await client.stop() }
        }
        return stream
    }

    /// Registra en `registry` las nueve herramientas de navegador (`read_webpage` y `browser_*`).
    /// Comparten una única instancia de `AgentBrowserService`, y por tanto la misma sesión de
    /// `agent-browser`. Es la única ruta de registro: `runAgentTurn` y `browserToolRegistry()` la usan.
    /// `userAskedToClose` viaja hasta `BrowserCloseTool`: es el único camino por el que el
    /// navegador se puede cerrar. Por defecto `false`, así que un registro que no diga nada
    /// (las pruebas, `browserToolRegistry()`) no puede cerrar nada.
    ///
    /// `almacen` existe para que una PRUEBA no tenga que leer el token real del usuario del
    /// llavero: este método es la única ruta hasta `browserInvoker`, y cinco pruebas lo alcanzan
    /// por `browserToolRegistry()`.
    ///
    /// `formBroker` y `boveda` son opcionales y las cuatro herramientas de formularios/secretos
    /// (`present_form`, `list_secrets`, `forget_secret`, `browser_fill_secret`) solo se registran si
    /// llegan AMBOS: comparten el `AgentBrowserService` de abajo (la atadura al origen lee la página
    /// abierta por él) y sin bóveda o sin dónde mostrar la tarjeta ninguna tiene sentido.
    static func registerBrowserTools(into registry: ToolRegistry, userAskedToClose: Bool = false,
                                     almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido,
                                     formBroker: FormBroker? = nil, boveda: SecretVault? = nil,
                                     turno: UUID? = nil) {
        let service = AgentBrowserService(invoker: browserInvoker(almacen: almacen))
        registry.register(ReadWebpageTool(service: service))
        registry.register(BrowserOpenTool(service: service))
        registry.register(BrowserSnapshotTool(service: service))
        registry.register(BrowserClickTool(service: service))
        registry.register(BrowserFillTool(service: service))
        registry.register(BrowserPressTool(service: service))
        registry.register(BrowserWaitTool(service: service))
        registry.register(BrowserGetTool(service: service))
        registry.register(BrowserCloseTool(service: service, userAskedToClose: userAskedToClose))
        if let formBroker, let boveda {
            registry.register(PresentFormTool(broker: formBroker, vault: boveda, service: service, turno: turno))
            registry.register(ListSecretsTool(vault: boveda))
            registry.register(ForgetSecretTool(vault: boveda))
            registry.register(BrowserFillSecretTool(service: service, vault: boveda))
        }
    }

    /// Con `browserBaseURL` configurada el navegador es el del i3 (HTTP); sin ella, en macOS el
    /// `agent-browser` local de siempre y en iOS ninguno (hay que configurarla en Ajustes). Se lee en cada registro, así que Ajustes surte efecto en el turno siguiente.
    static func browserInvoker(defaults: UserDefaults = .standard,
                               session: URLSession = .shared,
                               almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido)
        -> any AgentBrowserInvoking {
        let raw = (defaults.string(forKey: SettingsKeys.browserBaseURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Solo el campo VACÍO es "sin i3" (comportamiento de siempre). Una URL escrita pero
        // inválida no debe caer al navegador local a espaldas del usuario: ver `InvalidBrowserURLInvoker`.
        if raw.isEmpty {
            #if os(macOS)
            // El agente solo llama a `browser_open`/`browser_close`; la app abre y cierra el Chrome real.
            return ProcessAgentBrowserInvoker(navegadorReal: ChromeRealDeLaMac())
            #else
            // iOS no tiene navegador local: el campo vacío manda a Ajustes, no a instalar nada.
            return UnconfiguredBrowserInvoker()
            #endif
        }
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host != nil else {
            return InvalidBrowserURLInvoker()
        }
        // Token vacío con URL válida: se usa el HTTP igualmente. El servicio responderá 401 y
        // el invocador lo traduce a "el i3 rechazó el token", que es accionable; desviar al
        // navegador local sería peor (ver arriba).
        // Del LLAVERO, no de `UserDefaults` (ver `TokenDeConducir`). Es el SEGUNDO de los dos
        // lectores del token, y no hay un tercero: medido con un grep de la clave sobre todo el
        // árbol de la app, los únicos sitios que la nombran son `TokenDeConducir` y sus pruebas.
        let token = TokenDeConducir.leer(almacen: almacen)
        return HTTPAgentBrowserInvoker(baseURL: url, bearerToken: token, session: session)
    }

    /// Registro con solo las herramientas de navegador, para poder probarlas sin arrancar un turno.
    ///
    /// Incluye las herramientas de formularios con un broker y una bóveda sobre el MISMO `almacen`
    /// inyectado, igual que producción: así el registro de prueba es el de verdad y no toca el Keychain.
    static func browserToolRegistry(almacen: any AlmacenDeSecretos = LlaveroDelSistema.compartido)
        -> ToolRegistry {
        let registry = ToolRegistry()
        registerBrowserTools(into: registry, almacen: almacen,
                             formBroker: FormBroker(), boveda: SecretVault(almacen: almacen))
        return registry
    }

    /// Quita del texto del asistente el aviso que escribió la APP, si lo lleva pegado al final.
    ///
    /// LO QUE SE MUESTRA Y LO QUE SE ARCHIVA NO SON LA MISMA COSA, Y ESTO ES LO QUE LOS SEPARA.
    /// La línea de estado del navegador (`Agent.lineaDeEstadoDelNavegador`) viaja concatenada al
    /// `text` del `.completed` porque la interfaz tiene que pintarla; pero ese mismo texto es el
    /// que `runAgentTurn` persiste en el servicio de memoria como «lo que dijo el asistente», y
    /// de ahí pasa a los resúmenes, a la consolidación y a `reflect`. Sin esto, un aviso de la
    /// app —«la última acción sobre la página devolvió `refused`»— acaba guardado como una frase
    /// del asistente y puede terminar convertido en un «insight» sobre el usuario: memoria a
    /// largo plazo contaminada con diagnóstico de la app.
    ///
    /// Es un SUFIJO DECLARADO, no una búsqueda: el aviso llega aparte en
    /// `GenerationResult.appNotice` y aquí solo se comprueba que de verdad esté al final. Si no
    /// está, no se quita nada — el texto del modelo no se toca nunca por si acaso.
    nonisolated static func sinElAvisoDeLaApp(_ texto: String, aviso: String?) -> String {
        guard let aviso, !aviso.isEmpty, texto.hasSuffix(aviso) else { return texto }
        return String(texto.dropLast(aviso.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Consume los eventos de un turno: pinta el registro del chat y gobierna el panel del
    /// navegador. Separado de `runAgentTurn` para poder probar el cableado sin modelo ni red.
    /// Devuelve el texto final del asistente, para la transcripción.
    func consumeAgentEvents<S: AsyncSequence>(_ events: S) async -> String where S.Element == AgentEvent {
        var answer = ""
        var finalAssistantText = ""
        var currentThought = ""
        var activeGemmaIdx: Int? = nil

        do {
            for try await event in events {
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
                    finalAssistantText = answer
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
                    agentLog.append(ChatLogEntry(role: "tool", text: "", toolName: n))
                    if let id = browserPanels.openIfNeeded(toolName: n) {
                        agentLog.append(ChatLogEntry(role: "browserPanel", text: "", panelID: id))
                    }
                    activeGemmaIdx = nil
                    currentThought = ""
                    answer = ""
                    finalAssistantText = ""
                case .toolCallFinished(let n, let r):
                    ToolLogRow.closeRow(in: &agentLog, toolName: n, result: r)
                    browserPanels.toolFinished(toolName: n, result: r)
                    activeGemmaIdx = nil
                    currentThought = ""
                    answer = ""
                    finalAssistantText = ""
                case .completed(let res):
                    let chosen = !res.text.isEmpty ? res.text : answer
                    let stripped = GemmaToolCallParser.strip(chosen)
                    // LO QUE SE MUESTRA LLEVA EL AVISO DE LA APP; LO QUE SE ARCHIVA, NO. Ver
                    // `sinElAvisoDeLaApp`: el valor que devuelve este bucle es lo que se
                    // persiste en el servicio de memoria como texto del asistente, y de ahi
                    // pasa a la consolidacion y a `reflect`.
                    finalAssistantText = Self.sinElAvisoDeLaApp(stripped, aviso: res.appNotice)
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
            browserPanels.endTurn(survive: false, porque: "el turno fue cancelado")
            if let idx = activeGemmaIdx {
                let current = agentLog[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
                if current.isEmpty && (agentLog[idx].thought?.isEmpty ?? true) {
                    agentLog.remove(at: idx)
                }
            }
        } catch {
            browserPanels.endTurn(survive: false, porque: "el turno falló: \(type(of: error))")
            agentLog.append(ChatLogEntry(role: "error", text: "\(error)"))
        }
        // Salida normal del bucle: congela el panel (no-op si ya lo cerró un catch).
        browserPanels.endTurn()
        return finalAssistantText
    }

    /// Tras más de 30 min de silencio empieza un episodio nuevo. Con él se retira también el panel
    /// de navegador que siguiera vivo: es una conversación distinta y nadie lo está mirando.
    func startNewChatIfIdle(now: Double) {
        guard ChatSession.shouldStartNewChat(lastActivity: lastTurnEndedAt, now: now) else { return }
        threadId = UUID().uuidString   // new episode → new chat_id; server restarts seq at 1
        UserDefaults.standard.set(threadId, forKey: "activeThreadId")
        turnIndex = 0
        browserPanels.retireLivePanel(porque: "más de 30 min en silencio: conversación nueva")
    }

    /// El `Agent` de producción. Separado de `runAgentTurn` para poder PROBAR que recibe la bóveda:
    /// sin ella el redactor (`SecretRedactor`) es código muerto y un secreto podría llegar al
    /// registro, al transcript o al modelo en el resultado de una herramienta.
    func construyeAgent(registry: ToolRegistry, recallTail: String, wakeContext: String) -> Agent {
        Agent(runtime: runtime, registry: registry, recallTail: recallTail, wakeContext: wakeContext,
              bóveda: boveda)
    }

    // MARK: - Formularios

    /// Observa `formularios.pendiente`: cada vez que cambia, sincroniza el chat. `onChange` salta
    /// ANTES del cambio y una sola vez, así que se salta al siguiente ciclo del hilo principal para
    /// leer el valor nuevo y se vuelve a armar.
    private func observaFormularios() {
        withObservationTracking {
            _ = self.formularios.pendiente
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.sincronizaFormularios()
                self?.observaFormularios()
            }
        }
    }

    /// Pone el chat al día con el broker: una sola tarjeta por formulario (se identifica por su id),
    /// y toda tarjeta que seguía «pendiente» sin ser ya el formulario abierto pasa a «cancelado»
    /// (plazo vencido, fin de turno o cancelación del llamador; enviar y cancelar desde la tarjeta
    /// ya la marcan ellos mismos antes de resolver).
    func sincronizaFormularios() {
        let abierto = formularios.pendiente
        for i in agentLog.indices where agentLog[i].role == "form"
            && agentLog[i].formEstado == "pendiente" && agentLog[i].formID != abierto?.id {
            agentLog[i].formEstado = "cancelado"
        }
        if let abierto, !agentLog.contains(where: { $0.formID == abierto.id }) {
            agentLog.append(ChatLogEntry(role: "form", text: abierto.spec.title,
                                         formID: abierto.id, formEstado: "pendiente"))
        }
    }

    /// Detener / mensaje nuevo: lo que esté abierto se cierra como cancelado (es del turno que se
    /// abandona).
    func cierraFormularioAbierto() {
        formularios.cancelaTodo()
        sincronizaFormularios()
    }

    /// Fin de UN turno: solo se cierra el formulario que pidió ese turno. Un turno viejo cancelado
    /// que termina tarde no debe cerrar el del turno nuevo.
    func cierraFormularioAbierto(delTurno turno: UUID) {
        formularios.cancela(turno: turno)
        if formularios.turnoVigente == turno { formularios.turnoVigente = nil }
        sincronizaFormularios()
    }

    /// Lo que la tarjeta de esta fila necesita para dibujarse. Abierta: el formulario real. Ya
    /// resuelta: solo el título, sin campos y por tanto sin posibilidad de mostrar valores.
    func especificacionDeFormulario(_ entry: ChatLogEntry) -> FormSpec {
        if entry.formEstado == "pendiente", let p = formularios.pendiente, p.id == entry.formID {
            return p.spec
        }
        return FormSpec(title: entry.text, description: nil, submitLabel: nil, fields: [])
    }

    /// «Se guardará para: <host>» mientras la tarjeta de esta fila está abierta y pide secretos;
    /// `nil` en otro caso. Ver `FormBroker.PendingForm.avisoDeAtadura`.
    func avisoDeFormulario(_ entry: ChatLogEntry) -> String? {
        guard entry.formEstado == "pendiente", let p = formularios.pendiente, p.id == entry.formID else { return nil }
        return p.avisoDeAtadura
    }

    func enviaFormulario(_ entry: ChatLogEntry, valores: [String: String]) {
        guard let id = entry.formID, let i = agentLog.firstIndex(where: { $0.id == entry.id }),
              agentLog[i].formEstado == "pendiente" else { return }
        // Primero la tarjeta, luego el broker: al resolver, el observador no debe ver una tarjeta
        // «pendiente» huérfana y marcarla como cancelada.
        agentLog[i].formEstado = "enviado"
        formularios.envia(id: id, valores: valores)
    }

    func cancelaFormulario(_ entry: ChatLogEntry) {
        guard let id = entry.formID, let i = agentLog.firstIndex(where: { $0.id == entry.id }),
              agentLog[i].formEstado == "pendiente" else { return }
        agentLog[i].formEstado = "cancelado"
        formularios.cancela(id: id)
    }

    public func runAgentTurn(_ prompt: String) async {
        let provider = Self.chatProvider(keyLookup: Self.clavesDelAlmacen(almacenDeSecretos))
        if !(self.runtime is LlamaCppRuntime && provider.kind == .onDevice) {
            self.runtime = RuntimeFactory.make(provider)
        }
        surfaceProactive()
        // Identidad de este turno: el broker solo deja abrir formularios al turno vigente, y el
        // cierre del final solo toca el formulario que pidió este turno.
        let turno = UUID()
        formularios.turnoVigente = turno
        agentRunning = true; defer { agentRunning = false }
        agentLog.append(ChatLogEntry(role: "you", text: prompt))
        ensureMemory()
        let client = memory
        let registry = ToolRegistry()
        registry.register(CurrentTimeTool())
        if client != nil {
            registry.register(ForgetTool()); registry.register(ReflectTool()); registry.register(LoadMessagesTool())
            registry.register(SaveMemoryTool()); registry.register(SearchMemoryTool())
            registry.register(CheckScheduleTool()); registry.register(CreateEventTool())
            registry.register(QueryScheduleTool()); registry.register(CancelEventsTool())
            registry.register(UpdateEventTool())
            registry.register(CreateTaskTool()); registry.register(ListTasksTool()); registry.register(DeleteTaskTool())
            registry.register(ListTopicsTool()); registry.register(RecallByTopicTool()); registry.register(WhyTool())
            registry.register(SetRoutineTool()); registry.register(ListRoutinesTool())
        }
        registry.register(ListAvailableShiftsTool())
        registry.register(AddShiftTool())
        registry.register(DropShiftTool())
        registry.register(PlayMusicTool())
        registry.register(ListMusicPlaylistsTool())
        registry.register(RunShortcutTool())
        registry.register(ListShortcutsTool())
        registry.register(RememberShortcutTool())
        registry.register(InstallShortcutTool())
        registry.register(ListInstallableShortcutsTool())
        // Compartir es transversal: hoy conoce las notas de Gemma; las tareas,
        // memorias, insights, mensajes y chats se añaden como fuentes nuevas.
        registry.register(ShareTool())
        // CRUD completo de las notas de Gemma: crear, leer, buscar, editar, borrar.
        registry.register(CreateNoteTool())
        registry.register(SearchNotesTool())
        registry.register(ReadNoteTool())
        registry.register(UpdateNoteTool())
        registry.register(DeleteNoteTool())
        registry.register(GetDeviceStatusTool())
        registry.register(OpenAppTool())
        registry.register(WebSearchTool())
        Self.registerBrowserTools(into: registry,
                                  userAskedToClose: BrowserCloseIntent.userAskedToClose(prompt),
                                  formBroker: formularios, boveda: boveda, turno: turno)
        registry.register(GetWeatherTool())
        registry.register(GetForecastTool())
        registry.register(CreateAlarmTool())
        registry.register(ListAlarmsTool())
        registry.register(CancelAlarmTool())
        registry.register(ListRemindersTool())
        registry.register(UpdateReminderTool())
        registry.register(DeleteReminderTool())
        registry.register(ControlMusicTool())
        registry.register(UpdateAlarmTool())
        registry.register(ForgetShortcutTool())
        registry.register(ListContactAliasesTool())
        registry.register(ForgetContactAliasTool())
        registry.register(UpdateTaskTool())
        registry.register(DeleteRoutineTool())
        registry.register(RenamePlaceTool())
        registry.register(CreateTimerTool())
        registry.register(SearchContactsTool())
        registry.register(MakePhoneCallTool())
        registry.register(DraftMessageTool())
        registry.register(SendMessageTool())
        registry.register(CreateCalendarEventTool())
        registry.register(ListCalendarEventsTool())
        registry.register(UpdateCalendarEventTool())
        registry.register(DeleteCalendarEventTool())
        registry.register(CurrentLocationTool())
        registry.register(OpenNavigationTool())
        registry.register(SavePlaceTool())
        registry.register(ListPlacesTool())
        registry.register(DeletePlaceTool())
        registry.register(CurrentActivityTool())
        registry.register(RememberContactAliasTool())
        registry.register(CreateReminderTool())
        let now = Date().timeIntervalSince1970
        let isWake = (lastTurnEndedAt == 0) || (now - lastTurnEndedAt > Self.wakeGapSeconds)
        _ = isWake // followUps / focus are service-driven now (no per-turn HTTP for them in M3a)
        startNewChatIfIdle(now: now)
        let wakeContext: String = {
            guard lastTurnEndedAt > 0 else {
                return "Last interaction with user: none recorded (first interaction or new session)."
            }
            let elapsedSec = now - lastTurnEndedAt
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
        // Build recallTail via HTTP. recall() returns .empty on transport failure (see
        // MemoryClient.recall), so an offline service degrades to "no recall" instead of crashing.
        var recallTail = ""
        if let client {
            let bundle = (try? await client.recall(query: prompt, threadId: threadId)) ?? .empty
            recallTail = bundle.injectionBlock()
        }
        // Fetch the short-term conversation window over HTTP. Falls back to empty on failure.
        let history: [ChatMessage] = await {
            guard let client else { return [] }
            let turns = (try? await client.conversationWindow(threadId: threadId)) ?? []
            return turns.map { ChatMessage(role: $0.role == "assistant" ? .assistant : .user, content: $0.text) }
        }()
        let agent = construyeAgent(registry: registry, recallTail: recallTail, wakeContext: wakeContext)
        let finalAssistantText = await consumeAgentEvents(agent.run(prompt: prompt, options: makeGenerationOptions(history: history)))
        // Un formulario que siguiera abierto al acabar el turno ya no tiene a nadie esperándolo.
        // Solo el de ESTE turno: si este turno fue abandonado y acaba tarde, el formulario abierto
        // puede ser ya del turno nuevo.
        cierraFormularioAbierto(delTurno: turno)
        // Append both turns to the transcript over HTTP. Failures are silent (service-down
        // shouldn't crash a successful turn — the user can see Gemma's reply).
        if let client {
            try? await client.appendTranscript(threadId: threadId, role: "user", text: prompt, turnIndex: turnIndex)
            let cleanForTranscript = GemmaToolCallParser.strip(finalAssistantText)
            if !cleanForTranscript.isEmpty {
                try? await client.appendTranscript(threadId: threadId, role: "assistant", text: cleanForTranscript, turnIndex: turnIndex)
            }
            turnIndex += 1
            // Signal the service to arm its consolidation timers. Fire-and-forget.
            try? await client.consolidationTurnEnd(threadId: threadId)
        }
        let finishedNow = Date().timeIntervalSince1970
        lastTurnEndedAt = finishedNow
        UserDefaults.standard.set(finishedNow, forKey: "lastTurnEndedAt")
    }
}
