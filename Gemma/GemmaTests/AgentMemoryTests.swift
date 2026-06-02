import XCTest
@testable import Gemma

/// Phase 5 Task 5.1 — the Agent injects retrieved memories into the system prompt (#18).
@MainActor
final class AgentMemoryTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.store = nil
        MemoryToolbox.shared.embedder = nil
        super.tearDown()
    }

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

    func testInjectsMemoryIntoUserPromptTail() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        try store.upsert(Node(id: "1", kind: NodeKind.preference.rawValue, label: "sushi", body: "likes sushi", layer: .daily,
                              createdAt: now, updatedAt: now, lastSeenAt: now, salience: 5, decayRate: 0.0001,
                              confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                              origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil))
        let retriever = MemoryRetriever(store: store, embedder: nil)
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry(),
                          memory: MemoryServices(retriever: retriever))
        for try await _ in agent.run(prompt: "sushi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedUserPrompt?.contains("sushi") ?? false,
                      "recall must be prepended to the user prompt; got: \(rt.capturedUserPrompt ?? "nil")")
        XCTAssertEqual(rt.capturedSystemPrompt?.contains("What you remember"), false,
                       "recall must NOT be in the system prompt (it would bust the prefix cache)")
        XCTAssertTrue(rt.capturedUserPrompt?.hasSuffix("sushi") ?? false)
    }

    func testNoMemoryIsPlainSystemPrompt() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())  // memory = nil
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertEqual(rt.capturedSystemPrompt?.contains("What you remember"), false)
    }

    func test_wakeContext_rides_user_prompt_tail() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry(), memory: nil,
                          wakeContext: "You were reflecting on: sushi.")
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedUserPrompt?.contains("You were reflecting on: sushi.") ?? false,
                      "wakeContext must ride the user prompt; got: \(rt.capturedUserPrompt ?? "nil")")
        XCTAssertEqual(rt.capturedSystemPrompt?.contains("You were reflecting on") ?? false, false,
                       "wakeContext must NOT be in the system prompt")
    }

    func test_noMemory_noWake_leaves_user_prompt_unchanged() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())  // memory = nil, wakeContext = ""
        for try await _ in agent.run(prompt: "hola", options: GenerationOptions()) {}
        XCTAssertEqual(rt.capturedUserPrompt, "hola")
    }
}
