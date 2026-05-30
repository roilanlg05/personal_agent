import Foundation

public enum RuntimeKind: String, CaseIterable, Identifiable, Sendable {
    case dummy
    // .server is added in M1 Task 8 once ServerRuntime exists.
    public var id: String { rawValue }
    public var displayName: String {
        switch self { case .dummy: return "Dummy" }
    }
}

@MainActor
public enum RuntimeFactory {
    public static func make(_ kind: RuntimeKind) -> ModelRuntime {
        switch kind {
        case .dummy: return DummyRuntime()
        }
    }
}
