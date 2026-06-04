import Foundation

@MainActor
enum RuntimeFactory {
    static func make(_ provider: ModelProvider) -> ModelRuntime & ToolCallingRuntime {
        ServerRuntime(provider: provider)
    }
    static func dummy() -> ModelRuntime { DummyRuntime() }
}
