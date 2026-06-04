# Consolidation Pipeline: Machine-Native Clustering + Tagging + Provenance (SP-B) — Design Spec

**Date:** 2026-06-04
**Status:** Approved (brainstorm), pending plans
**Repo:** `gemma-memory` (i3 server), with a thin `personal_agent` app touch for tag surfacing.
**Builds on:** SP-A (traceable summaries — summaries carry chat_id+seq range).

---

## 1. Motivation

The consolidation engine is "sleep consolidation" — a human-shaped offline pipeline (extract → gist → forget). SP-B restructures it into an explicit 7-stage backbone and adds the two missing stages — **tagging** and **clustering** — plus **provenance**. The guiding decision (approved): keep the human-shaped *pipeline*, but use **machine-native mechanisms** inside each stage, because the machine has capabilities biology lacks:

- **Embeddings are the primary index**, not discrete tags — so we cluster on vectors and let tags *emerge* as cluster labels (cluster→tag), instead of the human tag→cluster order.
- **Real community detection** (graph-based, globally recomputed) beats the brain's greedy local merging.
- **Perfect immutable provenance** (a `derivesFrom` DAG) beats fading human source-memory.

This produces better-organized, more retrievable memory and emergent identity, while every abstraction can return to its source.

## 2. Goals

1. Reorder consolidation into the machine-native 7-stage backbone (+ the kept cognition phases), with graph-linking last on clean nodes.
2. **Embeddings as an explicit, idempotent stage** — the substrate for clustering.
3. **Clustering**: community detection (label-propagation) over a k-NN similarity graph, globally recomputed each cycle → ephemeral cluster anchors + `belongsToCluster` edges.
4. **Tagging (cluster→tag)**: the model labels each cluster with 1–3 canonical tags; members inherit them into a queryable `node_tags` table; synonym collapse by embedding (no LLM curation pass). Recall surfaces tags + supports a tag filter.
5. **Reflect per-cluster → identity (CAPA 4)**: insights grounded in cluster members; strong clusters promote a trait to the identity layer linked to `self`.
6. **Provenance DAG**: `derivesFrom` edges (insight→members, memory→summary) — every abstraction traces to evidence.

## 3. Non-Goals

- **Retraction/belief-revision propagation** (when a source is deleted/contradicted, propagate to derived nodes). Deferred — its own sub-project.
- **Stable cluster identity across cycles** (matching new clusters to old to preserve a cluster's accumulated metadata). Deferred — clusters are ephemeral; durable outputs live on member nodes.
- **Louvain/HDBSCAN**. Start with label-propagation; modularity-based clustering is a future upgrade.
- The research architecture from `logs.txt` (chunking, working summary). Deferred.

## 4. Design

### 4.1 Pipeline shape (machine-native order)

`runCycle` phase order becomes:
```
nrem(extract) → summarize → detect → embeddings → cluster → tag →
reflect → compress → curate → rem(graph-linking) → clarify → shy(forget)
```
- New stages: **embeddings**, **cluster**, **tag**.
- `compress` (insight dedup) + `curate` (kind normalization) remain — they are the "consolidation/hygiene" stage, now positioned after reflect.
- `rem`/`associate` (graph-linking) moves to **last** (before clarify/shy) so it links clean, clustered, deduped entities.
- `reflect` runs **after** clustering (per-cluster — see 4.4).
- `runLight` (awake-fast path) stays lean — global re-clustering runs only in the full sleep cycle.

The logical order: embed → cluster globally → label & reason over clusters → dedup within clusters → link clean entities last.

### 4.2 Embeddings stage

`embedMissing()` — idempotent: for every live clusterable node lacking a vector in `node_embedding`, compute + store it. Inline embedding at upsert stays (belt-and-suspenders); this stage guarantees completeness before clustering. New store primitive `allEmbeddings() -> [(id, [Float])]` (one query) for clustering input.

### 4.3 Clustering stage

- **Clusterable set:** durable atomic memories (person/place/preference/fact/trait/…) + `summary` nodes. Excluded: `self`, hubs, `event`, `conversation`, `insight`, `cluster`, `follow_up`.
- **k-NN graph:** for each clusterable node, edges to its k≈8 nearest neighbours with cosine distance ≤ 0.25 (an undirected similarity graph).
- **Community detection:** pure `labelPropagation(adjacency)` in MemoryCore → a partition. Near-linear, no fixed K, order-robust.
- **Global recompute each cycle:** delete prior `cluster` nodes + `belongsToCluster` edges, then create one `cluster` anchor per community (size ≥ 2) + `belongsToCluster` edges (anchor → each member). Singletons (no qualifying neighbour) get no cluster.
- **Ephemeral anchors, durable member outputs:** anchors are rebuilt every cycle; the durable artifacts (tags on members, insights, identity traits) live on real member nodes, so rebuild never orphans anything. The anchor is a navigation snapshot (visible in the brain-graph; recall can say "part of the 'trading' cluster").

### 4.4 Tagging stage (cluster→tag)

- For each cluster, one model call: given the member labels, return 1–3 short canonical lowercase tags. Per-cluster, not per-memory → far less drift, far cheaper.
- **Synonym collapse (machine-native, replaces the human curation pass):** embed each emitted tag; if within ≤ a tight cosine threshold of an existing distinct tag, reuse the canonical string; else it's new.
- **Storage:** `node_tags(node_id, tag)` table, indexed on `tag`. Each cluster member's tags are **overwritten** each cycle from its current cluster (a migrated node is re-tagged; a singleton's tags are cleared). The cluster anchor's label is set to its primary tag.
- **Recall use:** each recalled node carries its `tags`; recall accepts an optional `tag` filter (indexed lookup) so the agent can pull "what I know about finanzas" directly.

