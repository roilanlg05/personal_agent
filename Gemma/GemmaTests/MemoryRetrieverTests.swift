import XCTest
@testable import Gemma

/// Phase 3 Task 3.3 — hybrid retrieval (FTS + graph spreading-activation + ranking).
final class MemoryRetrieverTests: XCTestCase {
    private func store() throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: 4) }
    private func node(_ label: String, _ kind: NodeKind) -> Node {
        let now = Date().timeIntervalSince1970
        return Node(id: UUID().uuidString, kind: kind.rawValue, label: label, body: label, layer: .daily,
                    createdAt: now, updatedAt: now, lastSeenAt: now, salience: 5, decayRate: 0.0001,
                    confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                    origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
    }

    func testRetrievesByKeywordWithoutEmbedder() throws {
        let s = try store()
        try s.upsert(node("sushi", .preference))
        try s.upsert(node("pizza", .preference))
        let r = MemoryRetriever(store: s, embedder: nil)
        let got = try r.retrieve(query: "sushi", k: 5)
        XCTAssertTrue(got.contains { $0.label == "sushi" })
    }

    func testSpreadingActivationPullsNeighbors() throws {
        let s = try store()
        let juan = node("Juan", .person)
        let place = node("Tradzzy", .place)
        try s.upsert(juan)
        try s.upsert(place)
        try s.upsert(Edge(id: UUID().uuidString, srcId: juan.id, dstId: place.id, relation: .worksWith,
                          weight: 1, confidence: .probable, createdAt: 0, updatedAt: 0, dirty: true, deleted: false, extra: nil))
        let r = MemoryRetriever(store: s, embedder: nil)
        let got = try r.retrieve(query: "Juan", k: 5)
        XCTAssertTrue(got.contains { $0.label == "Tradzzy" })
    }

    func testInjectionBlockFormats() throws {
        let s = try store()
        let r = MemoryRetriever(store: s, embedder: nil)
        let block = r.injectionBlock(for: [node("sushi", .preference)])
        XCTAssertTrue(block.contains("sushi"))
        XCTAssertTrue(r.injectionBlock(for: []).isEmpty)
    }

    func testRanksWithFakeEmbedder() throws {
        let s = try store()
        let sushi = node("sushi", .preference)
        try s.upsert(sushi)
        try s.setEmbedding(nodeId: sushi.id, try FakeEmbedder(dimension: 4).embed("sushi"))
        let r = MemoryRetriever(store: s, embedder: FakeEmbedder(dimension: 4))
        let got = try r.retrieve(query: "sushi", k: 5)
        XCTAssertEqual(got.first?.label, "sushi")
    }
}
