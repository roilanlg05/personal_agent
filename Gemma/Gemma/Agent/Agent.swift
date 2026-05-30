import Foundation
import LiteRTLM

public enum AgentEvent: Sendable {
    case token(String)
    case toolCallStarted(name: String, args: String)
    case toolCallFinished(name: String, result: String)
    case completed(GenerationResult)
    case failed(String)
}

/// Orchestrates one agent turn over a tool-calling runtime. Thin for now: it owns the tool
/// registry + system prompt and relays the runtime's event stream. Future home of
/// scratchpad (#20), memory injection (#18), and latency tricks (#23).
@MainActor
final class Agent {
    private let runtime: ToolCallingRuntime
    private let registry: ToolRegistry

    init(runtime: ToolCallingRuntime, registry: ToolRegistry) {
        self.runtime = runtime
        self.registry = registry
    }

    private var systemPrompt: String {
        "You are Gemma, a helpful on-device assistant. You can call tools to get real information. When a tool is relevant (e.g. the user asks the time), call it instead of guessing."
    }

    func run(prompt: String, options: GenerationOptions) -> AsyncThrowingStream<AgentEvent, Error> {
        let tools = registry.tools
        var opts = options
        opts.systemPrompt = systemPrompt
        return AsyncThrowingStream { continuation in
            let task = Task {
                let stream = await runtime.generate(prompt: prompt, tools: tools, options: opts)
                do {
                    for try await event in stream {
                        switch event {
                        case .token(let t): continuation.yield(.token(t))
                        case .toolCallStarted(let n, let a): continuation.yield(.toolCallStarted(name: n, args: a))
                        case .toolCallFinished(let n, let r): continuation.yield(.toolCallFinished(name: n, result: r))
                        case .completed(let res): continuation.yield(.completed(res))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.failed("\(error)"))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
