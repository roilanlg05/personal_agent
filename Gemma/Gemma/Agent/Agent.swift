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

                do {
                    // Client-side tool loop. ServerRuntime stops to request a tool (emits
                    // `.toolCallStarted` + an EMPTY `.completed`) but never runs it; the Agent must
                    // execute the tool, feed the result back, and re-call until a final text answer.
                    // NOTE (M1): we feed results back by augmenting the flat prompt with a bracketed
                    // note. The proper fix (M2) is OpenAI tool-role messages — send the assistant's
                    // tool_call message + a tool-role result message and re-send the full history.
                    // That requires a message-history runtime API; the prompt-augmentation here keeps
                    // the `generate(prompt:tools:options:)` signature unchanged for M1.
                    let maxIterations = 5
                    var currentPrompt = prompt
                    loop: for iteration in 0..<maxIterations {
                        let stream = await runtime.generate(prompt: currentPrompt, tools: tools, options: opts)
                        // Tokens, started-events and any runtime-emitted finished-events are relayed
                        // LIVE (preserving order for all-in-one engines that stream a full turn).
                        // We only buffer the decision of whether to drive another round.
                        var pendingToolCalls: [(name: String, args: String)] = []
                        var runtimeFinishedAnyTool = false
                        var completed: GenerationResult?
                        for try await event in stream {
                            switch event {
                            case .token(let t):
                                continuation.yield(.token(t))
                            case .toolCallStarted(let n, let a):
                                pendingToolCalls.append((n, a))
                                continuation.yield(.toolCallStarted(name: n, args: a))
                            case .toolCallFinished(let n, let r):
                                // An all-in-one engine ran the tool itself; relay and stop driving.
                                runtimeFinishedAnyTool = true
                                continuation.yield(.toolCallFinished(name: n, result: r))
                            case .completed(let res):
                                completed = res
                            }
                        }

                        // Final answer when: the model requested no tools, OR the runtime already ran
                        // them itself, OR it produced visible text alongside the call. In those cases
                        // this iteration's `.completed` IS the turn's answer — yield it and finish.
                        let producedVisibleAnswer = !(completed?.text.isEmpty ?? true)
                        let isFinal = pendingToolCalls.isEmpty || runtimeFinishedAnyTool || producedVisibleAnswer
                        if isFinal {
                            if let completed { continuation.yield(.completed(completed)) }
                            break loop
                        }

                        // The model stopped to call one or more tools and the runtime did NOT run
                        // them (empty `.completed`). Execute each here, emit `.toolCallFinished`, and
                        // append the result to the follow-up prompt. The intermediate (empty)
                        // `.completed` is suppressed — it is not the turn's answer.
                        var resultsNote = currentPrompt
                        for tc in pendingToolCalls {
                            let result: String
                            if let tool = registry.tool(named: tc.name) {
                                result = await tool.run(argsJSON: tc.args)
                            } else {
                                result = "error: no tool named \(tc.name)"
                            }
                            continuation.yield(.toolCallFinished(name: tc.name, result: result))
                            resultsNote += "\n\n[You called the tool `\(tc.name)` with arguments \(tc.args); it returned: \(result). Now reply to the user in a short natural sentence using this result.]"
                        }
                        currentPrompt = resultsNote

                        // Safety: hit the cap while still getting tool calls — end the turn with
                        // whatever the last generation produced so the turn never hangs.
                        if iteration == maxIterations - 1 {
                            if let completed { continuation.yield(.completed(completed)) }
                            else { continuation.yield(.failed("tool loop did not converge")) }
                            break loop
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
