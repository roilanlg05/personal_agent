# M2b-1 — Memory Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the chat as episodic nodes, replace the dual noisy capture (RememberTool + MemoryConsolidator) with one synchronous semantic-dedup `SaveMemoryTool`, add multi-timescale EMA salience, and scope memory injection to identity-core + query-relevant.

**Architecture:** Phase 1 of the "Sleep Consolidation" memory (vision: `docs/superpowers/specs/2026-05-31-sleep-consolidation-vision.md`). Reuses `MemoryStore`/Node/Edge/`Embedder`/`MemoryText`/`MemoryRetriever`. The model captures facts in-turn via `SaveMemoryTool` (clean→embed→semantic-dedup→upsert); each turn's user+assistant messages are stored as `conversation`/`episodic` nodes by `EpisodeRecorder`; the per-turn `MemoryConsolidator` is deleted (passive capture moves to the M2b-2 sleep pass).

**Tech Stack:** Swift, SwiftUI, XCTest, GRDB, Apple NaturalLanguage (NLContextualEmbedder). macOS app.

## Spec
`docs/superpowers/specs/2026-05-31-m2b-1-foundations-design.md`.

## Conventions
- Build/test on macOS: `xcodebuild test -scheme Gemma -project /Users/hashdown/Projects/personal_agent/Gemma/Gemma.xcodeproj -destination 'platform=macOS'`. Success = "TEST SUCCEEDED" / "BUILD SUCCEEDED". (Always pass the ABSOLUTE `-project` path; relative paths fail if the shell cwd drifted.)
- New `.swift` files auto-add to the target (synchronized groups). No pbxproj edits for Swift files.
- SourceKit "No such module"/"Cannot find type" diagnostics are spurious if xcodebuild succeeds.
- `@MainActor` XCTest classes must use `async` test methods (sync ones crash on deinit under XCTMemoryChecker on macOS 26).
- Commit after each task. End commit messages with a blank line then:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- After code changes: `graphify update .` (ignore errors).

## Current state (verified — exact APIs)
- `Decay` (`Memory/Decay.swift`): `effectiveSalience(base:decayRate:elapsedSeconds:)`, `reinforce(current:bump:cap:)` (flat +0.5, cap 10), `shouldPromote(mentionCount:origin:permanent:threshold:)`, `shouldForget(...)`, `defaultDecayRate(for:)`.
- `MemoryStore`: `init(url:inMemory:embeddingDim:)`, `upsert(Node)`, `upsert(Edge)`, `node(id:)`, `allNodes(includeDeleted:)`, `coreMemories(limit:)` (currently identity + top-salience), `edges(from:)`, `allEdges()`, `softDelete(nodeId:)`, `searchFTS(query:limit:)`, `defaultURL()`. Vector (`MemoryStore+Vector`): `setEmbedding(nodeId:_:)`, `nearest(to:k:) -> [(id:String, distance:Double)]` (distance = 1 − cosine). Dedup (`MemoryStore+Dedup`): `findDuplicate(kind:label:)`, `upsertMerging(_:)`, `sweep(now:)`.
- `Node` fields: id, kind:NodeKind{person,place,fact,preference,topic,day,episode,conversation}, label, body, layer:MemoryLayer{live,daily,identity,episodic}, createdAt, updatedAt, lastSeenAt, salience:Double, decayRate:Double, confidence:Confidence{sure,probable,maybe}, mentionCount:Int, ttlExpiresAt:Double?, sourceRef:String?, origin:Origin{explicit,extracted}, serverId, dirty, deleted, extra:String?.
- `Embedder` protocol: `dimension`, `embed(_:) throws -> [Float]`. `FakeEmbedder(dimension:)`, `NLContextualEmbedder()`.
- `MemoryText`: `cleanLabel`, `dedupKey`, `isJunkLabel`.
- `AgentTool` protocol: `static name/description/parameters`, `func run(argsJSON:) async -> String`; `AgentToolParam(name:type:description:required:)`; `ToolActivityRelay.shared`.
- `RememberTool` (`Memory/RememberTool.swift`): `content`/`kind`/`permanent`; writes via `upsertMerging` + `setEmbedding`. **To be replaced.**
- `ForgetTool`: `query` → `searchFTS` + `softDelete`. **Kept.**
- `MemoryConsolidator` (`Memory/MemoryConsolidator.swift`): post-turn JSON extraction. **To be deleted.**
- `MemoryToolbox.shared`: `store`, `embedder`, `consolidationTask`. **consolidationTask removed in Task 6.**
- `Agent` (`Agent/Agent.swift`): `MemoryServices{retriever, consolidator}`; `run` awaits `MemoryToolbox.shared.consolidationTask`, retrieves+injects, runs the tool loop, then fires `consolidator.consolidate`. **consolidator removed; episode recording added in Task 6.**
- `HarnessModel`: `ensureMemory()` builds `MemoryServices(retriever, consolidator)`; `runAgentTurn` registers `CurrentTimeTool` + (if memory) `RememberTool`+`ForgetTool`.

