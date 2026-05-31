import XCTest
@testable import Gemma

final class NodeKindStringTests: XCTestCase {
    func test_node_stores_arbitrary_kind_string_verbatim() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        let n = Node(id: "x", kind: "spaceship", label: "Falcon", body: "", layer: .daily,
                     createdAt: now, updatedAt: now, lastSeenAt: now, salience: 1,
                     decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil,
                     sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil)
        try store.upsert(n)
        XCTAssertEqual(try store.node(id: "x")?.kind, "spaceship", "unknown kind preserved, not coerced")
    }
    func test_nodekind_constants_available() {
        XCTAssertEqual(NodeKind.task.rawValue, "task")
        XCTAssertEqual(NodeKind.plan.rawValue, "plan")
        XCTAssertEqual(NodeKind.trait.rawValue, "trait")
        XCTAssertEqual(NodeKind.insight.rawValue, "insight")
        XCTAssertEqual(NodeKind.person.rawValue, "person")
    }
}
