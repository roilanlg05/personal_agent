import XCTest
@testable import Gemma

/// RC6 — meta-questions ("what do I like?") that match no single entity must still recall the
/// user's strong facts via the always-injected identity core.
final class MemoryCoreRecallTests: XCTestCase {
    private func store() throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: 4) }
    private func node(_ label: String, _ kind: NodeKind, layer: MemoryLayer = .daily, salience: Double = 5) -> Node {
        let now = Date().timeIntervalSince1970
        return Node(id: UUID().uuidString, kind: kind, label: label, body: "likes \(label)", layer: layer,
                    createdAt: now, updatedAt: now, lastSeenAt: now, salience: salience, decayRate: 0.0001,
                    confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                    origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
    }

    func testMetaQuestionRecallsPreferencesWithoutEntityMatch() throws {
        let s = try store()
        // Core is now identity-ONLY, so the always-injected recall path uses identity-layer prefs.
        try s.upsert(node("sushi", .preference, layer: .identity, salience: 8))
        try s.upsert(node("Messi", .preference, layer: .identity, salience: 8))
        let r = MemoryRetriever(store: s, embedder: nil)   // no embedder → pure non-vector path
        // The query shares NO keyword with the entity labels (sushi/Messi).
        let got = try r.retrieve(query: "sabes que me gusta")
        let labels = Set(got.map { $0.label })
        XCTAssertTrue(labels.contains("sushi"), "identity core should surface preferences for a meta-question; got: \(labels)")
        XCTAssertTrue(labels.contains("Messi"))
    }

    func test_coreMemories_returns_identity_only() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        func node(_ id: String, _ kind: NodeKind, _ label: String, _ layer: MemoryLayer, _ sal: Double) -> Node {
            Node(id: id, kind: kind, label: label, body: label, layer: layer, createdAt: now, updatedAt: now,
                 lastSeenAt: now, salience: sal, decayRate: Decay.defaultDecayRate(for: layer), confidence: .sure,
                 mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil,
                 dirty: true, deleted: false, extra: nil)
        }
        try store.upsert(node("n1", .fact, "name Roilan", .identity, 8))
        try store.upsert(node("w1", .fact, "works at Amazon", .daily, 9)) // high salience but NOT identity
        let core = try store.coreMemories()
        XCTAssertTrue(core.contains { $0.id == "n1" })
        XCTAssertFalse(core.contains { $0.id == "w1" }, "core must be identity-only (no top-salience union)")
    }

    func testIdentityLayerAlwaysInCore() throws {
        let s = try store()
        try s.upsert(node("name", .fact, layer: .identity, salience: 8))
        let r = MemoryRetriever(store: s, embedder: nil)
        let got = try r.retrieve(query: "totally unrelated query xyz")
        XCTAssertTrue(got.contains { $0.label == "name" }, "identity-layer facts are always recalled")
    }
}