## File structure (after M2b-1)
**New:** `Memory/SaveMemoryTool.swift`, `Memory/EpisodeRecorder.swift`; tests `GemmaTests/SaveMemoryToolTests.swift`, `GemmaTests/EpisodeRecorderTests.swift`.
**Modified:** `Memory/Decay.swift`, `Memory/MemoryStore.swift` (coreMemories), `Memory/MemoryStore+Dedup.swift`, `Agent/Agent.swift`, `Harness/HarnessModel.swift`, `Memory/MemoryToolbox.swift`; tests `DecayTests`, `MemoryStoreDedupTests`, `MemoryRetrieverTests`/`MemoryCoreRecallTests`, `MemoryToolsTests`, `AgentMemoryTests`.
**Removed:** `Memory/MemoryConsolidator.swift`, `Memory/RememberTool.swift`, `GemmaTests/MemoryConsolidatorTests.swift`.

---

## Task 1: Multi-timescale EMA salience in `Decay`

**Files:** Modify `Memory/Decay.swift`, Test `GemmaTests/DecayTests.swift`.

- [ ] **Step 1: Add failing tests** to `GemmaTests/DecayTests.swift`:
```swift
func test_beta_increases_with_layer_timescale() {
    XCTAssertLessThan(Decay.beta(for: .live), Decay.beta(for: .daily))
    XCTAssertLessThan(Decay.beta(for: .daily), Decay.beta(for: .identity))
}

func test_reinforceEMA_climbs_toward_cap_monotonically() {
    var s = 0.0
    var last = -1.0
    for _ in 0..<20 {
        let next = Decay.reinforceEMA(current: s, beta: 0.9)
        XCTAssertGreaterThan(next, last)   // monotonic climb
        XCTAssertLessThanOrEqual(next, 10.0) // never exceeds cap
        last = next; s = next
    }
}

func test_reinforceEMA_smaller_beta_climbs_faster() {
    let fast = Decay.reinforceEMA(current: 0, beta: 0.5)  // live
    let slow = Decay.reinforceEMA(current: 0, beta: 0.99) // identity
    XCTAssertGreaterThan(fast, slow)
}
```

- [ ] **Step 2: Run → fail** (`-only-testing:GemmaTests/DecayTests`): "cannot find 'beta'/'reinforceEMA'".

- [ ] **Step 3: Implement** — add to `enum Decay` in `Memory/Decay.swift`:
```swift
    /// EMA decay factor (β) per layer = memory timescale. Larger β = slower/longer memory
    /// (effective horizon ≈ 1/(1−β)): live changes fast, identity is near-stable. This is the
    /// Adam-moment analogy `m ← β·m + (1−β)·signal` applied to a node's salience.
    static func beta(for layer: MemoryLayer) -> Double {
        switch layer {
        case .live: return 0.5        // horizon ~2
        case .episodic: return 0.8    // ~5
        case .daily: return 0.9       // ~10
        case .identity: return 0.99   // ~100
        }
    }

    /// Reinforcement on re-mention via EMA toward a full-strength signal (default = cap).
    /// Moves salience a (1−β) fraction toward `signal` each mention: frequent mentions climb
    /// toward `cap`, and a larger β makes the climb slower/steadier (more stable memory).
    static func reinforceEMA(current: Double, signal: Double = 10, beta: Double, cap: Double = 10) -> Double {
        min(cap, beta * current + (1 - beta) * signal)
    }
```

