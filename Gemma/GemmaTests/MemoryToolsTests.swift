import XCTest
@testable import Gemma

@MainActor
final class MemoryToolsTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.store = nil
        MemoryToolbox.shared.embedder = nil
        super.tearDown()
    }

    func testRememberCreatesIdentityNodeWhenPermanent() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.embedder = FakeEmbedder(dimension: 4)
        _ = await RememberTool().run(argsJSON: #"{"content":"user likes sushi","kind":"preference","permanent":true}"#)
        let nodes = try store.allNodes()
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].layer, .identity)
        XCTAssertEqual(nodes[0].origin, .explicit)
    }

    func testForgetSoftDeletes() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        MemoryToolbox.shared.store = store
        let now = Date().timeIntervalSince1970
        try store.upsert(Node(id: "x", kind: .fact, label: "sushi", body: "sushi", layer: .daily,
                              createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001,
                              confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                              origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil))
        _ = await ForgetTool().run(argsJSON: #"{"query":"sushi"}"#)
        XCTAssertTrue(try store.allNodes().isEmpty)
    }

    func testRememberNoStoreIsSafe() async throws {
        let result = await RememberTool().run(argsJSON: #"{"content":"x","kind":"fact","permanent":false}"#)
        XCTAssertEqual(result, "memory unavailable")
    }
}
