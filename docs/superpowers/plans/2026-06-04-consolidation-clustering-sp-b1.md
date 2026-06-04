# Consolidation Clustering + Tagging (SP-B1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add machine-native clustering (community detection over a k-NN embedding graph, recomputed each cycle) and cluster→tag tagging to the consolidation pipeline, surfacing tags in recall — producing organized clusters + a queryable thematic tag layer.

**Architecture:** A new explicit `embeddings` stage guarantees every clusterable node has a vector; a `cluster` stage builds a k-NN similarity graph and runs label-propagation to form ephemeral cluster anchor nodes + `belongsToCluster` edges; a `tag` stage has the model label each cluster and writes the labels onto member nodes (`node_tags` table, synonym-collapsed by embedding). The pipeline is reordered so graph-linking (`rem`) runs last.

**Tech Stack:** Swift 6 — server (SwiftPM, GRDB, Hummingbird), thin app touch (SwiftUI). Spec: `docs/superpowers/specs/2026-06-04-consolidation-pipeline-clustering-design.md`. This is **SP-B1**; SP-B2 (reflect-per-cluster, identity promotion, `derivesFrom` DAG) is a separate plan.

**Server tests:** `swift test --filter <Name>` in `gemma-memory/memory-service` (branch from `main`).
**App tests:** `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/<Class> 2>&1 | tail -30`. **Known app failure to IGNORE:** `HarnessModelTests.test_defaultBaseURL_isLocalhost8081`.

**Engine context (verified current shapes):**
- `SleepPhase` enum: `MemoryStore.swift:4` — `case nrem, summarize, detect, rem, reflect, compress, clarify, curate, shy`.
- `runCycle` order array: `MemoryConsolidationEngine.swift:489` + the phase `switch` at 493–524 (exhaustive — adding an enum case REQUIRES a matching switch case).
- `NodeKind`: `MemoryModels.swift:6`. `hubLabel` switch ~30–48. `Relation`: `MemoryModels.swift:11`.
- `MemoryStore.cosineDistance(_:_:) -> Double` (static) exists (`MemoryStore+Vector.swift:38`). `nearest`/`setEmbedding`/`blobToFloats` there. Last migration `v8-transcript-seq` (`MemoryStore.swift:155`).
- Engine has `store`, `embedder` (`Embedder?`), `now()`, `generate(_:maxTokens:)`, `parse(_:_.self)`, `onProgress`.

---

## File Structure

- `Sources/MemoryCore/MemoryModels.swift` — `NodeKind.cluster` + `hubLabel`; `Relation.belongsToCluster`.
- `Sources/MemoryCore/MemoryStore.swift` — migration `v9-node-tags`; `SleepPhase` new cases.
- `Sources/MemoryCore/MemoryStore+Tags.swift` (create) — `node_tags` store methods.
- `Sources/MemoryCore/MemoryStore+Vector.swift` — `allEmbeddings()`.
- `Sources/MemoryCore/MemoryStore+Clusters.swift` (create) — `clearClusters()`.
- `Sources/MemoryCore/Clustering.swift` (create) — pure `knnGraph` + `labelPropagation`.
- `Sources/MemoryCore/MemoryConsolidationEngine.swift` — `embedMissing()`, `cluster()`, `tagClusters()`, the reordered `order`, new switch cases.
- `Sources/MemoryService/Handlers/MemoryHandlers.swift` — recall `tags` per node + optional `tag` filter.
- `Gemma/Gemma/Memory/MemoryClient.swift` — decode `tags` on `RecallNode`.

---

## Task 1: Data model — `node_tags`, `cluster` kind, `belongsToCluster`, `allEmbeddings`, `clearClusters`

**Files:** `MemoryModels.swift`, `MemoryStore.swift`, `MemoryStore+Tags.swift` (create), `MemoryStore+Vector.swift`, `MemoryStore+Clusters.swift` (create); Test: `Tests/MemoryCoreTests/NodeTagsTests.swift` (create).

### Step 0: Read `MemoryModels.swift` (`NodeKind` line 6, `hubLabel` switch, `Relation` line 11), the `migrator` in `MemoryStore.swift` (last = `v8-transcript-seq`), and how `node_fts`/`node_embedding` rows are removed when a node is deleted (grep `node_fts`, `softDelete`, any `DELETE FROM node`) — so `clearClusters` cleans up consistently.