### 4.5 Reflect → identity + provenance (SP-B2)

- **Reflect per-cluster:** for each cluster (≥3 members) the model infers the stable higher-level pattern grounded in ≥2 members (anti-fabrication kept) → an `insight`. Coherent cluster input yields far better insights than a flat global list.
- **Identity promotion (deterministic rule):** an insight from a cluster with ≥4 members and confidence ≥ probable is promoted to the `identity` layer and linked to the `self` node — emergent CAPA 4 ("options trader").
- **Provenance DAG (`derivesFrom`, now used):** insight/trait → `derivesFrom` → its source member memories (replaces reflect's current `relatedTo`); each extracted atomic memory → `derivesFrom` → the `summary` of its thread. Full chain: identity-trait → memories → summary → transcript (the summary already traces to raw via SP-A). `derivesFrom` edges are durable (not rebuilt with clusters).

## 5. Data Model

- New table `node_tags(node_id TEXT, tag TEXT, PRIMARY KEY(node_id, tag))` + index on `tag` (migration `v9-node-tags`). Store methods `setTags(nodeId:_:)` (replace), `tagsFor(nodeId:)`, `nodesWithTag(_:)`, `distinctTags()`.
- New `NodeKind.cluster` (rawValue `"cluster"`) — ephemeral anchors (`hubLabel` "Cluster").
- New `Relation.belongsToCluster` (anchor → member) — ephemeral. `Relation.derivesFrom` already exists → now created (durable, SP-B2).
- New store primitive `allEmbeddings() -> [(id, [Float])]`.
- `SleepPhase` gains `embeddings`, `cluster`, `tag`.
- Clusters/edges need no schema (rows with the new enum cases).

## 6. Decomposition

Large → two implementation cycles, one design doc:

- **SP-B1 — embedding-centric grouping (this plan):** §4.1 reorder, §4.2 embeddings stage, §4.3 clustering, §4.4 tagging + recall tag surfacing/filter, §5 data model (node_tags, cluster kind, belongsToCluster, allEmbeddings). **Produces clusters + tags.**
- **SP-B2 — intelligence (next plan):** §4.5 reflect-per-cluster, identity promotion, `derivesFrom` provenance DAG. Depends on B1's clusters.

## 7. Testing (SP-B1)

- **Server unit:** `embedMissing` embeds only un-embedded nodes (idempotent); `labelPropagation` (pure) splits a synthetic 2-community graph into 2 partitions + isolates a singleton; clustering stage — seed N memories with embeddings in 2 semantic groups → 2 `cluster` anchors + correct `belongsToCluster` edges, and re-running rebuilds without duplicate clusters; tagging stage (canned model) writes `node_tags` to all members + synonym collapse reuses the canonical tag; `node_tags` store round-trips (set/tagsFor/nodesWithTag); recall returns each node's `tags` and an optional `tag` filter returns only tagged nodes; `runCycle` order is the new order and `rem`/`compress`/`curate` still run.
- **App unit:** recall decodes `tags` per node (thin).
- **E2E manual:** converse about two distinct themes → consolidate → verify 2 clusters, tags on members, and a tag-filtered recall returns the right subset.

## 8. Implementation order (SP-B1)

1. Data model: migration `v9-node-tags` + `node_tags` store methods; `NodeKind.cluster`; `Relation.belongsToCluster`; `allEmbeddings()`.
2. `labelPropagation` pure function + k-NN graph builder (MemoryCore).
3. Embeddings stage (`embedMissing`) + `SleepPhase.embeddings` + wire.
4. Clustering stage + `SleepPhase.cluster` + wire.
5. Tagging stage (cluster→tag + synonym collapse) + `SleepPhase.tag` + wire.
6. Pipeline reorder (new `order` array; `rem` last).
7. Recall: surface `tags` per node + optional `tag` filter (server) + thin app decode.
8. Deploy + manual E2E.

Server changes need a rebuild/redeploy; the app change ships in the next build.
