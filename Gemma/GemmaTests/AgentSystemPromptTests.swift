import XCTest
@testable import Gemma

@MainActor
final class AgentSystemPromptTests: XCTestCase {
    final class CapturingRuntime: ToolCallingRuntime {
        var capturedSystem: String = ""
        var capturedPrompt: String = ""
        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            capturedSystem = options.systemPrompt ?? ""
            capturedPrompt = prompt
            return AsyncThrowingStream { c in
                c.yield(.completed(GenerationResult(text: "ok", metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    func test_system_prompt_has_no_save_memory_instruction() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertFalse(rt.capturedSystem.lowercased().contains("save_memory"),
                       "live-turn system prompt must not instruct the model to call save_memory")
        XCTAssertTrue(rt.capturedSystem.contains("Answer only what was asked"),
                      "the answer-only guidance stays")
    }

    func test_current_date_rides_the_tail_not_the_static_prefix() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        // JARVIS rework: the date is intentionally OUT of the static system prefix (kept byte-stable
        // for the APC prefix cache) and now rides the per-turn message tail via nowContext().
        XCTAssertFalse(rt.capturedSystem.contains(today), "static prefix must NOT carry the date")
        XCTAssertTrue(rt.capturedPrompt.contains(today), "the per-turn tail must carry today's date")
    }

    func test_system_prompt_asks_to_mention_all_matching_memories() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedSystem.localizedCaseInsensitiveContains("all of them"),
                      "prompt should tell the model to mention all matching memories, not only the newest")
    }
}
