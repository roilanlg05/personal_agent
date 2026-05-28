import Foundation

/// All user-tunable generation/engine parameters. Persisted by SettingsStore.
public struct GenerationSettings: Codable, Equatable, Sendable {
    // Engine-level — changing these requires reloading the model.
    public var backend: ComputeBackend
    public var contextLength: Int
    public var useSpeculativeDecoding: Bool
    // Live — applied on the next generation, no reload.
    public var systemPrompt: String
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var maxOutputTokens: Int

    public init(
        backend: ComputeBackend = .gpu,
        contextLength: Int = 4096,
        useSpeculativeDecoding: Bool = false,
        systemPrompt: String = "",
        temperature: Double = 1.0,
        topP: Double = 0.95,
        topK: Int = 64,
        maxOutputTokens: Int = 256
    ) {
        self.backend = backend
        self.contextLength = contextLength
        self.useSpeculativeDecoding = useSpeculativeDecoding
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxOutputTokens = maxOutputTokens
    }

    /// Edge Gallery iOS recipe for Gemma 4.
    public static let `default` = GenerationSettings()

    /// True when an Engine-level field (backend / contextLength / MTP) differs.
    public func engineLevelDiffers(from other: GenerationSettings) -> Bool {
        backend != other.backend
            || contextLength != other.contextLength
            || useSpeculativeDecoding != other.useSpeculativeDecoding
    }
}