- [ ] **Step 4: Run → pass** (`-only-testing:GemmaTests/DecayTests`).

- [ ] **Step 5: Commit**
```bash
git add -A && git commit -m "feat(m2b-1): EMA multi-timescale salience in Decay (beta per layer + reinforceEMA)"
```

---

## Task 2: Relevance-scoped injection — `coreMemories()` → identity-only

**Files:** Modify `Memory/MemoryStore.swift`. Check/Modify `GemmaTests/MemoryCoreRecallTests.swift`.

- [ ] **Step 1: Read `GemmaTests/MemoryCoreRecallTests.swift`** to see what it asserts about `coreMemories()`. If it asserts that a high-salience NON-identity node is returned by `coreMemories()`, that assertion must change (core is now identity-only). Adjust the test to assert: `coreMemories()` returns identity-layer nodes and does NOT include a high-salience `daily` node. Concretely, write/adjust:
```swift
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
```
(If `MemoryCoreRecallTests` is `@MainActor`, make the method `async` and the body unchanged — it's pure store work, but follow the file's existing pattern.)

- [ ] **Step 2: Run → fail** (the current `coreMemories` includes top-salience `w1`).

- [ ] **Step 3: Implement** — replace `coreMemories` in `Memory/MemoryStore.swift` with identity-only:
```swift
    /// Always-relevant "identity core": who the user is and their permanent identity-layer
    /// facts, regardless of the current query. Identity-ONLY (no top-salience union) so the
    /// injected core stays small — query-relevant nodes (from MemoryRetriever) carry the rest.
    func coreMemories(limit: Int = 6) throws -> [Node] {
        try dbQueue.read { db in
            try Node.filter(Column("layer") == MemoryLayer.identity.rawValue && Column("deleted") == false)
                .order(Column("salience").desc).limit(limit).fetchAll(db)
        }
    }
```

- [ ] **Step 4: Run → pass.** Also run `-only-testing:GemmaTests/MemoryRetrieverTests` to confirm retrieval still green (it unions core after query-relevant; a smaller core is fine).

- [ ] **Step 5: Commit**
```bash
git add -A && git commit -m "fix(m2b-1): scope injected core to identity-only (no top-salience over-injection)"
```

---

## Task 3: Semantic dedup + EMA reinforcement in `MemoryStore+Dedup`

**Files:** Modify `Memory/MemoryStore+Dedup.swift`, Test `GemmaTests/MemoryStoreDedupTests.swift`.

- [ ] **Step 1: Add failing tests** to `GemmaTests/MemoryStoreDedupTests.swift`. (A keyword stub embedder makes semantic dedup deterministic.)
```swift
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
```

- [ ] **Step 2: Run → fail** ("cannot find 'upsertMergingSemantic'").

