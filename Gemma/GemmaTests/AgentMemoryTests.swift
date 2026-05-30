import XCTest
@testable import Gemma

/// Phase 5 Task 5.1 — the Agent injects retrieved memories into the system prompt (#18).
@MainActor
final class AgentMemoryTests: XCTestCase {
    override func tearDown() {
        // Agent now tracks consolidation on the shared toolbox (RC3 serialization); reset it
        // so it can't leak into other tests.
        MemoryToolbox.shared.consolidationTask = nil
        MemoryToolbox.shared.store = nil
        MemoryToolbox.shared.embedder = nil
        super.tearDown()
    }

    /// Captures the system prompt the runtime receives, then completes immediately.
    final class CapturingRuntime: ToolCallingRuntime {
        var capturedSystemPrompt: String?
        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            capturedSystemPrompt = options.systemPrompt
            return AsyncThrowingStream { c in
                c.yield(.completed(GenerationResult(text: "ok", metrics: RuntimeMetrics(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    func testInjectsMemoryIntoSystemPrompt() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        try store.upsert(Node(id: "1", kind: .preference, label: "sushi", body: "likes sushi", layer: .daily,
                              createdAt: now, updatedAt: now, lastSeenAt: now, salience: 5, decayRate: 0.0001,
                              confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                              origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil))
        let retriever = MemoryRetriever(store: store, embedder: nil)
        let consolidator = MemoryConsolidator(runtime: DummyRuntime(), store: store, embedder: nil)
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry(),
                          memory: MemoryServices(retriever: retriever, consolidator: consolidator))
        // Query lexically overlaps the stored memory so FTS recall works without an embedder.
        for try await _ in agent.run(prompt: "sushi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedSystemPrompt?.contains("sushi") ?? false,
                      "system prompt should include the recalled memory; got: \(rt.capturedSystemPrompt ?? "nil")")
    }

    func testNoMemoryIsPlainSystemPrompt() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())  // memory = nil
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertEqual(rt.capturedSystemPrompt?.contains("What you remember"), false)
    }

    /// RC3: a memory turn schedules a consolidation task on the shared toolbox, so the next
    /// turn can serialize against it (await it before driving the single engine session).
    func testMemoryTurnSchedulesConsolidation() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let retriever = MemoryRetriever(store: store, embedder: nil)
        let consolidator = MemoryConsolidator(runtime: DummyRuntime(), store: store, embedder: nil)
        let agent = Agent(runtime: CapturingRuntime(), registry: ToolRegistry(),
                          memory: MemoryServices(retriever: retriever, consolidator: consolidator))
        MemoryToolbox.shared.consolidationTask = nil
        for try await _ in agent.run(prompt: "hola", options: GenerationOptions()) {}
        XCTAssertNotNil(MemoryToolbox.shared.consolidationTask, "a memory turn should schedule consolidation")
        await MemoryToolbox.shared.consolidationTask?.value  // let it settle
    }
}
