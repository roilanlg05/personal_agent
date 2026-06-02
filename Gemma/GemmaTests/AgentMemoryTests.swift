import XCTest
@testable import Gemma

/// Phase 5 Task 5.1 — the Agent injects recallTail + wakeContext into the USER prompt tail
/// (never the system prompt — that's load-bearing for APC). The agent is memory-agnostic now;
/// recall fetching itself lives in HarnessModel (HTTP to the Memory Service), so this suite
/// only verifies the agent's injection contract: given a non-empty recallTail, it must ride
/// the user prompt and never the system prompt.
@MainActor
final class AgentMemoryTests: XCTestCase {
    /// Captures the system prompt AND the user prompt the runtime receives, then completes.
    final class CapturingRuntime: ToolCallingRuntime {
        var capturedSystemPrompt: String?
        var capturedUserPrompt: String?
        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            capturedSystemPrompt = options.systemPrompt
            capturedUserPrompt = prompt
            return AsyncThrowingStream { c in
                c.yield(.completed(GenerationResult(text: "ok", metrics: RuntimeMetrics(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    func testInjectsRecallTailIntoUserPrompt() async throws {
        let rt = CapturingRuntime()
        let tail = "What you remember about the user (use if relevant):\n- [preference] sushi: likes sushi"
        let agent = Agent(runtime: rt, registry: ToolRegistry(), recallTail: tail)
        for try await _ in agent.run(prompt: "sushi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedUserPrompt?.contains("sushi") ?? false,
                      "recall must be prepended to the user prompt; got: \(rt.capturedUserPrompt ?? "nil")")
        XCTAssertTrue(rt.capturedUserPrompt?.contains("What you remember") ?? false)
        XCTAssertEqual(rt.capturedSystemPrompt?.contains("What you remember"), false,
                       "recall must NOT be in the system prompt (it would bust the prefix cache)")
        XCTAssertTrue(rt.capturedUserPrompt?.hasSuffix("sushi") ?? false)
    }

    func testNoRecallIsPlainSystemPrompt() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())  // recallTail = ""
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertEqual(rt.capturedSystemPrompt?.contains("What you remember"), false)
    }

    func test_wakeContext_rides_user_prompt_tail() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry(),
                          wakeContext: "You were reflecting on: sushi.")
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedUserPrompt?.contains("You were reflecting on: sushi.") ?? false,
                      "wakeContext must ride the user prompt; got: \(rt.capturedUserPrompt ?? "nil")")
        XCTAssertEqual(rt.capturedSystemPrompt?.contains("You were reflecting on") ?? false, false,
                       "wakeContext must NOT be in the system prompt")
    }

    func test_noRecall_noWake_leaves_user_prompt_unchanged() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())  // recallTail = "", wakeContext = ""
        for try await _ in agent.run(prompt: "hola", options: GenerationOptions()) {}
        XCTAssertEqual(rt.capturedUserPrompt, "hola")
    }
}
