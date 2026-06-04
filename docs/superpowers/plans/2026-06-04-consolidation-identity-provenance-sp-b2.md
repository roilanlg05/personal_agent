# Reflect-per-Cluster → Identity + Provenance (SP-B2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `reflect` run per-cluster (insights grounded in a cluster's members), wire a `derivesFrom` provenance edge from each insight to its source memories, and promote insights from large/confident clusters into the identity layer (CAPA 4) linked to the `self` node.

**Architecture:** `reflect()` is rewritten to iterate the cluster anchors built by SP-B1 (via `clusterNodes()` + `belongsToCluster` edges) instead of a flat global node list. Each substantial cluster (≥3 members) yields insights grounded in ≥2 of its members; insight→member edges use `derivesFrom` (durable provenance, replacing `relatedTo`). An insight from a cluster of ≥4 members with confidence ≥ probable is promoted to `layer = .identity` and linked from the `self` node, so it is always injected (emergent identity).

**Tech Stack:** Swift 6 — server only (`gemma-memory`). Spec: `docs/superpowers/specs/2026-06-04-consolidation-pipeline-clustering-design.md` §4.5. Depends on SP-B1 (clusters + `belongsToCluster` + `clusterNodes()`), now on `main`.

**Server tests:** `swift test --filter <Name>` in `gemma-memory/memory-service` (branch from `main`).

**Scope note (locked):** B2 ships **insight → derivesFrom → cluster members** (the well-defined, high-value provenance) + identity promotion. The spec also mentions **memory → summary** `derivesFrom`; that is **deferred** — `consolidate()` (nrem) joins all episode threads into one extraction pass, so an extracted memory is not cleanly attributed to a single thread/summary; wiring it correctly needs per-thread extraction, a larger change. The summary already traces to raw transcript via SP-A, and `insight → members` already gives "why I believe this". Retraction/belief-revision propagation remains deferred (its own sub-project).

**Engine context (verified current shapes, post-SP-B1):**
- `reflect()` currently reads `store.allNodes()` (which now excludes `cluster`+`hub`), builds insights with `relatedTo` edges to sources, `layer: .daily`, dedups by `MemoryText.dedupKey(body)`. `InsightsOut` = `{insights:[{text, sourceEntities:[String], confidence:String?}]}`.
- `Relation.derivesFrom` exists (`MemoryModels.swift:16`, currently unused).
- `store.clusterNodes() -> [Node]`, `store.edges(from:) -> [Edge]`, `store.node(id:)`, `store.upsert(_ node/edge)`, `store.upsertSelf(name:detail:embedder:)`, `selfUserID == "self:user"`, `store.allNodes()` (excludes cluster/hub), `coreMemories()` (returns identity-layer nodes, self first).
- `Confidence` enum = `{sure, probable, maybe}`. "≥ probable" ≡ `conf != .maybe`.
- `runLight` calls `reflect()` (over whatever clusters the last sleep cycle left); `runCycle` runs `reflect` AFTER `cluster`+`tag` (so fresh clusters exist).

---

## File Structure

- `Sources/MemoryCore/MemoryConsolidationEngine.swift` — rewrite `reflect()` (per-cluster + `derivesFrom`); add identity promotion.

(No data-model changes — `derivesFrom` and `identity` layer already exist; insights are already nodes.)

---

## Task 1: Reflect per-cluster + `derivesFrom` provenance

**Files:** `Sources/MemoryCore/MemoryConsolidationEngine.swift`; Test: `Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift` (append).

### Step 0: Read the current `reflect()` (it reads `allNodes()`, mints `insight` nodes with `relatedTo` edges, `layer: .daily`, dedups by body) + `InsightsOut` struct + how engine tests build `MemoryConsolidationEngine(store:embedder:runtime:)` with `CannedRuntime`/`FakeEmbedder`. Confirm `store.clusterNodes()` + `store.edges(from:)` + `MemoryText.dedupKey`.

