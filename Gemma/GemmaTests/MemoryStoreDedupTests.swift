import XCTest
@testable import Gemma

/// Phase 2 Task 2.2 — dedup/merge + sweep. Self-contained (own helpers) to keep the
/// Phase 1 MemoryStoreTests file untouched.
final class MemoryStoreDedupTests: XCTestCase {
    private func makeStore() throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: 4) }

    private func node(id: String = UUID().uuidString, kind: NodeKind = .preference, label: String = "sushi",
                      layer: MemoryLayer = .daily, ttl: Double? = nil, lastSeen: Double? = nil) -> Node {
        let now = Date().timeIntervalSince1970
        return Node(id: id, kind: kind, label: label, body: label, layer: layer,
                    createdAt: now, updatedAt: now, lastSeenAt: lastSeen ?? now, salience: 3,
                    decayRate: 0.001, confidence: .probable, mentionCount: 1, ttlExpiresAt: ttl,
                    sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
    }

    func testUpsertMergingReinforces() throws {
        let store = try makeStore()
        _ = try store.upsertMerging(node(label: "sushi"))
        _ = try store.upsertMerging(node(label: "sushi"))
        let nodes = try store.allNodes()
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].mentionCount, 2)
    }

    func testPromotesToIdentityAtThreshold() throws {
        let store = try makeStore()
        for _ in 0..<3 { _ = try store.upsertMerging(node(label: "Juan", kind: .person)) }
        XCTAssertEqual(try store.allNodes().first?.layer, .identity)
    }

    func testSweepForgetsExpiredDailyKeepsIdentity() throws {
        let store = try makeStore()
        let daily = node(label: "tmp", ttl: 1, lastSeen: 1)
        let ident = node(label: "name", layer: .identity)
        try store.upsert(daily)
        try store.upsert(ident)
        try store.sweep(now: Date().timeIntervalSince1970)
        let labels = Set(try store.allNodes().map { $0.label })
        XCTAssertFalse(labels.contains("tmp"))
        XCTAssertTrue(labels.contains("name"))
    }
}
