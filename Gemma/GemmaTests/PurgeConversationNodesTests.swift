import XCTest
import GRDB
@testable import Gemma

final class PurgeConversationNodesTests: XCTestCase {
    func test_purge_removes_conversation_nodes_keeps_knowledge() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let t = 1.0
        let convo = Node(id: "c1", kind: NodeKind.conversation.rawValue, label: "user: hi", body: "hi",
                         layer: .episodic, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 2,
                         decayRate: 0.1, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil,
                         sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        let fact = Node(id: "f1", kind: NodeKind.preference.rawValue, label: "sushi", body: "likes sushi",
                        layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3,
                        decayRate: 0.1, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil,
                        sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil)
        try store.upsert(convo)
        try store.upsert(fact)

        try store.purgeConversationNodes()

        let all = try store.allNodes()
        XCTAssertNil(all.first { $0.id == "c1" }, "conversation node must be purged")
        XCTAssertNotNil(all.first { $0.id == "f1" }, "knowledge node must remain")
    }
}