### Step 1: Write the failing test — append to `Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift`:
```swift
func test_reflect_per_cluster_uses_derivesFrom_to_members() async throws {
    let store = try MemoryStore(inMemory: true, embeddingDim: 4)
    func mk(_ id: String, _ kind: String) -> Node {
        Node(id: id, kind: kind, label: id, body: id, layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1,
             salience: 3, decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
             origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
    }
    for id in ["sushi", "ramen", "tempura"] { try store.upsert(mk(id, NodeKind.preference.rawValue)) }
    var anchor = mk("cl", NodeKind.cluster.rawValue); anchor.label = "comida"; try store.upsert(anchor)
    for m in ["sushi", "ramen", "tempura"] {
        try store.upsert(Edge(id: UUID().uuidString, srcId: "cl", dstId: m, relation: .belongsToCluster,
                              weight: 1, confidence: .probable, createdAt: 1, updatedAt: 1, dirty: true, deleted: false, extra: nil))
    }
    let json = #"{"insights":[{"text":"enjoys Japanese food","sourceEntities":["sushi","ramen"],"confidence":"probable"}]}"#
    let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime([json]))
    await engine.reflect()
    let insights = try store.allNodes().filter { $0.kind == NodeKind.insight.rawValue }
    XCTAssertEqual(insights.count, 1)
    let ins = try XCTUnwrap(insights.first)
    XCTAssertEqual(ins.layer, .daily)                                  // only 3 members → not promoted
    let prov = (try store.edges(from: ins.id)).filter { $0.relation == .derivesFrom }
    XCTAssertEqual(Set(prov.map { $0.dstId }), ["sushi", "ramen"])     // derivesFrom the 2 cited sources
    XCTAssertTrue((try store.edges(from: ins.id)).allSatisfy { $0.relation != .relatedTo })  // no relatedTo
}
```

### Step 2: Run → FAIL: `swift test --filter test_reflect_per_cluster_uses_derivesFrom_to_members` (current `reflect` is global + uses `relatedTo`).

### Step 3: Replace the body of `reflect()` with the per-cluster version (keep the method signature `public func reflect() async`):
```swift
public func reflect() async {
    let clusters = (try? store.clusterNodes()) ?? []
    guard !clusters.isEmpty else { return }
    // Dedup against insights already in the store (runLight reflects frequently over stable clusters).
    var existingInsights = Set(((try? store.allNodes()) ?? [])
        .filter { $0.kind == NodeKind.insight.rawValue }.map { MemoryText.dedupKey($0.body) })
    var added = 0
    for cluster in clusters {
        let memberIds = ((try? store.edges(from: cluster.id)) ?? []).filter { $0.relation == .belongsToCluster }.map { $0.dstId }
        let members = memberIds.compactMap { try? store.node(id: $0) }
        guard members.count >= 3 else { continue }   // need a substantial cluster to abstract from
        let labels = members.map { "\($0.kind): \($0.label)" }.joined(separator: "\n")
        let prompt = """
        These memories form ONE thematic group about the user. Infer 1-2 higher-level insights or patterns they reveal. Output JSON only.
        Each insight MUST be grounded in at least TWO of the listed entities (cite their exact labels in sourceEntities). Do not speculate beyond the evidence.
        Example: from `preference: sushi`, `preference: ramen` → {"insights":[{"text":"enjoys Japanese food","sourceEntities":["sushi","ramen"],"confidence":"probable"}]}
        Schema: {"insights":[{"text":"...","sourceEntities":["label1","label2"],"confidence":"probable|maybe"}]}
        Memories:
        \(labels)
        JSON:
        """
        guard let out = parse(await generate(prompt, maxTokens: 512), InsightsOut.self) else { continue }
        func resolve(_ label: String) -> Node? {
            let key = MemoryText.dedupKey(label)
            return members.first { MemoryText.dedupKey($0.label) == key }
        }
        for ins in out.insights {
            let sources = ins.sourceEntities.compactMap(resolve)
            if Set(sources.map { $0.id }).count < 2 { continue }   // anti-fabrication: grounded in ≥2 members
            let key = MemoryText.dedupKey(ins.text)
            if existingInsights.contains(key) { continue }
            existingInsights.insert(key)
            let t = now()
            let conf = Confidence(rawValue: ins.confidence ?? "probable") ?? .probable
            let node = Node(id: UUID().uuidString, kind: NodeKind.insight.rawValue, label: String(ins.text.prefix(60)),
                            body: ins.text, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3,
                            decayRate: Decay.defaultDecayRate(for: .daily), confidence: conf, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
            try? store.upsert(node)
            for s in sources {
                try? store.upsert(Edge(id: UUID().uuidString, srcId: node.id, dstId: s.id, relation: .derivesFrom, weight: 1,
                                       confidence: conf, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
            }
            added += 1
        }
    }
    onProgress?("+\(added) insights")
}
```
(Behavior change: insights now come only from clusters of ≥3 members, grounded in ≥2; edges are `derivesFrom` not `relatedTo`. When there are no clusters yet — e.g. the very first cycle before clustering — reflect produces nothing, which is correct: insights should emerge from coherent clusters.)