### Step 1: Failing test — `Tests/MemoryCoreTests/NodeTagsTests.swift`:
```swift
import XCTest
import GRDB
@testable import MemoryCore

final class NodeTagsTests: XCTestCase {
    func test_node_tags_roundtrip_and_overwrite() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 1024)
        try store.setTags(nodeId: "n1", ["trading", "finanzas"])
        XCTAssertEqual(try store.tagsFor(nodeId: "n1"), ["finanzas", "trading"])   // sorted
        XCTAssertEqual(try store.nodesWithTag("trading"), ["n1"])
        try store.setTags(nodeId: "n1", ["salud"])                                 // overwrite replaces
        XCTAssertEqual(try store.tagsFor(nodeId: "n1"), ["salud"])
        XCTAssertEqual(try store.nodesWithTag("trading"), [])
        XCTAssertEqual(try store.distinctTags(), ["salud"])
    }
    func test_clusterKind_and_relation_exist() {
        XCTAssertEqual(NodeKind.cluster.rawValue, "cluster")
        XCTAssertEqual(Relation.belongsToCluster.rawValue, "belongsToCluster")
    }
}
```

### Step 2: Run → FAIL: `swift test --filter NodeTagsTests`.

### Step 3a: `MemoryModels.swift` — add the kind + relation.
- `NodeKind`: append `, cluster` to the case list.
- `hubLabel` switch: add `case .cluster: return "Cluster"`.
- `Relation`: in the structural group, add `case belongsToCluster   // src = cluster anchor, dst = member (ephemeral, rebuilt each cycle)`.

### Step 3b: Migration. In `MemoryStore.swift`'s `migrator`, after `"v8-transcript-seq"`:
```swift
m.registerMigration("v9-node-tags") { db in
    try db.create(table: "node_tags") { t in
        t.column("node_id", .text).notNull()
        t.column("tag", .text).notNull()
        t.primaryKey(["node_id", "tag"])
    }
    try db.create(indexOn: "node_tags", columns: ["tag"])
}
```

### Step 3c: `Sources/MemoryCore/MemoryStore+Tags.swift` (create):
```swift
import Foundation
import GRDB

extension MemoryStore {
    /// Replace all tags for a node (overwrite). Empty/whitespace tags are skipped.
    public func setTags(nodeId: String, _ tags: [String]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM node_tags WHERE node_id = ?", arguments: [nodeId])
            for tag in Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !tag.isEmpty {
                try db.execute(sql: "INSERT OR IGNORE INTO node_tags(node_id, tag) VALUES (?, ?)", arguments: [nodeId, tag])
            }
        }
    }
    public func tagsFor(nodeId: String) throws -> [String] {
        try dbQueue.read { db in try String.fetchAll(db, sql: "SELECT tag FROM node_tags WHERE node_id = ? ORDER BY tag", arguments: [nodeId]) }
    }
    public func nodesWithTag(_ tag: String) throws -> [String] {
        try dbQueue.read { db in try String.fetchAll(db, sql: "SELECT node_id FROM node_tags WHERE tag = ? ORDER BY node_id", arguments: [tag]) }
    }
    public func distinctTags() throws -> [String] {
        try dbQueue.read { db in try String.fetchAll(db, sql: "SELECT DISTINCT tag FROM node_tags ORDER BY tag") }
    }
}
```

### Step 3d: `MemoryStore+Vector.swift` — add `allEmbeddings` (mirror `nearest`'s SELECT):
```swift
/// All stored node embeddings (one query) — input for clustering.
public func allEmbeddings() throws -> [(id: String, vec: [Float])] {
    try dbQueue.read { db in
        try Row.fetchAll(db, sql: "SELECT node_id, embedding FROM node_embedding")
            .map { (id: $0["node_id"] as String, vec: Self.blobToFloats($0["embedding"] as Data)) }
    }
}
```

### Step 3e: `Sources/MemoryCore/MemoryStore+Clusters.swift` (create) — remove all ephemeral cluster nodes + edges:
```swift
import Foundation
import GRDB

extension MemoryStore {
    /// Hard-delete all `cluster` anchor nodes and `belongsToCluster` edges (rebuilt each cycle).
    public func clearClusters() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM edge WHERE relation = ?", arguments: [Relation.belongsToCluster.rawValue])
            let ids = try String.fetchAll(db, sql: "SELECT id FROM node WHERE kind = ?", arguments: [NodeKind.cluster.rawValue])
            guard !ids.isEmpty else { return }
            let ph = ids.map { _ in "?" }.joined(separator: ",")
            try db.execute(sql: "DELETE FROM node_embedding WHERE node_id IN (\(ph))", arguments: StatementArguments(ids))
            try db.execute(sql: "DELETE FROM node_tags WHERE node_id IN (\(ph))", arguments: StatementArguments(ids))
            try db.execute(sql: "DELETE FROM node WHERE kind = ?", arguments: [NodeKind.cluster.rawValue])
        }
    }
}
```
**ADAPT** per Step 0: if `node_fts` is NOT trigger-maintained (i.e. existing node-deletion code manually deletes from `node_fts`), add `try db.execute(sql: "DELETE FROM node_fts WHERE ...")` for the cluster ids too, matching the existing pattern. If it IS trigger-maintained (FTS5 external-content with triggers), the `DELETE FROM node` cascades — leave it.

