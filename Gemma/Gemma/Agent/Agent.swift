import Foundation

public enum AgentEvent: Sendable {
    case token(String)
    case toolCallStarted(name: String, args: String)
    case toolCallFinished(name: String, result: String)
    case completed(GenerationResult)
    case failed(String)
}

/// Memory services injected into the Agent (nil → S4 behavior, no memory).
@MainActor
struct MemoryServices {
    let retriever: MemoryRetriever
    let consolidator: MemoryConsolidator
}

/// Orchestrates one agent turn over a tool-calling runtime. With memory: retrieves relevant
/// memories and injects them into the system prompt (#18), then consolidates the finished
/// exchange asynchronously. Without memory it behaves exactly as the S4 agent.
@MainActor
final class Agent {
    private let runtime: ToolCallingRuntime
    private let registry: ToolRegistry
    private let memory: MemoryServices?

    init(runtime: ToolCallingRuntime, registry: ToolRegistry, memory: MemoryServices? = nil) {
        self.runtime = runtime
        self.registry = registry
        self.memory = memory
    }

    private func systemPrompt(memoryBlock: String) -> String {
        let base = """
        You are Gemma, a helpful on-device assistant. You can call tools to get real information. \
        When a tool is relevant (e.g. the user asks the time), call it instead of guessing. \
        Use the remember tool to save durable facts the user shares. \
        IMPORTANT: after any tool runs, ALWAYS reply to the user in a short, natural sentence — \
        confirm what you did or answer their question (e.g. "It's 3:42 PM." or "Got it — I'll remember you like red."). \
        Never end your turn with only a tool call; the user must always see a written reply.
        """
        return memoryBlock.isEmpty ? base : base + "\n\n" + memoryBlock
    }

    func run(prompt: String, options: GenerationOptions) -> AsyncThrowingStream<AgentEvent, Error> {
        let tools = registry.tools
        let memory = self.memory
        return AsyncThrowingStream { continuation in
            let task = Task {
                // RC3: the engine has ONE session. Wait for any prior post-turn consolidation
                // (itself a generation) to finish before this turn drives the model — otherwise
                // the two collide ("a session already exists" → corrupted chat). Awaiting here
                // (after consolidation has written) also means retrieval below sees fresh memory.
                await MemoryToolbox.shared.consolidationTask?.value

                var memoryBlock = ""
                if let memory, let nodes = try? memory.retriever.retrieve(query: prompt) {
                    memoryBlock = memory.retriever.injectionBlock(for: nodes)
                }
                var opts = options
                opts.systemPrompt = systemPrompt(memoryBlock: memoryBlock)

                let stream = await runtime.generate(prompt: prompt, tools: tools, options: opts)
                var answer = ""
                do {
                    for try await event in stream {
                        switch event {
                        case .token(let t): answer += t; continuation.yield(.token(t))
                        case .toolCallStarted(let n, let a): continuation.yield(.toolCallStarted(name: n, args: a))
                        case .toolCallFinished(let n, let r): continuation.yield(.toolCallFinished(name: n, result: r))
                        case .completed(let res): continuation.yield(.completed(res))
                        }
                    }
                    continuation.finish()
                    // RC3b: consolidate from the USER's message only. Feeding the assistant's
                    // replies back in (which often echo/ask "you like sushi?") caused the model
                    // to re-extract those as new memories → duplicates and garbage labels.
                    // Tracked on the shared toolbox so the NEXT turn serializes against it.
                    if let memory {
                        let userTurn = prompt
                        MemoryToolbox.shared.consolidationTask = Task {
                            await memory.consolidator.consolidate(user: userTurn, assistant: "")
                        }
                    }
                } catch {
                    continuation.yield(.failed("\(error)"))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