- [ ] **Step 3: Implement** — add to `Memory/MemoryStore+Dedup.swift`, and switch the existing `upsertMerging` reinforcement to EMA. Replace the file's `upsertMerging` body's reinforcement line and ADD the new methods:
```swift
    /// Nearest same-kind, non-deleted node within `threshold` cosine distance, or nil.
    func findSemanticDuplicate(kind: NodeKind, embedding: [Float], threshold: Double) throws -> Node? {
        for hit in try nearest(to: embedding, k: 8) where hit.distance <= threshold {
            if let n = try node(id: hit.id), !n.deleted, n.kind == kind { return n }
        }
        return nil
    }

    /// Upsert with SEMANTIC dedup (falls back to string dedup): merge into the nearest same-kind
    /// node within `threshold`, else the canonical-label match, else insert. Reinforces via EMA.
    @discardableResult
    func upsertMergingSemantic(_ candidate: Node, embedding: [Float]?, embedder: Embedder?,
                               threshold: Double = 0.2) throws -> String {
        var existing: Node? = nil
        if let embedding { existing = try findSemanticDuplicate(kind: candidate.kind, embedding: embedding, threshold: threshold) }
        if existing == nil { existing = try findDuplicate(kind: candidate.kind, label: candidate.label) }

        if let existing {
            let merged = mergeReinforced(existing: existing, candidate: candidate)
            try upsert(merged)
            return merged.id
        } else {
            try upsert(candidate)
            if let embedding { try setEmbedding(nodeId: candidate.id, embedding) }
            return candidate.id
        }
    }

    /// Shared merge: EMA-reinforce salience, bump mentionCount, refresh times, promote if due.
    private func mergeReinforced(existing: Node, candidate: Node) -> Node {
        var merged = existing
        merged.salience = Decay.reinforceEMA(current: existing.salience, beta: Decay.beta(for: existing.layer))
        merged.mentionCount = existing.mentionCount + 1
        merged.lastSeenAt = candidate.lastSeenAt
        merged.updatedAt = candidate.updatedAt
        if merged.body.isEmpty { merged.body = candidate.body }
        if Decay.shouldPromote(mentionCount: merged.mentionCount, origin: merged.origin,
                               permanent: merged.layer == .identity) {
            merged.layer = .identity
            merged.ttlExpiresAt = nil
            merged.decayRate = Decay.defaultDecayRate(for: .identity)
        }
        merged.dirty = true
        return merged
    }
```
Then change the existing `upsertMerging(_:)` to reuse `mergeReinforced` (so string-only callers also get EMA reinforcement):
```swift
    @discardableResult
    func upsertMerging(_ candidate: Node) throws -> String {
        if let existing = try findDuplicate(kind: candidate.kind, label: candidate.label) {
            let merged = mergeReinforced(existing: existing, candidate: candidate)
            try upsert(merged)
            return merged.id
        } else {
            try upsert(candidate)
            return candidate.id
        }
    }
```

- [ ] **Step 4: Update the existing dedup test if it asserted the old flat +0.5 salience.** If `MemoryStoreDedupTests` has a test asserting `upsertMerging` reinforced salience to a specific value (e.g. 3.5), change it to assert `salience > original` (EMA value differs). Run `-only-testing:GemmaTests/MemoryStoreDedupTests` → all pass.

- [ ] **Step 5: Commit**
```bash
git add -A && git commit -m "feat(m2b-1): semantic dedup (embedding nearest) + EMA reinforcement on merge"
```

---

## Task 4: `SaveMemoryTool` (replaces `RememberTool`)

**Files:** Create `Memory/SaveMemoryTool.swift`, delete `Memory/RememberTool.swift`. Modify `Harness/HarnessModel.swift` (register SaveMemoryTool). Modify `GemmaTests/MemoryToolsTests.swift`.

- [ ] **Step 1: Write the failing test** — rewrite `GemmaTests/MemoryToolsTests.swift` for `SaveMemoryTool` (keep the ForgetTool tests):
```swift
import XCTest
@testable import Gemma

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
```

- [ ] **Step 2: Run → fail** ("cannot find 'SaveMemoryTool'").