### Step 4: Run → PASS: `swift test --filter NodeTagsTests`, then full `swift test`. (Adding a `NodeKind` case creates a `hub:cluster` via `ensureKindHubs` — additive/harmless. If a test enumerates all kinds and breaks, report it.)

### Step 5: Commit
```bash
git add Sources/MemoryCore/MemoryModels.swift Sources/MemoryCore/MemoryStore.swift Sources/MemoryCore/MemoryStore+Tags.swift Sources/MemoryCore/MemoryStore+Vector.swift Sources/MemoryCore/MemoryStore+Clusters.swift Tests/MemoryCoreTests/NodeTagsTests.swift
git commit -m "feat(clustering): data model — node_tags, cluster kind, belongsToCluster, allEmbeddings, clearClusters"
```

---

## Task 2: Pure clustering — k-NN graph + label propagation

**Files:** `Sources/MemoryCore/Clustering.swift` (create); Test: `Tests/MemoryCoreTests/ClusteringTests.swift` (create).

### Step 1: Failing test — `Tests/MemoryCoreTests/ClusteringTests.swift`:
```swift
import XCTest
@testable import MemoryCore

final class ClusteringTests: XCTestCase {
    func test_knnGraph_links_close_not_far() {
        // two tight pairs, far apart
        let embs: [(id: String, vec: [Float])] = [
            ("a", [1, 0, 0, 0]), ("b", [0.99, 0.01, 0, 0]),
            ("x", [0, 0, 1, 0]), ("y", [0, 0, 0.99, 0.01]),
        ]
        let adj = Clustering.knnGraph(embs, k: 8, maxDistance: 0.25)
        XCTAssertTrue(adj["a"]!.contains("b")); XCTAssertTrue(adj["b"]!.contains("a"))
        XCTAssertTrue(adj["x"]!.contains("y"))
        XCTAssertFalse(adj["a"]!.contains("x"))   // far → no edge
    }
    func test_labelPropagation_two_communities_and_drops_singleton() {
        let adj: [String: Set<String>] = [
            "a": ["b", "c"], "b": ["a", "c"], "c": ["a", "b"],
            "x": ["y", "z"], "y": ["x", "z"], "z": ["x", "y"],
            "lonely": [],
        ]
        let groups = Clustering.labelPropagation(adj, minSize: 2)
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.contains { Set($0) == ["a", "b", "c"] })
        XCTAssertTrue(groups.contains { Set($0) == ["x", "y", "z"] })
        XCTAssertFalse(groups.contains { $0.contains("lonely") })   // singleton dropped
    }
}
```

### Step 2: Run → FAIL (no `Clustering`).

### Step 3: `Sources/MemoryCore/Clustering.swift` (create):
```swift
import Foundation

/// Pure, deterministic embedding-graph clustering (no model/db). Builds a k-NN similarity
/// graph and runs label propagation for community detection.
public enum Clustering {
    /// Undirected k-NN adjacency: each node linked to its ≤k nearest neighbours within
    /// `maxDistance` (cosine). Symmetric.
    public static func knnGraph(_ embeddings: [(id: String, vec: [Float])], k: Int, maxDistance: Double) -> [String: Set<String>] {
        var adj: [String: Set<String>] = [:]
        for (id, _) in embeddings { adj[id] = [] }
        for (i, a) in embeddings.enumerated() {
            var dists: [(String, Double)] = []
            for (j, b) in embeddings.enumerated() where i != j {
                let d = MemoryStore.cosineDistance(a.vec, b.vec)
                if d <= maxDistance { dists.append((b.id, d)) }
            }
            for (nid, _) in dists.sorted(by: { $0.1 < $1.1 }).prefix(k) {
                adj[a.id, default: []].insert(nid)
                adj[nid, default: []].insert(a.id)
            }
        }
        return adj
    }

    /// Label-propagation community detection. Each node starts in its own community and adopts
    /// the most frequent neighbour label (ties → lexicographically smallest, for determinism),
    /// iterated to convergence. Returns communities of size ≥ `minSize`, each sorted, ordered by
    /// first member.
    public static func labelPropagation(_ adjacency: [String: Set<String>], minSize: Int = 2, maxIterations: Int = 20) -> [[String]] {
        var label: [String: String] = [:]
        let ids = adjacency.keys.sorted()
        for id in ids { label[id] = id }
        for _ in 0..<maxIterations {
            var changed = false
            for id in ids {
                let neighbours = adjacency[id] ?? []
                guard !neighbours.isEmpty else { continue }
                var counts: [String: Int] = [:]
                for n in neighbours { counts[label[n] ?? n, default: 0] += 1 }
                let best = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first!.key
                if label[id] != best { label[id] = best; changed = true }
            }
            if !changed { break }
        }
        var groups: [String: [String]] = [:]
        for (id, lab) in label { groups[lab, default: []].append(id) }
        return groups.values.map { $0.sorted() }.filter { $0.count >= minSize }.sorted { $0[0] < $1[0] }
    }
}
```

