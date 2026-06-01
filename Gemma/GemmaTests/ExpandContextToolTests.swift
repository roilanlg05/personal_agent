import XCTest
@testable import Gemma

@MainActor
final class ExpandContextToolTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.store = nil
        MemoryToolbox.shared.transcriptStore = nil
        super.tearDown()
    }

    func test_expand_returns_verbatim_turns_for_a_summary_topic() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "quiero ir a Japón en abril", now: 1)
        try ts.append(threadId: "T", turnIndex: 0, role: "assistant", text: "buena idea", now: 2)
        let extra = #"{"concepts":["Japón"],"threadId":"T","turnRange":[0,0]}"#
        let summary = Node(id: "s1", kind: NodeKind.summary.rawValue, label: "viaje a Japón", body: "Plan a trip",
                           layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 4, decayRate: 0.1,
                           confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: "T",
                           origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: extra)
        try store.upsert(summary)
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.transcriptStore = ts

        let out = await ExpandContextTool().run(argsJSON: #"{"topic":"viaje a Japón"}"#)
        XCTAssertTrue(out.contains("quiero ir a Japón en abril"), "verbatim user turn; got: \(out)")
        XCTAssertTrue(out.contains("buena idea"), "assistant turn")
    }

    func test_expand_unknown_topic_is_safe() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.transcriptStore = TranscriptStore(dbQueue: store.dbQueue)
        let out = await ExpandContextTool().run(argsJSON: #"{"topic":"inexistente"}"#)
        XCTAssertFalse(out.isEmpty)
    }
}