- [ ] **Step 3: Implement** `Memory/SaveMemoryTool.swift`:
```swift
import Foundation

/// Saves a durable fact the user stated about themselves. Structured (canonical `entity` +
/// optional `detail`) so the model gives a clean anchor; writes synchronously with semantic
/// dedup. Replaces the free-phrase RememberTool.
struct SaveMemoryTool: AgentTool {
    static let name = "save_memory"
    static let description = """
    Save a durable fact the USER stated about THEMSELVES (a preference, a person, a place, or a \
    personal fact). Only call this for things the user affirmed about themselves — NEVER for a \
    question they asked, NEVER for facts about you/the assistant or the current time, and NEVER \
    guess. Use a short canonical `entity` (e.g. "sushi", "Juan", "Madrid"), not a sentence.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "entity", type: .string, description: "Short canonical noun/name to remember, e.g. \"sushi\", \"Juan\". Not a sentence.", required: true),
        AgentToolParam(name: "detail", type: .string, description: "Optional free context, e.g. \"likes it a lot\", \"friend, works with the user\".", required: false),
        AgentToolParam(name: "kind", type: .string, description: "One of: person, place, preference, fact.", required: false),
        AgentToolParam(name: "permanent", type: .boolean, description: "true if this is permanent identity (name, lifelong facts).", required: false),
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let rawEntity = ((obj["entity"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (obj["detail"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let kind = (obj["kind"] as? String) ?? "fact"
        let permanent = (obj["permanent"] as? Bool) ?? false
        let entity = MemoryText.cleanLabel(rawEntity)
        guard !entity.isEmpty, !MemoryText.isJunkLabel(entity) else { return "nothing to save" }

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: entity) }
        let result: String = await MainActor.run {
            guard let store = MemoryToolbox.shared.store else { return "memory unavailable" }
            let now = Date().timeIntervalSince1970
            let layer: MemoryLayer = permanent ? .identity : .daily
            let k = NodeKind(rawValue: kind) ?? .fact
            let body = (detail?.isEmpty == false) ? detail! : entity
            let node = Node(id: UUID().uuidString, kind: k, label: entity, body: body, layer: layer,
                            createdAt: now, updatedAt: now, lastSeenAt: now, salience: permanent ? 8 : 3,
                            decayRate: Decay.defaultDecayRate(for: layer), confidence: .sure, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil,
                            dirty: true, deleted: false, extra: nil)
            let embedder = MemoryToolbox.shared.embedder
            let embedding = (try? embedder?.embed(entity)) ?? nil
            do {
                _ = try store.upsertMergingSemantic(node, embedding: embedding, embedder: embedder)
                return "Saved: \(entity)"
            } catch { return "memory error: \(error)" }
        }
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
```

- [ ] **Step 4: Delete `Memory/RememberTool.swift`**
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma/Gemma && rm Memory/RememberTool.swift
```

- [ ] **Step 5: Update `Harness/HarnessModel.swift`** — in `runAgentTurn`, register `SaveMemoryTool` instead of `RememberTool`. Change the line:
```swift
        if memory != nil { registry.register(RememberTool()); registry.register(ForgetTool()) }
```
to:
```swift
        if memory != nil { registry.register(SaveMemoryTool()); registry.register(ForgetTool()) }
```

- [ ] **Step 6: Run → pass** (`-only-testing:GemmaTests/MemoryToolsTests`) and build (`xcodebuild build … -destination 'platform=macOS' | tail -3` → BUILD SUCCEEDED). Grep to confirm no `RememberTool` references remain: `grep -rn RememberTool Gemma/Gemma Gemma/GemmaTests` → empty.

- [ ] **Step 7: Commit**
```bash
git add -A && git commit -m "feat(m2b-1): SaveMemoryTool (structured entity + semantic dedup) replaces RememberTool"
```

---

## Task 5: `EpisodeRecorder` — persist chat turns as episodic nodes

**Files:** Create `Memory/EpisodeRecorder.swift`, Test `GemmaTests/EpisodeRecorderTests.swift`.

- [ ] **Step 1: Write the failing test** `GemmaTests/EpisodeRecorderTests.swift`:
```swift
import XCTest
@testable import Gemma

final class EpisodeRecorderTests: XCTestCase {
    func test_record_writes_user_and_assistant_conversation_nodes() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        EpisodeRecorder.record(store: store, threadId: "T1", turnIndex: 0,
                               userText: "me llamo Roilan", assistantText: "¡Hola Roilan!")
        let convos = try store.allNodes().filter { $0.kind == .conversation }
        XCTAssertEqual(convos.count, 2)
        XCTAssertTrue(convos.allSatisfy { $0.layer == .episodic })
        let roles = Set(convos.compactMap { EpisodeRecorder.meta(from: $0)?.role })
        XCTAssertEqual(roles, ["user", "assistant"])
        let user = convos.first { EpisodeRecorder.meta(from: $0)?.role == "user" }
        XCTAssertEqual(user?.body, "me llamo Roilan")
        XCTAssertEqual(EpisodeRecorder.meta(from: user!)?.threadId, "T1")
        XCTAssertEqual(EpisodeRecorder.meta(from: user!)?.turnIndex, 0)
    }

    func test_episodes_do_not_count_as_facts() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        EpisodeRecorder.record(store: store, threadId: "T1", turnIndex: 0, userText: "hi", assistantText: "hello")
        XCTAssertTrue(try store.allNodes().filter { $0.kind != .conversation }.isEmpty)
    }
}
```

- [ ] **Step 2: Run → fail** ("cannot find 'EpisodeRecorder'").

- [ ] **Step 3: Implement** `Memory/EpisodeRecorder.swift`:
```swift
import Foundation