### Step 4: Run → PASS: `swift test --filter ClusteringTests`, then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryCore/Clustering.swift Tests/MemoryCoreTests/ClusteringTests.swift
git commit -m "feat(clustering): pure k-NN graph + label-propagation community detection"
```

---

## Task 3: Embeddings stage (`embedMissing`)

**Files:** `MemoryCore/MemoryStore.swift` (SleepPhase), `MemoryConsolidationEngine.swift`; Test: `Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift` (append).

### Step 0: Read the `SleepPhase` enum (`MemoryStore.swift:4`) + the `runCycle` switch (`MemoryConsolidationEngine.swift:493–524`) — note adding a case to `SleepPhase` makes the switch non-exhaustive until you add the matching case. Read how the engine accesses `store`/`embedder` and a method like `compress()`/`curateKinds()` to mirror style. Check whether `MemoryStore` exposes a way to know which nodes lack an embedding (there is `allEmbeddings()` from Task 1 + `allNodes()`).

### Step 1: Failing test — append to `MemoryConsolidationEngineTests.swift` (mirror the file's engine construction with `CannedRuntime`/`FakeEmbedder`):
```swift
func test_embedMissing_embeds_only_unembedded_nodes() async throws {
    let store = try MemoryStore(inMemory: true, embeddingDim: 4)
    let n1 = Node(id: "n1", kind: NodeKind.preference.rawValue, label: "sushi", body: "sushi", layer: .daily,
                  createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0, confidence: .probable,
                  mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                  dirty: true, deleted: false, extra: nil)
    try store.upsert(n1)                                   // upsert may embed inline; clear to simulate a gap:
    // ensure n1 has NO embedding (remove any inline one)
    try store.removeEmbeddingForTest(nodeId: "n1")         // see note
    XCTAssertTrue(try store.allEmbeddings().isEmpty)
    let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime([]))
    await engine.embedMissing()
    XCTAssertEqual(try store.allEmbeddings().count, 1)     // n1 now embedded
}
```
**Note:** `upsert` does NOT auto-embed (embedding is set separately via `setEmbedding`/`upsertMergingSemantic`); confirm in Step 0. If `upsert` leaves `n1` un-embedded, delete the `removeEmbeddingForTest` line and the comment — just assert `allEmbeddings().isEmpty` after `upsert`. If you DO need to clear an embedding for the test, add a tiny test-only helper `removeEmbeddingForTest` OR `setEmbedding` then assert `embedMissing` is a no-op for already-embedded nodes (adjust the test to match reality you find in Step 0). Keep the core assertion: after `embedMissing`, every clusterable node has an embedding, and it does NOT re-embed already-embedded ones.

### Step 2: Run → FAIL (`embedMissing` undefined).

### Step 3a: `SleepPhase` (`MemoryStore.swift:4`): add `embeddings` → `case nrem, summarize, detect, embeddings, rem, reflect, compress, clarify, curate, shy` (position doesn't matter yet — the `order` array in Task 6 sets execution order).

### Step 3b: In `runCycle`'s switch, add a case:
```swift
case .embeddings: await embedMissing()
```

### Step 3c: Add the method to `MemoryConsolidationEngine` (near `compress`/`reflect`):
```swift
/// Clusterable node kinds (durable atomic memories + summaries). Excludes self, hubs, events,
/// conversation, insight, cluster, follow_up, clarification, day, episode, task.
static let clusterableKinds: Set<String> = [
    NodeKind.person.rawValue, NodeKind.place.rawValue, NodeKind.fact.rawValue,
    NodeKind.preference.rawValue, NodeKind.topic.rawValue, NodeKind.trait.rawValue,
    NodeKind.plan.rawValue, NodeKind.summary.rawValue,
]

/// Idempotent: embed every clusterable node that lacks a vector. The substrate for clustering.
public func embedMissing() async {
    guard let embedder else { return }
    let embedded = Set(((try? store.allEmbeddings()) ?? []).map { $0.id })
    let nodes = ((try? store.allNodes()) ?? []).filter {
        Self.clusterableKinds.contains($0.kind) && !embedded.contains($0.id)
    }
    var done = 0
    for n in nodes {
        let text = n.body.isEmpty ? n.label : n.label + " " + n.body
        if let v = try? embedder.embed(text) { try? store.setEmbedding(nodeId: n.id, v); done += 1 }
    }
    if done > 0 { onProgress?("+\(done) embeddings") }
}
```

### Step 4: Run → PASS, then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryCore/MemoryStore.swift Sources/MemoryCore/MemoryConsolidationEngine.swift Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(clustering): embeddings stage — embedMissing ensures every clusterable node has a vector"
```

---

## Task 4: Clustering stage (`cluster`)

**Files:** `MemoryCore/MemoryStore.swift` (SleepPhase), `MemoryConsolidationEngine.swift`; Test: `MemoryConsolidationEngineTests.swift` (append).

