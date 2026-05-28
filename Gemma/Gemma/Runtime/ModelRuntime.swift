import Foundation
import UIKit

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

/// Compute backend for a model runtime. Package-agnostic so DummyRuntime and the
/// runtime types don't depend on LiteRTLM; LiteRTLMRuntime maps it to LiteRTLM.Backend.
public enum ComputeBackend: Sendable, Equatable {
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
        backend: ComputeBackend = .gpu
    ) {
        self.modelPath = modelPath
        self.drafterPath = drafterPath
        self.useMmap = useMmap
        self.contextLength = contextLength
        self.systemPrompt = systemPrompt
        self.enableThinking = enableThinking
        self.useSpeculativeDecoding = useSpeculativeDecoding
        self.backend = backend
    }
}

public struct GenerationOptions: Sendable {
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    /// Legacy per-call MTP request. Plan 3a moves the authoritative MTP toggle to ModelLoadOptions.
    /// Kept for backward source compatibility; runtimes may ignore it.
    public var useSpeculativeDecoding: Bool

    public init(
        maxTokens: Int = 4000,
        temperature: Double = 1.0,
        topP: Double = 0.95,
        topK: Int = 64,
        useSpeculativeDecoding: Bool = false
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.useSpeculativeDecoding = useSpeculativeDecoding
    }
}

public struct GenerationResult: Sendable {
    public let text: String
    public let metrics: RuntimeMetrics

    public init(text: String, metrics: RuntimeMetrics) {
        self.text = text
        self.metrics = metrics
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
        image: UIImage?,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<GenerationEvent, Error>

    func currentMetrics() async -> RuntimeMetrics?
}
