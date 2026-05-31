# M2b-2 — Consolidation system Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a brain-like consolidation system — extensible structured memory kinds, awake light reflection (agentic tool + auto short-pause), and a resumable 5-phase idle "sleep" cycle (consolidate → associate → reflect → curate → forget) — on top of M2b-1.

**Architecture:** A new `MemoryConsolidationEngine` holds the phase operations (LLM via `ModelRuntime.generate`, applied through the M2b-1 `MemoryStore`/`upsertMergingSemantic`/`sweep`). A `ConsolidationScheduler` (`@MainActor @Observable`) drives two tiers — awake (light, recent scope) and sleep (full cycle, resumable via a persisted `sleep_cycle`) — yielding to the user at phase boundaries. `Node.kind` becomes a free-form `String` so the model can mint new kinds; the Curate phase folds synonyms.

**Tech Stack:** Swift, SwiftUI, XCTest, GRDB, Apple NaturalLanguage. macOS app + local mlx-lm Gemma 4 26B.

## Spec
`docs/superpowers/specs/2026-05-31-m2b-2-sleep-consolidation-design.md`. Vision: `docs/superpowers/specs/2026-05-31-sleep-consolidation-vision.md`.

## Conventions
- Build/test on macOS, ABSOLUTE project path: `xcodebuild test -scheme Gemma -project /Users/hashdown/Projects/personal_agent/Gemma/Gemma.xcodeproj -destination 'platform=macOS'`. Success = "TEST SUCCEEDED" / "BUILD SUCCEEDED".
- New `.swift` files auto-add to the target. No pbxproj edits for Swift files. SourceKit "No such module"/"Cannot find type" diagnostics are spurious if xcodebuild succeeds.
- `@MainActor` XCTest classes MUST use `async` test methods (sync ones crash on deinit under XCTMemoryChecker on macOS 26).
- LLM phases use `runtime.generate(prompt:options:)` and parse JSON with a shared `extractJSON` (outermost `{...}`). Unit tests inject a FAKE `ModelRuntime` returning canned JSON — never hit the real server.
- Commit after each task with the trailer (blank line then): `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Commit only task files; never the unrelated dirty files (graphify-out, logs.txt, .gitignore, CLAUDE.md, Xcode user state). Run `graphify update .` after code changes (ignore errors).

## Current state (verified APIs from M2b-1)
- `Node` (`Memory/MemoryModels.swift`): fields incl. `var kind: NodeKind` (CHANGING to `String` in Task 1), `label, body, layer:MemoryLayer, salience, decayRate, confidence:Confidence{sure,probable,maybe}, mentionCount, origin:Origin{explicit,extracted}, extra:String?`, etc. `Edge{id,srcId,dstId,relation:Relation,weight,confidence,...}`. `enum NodeKind: String {person,place,fact,preference,topic,day,episode,conversation}`. `enum Relation {knows,worksWith,family,likes,dislikes,locatedAt,visited,happenedOn,mentionedIn,partOfEpisode,relatedTo}`.
- `MemoryStore` (`nonisolated final class`): `init(url:inMemory:embeddingDim:)`, `upsert(Node)`, `upsert(Edge)`, `node(id:)`, `allNodes(includeDeleted:)`, `allEdges()`, `edges(from:)`, `coreMemories(limit:)`, `softDelete(nodeId:)`, `searchFTS(query:limit:)`, `nearest(to:k:)`, `setEmbedding(nodeId:_:)`, `defaultURL()`. Migrator currently has one migration `"v1-core"`.
- Dedup (`MemoryStore+Dedup.swift`): `findDuplicate(kind:label:)`, `findSemanticDuplicate(kind:embedding:threshold:)`, `upsertMergingSemantic(_:embedding:embedder:threshold:0.2)`, `upsertMerging(_:)`, `sweep(now:)`, private `mergeReinforced(existing:candidate:)`.
- `Decay`: `beta(for:)`, `reinforceEMA(current:signal:beta:cap:)`, `effectiveSalience`, `shouldPromote`, `shouldForget`, `defaultDecayRate(for:)`.
- `Embedder` protocol (`dimension`, `embed`), `FakeEmbedder(dimension:)`, `NLContextualEmbedder()`.
- `MemoryText`: `cleanLabel`, `dedupKey`, `isJunkLabel`.
- `SaveMemoryTool` (`Memory/SaveMemoryTool.swift`): `AgentTool` `save_memory`, builds a `Node` with `NodeKind(rawValue: kind) ?? .fact` (CHANGING in Task 1) + `upsertMergingSemantic`.
- `EpisodeRecorder` (`Memory/EpisodeRecorder.swift`): `Meta{threadId,role,turnIndex,status}` JSON in `Node.extra`; `record(...)`, `meta(from:)`.
- `Agent` (`Agent/Agent.swift`): `MemoryServices{retriever}`; tool loop; `systemPrompt` base mentions `save_memory`.
- `HarnessModel`: owns `serverManager`, `runtime: ModelRuntime & ToolCallingRuntime`, `runAgentTurn`, `ensureMemory()`, `threadId`, `turnIndex`; registers `CurrentTimeTool`+`SaveMemoryTool`+`ForgetTool` when memory on.
- `AgentTool` protocol; `ToolActivityRelay.shared`; `MemoryToolbox.shared{store,embedder}`.
- `AgentChatView`: server banner + Send gating + Memory sheet (`MemoryView` → list/graph). `MemoryGraphView` colors nodes by kind (exhaustive `switch` over `NodeKind` — CHANGING to handle free-form String in Task 7).

## File structure (after M2b-2)
**New:** `Memory/NodeAttributes.swift`, `Memory/MemoryConsolidationEngine.swift` (+ `SleepPhase`/`SleepCycleState`), `Memory/ConsolidationScheduler.swift`, `Memory/ReflectTool.swift`. Tests: `NodeKindStringTests`, `NodeAttributesTests`, `MemoryStoreSleepTests`, `MemoryConsolidationEngineTests`, `ConsolidationSchedulerTests`, `ReflectToolTests`.
**Modified:** `Memory/MemoryModels.swift`, `Memory/MemoryStore.swift`, `Memory/MemoryStore+Dedup.swift`, `Memory/SaveMemoryTool.swift`, `Memory/MemoryRetriever.swift`, `Memory/EpisodeRecorder.swift` (only if it referenced `NodeKind` type), `Agent/Agent.swift`, `Harness/HarnessModel.swift`, `Harness/AgentChatView.swift`, `Harness/MemoryGraphView.swift`.

---

## Task 1: `Node.kind` → free-form `String` + curated constants + new kinds

Make `kind` a `String` so the model can mint new kinds (stored verbatim), while keeping `enum NodeKind: String` as the curated vocabulary of constants (adding `trait`, `task`, `plan`, `insight`).

**Files:** Modify `Memory/MemoryModels.swift`, `Memory/MemoryStore+Dedup.swift`, `Memory/SaveMemoryTool.swift`, `Memory/MemoryRetriever.swift` (only if it pattern-matches `NodeKind`), and any code/tests constructing `Node(kind:)`. Test `GemmaTests/NodeKindStringTests.swift`.

- [ ] **Step 1: Write the failing test** `GemmaTests/NodeKindStringTests.swift`:
```swift
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
```

- [ ] **Step 2: Run → fail** (`-only-testing:GemmaTests/NodeKindStringTests`): `Node(kind:)` currently wants `NodeKind`, not `String`.

- [ ] **Step 3: Edit `Memory/MemoryModels.swift`:**
  - Change `struct Node`'s field `var kind: NodeKind` → `var kind: String`.
  - Add the new cases to the enum (kept as a constants vocabulary): `enum NodeKind: String, Codable, CaseIterable { case person, place, fact, preference, topic, trait, task, plan, insight, day, episode, conversation }`.
  - (GRDB stores `kind` as TEXT already; `String` round-trips with no migration.)

- [ ] **Step 4: Fix all `Node(kind:)` construction + kind comparisons to use `String`.** Grep `grep -rn "kind:" Gemma/Gemma/Memory Gemma/Gemma/Harness Gemma/GemmaTests | grep -i node` and update:
  - `SaveMemoryTool.swift`: replace `let k = NodeKind(rawValue: kind) ?? .fact` + `kind: k` with `let k = kind.isEmpty ? NodeKind.fact.rawValue : kind` and `kind: k` (preserve the model's kind verbatim; default to `"fact"` only when empty).
  - `MemoryStore+Dedup.swift`: `findDuplicate(kind: NodeKind, ...)` and `findSemanticDuplicate(kind: NodeKind, ...)` → change the param type to `String`; the body compares `Column("kind") == kind` / `n.kind == kind` (now String). `upsertMergingSemantic`/`upsertMerging`/`mergeReinforced` pass `candidate.kind` (now String) — works unchanged.
  - `EpisodeRecorder.swift`: uses `kind: .conversation` → change to `kind: NodeKind.conversation.rawValue`.
  - Any test constructing `Node(kind: .something)` → `Node(kind: NodeKind.something.rawValue, ...)` OR a literal string. Update all (grep `Node(` in tests).
  - `MemoryRetriever.swift`: if it references `n.kind.rawValue` for the injection block, change to `n.kind` (already a String). The block line `"- [\($0.kind.rawValue)] ..."` → `"- [\($0.kind)] ..."`.

- [ ] **Step 5: Run → pass** (`-only-testing:GemmaTests/NodeKindStringTests`). Then build the whole app + run the memory suite to catch every call site:
```bash
xcodebuild build -scheme Gemma -project /Users/hashdown/Projects/personal_agent/Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -5
xcodebuild test -scheme Gemma -project /Users/hashdown/Projects/personal_agent/Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryStoreTests -only-testing:GemmaTests/MemoryStoreDedupTests -only-testing:GemmaTests/MemoryToolsTests -only-testing:GemmaTests/MemoryRetrieverTests -only-testing:GemmaTests/MemoryCoreRecallTests -only-testing:GemmaTests/EpisodeRecorderTests -only-testing:GemmaTests/NodeKindStringTests 2>&1 | tail -15
```
Expected: BUILD SUCCEEDED, TEST SUCCEEDED. Fix any remaining `NodeKind`-as-type usages the compiler flags (they should all become `String` field access or `NodeKind.x.rawValue` constants).

- [ ] **Step 6: Commit** `git add -A && git commit -m "refactor(m2b-2): Node.kind is free-form String + trait/task/plan/insight kinds"`

---

## Task 2: `NodeAttributes` — structured attrs (status/horizon) in `extra`

`task` nodes carry `status` (pending/done), `plan` nodes carry `horizon` (short/long). Store them in `Node.extra` JSON, coexisting with `EpisodeRecorder.Meta`.

**Files:** Create `Memory/NodeAttributes.swift`, Test `GemmaTests/NodeAttributesTests.swift`.

- [ ] **Step 1: Write the failing test** `GemmaTests/NodeAttributesTests.swift`:
```swift
import XCTest
@testable import Gemma

final class NodeAttributesTests: XCTestCase {
    func test_round_trip_status_and_horizon() {
        var a = NodeAttributes()
        a.status = "pending"; a.horizon = "long"
        let json = a.toJSON()
        let back = NodeAttributes.from(json)
        XCTAssertEqual(back.status, "pending")
        XCTAssertEqual(back.horizon, "long")
    }
    func test_from_nil_or_garbage_is_empty() {
        XCTAssertNil(NodeAttributes.from(nil).status)
        XCTAssertNil(NodeAttributes.from("not json").horizon)
    }
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement** `Memory/NodeAttributes.swift`:
```swift
import Foundation

/// Optional structured attributes for a memory node, stored as JSON in `Node.extra`.
/// `task` uses `status` (pending|done); `plan` uses `horizon` (short|long). Extensible:
/// unknown keys are ignored. (Episode metadata uses its own `EpisodeRecorder.Meta` JSON; a
/// node is either an episode or a structured fact, so the two never share one `extra`.)
struct NodeAttributes: Codable {
    var status: String?     // task: "pending" | "done"
    var horizon: String?    // plan: "short" | "long"

    func toJSON() -> String? {
        guard status != nil || horizon != nil else { return nil }
        return (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func from(_ extra: String?) -> NodeAttributes {
        guard let s = extra, let d = s.data(using: .utf8),
              let a = try? JSONDecoder().decode(NodeAttributes.self, from: d) else { return NodeAttributes() }
        return a
    }
}
```

- [ ] **Step 4: Run → pass; Commit** `git add -A && git commit -m "feat(m2b-2): NodeAttributes (task status / plan horizon in extra)"`

---

## Task 3: `MemoryStore` additions — sleep_cycle migration + helpers

**Files:** Modify `Memory/MemoryStore.swift`. Test `GemmaTests/MemoryStoreSleepTests.swift`.

- [ ] **Step 1: Write the failing tests** `GemmaTests/MemoryStoreSleepTests.swift`:
```swift
import XCTest
@testable import Gemma

final class MemoryStoreSleepTests: XCTestCase {
    private func ep(_ id: String, _ threadId: String, _ status: String) -> Node {
        let now = Date().timeIntervalSince1970
        let meta = EpisodeRecorder.Meta(threadId: threadId, role: "user", turnIndex: 0, status: status)
        let extra = (try? JSONEncoder().encode(meta)).flatMap { String(data: $0, encoding: .utf8) }
        return Node(id: id, kind: NodeKind.conversation.rawValue, label: "user: hi", body: "hi", layer: .episodic,
                    createdAt: now, updatedAt: now, lastSeenAt: now, salience: 2, decayRate: 0.001,
                    confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: threadId,
                    origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: extra)
    }

    func test_sleep_cycle_round_trip_and_clear() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        XCTAssertNil(try store.loadSleepCycle())
        try store.saveSleepCycle(SleepCycleState(phase: .rem, episodeIds: ["a","b"], startedAt: 123))
        let s = try store.loadSleepCycle()
        XCTAssertEqual(s?.phase, .rem)
        XCTAssertEqual(s?.episodeIds, ["a","b"])
        try store.clearSleepCycle()
        XCTAssertNil(try store.loadSleepCycle())
    }

    func test_unconsolidated_episodes_and_mark() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        try store.upsert(ep("e1", "T", "closed"))
        try store.upsert(ep("e2", "T", "consolidated"))
        XCTAssertEqual(try store.unconsolidatedEpisodes().map { $0.id }, ["e1"])
        try store.markEpisodesConsolidated(ids: ["e1"])
        XCTAssertTrue(try store.unconsolidatedEpisodes().isEmpty)
    }

    func test_distinct_kinds_and_reassign() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        func n(_ id: String, _ kind: String) -> Node {
            Node(id: id, kind: kind, label: id, body: "", layer: .daily, createdAt: now, updatedAt: now,
                 lastSeenAt: now, salience: 1, decayRate: 0.001, confidence: .sure, mentionCount: 1,
                 ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil)
        }
        try store.upsert(n("a", "meta")); try store.upsert(n("b", "plan"))
        XCTAssertEqual(Set(try store.distinctKinds()), Set(["meta", "plan"]))
        try store.reassignKind(from: "meta", to: "plan")
        XCTAssertEqual(try store.node(id: "a")?.kind, "plan")
        XCTAssertFalse(try store.distinctKinds().contains("meta"))
    }

    func test_prune_dangling_edges() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        func n(_ id: String) -> Node { Node(id: id, kind: "fact", label: id, body: "", layer: .daily, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 1, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil) }
        try store.upsert(n("a")); try store.upsert(n("b"))
        try store.upsert(Edge(id: "e", srcId: "a", dstId: "b", relation: .relatedTo, weight: 1, confidence: .sure, createdAt: now, updatedAt: now, dirty: true, deleted: false, extra: nil))
        try store.softDelete(nodeId: "b")
        try store.pruneDanglingEdges()
        XCTAssertTrue(try store.allEdges().isEmpty, "edge to a deleted node is pruned")
    }
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement.** In `Memory/MemoryStore.swift`:
  - **Add `SleepPhase` + `SleepCycleState`** (top of file or a small types file):
```swift
enum SleepPhase: String, Codable, CaseIterable { case nrem, rem, reflect, curate, shy }
struct SleepCycleState: Equatable { var phase: SleepPhase; var episodeIds: [String]; var startedAt: Double }
```
  - **Add the migration** — in the `migrator` computed property, after the `v1-core` migration register:
```swift
        m.registerMigration("v2-sleep") { db in
            try db.create(table: "sleep_cycle") { t in
                t.primaryKey("id", .integer)         // always 1
                t.column("phase", .text).notNull()
                t.column("episodeIds", .text).notNull()  // JSON array
                t.column("startedAt", .double).notNull()
            }
        }
```
  - **Add helpers** (in `MemoryStore` or an extension):
```swift
    func loadSleepCycle() throws -> SleepCycleState? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT phase, episodeIds, startedAt FROM sleep_cycle WHERE id=1") else { return nil }
            guard let phase = SleepPhase(rawValue: row["phase"]) else { return nil }
            let ids = (try? JSONDecoder().decode([String].self, from: Data((row["episodeIds"] as String).utf8))) ?? []
            return SleepCycleState(phase: phase, episodeIds: ids, startedAt: row["startedAt"])
        }
    }
    func saveSleepCycle(_ s: SleepCycleState) throws {
        let ids = String(data: (try? JSONEncoder().encode(s.episodeIds)) ?? Data(), encoding: .utf8) ?? "[]"
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO sleep_cycle(id, phase, episodeIds, startedAt) VALUES (1, ?, ?, ?)",
                           arguments: [s.phase.rawValue, ids, s.startedAt])
        }
    }
    func clearSleepCycle() throws { try dbQueue.write { try $0.execute(sql: "DELETE FROM sleep_cycle WHERE id=1") } }

    /// Episodic conversation nodes not yet consolidated (per EpisodeRecorder.Meta.status).
    func unconsolidatedEpisodes() throws -> [Node] {
        try allNodes().filter { $0.kind == NodeKind.conversation.rawValue
            && (EpisodeRecorder.meta(from: $0)?.status ?? "closed") != "consolidated" }
    }
    func markEpisodesConsolidated(ids: [String]) throws {
        for id in ids {
            guard var n = try node(id: id), var meta = EpisodeRecorder.meta(from: n) else { continue }
            meta.status = "consolidated"
            n.extra = (try? JSONEncoder().encode(meta)).flatMap { String(data: $0, encoding: .utf8) }
            n.updatedAt = Date().timeIntervalSince1970; n.dirty = true
            try upsert(n)
        }
    }
    func distinctKinds() throws -> [String] {
        try dbQueue.read { try String.fetchAll($0, sql: "SELECT DISTINCT kind FROM node WHERE deleted=0") }
    }
    func reassignKind(from: String, to: String) throws {
        try dbQueue.write { try $0.execute(sql: "UPDATE node SET kind=?, dirty=1, updatedAt=? WHERE kind=? AND deleted=0",
                                           arguments: [to, Date().timeIntervalSince1970, from]) }
    }
    /// Soft-delete edges whose endpoints are deleted/missing.
    func pruneDanglingEdges() throws {
        let live = Set(try allNodes().map { $0.id })
        for e in try allEdges() where !(live.contains(e.srcId) && live.contains(e.dstId)) {
            try dbQueue.write { try $0.execute(sql: "UPDATE edge SET deleted=1, dirty=1, updatedAt=? WHERE id=?",
                                               arguments: [Date().timeIntervalSince1970, e.id]) }
        }
    }