### Step 1: Failing test — append:
```swift
func test_cluster_builds_anchors_and_belongsTo_edges() async throws {
    let store = try MemoryStore(inMemory: true, embeddingDim: 4)
    // two semantic groups
    let seeds: [(String, [Float])] = [
        ("a", [1, 0, 0, 0]), ("b", [0.98, 0.02, 0, 0]), ("c", [0.97, 0.03, 0, 0]),
        ("x", [0, 0, 1, 0]), ("y", [0, 0, 0.98, 0.02]), ("z", [0, 0, 0.97, 0.03]),
    ]
    for (id, vec) in seeds {
        let n = Node(id: id, kind: NodeKind.preference.rawValue, label: id, body: id, layer: .daily,
                     createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0, confidence: .probable,
                     mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                     dirty: true, deleted: false, extra: nil)
        try store.upsert(n); try store.setEmbedding(nodeId: id, vec)
    }
    let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime([]))
    await engine.cluster()
    let clusters = try store.allNodes().filter { $0.kind == NodeKind.cluster.rawValue }
    XCTAssertEqual(clusters.count, 2)
    // each cluster has 3 belongsToCluster edges
    for c in clusters {
        let members = (try store.edges(from: c.id)).filter { $0.relation == .belongsToCluster }
        XCTAssertEqual(members.count, 3)
    }
    // re-running rebuilds (still 2, no duplicates)
    await engine.cluster()
    XCTAssertEqual(try store.allNodes().filter { $0.kind == NodeKind.cluster.rawValue }.count, 2)
}
```
(Confirm `store.edges(from:)` exists and returns `[Edge]` — used by the retriever; if the accessor differs, use the real one.)

### Step 2: Run → FAIL.

### Step 3a: `SleepPhase`: add `cluster` → `case nrem, summarize, detect, embeddings, cluster, rem, reflect, compress, clarify, curate, shy`. Add switch case `case .cluster: await cluster()`.

### Step 3b: Add the method:
```swift
/// Recompute clusters globally: build a k-NN graph over clusterable embeddings, run
/// label-propagation, and rebuild ephemeral `cluster` anchors + `belongsToCluster` edges.
public func cluster() async {
    let nodes = (try? store.allNodes()) ?? []
    let clusterableIds = Set(nodes.filter { Self.clusterableKinds.contains($0.kind) }.map { $0.id })
    let embs = ((try? store.allEmbeddings()) ?? []).filter { clusterableIds.contains($0.id) }
    try? store.clearClusters()
    guard embs.count >= 2 else { return }
    let adj = Clustering.knnGraph(embs.map { (id: $0.id, vec: $0.vec) }, k: 8, maxDistance: 0.25)
    let communities = Clustering.labelPropagation(adj, minSize: 2)
    let t = now()
    var made = 0
    for community in communities {
        let anchorId = UUID().uuidString
        let anchor = Node(id: anchorId, kind: NodeKind.cluster.rawValue, label: "cluster", body: "",
                          layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t,
                          salience: Double(community.count), decayRate: 0, confidence: .probable,
                          mentionCount: community.count, ttlExpiresAt: nil, sourceRef: nil,
                          origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        try? store.upsert(anchor)
        for memberId in community {
            try? store.upsert(Edge(id: UUID().uuidString, srcId: anchorId, dstId: memberId,
                                   relation: .belongsToCluster, weight: 1, confidence: .probable,
                                   createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
        }
        made += 1
    }
    onProgress?("+\(made) clusters")
}
```
(Note: `store.upsert(anchor)` auto-links the anchor to `hub:cluster` via the existing `linkToHub` — harmless. `clearClusters()` runs FIRST so each cycle starts clean, even when there are <2 embeddings.)

