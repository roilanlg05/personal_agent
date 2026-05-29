import Foundation
import LiteRTLM

/// Activity emitted by a tool's `run()` while the Conversation tool-loop executes it.
public enum ToolActivity: Sendable {
    case started(name: String, args: String)
    case finished(name: String, result: String)
}

/// Tools (instantiated by LiteRT-LM's ToolManager via `init()`) can't receive injected
/// context, so they emit activity through this shared @MainActor relay. The runtime sets
/// `sink` for the duration of one generation. Safe because LiteRTLMRuntime is @MainActor
/// and the engine runs one session at a time.
@MainActor
public final class ToolActivityRelay {
    public static let shared = ToolActivityRelay()
    public var sink: ((ToolActivity) -> Void)?
    public init() {}
    public func started(name: String, args: String) { sink?(.started(name: name, args: args)) }
    public func finished(name: String, result: String) { sink?(.finished(name: name, result: result)) }
}

/// A runtime that can run a generation with LiteRT-LM tools and stream tool-call events.
/// Separate from `ModelRuntime` so the LiteRT `Tool` coupling stays out of the base protocol.
public protocol ToolCallingRuntime: AnyObject {
    func generate(
        prompt: String,
        tools: [Tool],
        options: GenerationOptions
    ) async -> AsyncThrowingStream<GenerationEvent, Error>
}