```
  > `EpisodeRecorder.meta(from:)` and `Meta` already exist (M2b-1) and are reused here. `meta.status` is `var` (settable).

- [ ] **Step 4: Run → pass** (`-only-testing:GemmaTests/MemoryStoreSleepTests`).

- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(m2b-2): MemoryStore sleep_cycle persistence + episode/kind/edge consolidation helpers"`

---

## Task 4: `MemoryConsolidationEngine` — Consolidate + Associate phases

**Files:** Create `Memory/MemoryConsolidationEngine.swift`, Test `GemmaTests/MemoryConsolidationEngineTests.swift`.

- [ ] **Step 1: Write the failing tests** (fake runtime returns canned JSON):
```swift
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
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement** `Memory/MemoryConsolidationEngine.swift` (Consolidate + Associate; Reflect/Curate/Forget added in Task 5):
```swift
import Foundation

/// Brain-like consolidation operations over the memory graph, driven by the local model.
/// Phases are independent units (testable with a fake runtime). The cycle driver (runCycle)
/// and the awake-light path are added in later tasks; this file holds the phase operations.
nonisolated final class MemoryConsolidationEngine {
    private let store: MemoryStore
    private let embedder: Embedder?
    private let runtime: ModelRuntime
    private let now: () -> Double
    var onProgress: ((String) -> Void)?   // e.g. "+2 entities", "+1 edge"

    init(store: MemoryStore, embedder: Embedder?, runtime: ModelRuntime,
         now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.store = store; self.embedder = embedder; self.runtime = runtime; self.now = now
    }

    // MARK: shared

    /// Run one plain-text generation and return its full text.
    private func generate(_ prompt: String, maxTokens: Int = 512) async -> String {
        var out = ""
        let stream = await runtime.generate(prompt: prompt,
                                            options: GenerationOptions(maxTokens: maxTokens, temperature: 0.3))
        do { for try await e in stream {
            if case .token(let t) = e { out += t }
            if case .completed(let r) = e, out.isEmpty { out = r.text }
        } } catch { return "" }
        return out
    }

    /// Outermost {...} JSON object from noisy model output.
    static func extractJSON(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        return String(s[a...b])
    }
    private func parse<T: Decodable>(_ raw: String, _ type: T.Type) -> T? {
        guard let j = Self.extractJSON(raw), let d = j.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    // MARK: NREM — Consolidate

    private struct EntitiesOut: Decodable {
        struct E: Decodable { let entity: String; let kind: String?; let detail: String?; let permanent: Bool?
            struct Attr: Decodable { let status: String?; let horizon: String? }
            let attributes: Attr? }
        let entities: [E]
    }

    func consolidate(episodeTexts: [String]) async {
        guard !episodeTexts.isEmpty else { return }
        let convo = episodeTexts.joined(separator: "\n")
        let prompt = """
        Extract durable facts the USER stated about themselves from this conversation. Output JSON only.
        Use a short canonical `entity` (a noun/name, not a sentence). Choose a `kind`: person, place, \
        preference, fact, trait (personality), task (something to do — set attributes.status "pending"), \
        plan (an intention — set attributes.horizon "short" or "long"), or another short lowercase kind if \
        none fit. Put context in `detail`. Never invent; only what the user actually stated.
        Schema: {"entities":[{"entity":"...","kind":"...","detail":"...","permanent":false,"attributes":{"status":"pending|done","horizon":"short|long"}}]}
        Conversation:
        \(convo)
        JSON:
        """
        guard let out = parse(await generate(prompt), EntitiesOut.self) else { return }
        var added = 0
        for e in out.entities {
            let label = MemoryText.cleanLabel(e.entity)
            if MemoryText.isJunkLabel(label) { continue }
            let kind = (e.kind?.isEmpty == false) ? e.kind! : NodeKind.fact.rawValue
            let layer: MemoryLayer = (e.permanent ?? false) ? .identity : .daily
            var attrs = NodeAttributes(); attrs.status = e.attributes?.status; attrs.horizon = e.attributes?.horizon
            let t = now()
            let node = Node(id: UUID().uuidString, kind: kind, label: label, body: e.detail ?? label, layer: layer,
                            createdAt: t, updatedAt: t, lastSeenAt: t, salience: (e.permanent ?? false) ? 8 : 3,
                            decayRate: Decay.defaultDecayRate(for: layer), confidence: .probable, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                            dirty: true, deleted: false, extra: attrs.toJSON())
            let emb = (try? embedder?.embed(label)) ?? nil
            if (try? store.upsertMergingSemantic(node, embedding: emb, embedder: embedder)) != nil { added += 1 }
        }
        onProgress?("+\(added) entities")
    }

    // MARK: REM — Associate

    private struct EdgesOut: Decodable { struct E: Decodable { let from: String; let relation: String; let to: String }; let edges: [E] }

    func associate() async {
        let nodes = (try? store.allNodes().filter { $0.kind != NodeKind.conversation.rawValue }) ?? []
        guard nodes.count >= 2 else { return }
        let labels = nodes.prefix(60).map { "\($0.kind): \($0.label)" }.joined(separator: "\n")
        let relations = Relation.allCases.map { $0.rawValue }.joined(separator: ", ")
        let prompt = """
        Given these memory entities, propose meaningful relationships between them. Output JSON only.
        Use ONLY these relation types: \(relations). Only connect entities that are genuinely related; \
        do not invent entities. Schema: {"edges":[{"from":"<entity label>","relation":"<one of the types>","to":"<entity label>"}]}
        Entities:
        \(labels)
        JSON:
        """
        guard let out = parse(await generate(prompt), EdgesOut.self) else { return }
        func resolve(_ label: String) -> Node? {
            let key = MemoryText.dedupKey(label)
            if let n = nodes.first(where: { MemoryText.dedupKey($0.label) == key }) { return n }
            if let emb = (try? embedder?.embed(label)) ?? nil,
               let hit = (try? store.nearest(to: emb, k: 1))?.first, hit.distance <= 0.25 {
                return try? store.node(id: hit.id)
            }
            return nil
        }
        let existing = Set((try? store.allEdges())?.map { "\($0.srcId)|\($0.relation.rawValue)|\($0.dstId)" } ?? [])
        var added = 0
        for e in out.edges {
            guard let rel = Relation(rawValue: e.relation), let s = resolve(e.from), let d = resolve(e.to), s.id != d.id else { continue }
            let key = "\(s.id)|\(rel.rawValue)|\(d.id)"
            if existing.contains(key) { continue }
            let t = now()
            try? store.upsert(Edge(id: UUID().uuidString, srcId: s.id, dstId: d.id, relation: rel, weight: 1,
                                   confidence: .probable, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
            added += 1
        }
        onProgress?("+\(added) connections")
    }
}
```

- [ ] **Step 4: Run → pass** (`-only-testing:GemmaTests/MemoryConsolidationEngineTests`).

- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(m2b-2): consolidation engine — Consolidate (NREM) + Associate (REM) phases"`

---

## Task 5: Engine — Reflect + Curate + Forget phases, and the resumable `runCycle`

**Files:** Modify `Memory/MemoryConsolidationEngine.swift`. Modify `GemmaTests/MemoryConsolidationEngineTests.swift`.

- [ ] **Step 1: Add failing tests:**
```swift
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
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement** — append to `MemoryConsolidationEngine`:
```swift
    // MARK: Reflect — Abstract (grounded insights)
    private struct InsightsOut: Decodable { struct I: Decodable { let text: String; let sourceEntities: [String]; let confidence: String? }; let insights: [I] }

    func reflect() async {
        let nodes = (try? store.allNodes().filter { $0.kind != NodeKind.conversation.rawValue && $0.kind != NodeKind.insight.rawValue }) ?? []
        guard nodes.count >= 2 else { return }
        let labels = nodes.prefix(60).map { "\($0.kind): \($0.label)" }.joined(separator: "\n")
        let prompt = """
        From these memories about the user, infer a few higher-level insights. Output JSON only.
        Each insight MUST be grounded in at least TWO of the listed entities (cite their labels in \
        sourceEntities). Do not speculate beyond the evidence. Schema: \
        {"insights":[{"text":"...","sourceEntities":["label1","label2"],"confidence":"probable|maybe"}]}
        Memories:
        \(labels)
        JSON:
        """
        guard let out = parse(await generate(prompt), InsightsOut.self) else { return }
        func resolve(_ label: String) -> Node? {
            let key = MemoryText.dedupKey(label)
            return nodes.first { MemoryText.dedupKey($0.label) == key }
        }
        var added = 0
        for ins in out.insights {
            let sources = ins.sourceEntities.compactMap(resolve)
            if Set(sources.map { $0.id }).count < 2 { continue }   // anti-fabrication
            let t = now()
            let conf = Confidence(rawValue: ins.confidence ?? "probable") ?? .probable
            let node = Node(id: UUID().uuidString, kind: NodeKind.insight.rawValue, label: String(ins.text.prefix(60)),
                            body: ins.text, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3,
                            decayRate: Decay.defaultDecayRate(for: .daily), confidence: conf, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
            try? store.upsert(node)
            for s in sources {
                try? store.upsert(Edge(id: UUID().uuidString, srcId: node.id, dstId: s.id, relation: .relatedTo, weight: 1,
                                       confidence: conf, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
            }
            added += 1
        }
        onProgress?("+\(added) insights")
    }

    // MARK: Curate — fold synonym kinds into a canonical vocabulary
    private struct KindMapOut: Decodable { let map: [String: String] }

    func curateKinds() async {
        let known = NodeKind.allCases.map { $0.rawValue }
        let kinds = (try? store.distinctKinds()) ?? []
        let unknown = kinds.filter { !known.contains($0) }
        guard !unknown.isEmpty else { return }
        let prompt = """
        Map each non-standard memory kind to the closest STANDARD kind, or keep it if it's genuinely distinct. Output JSON only.
        Standard kinds: \(known.joined(separator: ", ")). Schema: {"map":{"<kind>":"<standard-or-same>"}}
        Kinds to map: \(unknown.joined(separator: ", "))
        JSON:
        """
        guard let out = parse(await generate(prompt, maxTokens: 256), KindMapOut.self) else { return }
        for (from, to) in out.map where from != to && !to.isEmpty {
            try? store.reassignKind(from: from, to: to)
        }
    }

    // MARK: SHY — Forget / downscale
    func forget() async {
        try? store.sweep()
        try? store.pruneDanglingEdges()
    }

    // MARK: Cycle driver (resumable). `@escaping` to match the ConsolidationRunning protocol (Task 6).
    func runCycle(isCancelled: @escaping () -> Bool) async {
        // Load or start a cycle.
        var state: SleepCycleState
        if let existing = try? store.loadSleepCycle() ?? nil {
            state = existing
        } else {
            let batch = ((try? store.unconsolidatedEpisodes()) ?? []).map { $0.id }
            guard !batch.isEmpty else { return }
            state = SleepCycleState(phase: .nrem, episodeIds: batch, startedAt: now())
            try? store.saveSleepCycle(state)
        }
        let order: [SleepPhase] = [.nrem, .rem, .reflect, .curate, .shy]
        guard let startIdx = order.firstIndex(of: state.phase) else { return }
        for phase in order[startIdx...] {
            if isCancelled() { return }   // leave persisted phase for resume
            switch phase {
            case .nrem:
                let texts = state.episodeIds.compactMap { (try? store.node(id: $0))?.body }
                await consolidate(episodeTexts: texts)
            case .rem: await associate()
            case .reflect: await reflect()
            case .curate: await curateKinds()
            case .shy: await forget()
            }
            // advance persisted phase (so resume skips this one)
            if let next = order.firstIndex(of: phase).map({ $0 + 1 }), next < order.count {
                state.phase = order[next]; try? store.saveSleepCycle(state)
            }
        }
        try? store.markEpisodesConsolidated(ids: state.episodeIds)
        try? store.clearSleepCycle()
        onProgress?("done")
    }

    /// Awake light reflection: associate + reflect over current memory, no replay/curate/forget.
    func runLight(isCancelled: @escaping () -> Bool) async {
        if isCancelled() { return }
        await associate()
        if isCancelled() { return }
        await reflect()
    }
```
> Note: `loadSleepCycle()` returns `SleepCycleState?`; the `?? nil` in `if let existing = try? ... ?? nil` flattens the `try?`-wrapped optional. Adjust to a clean `if let existing = (try? store.loadSleepCycle()) ?? nil { ... }` if the compiler prefers.

- [ ] **Step 4: Run → pass.** (Note `test_runCycle_resumes_from_persisted_phase` starts at `.shy`, so only `forget` runs — with `FakeEmbedder` and no weak nodes, it just sweeps the (recent, strong) episode? Episodes are layer `.episodic`; `Decay.shouldForget` for episodic with recent lastSeenAt + salience 2 stays above floor, so it survives — then gets marked consolidated. Verify this holds; if the episode is swept, raise its salience in the test seed.)

- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(m2b-2): engine Reflect/Curate/Forget phases + resumable runCycle + runLight"`

---

## Task 6: `ConsolidationScheduler` (awake + sleep timers) + `reflect` tool

**Files:** Create `Memory/ConsolidationScheduler.swift`, `Memory/ReflectTool.swift`. Tests `GemmaTests/ConsolidationSchedulerTests.swift`, `GemmaTests/ReflectToolTests.swift`.

- [ ] **Step 1: Write the failing scheduler test** (injected short delays + a spy engine via a protocol seam):
```swift
import XCTest
@testable import Gemma

@MainActor
final class ConsolidationSchedulerTests: XCTestCase {
    final class SpyRunner: ConsolidationRunning {
        var light = 0, cycle = 0
        func runLight(isCancelled: @escaping () -> Bool) async { light += 1 }
        func runCycle(isCancelled: @escaping () -> Bool) async { cycle += 1 }
    }
    func test_idle_fires_cycle_and_pause_fires_light() async throws {
        let spy = SpyRunner()
        let s = ConsolidationScheduler(runner: spy, isReady: { true },
                                       pauseInterval: .milliseconds(20), idleInterval: .milliseconds(60))
        s.noteUserActivity()
        try await Task.sleep(for: .milliseconds(40))   // past pause, before idle
        XCTAssertGreaterThanOrEqual(spy.light, 1)
        try await Task.sleep(for: .milliseconds(80))   // past idle
        XCTAssertGreaterThanOrEqual(spy.cycle, 1)
    }
    func test_activity_cancels_and_resets() async throws {
        let spy = SpyRunner()
        let s = ConsolidationScheduler(runner: spy, isReady: { true },
                                       pauseInterval: .milliseconds(50), idleInterval: .seconds(60))
        s.noteUserActivity()
        try await Task.sleep(for: .milliseconds(20))
        s.noteUserActivity()                            // reset before pause elapses
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(spy.light, 0, "pause timer was reset by activity")
    }
    func test_not_ready_does_not_fire() async throws {
        let spy = SpyRunner()
        let s = ConsolidationScheduler(runner: spy, isReady: { false },
                                       pauseInterval: .milliseconds(20), idleInterval: .milliseconds(40))
        s.noteUserActivity()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(spy.light + spy.cycle, 0)
    }
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement** `Memory/ConsolidationScheduler.swift`:
```swift
import Foundation
import Observation

/// Abstraction over the engine so the scheduler is testable with a spy.
protocol ConsolidationRunning: AnyObject {
    func runLight(isCancelled: @escaping () -> Bool) async
    func runCycle(isCancelled: @escaping () -> Bool) async
}

@MainActor
@Observable
final class ConsolidationScheduler {
    enum State: Equatable { case idle, reflecting, sleeping(String), done(String) }
    private(set) var state: State = .idle
    var lastSummary: String = ""

    @ObservationIgnored private let runner: ConsolidationRunning
    @ObservationIgnored private let isReady: () -> Bool
    @ObservationIgnored private let pauseInterval: Duration
    @ObservationIgnored private let idleInterval: Duration
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var cancelFlag = false

    init(runner: ConsolidationRunning, isReady: @escaping () -> Bool,
         pauseInterval: Duration = .seconds(15), idleInterval: Duration = .seconds(180)) {
        self.runner = runner; self.isReady = isReady
        self.pauseInterval = pauseInterval; self.idleInterval = idleInterval
    }

    /// Called at the START of every user turn: cancel any running consolidation + reset timers.
    func noteUserActivity() {
        cancelFlag = true
        running?.cancel(); running = nil
        pauseTask?.cancel(); idleTask?.cancel()
        state = .idle
        scheduleTimers()
    }

    func consolidateNow() { launch(light: false) }
    func requestLightReflection() { launch(light: true) }

    private func scheduleTimers() {
        pauseTask = Task { [weak self, pauseInterval] in
            try? await Task.sleep(for: pauseInterval)
            guard let self, !Task.isCancelled else { return }
            self.launch(light: true)
        }
        idleTask = Task { [weak self, idleInterval] in
            try? await Task.sleep(for: idleInterval)
            guard let self, !Task.isCancelled else { return }
            self.launch(light: false)
        }
    }

    private func launch(light: Bool) {
        guard isReady(), running == nil else { return }
        cancelFlag = false
        let isCancelled: @escaping () -> Bool = { [weak self] in self?.cancelFlag ?? true }
        state = light ? .reflecting : .sleeping("nrem")
        running = Task { [weak self, runner] in
            if light { await runner.runLight(isCancelled: isCancelled) }
            else { await runner.runCycle(isCancelled: isCancelled) }
            await MainActor.run {
                guard let self else { return }
                self.running = nil
                if self.state != .idle { self.state = .done(light ? "💭" : "🌙") }
            }
        }
    }
}
```
> The engine (`MemoryConsolidationEngine`) conforms to `ConsolidationRunning` — add `: ConsolidationRunning` to its declaration (its `runLight`/`runCycle` already match once you change their signatures to `isCancelled: @escaping () -> Bool`). Update Task 5's signatures to `@escaping () -> Bool` to match the protocol. For per-phase progress in `state`, the engine's `onProgress` can be wired by the scheduler to update `state = .sleeping(phase)` — keep this minimal; the test only checks counts.

- [ ] **Step 4: Run scheduler test → pass.**

- [ ] **Step 5: Write `ReflectTool` test** `GemmaTests/ReflectToolTests.swift`:
```swift
import XCTest
@testable import Gemma

@MainActor
final class ReflectToolTests: XCTestCase {
    override func tearDown() { MemoryToolbox.shared.reflectionRequest = nil; super.tearDown() }
    func test_reflect_tool_requests_light_reflection() async {
        var requested = false
        MemoryToolbox.shared.reflectionRequest = { requested = true }
        let out = await ReflectTool().run(argsJSON: "{}")
        XCTAssertTrue(requested)
        XCTAssertFalse(out.isEmpty)
    }
    func test_reflect_tool_no_handler_is_safe() async {
        let out = await ReflectTool().run(argsJSON: "{}")
        XCTAssertFalse(out.isEmpty)   // returns a benign ack, no crash
    }
}
```

- [ ] **Step 6: Implement** — add `var reflectionRequest: (() -> Void)?` to `MemoryToolbox` (`Memory/MemoryToolbox.swift`), and create `Memory/ReflectTool.swift`:
```swift
import Foundation

/// Lets the model choose to reflect while awake: enqueues a light reflection (associate + insight)
/// in the background. Returns immediately so the turn proceeds.
struct ReflectTool: AgentTool {
    static let name = "reflect"
    static let description = "Reflect on the recent conversation to connect and organize what you just learned about the user. Call this when something is worth noting or linking. It runs in the background; just acknowledge briefly."
    static let parameters: [AgentToolParam] = []
    func run(argsJSON: String) async -> String {
        await MainActor.run { MemoryToolbox.shared.reflectionRequest?() }
        return "Reflecting in the background."
    }
}
```

- [ ] **Step 7: Run → pass; Commit** `git add -A && git commit -m "feat(m2b-2): ConsolidationScheduler (awake+sleep timers) + reflect tool"`

---

## Task 7: Wiring (`HarnessModel`, `Agent` prompt) + UI (`AgentChatView`, `MemoryGraphView`)

**Files:** Modify `Harness/HarnessModel.swift`, `Agent/Agent.swift`, `Harness/AgentChatView.swift`, `Harness/MemoryGraphView.swift`.

- [ ] **Step 1: `HarnessModel`** — own the engine + scheduler; wire activity + the reflect tool. In `ensureMemory()` (after building `store`/`retriever`), build the engine + scheduler once and store them:
```swift
        // build once
        if consolidationScheduler == nil {
            let engine = MemoryConsolidationEngine(store: store, embedder: memoryEmbedder, runtime: runtime)
            let sched = ConsolidationScheduler(runner: engine, isReady: { [weak self] in self?.serverManager.state == .ready })
            MemoryToolbox.shared.reflectionRequest = { [weak sched] in sched?.requestLightReflection() }
            self.consolidationEngine = engine
            self.consolidationScheduler = sched
        }
```
  Add `@ObservationIgnored private var consolidationEngine: MemoryConsolidationEngine?` and `private(set) var consolidationScheduler: ConsolidationScheduler?` (observed, for the UI). In `runAgentTurn`: call `consolidationScheduler?.noteUserActivity()` at the very start; register `ReflectTool()` in the registry when `memory != nil`; after the turn ends, the scheduler's timers (reset by the next `noteUserActivity` or naturally) drive consolidation — also call `consolidationScheduler?.noteUserActivity()` once more at the end so the idle/pause countdown starts fresh from end-of-turn. Add `func consolidateNow() { consolidationScheduler?.consolidateNow() }`.

- [ ] **Step 2: `Agent` system prompt** — in `systemPrompt` base, add a sentence about structured kinds + reflect:
  append to the base string: `"Save people, places, preferences, personality traits, tasks (things to do), and plans as memories with save_memory. You may call reflect to connect what you've learned."`

- [ ] **Step 3: `AgentChatView`** — add a consolidation banner + a "Consolidar ahora" button. Add a computed view bound to `model.consolidationScheduler?.state`:
```swift
    @ViewBuilder private var consolidationBanner: some View {
        switch model.consolidationScheduler?.state {
        case .reflecting: Label("Reflexionando…", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
        case .sleeping(let phase): Label("Consolidando — \(phase)…", systemImage: "moon.stars").font(.caption).foregroundStyle(.secondary)
        case .done(let mark): Label("\(mark) memoria consolidada", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
        default: EmptyView()
        }
    }
```
  Place it just under `serverBanner`. Add a toolbar button: `Button { model.consolidateNow() } label: { Label("Consolidar", systemImage: "moon.zzz") }`.

- [ ] **Step 4: `MemoryGraphView`** — make the kind→color map handle free-form kinds. Replace the exhaustive `switch` over `NodeKind` (which no longer compiles against a `String` kind) with a string-keyed map that gives known kinds distinct colors and unknown kinds a stable fallback:
```swift
    static func color(for kind: String) -> Color {
        switch kind {
        case "person": return .blue
        case "place": return .green
        case "preference": return .orange
        case "fact": return .pink
        case "topic": return .purple
        case "trait": return .teal
        case "task": return .red
        case "plan": return .indigo
        case "insight": return .yellow
        case "conversation", "episode", "day": return .gray
        default: return .secondary   // model-minted kinds
        }
    }
```
  Update the legend to list the kinds actually present (it already filters to present kinds — just iterate the distinct `node.kind` strings instead of `NodeKind.allCases`).

- [ ] **Step 5: Build + full suite**
```bash
xcodebuild build -scheme Gemma -project /Users/hashdown/Projects/personal_agent/Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -5
xcodebuild test -scheme Gemma -project /Users/hashdown/Projects/personal_agent/Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -6
```
Expected: BUILD SUCCEEDED; TEST SUCCEEDED (live/E2E skip).

- [ ] **Step 6: `graphify update .`; Commit** `git add -A && git commit -m "feat(m2b-2): wire scheduler+reflect into HarnessModel/Agent + consolidation UI + free-form kind colors"`

---

## Task 8: Manual E2E on macOS + record

- [ ] **Step 1:** Run the app (⌘R; auto-launches server). Multi-turn conversation: state a fact, a preference, a person, **a task** ("recuérdame llamar a Juan mañana"), **a plan** ("este año quiero aprender alemán"). Optionally watch for the model calling `reflect`.
- [ ] **Step 2:** Click **"Consolidar"** (or wait idle ~3 min). Watch the banner cycle phases. Then open the Memory graph: confirm `task`/`plan`/`insight`/`trait` nodes (distinct colors), **associative edges** between related memories, and grounded insight nodes linked to ≥2 sources.
- [ ] **Step 3: Extensibility + curation:** if the model minted a non-standard kind, confirm it's stored (visible in the inspector) and that after a consolidation cycle the Curate phase folds obvious synonyms toward the standard vocabulary.
- [ ] **Step 4: Resume:** start a consolidation, send a message mid-cycle → it cancels; next idle/Consolidar resumes from the next phase (no duplicate work; episodes only marked consolidated at the end).
- [ ] **Step 5: Record** in `[[macos-mlx-pivot]]` (M2b-2 done) + a §note in the M2b-2 spec. Commit docs.

**M2b-2 DONE:** memory self-organizes — structured/extensible kinds, awake reflection, and a resumable multi-phase sleep cycle that associates, abstracts, curates, and forgets.

---

## Testing Strategy
- **Unit (macOS, no server):** kind-as-String round-trip; NodeAttributes; sleep_cycle + episode/kind/edge helpers; engine phases (consolidate/associate/reflect/curate/forget) with a `CannedRuntime`; runCycle resume + cancel; scheduler timers/cancel with injected intervals + spy runner; reflect tool. All M2b-1 suites stay green after the kind refactor.
- **Manual (macOS, real 26B):** Task 8 — structured nodes, associative edges, grounded insights, kind curation, resume.

## Self-Review (spec coverage)
- Free-form/extensible kinds → Task 1. Structured attrs (task/plan) → Task 2. sleep_cycle + helpers → Task 3. Consolidate/Associate → Task 4. Reflect/Curate/Forget + resumable runCycle + runLight → Task 5. Scheduler (awake+sleep, cancel) + reflect tool → Task 6. Wiring + UI + free-form colors + Agent prompt → Task 7. Manual E2E → Task 8. Anti-fabrication (≥2-source insight) → Task 5. Curation (synonym fold) → Task 5. Both awake triggers (tool + pause) → Task 6. ✅
- **Type consistency:** `MemoryConsolidationEngine` methods `consolidate(episodeTexts:)`, `associate()`, `reflect()`, `curateKinds()`, `forget()`, `runCycle(isCancelled:)`, `runLight(isCancelled:)`; `ConsolidationRunning` protocol matches `runLight`/`runCycle` (both `isCancelled: @escaping () -> Bool` — ensure Task 5 uses `@escaping`); `SleepPhase`/`SleepCycleState`; store helpers `loadSleepCycle/saveSleepCycle/clearSleepCycle/unconsolidatedEpisodes/markEpisodesConsolidated/distinctKinds/reassignKind/pruneDanglingEdges`; `NodeAttributes.from/toJSON`; `MemoryToolbox.reflectionRequest`. Names consistent across tasks.
- **Note:** intervals (15s/180s), insight grounding (≥2), semantic resolve threshold (0.25), curate scope (unknown kinds only) are tunable; manual E2E may refine.

## References
- Spec `…m2b-2-sleep-consolidation-design.md`; vision `…sleep-consolidation-vision.md`. Builds on M2b-1 (`…m2b-1-foundations-design.md`).
- M2b-3 (next): resume interrupted conversations (open-thread detection + proactive follow-up).
