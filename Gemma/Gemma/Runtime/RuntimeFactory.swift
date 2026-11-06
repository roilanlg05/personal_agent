import Foundation

@MainActor
enum RuntimeFactory {
    static func make(_ provider: ModelProvider) -> ModelRuntime & ToolCallingRuntime {
        if provider.kind == .onDevice {
            return LlamaCppRuntime()
        }
        return ServerRuntime(provider: provider)
    }
    static func dummy() -> ModelRuntime { DummyRuntime() }
}
