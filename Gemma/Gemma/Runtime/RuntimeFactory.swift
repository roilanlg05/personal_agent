import Foundation

public enum RuntimeKind: String, CaseIterable, Identifiable, Sendable {
    case dummy
    case server
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .dummy: return "Dummy"
        case .server: return "mlx-lm Server"
        }
    }
}

@MainActor
public enum RuntimeFactory {
    public static func make(_ kind: RuntimeKind) -> ModelRuntime {
        switch kind {
        case .dummy: return DummyRuntime()
        case .server: return ServerRuntime()
        }
    }
}
