import XCTest
import LiteRTLM
@testable import Gemma

/// Phase 4 — remember/forget tools via MemoryToolbox. Tools are built through the real
/// Decodable param path (JSONDecoder), matching how LiteRT-LM constructs them.
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

        var tool = try JSONDecoder().decode(RememberTool.self, from: Data(#"{"content":"user likes sushi","kind":"preference","permanent":true}"#.utf8))
        _ = try await tool.run()

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

        var tool = try JSONDecoder().decode(ForgetTool.self, from: Data(#"{"query":"sushi"}"#.utf8))
        _ = try await tool.run()
        XCTAssertTrue(try store.allNodes().isEmpty)
    }

    func testRememberNoStoreIsSafe() async throws {
        // No store set → tool degrades, does not crash.
        var tool = try JSONDecoder().decode(RememberTool.self, from: Data(#"{"content":"x"}"#.utf8))
        let output = try await tool.run()
        let result = output as? String
        XCTAssertEqual(result, "memory unavailable")
    }
}
