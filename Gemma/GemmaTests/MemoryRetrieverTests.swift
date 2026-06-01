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

// MARK: - M2d-2 Task 4: injection block lists summaries before other nodes

final class MemoryRetrieverInjectionTests: XCTestCase {
    private func node(_ kind: String, _ label: String, _ body: String) -> Node {
        Node(id: UUID().uuidString, kind: kind, label: label, body: body, layer: .daily,
             createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0.1, confidence: .sure,
             mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
             dirty: true, deleted: false, extra: nil)
    }

    func test_injectionBlock_lists_summaries_before_facts() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let r = MemoryRetriever(store: store, embedder: nil)
        let nodes = [node("preference", "sushi", "likes sushi"),
                     node(NodeKind.summary.rawValue, "viaje a Japón", "Plan a trip to Japan")]
        let block = r.injectionBlock(for: nodes)
        let iSummary = try XCTUnwrap(block.range(of: "viaje a Japón"))
        let iFact = try XCTUnwrap(block.range(of: "sushi"))
        XCTAssertTrue(iSummary.lowerBound < iFact.lowerBound, "summary must appear before the plain fact")
    }
}