### Step 4: Run → PASS. Then full `swift test` → green. **WATCH:** existing `reflect`/runLight/runCycle tests may have asserted the OLD global behavior (insights from a flat node list, or `relatedTo` edges). For any that now fail: if a test set up a cluster, keep it; if it relied on the old global reflect, update it to seed a cluster (anchor + ≥3 `belongsToCluster` members) so reflect has something to abstract — OR if the test was specifically asserting the old `relatedTo` edge from reflect, update the relation to `.derivesFrom`. Report every test you touched + why.

### Step 5: Commit
```bash
git add Sources/MemoryCore/MemoryConsolidationEngine.swift Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(reflect): per-cluster insights with derivesFrom provenance to source members"
```

---

## Task 2: Identity promotion (cluster ≥4 + confidence ≥ probable → identity layer + self link)

**Files:** `Sources/MemoryCore/MemoryConsolidationEngine.swift`; Test: `Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift` (append).

### Step 0: Re-read the `reflect()` you wrote in Task 1 (the per-cluster loop + insight creation). Confirm `selfUserID` (== "self:user") is accessible and `store.upsertSelf(name:detail:embedder:)` exists, and that `coreMemories()` returns identity-layer nodes (so a promoted insight gets injected).

### Step 1: Write the failing test — append:
```swift
func test_reflect_promotes_large_confident_cluster_to_identity() async throws {
    let store = try MemoryStore(inMemory: true, embeddingDim: 4)
    _ = try store.upsertSelf(name: "Roilan", detail: nil, embedder: nil)
    func mk(_ id: String) -> Node {
        Node(id: id, kind: NodeKind.preference.rawValue, label: id, body: id, layer: .daily, createdAt: 1, updatedAt: 1,
             lastSeenAt: 1, salience: 3, decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
             sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
    }
    for id in ["calls", "puts", "spreads", "iron-condor"] { try store.upsert(mk(id)) }   // 4 members
    var anchor = mk("cl"); anchor.id = "cl"; anchor.kind = NodeKind.cluster.rawValue; anchor.label = "trading"; try store.upsert(anchor)
    for m in ["calls", "puts", "spreads", "iron-condor"] {
        try store.upsert(Edge(id: UUID().uuidString, srcId: "cl", dstId: m, relation: .belongsToCluster,
                              weight: 1, confidence: .probable, createdAt: 1, updatedAt: 1, dirty: true, deleted: false, extra: nil))
    }
    let json = #"{"insights":[{"text":"trades options actively","sourceEntities":["calls","puts"],"confidence":"probable"}]}"#
    let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime([json]))
    await engine.reflect()
    let ins = try XCTUnwrap(try store.allNodes().filter { $0.kind == NodeKind.insight.rawValue }.first)
    XCTAssertEqual(ins.layer, .identity)                                   // promoted (≥4 members, conf≥probable)
    // self → insight edge exists
    let selfLink = (try store.edges(from: selfUserID)).filter { $0.dstId == ins.id }
    XCTAssertEqual(selfLink.count, 1)
    // promoted insight is injected as a core (identity) memory
    XCTAssertTrue(try store.coreMemories(limit: 10).contains { $0.id == ins.id })
}
```

### Step 2: Run → FAIL (insight is still `.daily`, no self link).