### Step 4: Run → PASS, then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryCore/MemoryStore.swift Sources/MemoryCore/MemoryConsolidationEngine.swift Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(clustering): clustering stage — k-NN communities → ephemeral cluster anchors + belongsToCluster"
```

---

## Task 5: Tagging stage (`tagClusters`) — cluster→tag + synonym collapse

**Files:** `MemoryCore/MemoryStore.swift` (SleepPhase), `MemoryConsolidationEngine.swift`; Test: `MemoryConsolidationEngineTests.swift` (append).

### Step 0: Read how the engine declares its model-output `Decodable` structs (e.g. `EntitiesOut`, `EdgesOut`) and `parse(_:_.self)`. Read `CannedRuntime` (it returns canned strings from `generate` in order). The tagging stage makes ONE `generate` call per cluster, so the canned array needs one entry per cluster (in cluster-iteration order — `store.allNodes().filter kind==cluster`).

### Step 1: Failing test — append. Use a controlled stub embedder so the synonym-collapse is deterministic:
```swift
func test_tagClusters_writes_tags_to_members_and_collapses_synonyms() async throws {
    let store = try MemoryStore(inMemory: true, embeddingDim: 4)
    // Two members already tagged "trading" (seed the vocabulary), one cluster of two NEW members.
    func mk(_ id: String) -> Node {
        Node(id: id, kind: NodeKind.preference.rawValue, label: id, body: id, layer: .daily, createdAt: 1,
             updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0, confidence: .probable, mentionCount: 1,
             ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
    }
    try store.upsert(mk("m1")); try store.upsert(mk("m2"))
    try store.setTags(nodeId: "old", ["trading"])               // existing vocabulary
    // a cluster anchor with m1,m2 as members
    let anchor = mk("clusterA"); var a = anchor; a.kind = NodeKind.cluster.rawValue; a.label = "cluster"; try store.upsert(a)
    for m in ["m1", "m2"] {
        try store.upsert(Edge(id: UUID().uuidString, srcId: "clusterA", dstId: m, relation: .belongsToCluster,
                              weight: 1, confidence: .probable, createdAt: 1, updatedAt: 1, dirty: true, deleted: false, extra: nil))
    }
    // stub embedder: "inversión" maps NEAR "trading"; everything else distinct
    let stub = SynonymStubEmbedder(near: ["inversión": "trading"], dim: 4)
    let json = #"{"tags":["inversión"]}"#
    let engine = MemoryConsolidationEngine(store: store, embedder: stub, runtime: CannedRuntime([json]))
    await engine.tagClusters()
    // synonym collapsed → members tagged "trading", not "inversión"
    XCTAssertEqual(try store.tagsFor(nodeId: "m1"), ["trading"])
    XCTAssertEqual(try store.tagsFor(nodeId: "m2"), ["trading"])
    // anchor renamed to its primary tag
    XCTAssertEqual(try store.node(id: "clusterA")?.label, "trading")
}
```
Add the stub embedder at the bottom of the test file (or a shared test helpers file):
```swift
/// Test embedder: returns a fixed vector per string; strings in `near` map to the SAME vector as
/// their target, so cosine distance is 0 (collapse). Unknown strings get a per-string unit vector.
final class SynonymStubEmbedder: Embedder, @unchecked Sendable {
    let near: [String: String]; let dim: Int
    init(near: [String: String], dim: Int) { self.near = near; self.dim = dim }
    func embed(_ text: String) throws -> [Float] {
        let key = near[text] ?? text
        var v = [Float](repeating: 0, count: dim)
        v[abs(key.hashValue) % dim] = 1
        return v
    }
}
```
(Confirm the real `Embedder` protocol signature — `func embed(_:) throws -> [Float]` — and match it. If `embed` is `async`/non-throwing, adjust the stub.)

### Step 2: Run → FAIL (`tagClusters` undefined).

### Step 3a: `SleepPhase`: add `tag` → `case nrem, summarize, detect, embeddings, cluster, tag, rem, reflect, compress, clarify, curate, shy`. Add switch case `case .tag: await tagClusters()`.

### Step 3b: Add the model-output struct (near the other `*Out` structs in the engine):
```swift
private struct TagsOut: Decodable { let tags: [String] }
```

### Step 3c: Add the method:
```swift
/// Label each cluster with 1-3 canonical thematic tags (cluster→tag) and write them onto the
/// member nodes. New tags are collapsed onto an existing near-synonym (embedding ≤ 0.15) so the
/// vocabulary stays clean without an LLM curation pass.
public func tagClusters() async {
    let clusters = ((try? store.allNodes()) ?? []).filter { $0.kind == NodeKind.cluster.rawValue }
    guard !clusters.isEmpty else { return }
    // existing tag vocabulary, embedded once
    var vocab: [(tag: String, vec: [Float])] = []
    for tag in (try? store.distinctTags()) ?? [] {
        if let v = (try? embedder?.embed(tag)) ?? nil { vocab.append((tag, v)) }
    }
    func canonical(_ raw: String) -> String? {
        let tag = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return nil }
        if let existing = vocab.first(where: { $0.tag == tag }) { return existing.tag }   // exact reuse
        if let v = (try? embedder?.embed(tag)) ?? nil {
            if let hit = vocab.min(by: { MemoryStore.cosineDistance($0.vec, v) < MemoryStore.cosineDistance($1.vec, v) }),
               MemoryStore.cosineDistance(hit.vec, v) <= 0.15 { return hit.tag }           // synonym collapse
            vocab.append((tag, v))                                                         // new canonical
        }
        return tag
    }
    for cluster in clusters {
        let memberIds = ((try? store.edges(from: cluster.id)) ?? []).filter { $0.relation == .belongsToCluster }.map { $0.dstId }
        let members = memberIds.compactMap { try? store.node(id: $0) }
        guard !members.isEmpty else { continue }
        let labels = members.map { $0.label }.joined(separator: ", ")
        let prompt = """
        These memories form ONE thematic group about the user: \(labels).
        Give 1-3 short canonical lowercase thematic tags (a single word or two-word phrase each). Output JSON only.
        Schema: {"tags":["..."]}
        JSON:
        """
        guard let out = parse(await generate(prompt, maxTokens: 128), TagsOut.self) else { continue }
        let tags = Array(out.tags.compactMap(canonical).prefix(3))
        guard !tags.isEmpty else { continue }
        for m in members { try? store.setTags(nodeId: m.id, tags) }
        if var c = try? store.node(id: cluster.id) { c.label = tags[0]; c.updatedAt = now(); c.dirty = true; try? store.upsert(c) }
    }
    onProgress?("tagged \(clusters.count) clusters")
}
```

### Step 4: Run → PASS, then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryCore/MemoryStore.swift Sources/MemoryCore/MemoryConsolidationEngine.swift Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(tagging): cluster→tag stage with embedding synonym-collapse; tags written to members"
```

