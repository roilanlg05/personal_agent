import Foundation

public enum AgentEvent: Sendable {
    case token(String)
    case toolCallStarted(name: String, args: String)
    case toolCallFinished(name: String, result: String)
    case completed(GenerationResult)
    case failed(String)
}

/// Orchestrates one agent turn over a tool-calling runtime. The caller (HarnessModel) is
/// responsible for fetching recall (via MemoryClient) and rendering it into `recallTail`
/// before the turn — Agent itself is memory-agnostic and just appends `recallTail` + `wakeContext`
/// to the user prompt, keeping the system prompt byte-stable so the server's prefix cache (APC)
/// stays warm. The live turn does NOT write memory (no save_memory) — capture is deferred to
/// background consolidation, and the caller appends the turn to the Memory Service.
@MainActor
final class Agent {
    /// Schedule conventions injected into the system prompt. Static (date-independent) so it is
    /// testable and stays byte-stable for the server prefix cache.
    nonisolated static let scheduleConventions = """
    Time conventions: a week runs Monday–Sunday; the working week runs Monday–Friday. \
    "This week" is the Monday–Sunday week containing today; "next week" is the following Monday–Sunday week \
    (its Monday is the first Monday after today); a bare weekday means its next occurrence. \
    ALWAYS resolve any relative term to an absolute date (yyyy-MM-dd) from today's date BEFORE calling a \
    schedule tool — never pass terms like "next week" to a tool. \
    For "what's on my schedule / this week / next week", query_schedule is the ONLY source of truth: call it \
    with the resolved range and report exactly what it returns; never list events from memory as if active, \
    and if it returns nothing, say there is nothing. To show cancelled/past events the user explicitly asks \
    about, call query_schedule with includeCancelled true; they are shown marked "(cancelado)".
    """

    /// Current local date + time, injected per-turn on the message tail (NOT in the static prefix),
    /// so the model always has the correct "now" to resolve relative dates against.
    nonisolated static func nowContext(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd (EEEE) HH:mm"
        return "Current date and time: \(f.string(from: date)) (local)."
    }

    private let runtime: ToolCallingRuntime
    private let registry: ToolRegistry
    private let recallTail: String
    private let wakeContext: String

    init(runtime: ToolCallingRuntime, registry: ToolRegistry, recallTail: String = "", wakeContext: String = "") {
        self.runtime = runtime
        self.registry = registry
        self.recallTail = recallTail
        self.wakeContext = wakeContext
    }

    private func systemPrompt() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd (EEEE)"
        let today = df.string(from: Date())
        // Static instructions only — kept byte-stable across turns so the mlx_vlm.server APC
        // prefix cache reuses its KV (cold start restored from the SSD tier). Per-turn recall and
        // wakeContext are NOT here; they ride the tail of the user message (see run()).
        // The date is intentionally kept in the prefix: stable within a day (≤1 cache rebuild/day)
        // and preserves temporal grounding.
        return """
        You are Gemma, a helpful on-device assistant. Today is \(today). You can call tools to get real information. \
        When a tool is relevant (e.g. the user asks the time), call it instead of guessing. \
        Answer only what the user asked; do not list unrelated things you remember. \
        But when several remembered facts match the question (e.g. multiple meetings or events), \
        mention ALL of them with their dates — never answer with only the most recent. \
        IMPORTANT: after any tool runs, ALWAYS reply to the user in a short, natural sentence — \
        confirm what you did or answer their question. Never end your turn with only a tool call. \
        Scheduling: the user's calendar lives in tools. For appointments/meetings/trips, FIRST acknowledge briefly ("let me check your schedule"), then call check_schedule, then create_event. \
        Pass times as LOCAL ISO datetimes using today's date above (e.g. "tomorrow 3pm" → 2026-06-10T15:00). \
        If the user gives only a start time, ASK for the end before creating. If a time span is vague ("rest of the week"), ASK whether it starts now or tomorrow; "rest of the night" means until 06:00 the next day. \
        If create_event reports a conflict, do NOT force it: tell the user what it conflicts with (consider travel/location too — e.g. a meeting in another city during a trip) and ask whether to reschedule, cancel the other, or book anyway. If the user says book anyway, call create_event again with force set to true. \
        Use query_schedule for "what's on my schedule"; use cancel_events (which only cancels, never deletes) for "cancel my appointments". To-dos without a fixed time (call mom, gym) are not calendar events — don't create_event for them.
        \(Self.scheduleConventions)
        """
    }

    func run(prompt: String, options: GenerationOptions) -> AsyncThrowingStream<AgentEvent, Error> {
        let tools = registry.tools
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Recall + wakeContext ride the TAIL of the user message so the system prefix
                // stays byte-identical across turns → APC prefix-cache hit (disk on cold start,
                // memory when warm). See docs/superpowers/specs/2026-06-02-mlx-ttft-quickwin-design.md.
                var recallTail = self.recallTail
                if !wakeContext.isEmpty {
                    recallTail = recallTail.isEmpty ? wakeContext : recallTail + "\n\n" + wakeContext
                }
                var opts = options
                opts.systemPrompt = systemPrompt()

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
                    // Iteration 0 carries the recall tail; tool-loop iterations reuse their own prompt.
                    var currentPrompt = recallTail.isEmpty ? prompt : recallTail + "\n\n" + prompt
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
                        // them itself. We must NOT treat visible text as final while tool calls are
                        // still pending+unexecuted — otherwise a model that emits text alongside a
                        // requested tool call would have that side-effecting call silently dropped.
                        // Pending, unexecuted tool calls are always executed before the turn ends.
                        let isFinal = pendingToolCalls.isEmpty || runtimeFinishedAnyTool
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
                } catch {
                    continuation.yield(.failed("\(error)"))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
