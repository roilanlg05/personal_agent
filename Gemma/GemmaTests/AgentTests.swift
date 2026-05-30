import XCTest
@testable import Gemma

@MainActor
final class AgentTests: XCTestCase {
    /// Stub tool-calling runtime that emits a fixed event sequence.
    final class StubRuntime: ToolCallingRuntime {
        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            AsyncThrowingStream { c in
                c.yield(.token("It is "))
                c.yield(.toolCallStarted(name: "get_current_time", args: "{}"))
                c.yield(.toolCallFinished(name: "get_current_time", result: "12:00"))
                c.yield(.token("12:00."))
                c.yield(.completed(GenerationResult(text: "It is 12:00.", metrics: RuntimeMetrics(tokensGenerated: 2, elapsedSeconds: 0.1, timeToFirstTokenSeconds: 0.05, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    func test_run_relaysEventsAsAgentEvents() async throws {
        let agent = Agent(runtime: StubRuntime(), registry: ToolRegistry.withDefaults())
        var kinds: [String] = []
        var finalText: String?
        for try await event in agent.run(prompt: "what time is it?", options: GenerationOptions(maxTokens: 64)) {
            switch event {
            case .token: kinds.append("token")
            case .toolCallStarted(let n, _): kinds.append("start:\(n)")
            case .toolCallFinished(let n, _): kinds.append("done:\(n)")
            case .completed(let r): finalText = r.text; kinds.append("completed")
            case .failed(let m): XCTFail("unexpected failure: \(m)")
            }
        }
        XCTAssertEqual(kinds, ["token", "start:get_current_time", "done:get_current_time", "token", "completed"])
        XCTAssertEqual(finalText, "It is 12:00.")
    }

    /// New ServerRuntime semantics: call 1 surfaces a tool call and an EMPTY completed (the model
    /// stopped to call a tool); the runtime does NOT execute the tool or emit `.toolCallFinished`.
    /// The Agent must drive the loop: run the tool, emit `.toolCallFinished`, re-call → final text.
    func test_run_executesToolAndFinishes() async throws {
        final class TwoStepRuntime: ToolCallingRuntime {
            var call = 0
            var prompts: [String] = []
            func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
                call += 1
                prompts.append(prompt)
                let isFirst = call == 1
                return AsyncThrowingStream { c in
                    if isFirst { c.yield(.toolCallStarted(name: "get_current_time", args: "{}")) }
                    else { c.yield(.token("done")) }
                    c.yield(.completed(GenerationResult(text: isFirst ? "" : "done", metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                    c.finish()
                }
            }
        }
        let runtime = TwoStepRuntime()
        let agent = Agent(runtime: runtime, registry: ToolRegistry.withDefaults())
        var sawToolFinished = false
        var toolResult = ""
        var finalText = ""
        for try await e in agent.run(prompt: "time?", options: GenerationOptions()) {
            if case .toolCallFinished(_, let r) = e { sawToolFinished = true; toolResult = r }
            if case .completed(let r) = e { finalText = r.text }
        }
        XCTAssertTrue(sawToolFinished)
        XCTAssertEqual(finalText, "done")
        // The tool result must be fed back: the runtime's SECOND call should receive a prompt
        // augmented with the bracketed tool-result note (this exercises the M1 prompt-augmentation
        // mechanism, which is otherwise untested).
        XCTAssertEqual(runtime.prompts.count, 2)
        let secondPrompt = runtime.prompts[1]
        XCTAssertTrue(secondPrompt.contains("get_current_time"), "second prompt should mention the called tool: \(secondPrompt)")
        XCTAssertTrue(secondPrompt.contains(toolResult), "second prompt should contain the tool result \(toolResult): \(secondPrompt)")
        XCTAssertTrue(secondPrompt.contains("it returned:"), "second prompt should contain the augmentation note: \(secondPrompt)")
    }

    /// Regression: the model returns BOTH visible text AND a requested-but-unexecuted tool call in
    /// the same iteration. The visible text must NOT cause the pending (side-effecting) tool call to
    /// be skipped — the Agent must still execute it before treating the turn as final.
    func test_run_executesToolEvenWhenModelAlsoReturnsText() async throws {
        final class TextPlusToolRuntime: ToolCallingRuntime {
            var call = 0
            func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
                call += 1
                let isFirst = call == 1
                return AsyncThrowingStream { c in
                    if isFirst {
                        c.yield(.token("Got it"))
                        c.yield(.toolCallStarted(name: "get_current_time", args: "{}"))
                        c.yield(.completed(GenerationResult(text: "Got it", metrics: .init(tokensGenerated: 1, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                    } else {
                        c.yield(.token("It is 12:00."))
                        c.yield(.completed(GenerationResult(text: "It is 12:00.", metrics: .init(tokensGenerated: 1, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                    }
                    c.finish()
                }
            }
        }
        let agent = Agent(runtime: TextPlusToolRuntime(), registry: ToolRegistry.withDefaults())
        var sawToolFinished = false
        var finalText = ""
        for try await e in agent.run(prompt: "time?", options: GenerationOptions()) {
            if case .toolCallFinished = e { sawToolFinished = true }
            if case .completed(let r) = e { finalText = r.text }
        }
        XCTAssertTrue(sawToolFinished, "pending tool must execute even though the model also emitted visible text")
        XCTAssertEqual(finalText, "It is 12:00.")
    }
}