---

## Task 6: Pipeline reorder

**Files:** `MemoryConsolidationEngine.swift`; Test: `MemoryConsolidationEngineTests.swift` (append).

### Step 1: Failing test — append:
```swift
func test_runCycle_order_is_machine_native() {
    XCTAssertEqual(MemoryConsolidationEngine.cycleOrder,
                   [.nrem, .summarize, .detect, .embeddings, .cluster, .tag,
                    .reflect, .compress, .curate, .rem, .clarify, .shy])
}
```

### Step 2: Run → FAIL (`cycleOrder` not exposed / order differs).

### Step 3: In `MemoryConsolidationEngine`, replace the local `let order: [SleepPhase] = [...]` at line 489 with a reference to a static, and define the static (so it's testable):
```swift
static let cycleOrder: [SleepPhase] = [
    .nrem, .summarize, .detect, .embeddings, .cluster, .tag,
    .reflect, .compress, .curate, .rem, .clarify, .shy,
]
```
and in `runCycle`: `let order = MemoryConsolidationEngine.cycleOrder`. (The switch already handles every case from Tasks 3–5; this only changes the execution order so `rem`/graph-linking runs after clustering+tagging+reflect+compress+curate, on clean nodes.)

### Step 4: Run → PASS, then full `swift test`. (A resumed in-flight cycle persisted with an old phase still resolves via `order.firstIndex(of:)`; if its phase isn't in the new order it returns at the guard — acceptable, cycles are short-lived and the i3 memory is freshly migrated.)

### Step 5: Commit
```bash
git add Sources/MemoryCore/MemoryConsolidationEngine.swift Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(consolidation): machine-native phase order — embed→cluster→tag→reflect→…→graph-linking last"
```

---

## Task 7: Recall surfaces tags (+ optional tag filter)

**Files:** `Sources/MemoryService/Handlers/MemoryHandlers.swift`, `Gemma/Gemma/Memory/MemoryClient.swift`; Test: `Tests/MemoryServiceTests/MemoryEndpointsTests.swift` (append) + `Gemma/GemmaTests/MemoryClientTests.swift` (append).

### Step 0: Read the `recall` handler (`MemoryHandlers.swift` — the `OutNode` struct + `RecallBody` decode + how `core`/`recall` are built, post SP-A which added the `summaries` tier). Read app `MemoryClient.RecallNode`.

### Step 1: Failing test — server, append to `MemoryEndpointsTests.swift`:
```swift
func test_recall_attaches_tags_and_filters_by_tag() async throws {
    let (app, services) = try await makeAppWithServices()
    func seed(_ id: String, _ label: String, tags: [String]) throws {
        let n = Node(id: id, kind: NodeKind.preference.rawValue, label: label, body: label, layer: .daily,
                     createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 5, decayRate: 0, confidence: .probable,
                     mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                     dirty: true, deleted: false, extra: nil)
        try services.store.upsert(n)
        try services.store.setEmbedding(nodeId: id, services.embedder.embed(label))
        try services.store.setTags(nodeId: id, tags)
    }
    try seed("n1", "opciones", tags: ["trading"])
    try seed("n2", "yoga", tags: ["salud"])
    struct Out: Decodable { struct N: Decodable { let label: String; let tags: [String] }; let recall: [N] }
    try await app.test(.live) { client in
        try await client.execute(uri: "/v1/memory/recall", method: .post,
            headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
            body: ByteBuffer(string: #"{"query":"opciones","tag":"trading"}"#)) { res in
            let out = try JSONDecoder().decode(Out.self, from: Data(buffer: res.body))
            XCTAssertTrue(out.recall.contains { $0.label == "opciones" && $0.tags == ["trading"] })
            XCTAssertFalse(out.recall.contains { $0.label == "yoga" })   // filtered out by tag
        }
    }
}
```
ADAPT to the real `Node(...)` init, `makeAppWithServices`, `services.embedder.embed`, response decode.

### Step 2: Run → FAIL.