/// Persists each chat turn as two `conversation` nodes (user + assistant) in the `episodic`
/// layer — the replayable substrate the sleep-consolidation pass (M2b-2) reads. Thread metadata
/// (session id, role, turn index, status) is packed into `Node.extra` as JSON (no schema change).
enum EpisodeRecorder {
    struct Meta: Codable {
        var threadId: String
        var role: String       // "user" | "assistant"
        var turnIndex: Int
        var status: String     // "open" | "closed"
    }

    static func meta(from node: Node) -> Meta? {
        guard let s = node.extra, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: d)
    }

    /// Record one finished turn. Best-effort: storage errors are swallowed (never break a reply).
    static func record(store: MemoryStore, threadId: String, turnIndex: Int,
                       userText: String, assistantText: String,
                       now: Double = Date().timeIntervalSince1970) {
        write(store: store, threadId: threadId, turnIndex: turnIndex, role: "user", text: userText, now: now)
        write(store: store, threadId: threadId, turnIndex: turnIndex, role: "assistant", text: assistantText, now: now)
    }

    private static func write(store: MemoryStore, threadId: String, turnIndex: Int,
                              role: String, text: String, now: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let meta = Meta(threadId: threadId, role: role, turnIndex: turnIndex, status: "closed")
        let extra = (try? JSONEncoder().encode(meta)).flatMap { String(data: $0, encoding: .utf8) }
        let preview = String(trimmed.prefix(60))
        let node = Node(id: UUID().uuidString, kind: .conversation, label: "\(role): \(preview)",
                        body: trimmed, layer: .episodic, createdAt: now, updatedAt: now, lastSeenAt: now,
                        salience: 2, decayRate: Decay.defaultDecayRate(for: .episodic), confidence: .sure,
                        mentionCount: 1, ttlExpiresAt: nil, sourceRef: threadId, origin: .extracted,
                        serverId: nil, dirty: true, deleted: false, extra: extra)
        try? store.upsert(node)   // distinct per turn — NOT deduped
    }
}
```

- [ ] **Step 4: Run → pass** (`-only-testing:GemmaTests/EpisodeRecorderTests`).

- [ ] **Step 5: Commit**
```bash
git add -A && git commit -m "feat(m2b-1): EpisodeRecorder persists chat turns as episodic conversation nodes"
```

---

## Task 6: Remove `MemoryConsolidator`; wire episode recording into the turn

**Files:** Modify `Agent/Agent.swift`, `Harness/HarnessModel.swift`, `Memory/MemoryToolbox.swift`. Delete `Memory/MemoryConsolidator.swift`, `GemmaTests/MemoryConsolidatorTests.swift`. Modify `GemmaTests/AgentMemoryTests.swift`.

- [ ] **Step 1: `MemoryServices` → `{ retriever }`; drop consolidation from `Agent.run`.** In `Agent/Agent.swift`:
  - Change the struct:
```swift
@MainActor
struct MemoryServices {
    let retriever: MemoryRetriever
}
```
  - In `run(prompt:options:)`, DELETE the line `await MemoryToolbox.shared.consolidationTask?.value` (and its RC3 comment). The retrieval/inject block stays unchanged (`memory.retriever.retrieve` / `injectionBlock`).
  - DELETE the post-loop consolidation block:
```swift
                    if let memory {
                        let userTurn = prompt
                        MemoryToolbox.shared.consolidationTask = Task {
                            await memory.consolidator.consolidate(user: userTurn, assistant: "")
                        }
                    }
