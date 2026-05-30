import Foundation

public enum ToolActivity: Sendable {
    case started(name: String, args: String)
    case finished(name: String, result: String)
}

@MainActor
public final class ToolActivityRelay {
    public static let shared = ToolActivityRelay()
    public var sink: ((ToolActivity) -> Void)?
    public init() {}
    // Keep the type @MainActor (app/UI-owned), but allow off-main teardown — its deinit does
    // no main-actor work. Avoids the MainActor-isolated-deinit double-free under
    // XCTMemoryChecker (macOS 26 XCTest).
    nonisolated deinit {}
    public func started(name: String, args: String) { sink?(.started(name: name, args: args)) }
    public func finished(name: String, result: String) { sink?(.finished(name: name, result: result)) }
}

/// A runtime that can run a generation with agent tools and stream tool-call events.
public protocol ToolCallingRuntime: AnyObject {
    func generate(
        prompt: String,
        tools: [AgentTool],
        options: GenerationOptions
    ) async -> AsyncThrowingStream<GenerationEvent, Error>
}
