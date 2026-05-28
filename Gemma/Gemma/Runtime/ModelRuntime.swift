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

public struct ModelLoadOptions: Sendable {
    public var modelPath: URL
    public var drafterPath: URL?
    public var useMmap: Bool
    public var contextLength: Int

    public init(
        modelPath: URL,
        drafterPath: URL? = nil,
        useMmap: Bool = true,
        contextLength: Int = 4096
    ) {
        self.modelPath = modelPath
        self.drafterPath = drafterPath
        self.useMmap = useMmap
        self.contextLength = contextLength
    }
}

public struct GenerationOptions: Sendable {
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double
    public var useSpeculativeDecoding: Bool

    public init(
        maxTokens: Int = 256,
        temperature: Double = 0.7,
        topP: Double = 0.9,
        useSpeculativeDecoding: Bool = false
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
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

// MARK: - Protocol

public protocol ModelRuntime: Sendable {
    /// Stable identifier used in reports (e.g. "dummy", "litertlm", "llamacpp").
    var identifier: String { get }

    func isLoaded() async -> Bool
    func load(options: ModelLoadOptions) async throws
    func unload() async

    /// Streams tokens via `onToken` as they are produced; returns the final result on completion.
    func generate(
        prompt: String,
        image: UIImage?,
        options: GenerationOptions,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> GenerationResult

    func currentMetrics() async -> RuntimeMetrics?
}