```
    Leave `continuation.finish()` in place. (Episode recording happens in `HarnessModel`, Step 4 — the Agent stays caller-agnostic.)
  - Update the `systemPrompt` base string: change the "Use the remember tool…" sentence to mention `save_memory` and add the answer-only-what-was-asked rule:
```swift
        let base = """
        You are Gemma, a helpful on-device assistant. You can call tools to get real information. \
        When a tool is relevant (e.g. the user asks the time), call it instead of guessing. \
        Use the save_memory tool to store durable facts the user states about themselves. \
        Answer only what the user asked; do not list unrelated things you remember. \
        IMPORTANT: after any tool runs, ALWAYS reply to the user in a short, natural sentence — \
        confirm what you did or answer their question. Never end your turn with only a tool call.
        """
```

- [ ] **Step 2: Remove `consolidationTask` from `MemoryToolbox`.** In `Memory/MemoryToolbox.swift`, delete the `consolidationTask` property and its doc comment (nothing references it after Step 1).

- [ ] **Step 3: Delete the consolidator + its test**
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma && rm Gemma/Memory/MemoryConsolidator.swift GemmaTests/MemoryConsolidatorTests.swift
```

- [ ] **Step 4: Wire episode recording + threadId into `HarnessModel`.** In `Harness/HarnessModel.swift`:
  - Add stored properties: `@ObservationIgnored private let threadId = UUID().uuidString` and `@ObservationIgnored private var turnIndex = 0`.
  - In `ensureMemory()`, change the return to drop the consolidator:
```swift
        let retriever = MemoryRetriever(store: store, embedder: memoryEmbedder)
        return MemoryServices(retriever: retriever)
```
    (Remove the `let consolidator = MemoryConsolidator(...)` line.)
  - In `runAgentTurn`, after the `for try await` loop finishes (after the `do/catch`), record the episode:
```swift
        } catch { agentLog.append("[error: \(error)]") }
        if let store = memoryStore {
            EpisodeRecorder.record(store: store, threadId: threadId, turnIndex: turnIndex,
                                   userText: prompt, assistantText: answer)
            turnIndex += 1
        }
```

- [ ] **Step 5: Fix tests that reference `MemoryServices(...consolidator...)` or `MemoryConsolidator`.** At least two test files construct them — update BOTH (grep first: `grep -rln "consolidator\|MemoryConsolidator" Gemma/GemmaTests`):
  - `GemmaTests/AgentMemoryTests.swift`: change `MemoryServices(retriever:consolidator:)` → `MemoryServices(retriever:)`; drop any consolidator stub. Keep its assertions (memory retrieved + injected into the prompt). If a test asserted consolidation happened, delete that assertion (gone in M2b-1; returns in M2b-2).
  - `GemmaTests/ServerE2ETests.swift`: its `makeAgent()` builds `let consolidator = MemoryConsolidator(runtime:store:embedder:)` and `MemoryServices(retriever: retriever, consolidator: consolidator)`. Remove the `consolidator` line and change to `MemoryServices(retriever: retriever)`. (This is a server-gated test; it must still COMPILE so the suite builds.)

- [ ] **Step 6: Build + run the memory/agent suite**
```bash
cd /Users/hashdown/Projects/personal_agent
xcodebuild build -scheme Gemma -project /Users/hashdown/Projects/personal_agent/Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -3
xcodebuild test -scheme Gemma -project /Users/hashdown/Projects/personal_agent/Gemma/Gemma.xcodeproj -destination 'platform=macOS' \
  -only-testing:GemmaTests/AgentTests -only-testing:GemmaTests/AgentMemoryTests -only-testing:GemmaTests/MemoryToolsTests \
  -only-testing:GemmaTests/MemoryStoreDedupTests -only-testing:GemmaTests/MemoryRetrieverTests \
  -only-testing:GemmaTests/MemoryCoreRecallTests -only-testing:GemmaTests/DecayTests \
  -only-testing:GemmaTests/EpisodeRecorderTests -only-testing:GemmaTests/SaveMemoryToolTests 2>&1 | tail -12
```
Expected: BUILD SUCCEEDED; "TEST SUCCEEDED". Then run the FULL suite once: `xcodebuild test … -destination 'platform=macOS' 2>&1 | tail -4` → TEST SUCCEEDED (live/E2E tests skip). Grep no consolidator refs: `grep -rn "MemoryConsolidator\|consolidationTask" Gemma/Gemma Gemma/GemmaTests` → empty.

