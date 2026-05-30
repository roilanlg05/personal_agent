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
        try s.upsert(node("sushi", .preference))
        try s.upsert(node("Messi", .preference))
        let r = MemoryRetriever(store: s, embedder: nil)   // no embedder → pure non-vector path
        // The query shares NO keyword with the entity labels (sushi/Messi).
        let got = try r.retrieve(query: "sabes que me gusta")
        let labels = Set(got.map { $0.label })
        XCTAssertTrue(labels.contains("sushi"), "identity core should surface preferences for a meta-question; got: \(labels)")
        XCTAssertTrue(labels.contains("Messi"))
    }

    func testIdentityLayerAlwaysInCore() throws {
        let s = try store()
        try s.upsert(node("name", .fact, layer: .identity, salience: 8))
        let r = MemoryRetriever(store: s, embedder: nil)
        let got = try r.retrieve(query: "totally unrelated query xyz")
        XCTAssertTrue(got.contains { $0.label == "name" }, "identity-layer facts are always recalled")
    }
}
