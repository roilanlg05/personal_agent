import Foundation

public enum RuntimeKind: String, Sendable, CaseIterable, Codable, Hashable, Identifiable {
    case dummy
    case litertlmE4B
    case litertlmE2B
    // Plan 4 adds: case llamacpp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dummy: return "Dummy (no model)"
        case .litertlmE4B: return "Gemma 4 E4B (LiteRT-LM)"
        case .litertlmE2B: return "Gemma 4 E2B (LiteRT-LM)"
        }
    }

    /// The catalog id this runtime requires installed, or nil if it needs no model on disk.
    public var requiredModelId: String? {
        switch self {
        case .dummy: return nil
        case .litertlmE4B: return "gemma-4-e4b-it"
        case .litertlmE2B: return "gemma-4-e2b-it"
        }
    }
}

public enum RuntimeFactory {
    /// Returns a fresh runtime instance for the given kind. Caller owns the lifecycle.
    /// Plan 2 returns a DummyRuntime for the LiteRT-LM kinds; Plan 3 swaps in the real runtime.
    public static func make(_ kind: RuntimeKind) -> ModelRuntime {
        switch kind {
        case .dummy, .litertlmE4B, .litertlmE2B:
            return DummyRuntime()
        }
    }
}
