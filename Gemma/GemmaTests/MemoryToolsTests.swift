import XCTest
@testable import Gemma

/// Keyword-stub embedder: maps any "messi"-bearing text to the SAME vector so distinct labels
/// ("Messi" vs "Lionel Messi", different dedupKeys) collide only via the semantic path.
private final class KeywordEmbedder: Embedder {
    let dimension = 4
    func embed(_ text: String) throws -> [Float] {
        text.lowercased().contains("messi") ? [1, 0, 0, 0] : [0, 0, 1, 0]
    }
}

@MainActor
final class MemoryToolsTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.store = nil
        MemoryToolbox.shared.embedder = nil
        super.tearDown()
    }

    func test_saveMemory_creates_identity_node_when_permanent() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.embedder = FakeEmbedder(dimension: 4)
        _ = await SaveMemoryTool().run(argsJSON: #"{"entity":"sushi","detail":"likes sushi","kind":"preference","permanent":true}"#)
        let nodes = try store.allNodes()
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].label, "sushi")
        XCTAssertEqual(nodes[0].layer, .identity)
        XCTAssertEqual(nodes[0].origin, .explicit)
    }

    func test_saveMemory_dedups_phrasing_variants() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.embedder = FakeEmbedder(dimension: 4)
        _ = await SaveMemoryTool().run(argsJSON: #"{"entity":"Messi","kind":"preference"}"#)
        _ = await SaveMemoryTool().run(argsJSON: #"{"entity":"Messi","detail":"favorite player","kind":"preference"}"#)
        let prefs = try store.allNodes().filter { $0.kind == .preference }
        XCTAssertEqual(prefs.count, 1, "same entity collapses (string dedup at minimum)")
        XCTAssertEqual(prefs.first?.mentionCount, 2)
    }

    func test_saveMemory_semantic_dedup_merges_distinct_phrasings() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.embedder = KeywordEmbedder()
        _ = await SaveMemoryTool().run(argsJSON: #"{"entity":"Messi","kind":"preference"}"#)
        _ = await SaveMemoryTool().run(argsJSON: #"{"entity":"Lionel Messi","kind":"preference"}"#) // different label, same keyword vector
        let prefs = try store.allNodes().filter { $0.kind == .preference }
        XCTAssertEqual(prefs.count, 1, "different phrasings with near embeddings collapse semantically")
        XCTAssertEqual(prefs.first?.mentionCount, 2)
    }

    func test_saveMemory_uses_detail_as_body() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.embedder = FakeEmbedder(dimension: 4)
        _ = await SaveMemoryTool().run(argsJSON: #"{"entity":"sushi","detail":"loves it for dinner","kind":"preference"}"#)
        let n = try store.allNodes().first
        XCTAssertEqual(n?.label, "sushi")
        XCTAssertEqual(n?.body, "loves it for dinner")
    }

    func test_saveMemory_body_falls_back_to_entity_when_no_detail() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.embedder = FakeEmbedder(dimension: 4)
        _ = await SaveMemoryTool().run(argsJSON: #"{"entity":"sushi","kind":"preference"}"#)
        let n = try store.allNodes().first
        XCTAssertEqual(n?.body, "sushi", "body falls back to entity when detail omitted")
    }

    func test_saveMemory_no_store_is_safe() async {
        let result = await SaveMemoryTool().run(argsJSON: #"{"entity":"x","kind":"fact"}"#)
        XCTAssertEqual(result, "memory unavailable")
    }

    func test_saveMemory_junk_entity_discarded() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        MemoryToolbox.shared.store = store
        _ = await SaveMemoryTool().run(argsJSON: #"{"entity":"me gusta","kind":"preference"}"#)
        XCTAssertTrue(try store.allNodes().isEmpty, "junk filler is not stored")
    }

    func test_forget_soft_deletes() async throws {
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
}