- [ ] **Step 7: `graphify update .`; Commit**
```bash
graphify update . || true
git add -A && git commit -m "feat(m2b-1): drop MemoryConsolidator; record chat episodes per turn; relevance prompt"
```

---

## Task 7: Manual device E2E on macOS + record

- [ ] **Step 1:** Run the app (⌘R; the app auto-launches the server). Have a short conversation: "Me llamo Roilan y me gusta el sushi." → reply. New message: "¿Qué me gusta?" → should recall sushi (not the workplace). State a person: "Mi amigo Juan trabaja conmigo." Then "¿quién es Juan?".
- [ ] **Step 2: Memory inspector (graph + list):** open via the Memory button. Confirm: clean entity nodes (sushi/Juan, no sentence-labels, no duplicates), the **conversation episodes** are present (kind `conversation`, episodic), identity has the name. No fabrication when you ASK a question (asking "¿qué me gusta?" must NOT create a new node).
- [ ] **Step 3: Restart the app** → ask "¿qué me gusta?" again → still recalls (persistence). Re-state "me gusta el sushi" → must reinforce (mentionCount up), NOT create a duplicate (semantic dedup).
- [ ] **Step 4: Record** results in `[[macos-mlx-pivot]]` (M2b-1 done) + a §note in the M2b-1 spec. Commit docs.

**M2b-1 DONE:** the chat is persisted as episodes, capture is one clean semantic-dedup tool, salience is multi-timescale, and injection is relevance-scoped — the substrate for the M2b-2 sleep pass is in place.

---

## Testing Strategy
- **Unit (macOS, no server):** Decay EMA (pure); coreMemories identity-only; semantic dedup with a keyword stub embedder; SaveMemoryTool (in-memory store + FakeEmbedder); EpisodeRecorder; relevance retrieval; regression across existing memory suites. Run with the absolute `-project` path.
- **Manual (macOS, real 26B):** Task 7 — capture, recall, no-fabrication-on-questions, persistence, reinforcement-not-duplication, episodes visible in the inspector.

## Self-Review (spec coverage)
- Episodic chat capture → Task 5 + Task 6 (wiring). save_memory synchronous + semantic dedup → Tasks 3,4. Drop MemoryConsolidator → Task 6. EMA multi-timescale salience → Tasks 1,3. Relevance-scoped injection (identity-core + query-relevant) → Task 2 (+ prompt in Task 6). forget_memory kept → Task 4 (ForgetTool unchanged). Reuse of MemoryStore/Embedder/MemoryText/MemoryRetriever → throughout. ✅
- **Type consistency:** `upsertMergingSemantic(_:embedding:embedder:threshold:)`, `findSemanticDuplicate(kind:embedding:threshold:)`, `reinforceEMA(current:signal:beta:cap:)`, `beta(for:)`, `EpisodeRecorder.record(store:threadId:turnIndex:userText:assistantText:now:)`, `EpisodeRecorder.meta(from:)`, `MemoryServices(retriever:)`, `SaveMemoryTool` (`save_memory`) — names used consistently across tasks.
- **Note:** semantic-dedup threshold 0.2 (cosine distance) and EMA β values are tunable constants; device testing (Task 7) may refine them — adjust in `Decay.beta`/`upsertMergingSemantic` default if recall shows over/under-merging.

## References
- Spec `docs/superpowers/specs/2026-05-31-m2b-1-foundations-design.md`; vision `docs/superpowers/specs/2026-05-31-sleep-consolidation-vision.md`.
- Reuses S5a memory layer; next phase M2b-2 (sleep consolidation pass) reads the episode nodes this phase creates.
