import Foundation

public enum RuntimeKind: String, Sendable, CaseIterable, Codable, Hashable, Identifiable {
    case dummy
    // Plan 2 adds: case litertlm
    // Plan 3 adds: case llamacpp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dummy: return "Dummy (no model)"
        }
    }
}

public enum RuntimeFactory {
    /// Returns a fresh runtime instance for the given kind. Caller owns the lifecycle.
    public static func make(_ kind: RuntimeKind) -> ModelRuntime {
        switch kind {
        case .dummy:
            return DummyRuntime()
        }
    }
}