### Step 3: In `reflect()`, change the insight creation to promote large/confident clusters. Replace the insight-node creation + the source-edge loop (inside `for ins in out.insights`) with:
```swift
            let t = now()
            let conf = Confidence(rawValue: ins.confidence ?? "probable") ?? .probable
            // Identity promotion (CAPA 4): an insight from a substantial cluster, confidently held,
            // becomes always-injected identity knowledge linked to the self.
            let promote = members.count >= 4 && conf != .maybe
            let layer: MemoryLayer = promote ? .identity : .daily
            let node = Node(id: UUID().uuidString, kind: NodeKind.insight.rawValue, label: String(ins.text.prefix(60)),
                            body: ins.text, layer: layer, createdAt: t, updatedAt: t, lastSeenAt: t,
                            salience: promote ? 7 : 3, decayRate: Decay.defaultDecayRate(for: layer), confidence: conf,
                            mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                            dirty: true, deleted: false, extra: nil)
            try? store.upsert(node)
            for s in sources {
                try? store.upsert(Edge(id: UUID().uuidString, srcId: node.id, dstId: s.id, relation: .derivesFrom, weight: 1,
                                       confidence: conf, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
            }
            if promote, (try? store.node(id: selfUserID)) != nil {
                try? store.upsert(Edge(id: UUID().uuidString, srcId: selfUserID, dstId: node.id, relation: .relatedTo, weight: 1,
                                       confidence: conf, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
            }
            added += 1
```
(`members` is in scope from the enclosing per-cluster loop. The self link uses `relatedTo` — the user "relates to" this identity trait; it only fires when a self node exists. `salience: 7` keeps a promoted identity insight high so `coreMemories` orders it well.)

### Step 4: Run → PASS: the new test + the Task-1 test (a 3-member cluster stays `.daily` with no self link). Full `swift test` → green.

### Step 5: Commit
```bash
git add Sources/MemoryCore/MemoryConsolidationEngine.swift Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(reflect): promote large confident cluster insights to identity layer, linked to self"
```

---

## Task 3: Deploy server + manual E2E

- [ ] **Deploy:** `ssh HomeLab 'cd ~/Projects/gemma-memory && git pull --ff-only origin main && docker compose build memory && docker compose up -d memory'`. Verify `healthz` 200.
- [ ] **App build (⌘R) on fresh-ish memory:** converse enough about ONE deep theme (e.g. options trading: several distinct facts/preferences) so consolidation forms a cluster of ≥4 members → trigger consolidation. Confirm in the inspector/brain-graph: an **`insight`** node with **`derivesFrom`** edges to its source members; and if the cluster is ≥4, the insight is in the **identity layer** (always injected) with a **`self → insight`** edge. Then in a NEW chat, ask something the identity trait answers ("¿a qué me dedico?") — the agent should answer from the always-injected identity insight.
- [ ] **Record** the result.

---

## Self-Review

**Spec coverage (§4.5):** reflect-per-cluster → Task 1. `derivesFrom` provenance (insight→members, replacing `relatedTo`) → Task 1. Identity promotion (≥4 members + conf≥probable → identity layer + self link) → Task 2. The spec's `memory→summary` derivesFrom is explicitly **deferred** (stated in the Scope note with rationale); retraction deferred. ✓

**Placeholder scan:** No TBD/TODO. Each code step shows the full method/block. The Step-4 note in Task 1 ("update tests that relied on old global reflect") points the implementer to a concrete, bounded follow-up discoverable by running the suite, with both resolution branches specified.

**Type consistency:** `reflect()` signature unchanged (`public func reflect() async`). `clusterNodes()`/`edges(from:)`/`belongsToCluster` (SP-B1) used in Task 1. `Relation.derivesFrom` (Task 1) + `Relation.relatedTo` for the self link (Task 2). `selfUserID` (== "self:user") + `coreMemories()` (Task 2). `Confidence != .maybe`, `MemoryLayer.identity`, `members.count >= 4` consistent between the Task-2 code and its test. `InsightsOut` reused unchanged. The Task-2 insight-creation block supersedes the Task-1 block in the same loop (Task 2 explicitly replaces it).