### Step 3a: Server. In `MemoryHandlers.swift`:
- Add `tag` to `RecallBody`: `let tag: String?` (optional).
- Add `tags` to `OutNode`: `let tags: [String]` and populate it in `toOut` via `(try? services.store.tagsFor(nodeId: n.id)) ?? []`.
- After building `recallNodes`, if `body.tag` is non-nil/non-empty, filter: keep only nodes whose id is in `services.store.nodesWithTag(tag)`:
```swift
var recallNodes = retrieved.filter { !coreIds.contains($0.id) }
if let tag = body.tag, !tag.isEmpty {
    let allowed = Set((try? services.store.nodesWithTag(tag)) ?? [])
    recallNodes = recallNodes.filter { allowed.contains($0.id) }
}
```
(Apply the filter to the `recallNodes` used for the `recall`/`summaries` split from SP-A. `core` identity is NOT tag-filtered. Keep the existing summaries-split logic.)

### Step 3b: App. In `MemoryClient.RecallNode`, add `let tags: [String]` (the server now always sends it). Update any `RecallNode(...)` test constructors + recall JSON mocks lacking `tags` (grep `RecallNode(` and recall payload mocks in `GemmaTests/`; add `tags: []` / `"tags":[]`). Append a decode test:
```swift
func test_recall_node_decodes_tags() async throws {
    StubProtocol.stub = { req in
        let payload = #"{"core":[],"recall":[{"kind":"preference","label":"opciones","body":"x","extra":null,"tags":["trading"]}],"summaries":[],"recentTurns":[]}"#.data(using: .utf8)!
        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, payload)
    }
    let bundle = try await makeClient().recall(query: "opciones", scope: nil, limit: nil)
    XCTAssertEqual(bundle.recall.first?.tags, ["trading"])
}
```

### Step 4: Run server `swift test --filter test_recall_attaches_tags_and_filters_by_tag` + full `swift test` → green. Then app `-only-testing:GemmaTests/MemoryClientTests` → green (only the known failure elsewhere).

### Step 5: Commit
```bash
git add Sources/MemoryService/Handlers/MemoryHandlers.swift Gemma/Gemma/Memory/MemoryClient.swift Gemma/GemmaTests/ Tests/MemoryServiceTests/MemoryEndpointsTests.swift
git commit -m "feat(recall): attach tags per node + optional tag filter"
```

---

## Task 8: Deploy server + manual E2E

- [ ] **Deploy:** `ssh HomeLab 'cd ~/Projects/gemma-memory && git pull --ff-only origin main && docker compose build memory && docker compose up -d memory'`. Verify `healthz` 200 and migration `v9-node-tags` applied (a `save`+`recall` still works).
- [ ] **App build (⌘R) on fresh-ish memory:** converse about two clearly distinct themes (e.g. options trading; family/health) across enough turns to extract several memories → trigger consolidation (idle / button) → in the inspector / brain-graph, confirm **2 cluster anchors** named by their tags, members linked by `belongsToCluster`, and each member carries the cluster's `tag`. Then ask a tag-scoped question and confirm recall returns the right subset.
- [ ] **Record** the result.

---

## Self-Review

**Spec coverage:** §4.1 reorder → Task 6. §4.2 embeddings stage → Task 3. §4.3 clustering (k-NN + label-propagation + ephemeral anchors) → Tasks 2 + 4. §4.4 tagging (cluster→tag, synonym collapse, node_tags, recall surfacing/filter) → Tasks 5 + 7. §5 data model → Task 1. §7 testing → unit tests in Tasks 1–7 + E2E Task 8. §8 order → Tasks 1–8. SP-B2 (reflect-per-cluster, identity, derivesFrom) correctly NOT in this plan. ✓

**Placeholder scan:** No TBD/TODO. Step-0 "verify the real shape" notes (Embedder signature, `store.edges(from:)`, `node_fts` deletion path, `upsert` embedding behavior, `RecallNode` mocks) point to concrete existing code to mirror, not invented APIs. The one conditional in Task 3 (how to make a node un-embedded for the test) is resolved by Step 0 inspection with both branches specified.

**Type consistency:** `NodeKind.cluster` ("cluster") + `Relation.belongsToCluster` (Task 1) used by `clearClusters` (Task 1), `cluster()` (Task 4), `tagClusters()` (Task 5). `Clustering.knnGraph`/`labelPropagation` (Task 2) consumed by `cluster()` (Task 4). `clusterableKinds` (Task 3) used by `embedMissing` (Task 3) + `cluster()` (Task 4). `allEmbeddings() -> [(id,vec)]` (Task 1) used in Tasks 3, 4. `node_tags` methods `setTags`/`tagsFor`/`nodesWithTag`/`distinctTags` (Task 1) used in Tasks 5, 7. `SleepPhase` cases `embeddings`/`cluster`/`tag` added in Tasks 3/4/5, ordered in `cycleOrder` (Task 6). `OutNode.tags` + `RecallBody.tag` (Task 7, server) ↔ `RecallNode.tags` (Task 7, app).
