import XCTest
@testable import Gemma

@MainActor
final class AgentRuntimeTests: XCTestCase {
    private func installedModelURL() throws -> URL {
        let store = InstalledModels.defaultInDocuments()
        for id in ["gemma-4-e2b-it", "gemma-4-e4b-it"] {
            if let d = ModelCatalog.find(id), case .installed(let url) = store.status(of: d) { return url }
        }
        throw XCTSkip("No Gemma 4 .litertlm installed — sideload to run the agent E2E test.")
    }

    /// End-to-end: the model must actually call the CurrentTimeTool when asked the time.
    /// Validates the core S4 risk — function-calling reliability on the small E4B. Device-only.
    func test_agent_callsCurrentTimeTool() async throws {
        let url = try installedModelURL()
        let runtime = LiteRTLMRuntime()
        try await runtime.load(options: ModelLoadOptions(modelPath: url))
        let agent = Agent(runtime: runtime, registry: ToolRegistry.withDefaults())
        var calledTool = false
        var text = ""
        for try await event in agent.run(prompt: "What time is it right now?", options: GenerationOptions(maxTokens: 128)) {
            switch event {
            case .toolCallStarted(let n, _) where n == "get_current_time": calledTool = true
            case .token(let t): text += t
            case .completed(let r): text = r.text
            default: break
            }
        }
        await runtime.unload()
        XCTAssertTrue(calledTool, "E4B should have called get_current_time")
        XCTAssertFalse(text.isEmpty)
    }
}
