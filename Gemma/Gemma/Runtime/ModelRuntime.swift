import Foundation

/// One message in a chat history sent to the model (short-term context, M2d-1).
public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Codable { case system, user, assistant }
    public var role: Role
    public var content: String
    public init(role: Role, content: String) { self.role = role; self.content = content }
}

// MARK: - Value types

public struct RuntimeMetrics: Sendable, Codable, Equatable {
    public var tokensGenerated: Int
    public var elapsedSeconds: Double
    public var timeToFirstTokenSeconds: Double
    public var peakResidentMemoryBytes: UInt64
    public var draftAcceptanceRate: Double?

    public init(
        tokensGenerated: Int,
        elapsedSeconds: Double,
        timeToFirstTokenSeconds: Double,
        peakResidentMemoryBytes: UInt64,
        draftAcceptanceRate: Double?
    ) {
        self.tokensGenerated = tokensGenerated
        self.elapsedSeconds = elapsedSeconds
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.draftAcceptanceRate = draftAcceptanceRate
    }

    public var tokensPerSecond: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(tokensGenerated) / elapsedSeconds
    }
}

/// Compute backend for a model runtime. Package-agnostic so the runtime types
/// stay decoupled from any specific backend.
public enum ComputeBackend: Sendable, Equatable, Codable {
    case cpu
    case gpu
}

public struct ModelLoadOptions: Sendable {
    public var modelPath: URL
    public var drafterPath: URL?
    public var useMmap: Bool
    public var contextLength: Int
    public var systemPrompt: String?
    public var enableThinking: Bool
    public var useSpeculativeDecoding: Bool
    public var supportsImage: Bool
    public var supportsAudio: Bool
    public var backend: ComputeBackend

    public init(
        modelPath: URL,
        drafterPath: URL? = nil,
        useMmap: Bool = true,
        // KV-cache size (maps to EngineConfig.maxNumTokens = sum of input+output
        // tokens). 4096 matches the Edge Gallery recipe for Gemma 4; 32K overflows
        // the on-device GPU Metal texture budget and fails engine creation.
        contextLength: Int = 4096,
        systemPrompt: String? = nil,
        enableThinking: Bool = false,
        useSpeculativeDecoding: Bool = false,
        supportsImage: Bool = false,
        supportsAudio: Bool = false,
        backend: ComputeBackend = .gpu
    ) {
        self.modelPath = modelPath
        self.drafterPath = drafterPath
        self.useMmap = useMmap
        self.contextLength = contextLength
        self.systemPrompt = systemPrompt
        self.enableThinking = enableThinking
        self.useSpeculativeDecoding = useSpeculativeDecoding
        self.supportsImage = supportsImage
        self.supportsAudio = supportsAudio
        self.backend = backend
    }
}

public struct GenerationOptions: Sendable {
    public var maxTokens: Int
    /// Explicit total window for this request, including its output reservation.
    public var contextTokens: Int?
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    /// Legacy per-call MTP request. Plan 3a moves the authoritative MTP toggle to ModelLoadOptions.
    /// Kept for backward source compatibility; runtimes may ignore it.
    public var useSpeculativeDecoding: Bool
    /// Optional system prompt applied when the conversation is (re)created for this
    /// generation. nil = no system message.
    public var systemPrompt: String?
    /// Prior conversation turns (short-term context) prepended to the request, oldest first.
    /// Empty = single-shot (legacy behavior).
    public var history: [ChatMessage]

    public init(
        maxTokens: Int = 4000,
        contextTokens: Int? = nil,
        temperature: Double = 1.0,
        topP: Double = 0.95,
        topK: Int = 64,
        useSpeculativeDecoding: Bool = false,
        systemPrompt: String? = nil,
        history: [ChatMessage] = []
    ) {
        self.maxTokens = maxTokens
        self.contextTokens = contextTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.useSpeculativeDecoding = useSpeculativeDecoding
        self.systemPrompt = systemPrompt
        self.history = history
    }
}

public struct GenerationResult: Sendable {
    public let text: String
    public let metrics: RuntimeMetrics
    /// El aviso que escribió la APP —no el modelo— y que viaja pegado al final de `text`.
    /// `nil` cuando el turno no lleva ninguno, que es el caso de la inmensa mayoría.
    ///
    /// EXISTE PARA SEPARAR LO QUE SE MUESTRA DE LO QUE SE ARCHIVA, y el defecto que cierra es
    /// de los que no se ven hasta semanas después. La línea de estado del navegador
    /// (`Agent.lineaDeEstadoDelNavegador`) se concatena a `text` para que la interfaz la pinte,
    /// y `text` es exactamente lo que el arnés persiste en el servicio de memoria como «lo que
    /// dijo el asistente» (`HarnessModel.consumeAgentEvents` → `appendTranscript`). O sea que
    /// un aviso de la app —«la última acción sobre la página devolvió `refused`»— acababa
    /// guardado como una frase del asistente, pasaba por los resúmenes, por la consolidación y
    /// por `reflect`, y podía terminar convertido en un «insight» sobre el usuario. Es
    /// contaminación de la memoria a largo plazo con diagnóstico de la app.
    ///
    /// NO ES UN SEGUNDO CANAL DE TEXTO: es una DECLARACIÓN sobre el que ya hay. Dice «este
    /// sufijo exacto de `text` lo escribí yo, la app», y quien archiva lo quita
    /// (`HarnessModel.sinElAvisoDeLaApp`) mientras quien muestra lo deja. Si el sufijo no está,
    /// no se quita nada: el valor es una pista, no una orden de recortar.
    public let appNotice: String?

    public init(text: String, metrics: RuntimeMetrics, appNotice: String? = nil) {
        self.text = text
        self.metrics = metrics
        self.appNotice = appNotice
    }
}

public enum RuntimeError: Error, Sendable, Equatable {
    case modelNotFound(URL)
    case loadFailed(String)
    case notLoaded
    case generationFailed(String)
}

// MARK: - Streaming events

public enum GenerationEvent: Sendable {
    /// A single streamed piece of text.
    case token(String)
    /// A single streamed piece of internal reasoning (chain-of-thought).
    case thought(String)
    /// A tool the model decided to call is about to run. `args` is a JSON string (may be "{}").
    case toolCallStarted(name: String, args: String)
    /// A tool finished; `result` is its stringified return (or an "error: …" message).
    case toolCallFinished(name: String, result: String)
    /// Final result with metrics; the last event in the stream.
    case completed(GenerationResult)
}

// MARK: - Protocol

public protocol ModelRuntime: Sendable {
    /// Stable identifier used in reports (e.g. "dummy", "litertlm", "llamacpp").
    var identifier: String { get }

    func isLoaded() async -> Bool
    func load(options: ModelLoadOptions) async throws
    func unload() async

    /// Streams generation events. Last event is always `.completed(_)`. Errors propagate through the stream.
    func generate(
        prompt: String,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<GenerationEvent, Error>

    func currentMetrics() async -> RuntimeMetrics?
}
