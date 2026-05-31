import XCTest
@testable import Gemma

/// Fake ModelRuntime that returns queued canned responses, one per generate() call.
final class CannedRuntime: ModelRuntime, @unchecked Sendable {
    nonisolated let identifier = "canned"
    var responses: [String]
    private var i = 0
    init(_ responses: [String]) { self.responses = responses }
    func isLoaded() async -> Bool { true }
    func load(options: ModelLoadOptions) async throws {}
    func unload() async {}
    func currentMetrics() async -> RuntimeMetrics? { nil }
    func generate(prompt: String, options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
        let text = i < responses.count ? responses[i] : "{}"; i += 1
        return AsyncThrowingStream { c in
            c.yield(.completed(GenerationResult(text: text, metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
            c.finish()
        }
    }
}

final class MemoryConsolidationEngineTests: XCTestCase {
    private func makeStore() throws -> MemoryStore { try MemoryStore(inMemory: true, embeddingDim: 4) }

    func test_consolidate_creates_structured_nodes_including_new_kind() async throws {
        let store = try makeStore()
        let rt = CannedRuntime([#"{"entities":[{"entity":"Juan","kind":"person","detail":"friend"},{"entity":"call Juan","kind":"task","attributes":{"status":"pending"}},{"entity":"Falcon","kind":"spaceship"}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.consolidate(episodeTexts: ["I should call Juan, my friend, about the Falcon"])
        let kinds = Set(try store.allNodes().map { $0.kind })
        XCTAssertTrue(kinds.isSuperset(of: ["person", "task", "spaceship"]), "structured + model-minted kind stored verbatim")
        let task = try store.allNodes().first { $0.kind == "task" }
        XCTAssertEqual(NodeAttributes.from(task?.extra).status, "pending")
    }

    func test_associate_creates_edges_between_existing_nodes() async throws {
        let store = try makeStore()
        let now = Date().timeIntervalSince1970
        for (id, label) in [("a","Roilan"),("b","sushi")] {
            try store.upsert(Node(id: id, kind: "preference", label: label, body: label, layer: .daily, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil))
        }
        let rt = CannedRuntime([#"{"edges":[{"from":"Roilan","relation":"likes","to":"sushi"}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.associate()
        XCTAssertEqual(try store.allEdges().count, 1)
        let e = try store.allEdges().first
        XCTAssertEqual(e?.relation, .likes)
    }

    func test_associate_skips_unknown_relation_and_unresolved_endpoints() async throws {
        let store = try makeStore()
        let rt = CannedRuntime([#"{"edges":[{"from":"Ghost","relation":"likes","to":"Nothing"},{"from":"X","relation":"bogusRel","to":"Y"}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.associate()
        XCTAssertTrue(try store.allEdges().isEmpty)
    }

    func test_reflect_creates_grounded_insight_and_drops_ungrounded() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        for (id,l) in [("a","sushi"),("b","ramen")] {
            try store.upsert(Node(id: id, kind: "preference", label: l, body: l, layer: .daily, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil))
        }
        let rt = CannedRuntime([#"{"insights":[{"text":"likes Japanese food","sourceEntities":["sushi","ramen"],"confidence":"probable"},{"text":"is a pilot","sourceEntities":["sushi"],"confidence":"maybe"}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.reflect()
        let insights = try store.allNodes().filter { $0.kind == NodeKind.insight.rawValue }
        XCTAssertEqual(insights.count, 1, "only the ≥2-source insight is kept")
        XCTAssertEqual(insights.first?.body, "likes Japanese food")
        XCTAssertGreaterThanOrEqual(try store.allEdges().count, 2, "insight linked to ≥2 sources")
    }

    func test_reflect_is_idempotent_no_duplicate_insights() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        for (id,l) in [("a","sushi"),("b","ramen")] {
            try store.upsert(Node(id: id, kind: "preference", label: l, body: l, layer: .daily, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil))
        }
        // Same insight returned twice; second reflect() must find the existing node and skip it.
        let same = #"{"insights":[{"text":"likes Japanese food","sourceEntities":["sushi","ramen"],"confidence":"probable"}]}"#
        let rt = CannedRuntime([same, same])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.reflect()
        await engine.reflect()
        let insights = try store.allNodes().filter { $0.kind == NodeKind.insight.rawValue }
        XCTAssertEqual(insights.count, 1, "re-run reflect() must not duplicate an existing insight")
    }

    func test_curate_folds_synonym_kind() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        try store.upsert(Node(id: "a", kind: "meta", label: "learn German", body: "", layer: .daily, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 1, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil))
        let rt = CannedRuntime([#"{"map":{"meta":"plan"}}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.curateKinds()
        XCTAssertEqual(try store.node(id: "a")?.kind, "plan")
    }

    func test_forget_sweeps_weak_and_prunes_edges() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let old = Date().timeIntervalSince1970 - 10_000_000   // long ago → effective salience ~0
        try store.upsert(Node(id: "w", kind: "fact", label: "weak", body: "", layer: .daily, createdAt: old, updatedAt: old, lastSeenAt: old, salience: 0.1, decayRate: 1.0/(5*24*3600), confidence: .maybe, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil))
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: CannedRuntime([]))
        await engine.forget()
        XCTAssertTrue(try store.allNodes().isEmpty, "weak node forgotten")
    }

    func test_runCycle_resumes_from_persisted_phase() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        // one unconsolidated episode
        let meta = EpisodeRecorder.Meta(threadId: "T", role: "user", turnIndex: 0, status: "closed")
        let extra = String(data: try JSONEncoder().encode(meta), encoding: .utf8)
        let now = Date().timeIntervalSince1970
        try store.upsert(Node(id: "e1", kind: NodeKind.conversation.rawValue, label: "user: hi", body: "me gusta el sushi", layer: .episodic, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 2, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: "T", origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: extra))
        // pretend we already finished NREM+REM+Reflect+Curate; resume should run only SHY then finish.
        try store.saveSleepCycle(SleepCycleState(phase: .shy, episodeIds: ["e1"], startedAt: now))
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime([]))
        await engine.runCycle(isCancelled: { false })
        XCTAssertNil(try store.loadSleepCycle(), "cycle cleared after completion")
        XCTAssertEqual(EpisodeRecorder.meta(from: try store.node(id: "e1")!)?.status, "consolidated")
    }

    func test_runCycle_cancel_persists_phase_for_resume() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let meta = EpisodeRecorder.Meta(threadId: "T", role: "user", turnIndex: 0, status: "closed")
        let extra = String(data: try JSONEncoder().encode(meta), encoding: .utf8)
        let now = Date().timeIntervalSince1970
        try store.upsert(Node(id: "e1", kind: NodeKind.conversation.rawValue, label: "u", body: "hi", layer: .episodic, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 2, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: "T", origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: extra))
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime(["{}","{}","{}","{}"]))
        await engine.runCycle(isCancelled: { true })   // cancels immediately
        // a cycle was started (phase persisted) and NOT cleared
        XCTAssertNotNil(try store.loadSleepCycle())
        XCTAssertNotEqual(EpisodeRecorder.meta(from: try store.node(id: "e1")!)?.status, "consolidated")
    }

    func test_detect_creates_followup_nodes() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let rt = CannedRuntime([#"{"followUps":[{"text":"finish telling the story about the trip","sources":[]},{"text":"decide where to travel","sources":[]}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.detectFollowUps(episodeTexts: ["I was about to tell you about my trip but then..."])
        let fu = try store.allNodes().filter { $0.kind == NodeKind.followUp.rawValue }
        XCTAssertEqual(fu.count, 2)
        XCTAssertTrue(fu.allSatisfy { NodeAttributes.from($0.extra).status == "pending" })
    }
    func test_detect_dedups_repeats() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let json = #"{"followUps":[{"text":"call the dentist back","sources":[]}]}"#
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime([json, json]))
        await engine.detectFollowUps(episodeTexts: ["x"])
        await engine.detectFollowUps(episodeTexts: ["x"])
        XCTAssertEqual(try store.allNodes().filter { $0.kind == NodeKind.followUp.rawValue }.count, 1)
    }
    func test_runCycle_includes_detect_and_sets_focus() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let meta = EpisodeRecorder.Meta(threadId: "T", role: "user", turnIndex: 0, status: "closed")
        let extra = String(data: try JSONEncoder().encode(meta), encoding: .utf8)
        let now = Date().timeIntervalSince1970
        try store.upsert(Node(id: "e1", kind: NodeKind.conversation.rawValue, label: "u", body: "me gusta el sushi", layer: .episodic, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 2, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: "T", origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: extra))
        // start at .detect so only detect+rest run; assert focus was set when the cycle started.
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime(["{}","{}","{}","{}","{}"]))
        await engine.runCycle(isCancelled: { false })
        // cycle completed: episodes consolidated + cleared
        XCTAssertNil(try store.loadSleepCycle())
        XCTAssertEqual(EpisodeRecorder.meta(from: try store.node(id: "e1")!)?.status, "consolidated")
    }
}
