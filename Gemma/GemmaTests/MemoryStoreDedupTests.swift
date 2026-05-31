import XCTest
@testable import Gemma

/// Returns identical vectors for any string containing the keyword, distinct otherwise →
/// deterministic semantic-dedup tests without NL assets.
private final class KeywordEmbedder: Embedder {
    let dimension = 4
    func embed(_ text: String) throws -> [Float] {
        let t = text.lowercased()
        if t.contains("messi") { return [1, 0, 0, 0] }
        if t.contains("sushi") { return [0, 1, 0, 0] }
        return [0, 0, 1, 0]
    }
}

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

    func testDedupCanonicalAcrossPhrasings() throws {
        let store = try makeStore()
        _ = try store.upsertMerging(node(label: "me gusta el sushi"))
        _ = try store.upsertMerging(node(label: "Sushi"))
        let nodes = try store.allNodes()
        XCTAssertEqual(nodes.count, 1, "different phrasings of the same entity must merge; got: \(nodes.map { $0.label })")
    }

    func testPromotesToIdentityAtThreshold() throws {
        let store = try makeStore()
        for _ in 0..<3 { _ = try store.upsertMerging(node(kind: .person, label: "Juan")) }
        XCTAssertEqual(try store.allNodes().first?.layer, .identity)
    }

    func test_semantic_dedup_merges_phrasing_variants() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let emb = KeywordEmbedder()
        let now = Date().timeIntervalSince1970
        func cand(_ id: String, _ label: String) -> Node {
            Node(id: id, kind: .preference, label: label, body: label, layer: .daily, createdAt: now,
                 updatedAt: now, lastSeenAt: now, salience: 3, decayRate: Decay.defaultDecayRate(for: .daily),
                 confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit,
                 serverId: nil, dirty: true, deleted: false, extra: nil)
        }
        let id1 = try store.upsertMergingSemantic(cand("a", "Messi"), embedding: try emb.embed("Messi"), embedder: emb)
        _ = try store.upsertMergingSemantic(cand("b", "likes Messi"), embedding: try emb.embed("likes Messi"), embedder: emb)
        _ = try store.upsertMergingSemantic(cand("c", "Messi fan"), embedding: try emb.embed("Messi fan"), embedder: emb)
        let prefs = try store.allNodes().filter { $0.kind == .preference }
        XCTAssertEqual(prefs.count, 1, "3 Messi phrasings must collapse to 1 node")
        XCTAssertEqual(prefs.first?.id, id1)
        XCTAssertEqual(prefs.first?.mentionCount, 3)
        XCTAssertGreaterThan(prefs.first!.salience, 3, "reinforced via EMA")
    }

    func test_semantic_dedup_keeps_distinct_entities_separate() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let emb = KeywordEmbedder()
        let now = Date().timeIntervalSince1970
        func cand(_ id: String, _ label: String) -> Node {
            Node(id: id, kind: .preference, label: label, body: label, layer: .daily, createdAt: now,
                 updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001, confidence: .sure,
                 mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil,
                 dirty: true, deleted: false, extra: nil)
        }
        _ = try store.upsertMergingSemantic(cand("a", "Messi"), embedding: try emb.embed("Messi"), embedder: emb)
        _ = try store.upsertMergingSemantic(cand("b", "sushi"), embedding: try emb.embed("sushi"), embedder: emb)
        XCTAssertEqual(try store.allNodes().filter { $0.kind == .preference }.count, 2)
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
