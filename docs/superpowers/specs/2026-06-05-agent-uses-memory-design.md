# Agent Uses Memory (SP-C) — Design Spec

**Date:** 2026-06-05
**Status:** Approved (brainstorm), pending plan
**Repos:** `gemma-memory` (i3 server) + `personal_agent` (app).
**Builds on:** SP-A (traceable summaries), SP-B (clustering + tagging + identity + `derivesFrom` provenance).

---

## 1. Motivation

SP-A/SP-B built a rich memory backend — episodic summaries with drill-down, thematic **tags** (cluster→tag), emergent **identity** insights, and a `derivesFrom` **provenance** DAG. But the agent barely exploits it: recall is a fixed per-turn top-k injection, the app decodes `tags` but never filters by them, and there is no way for the agent to enumerate a topic completely or to justify a belief from its evidence. This closes the loop: give the agent read-tools that turn the rich memory into precise conversational answers. The server already has the data + store methods (`nodesWithTag`, `distinctTags`, `edges(from:)`, `derivesFrom`); SP-C is mostly **exposing and wiring**, not new computation.

## 2. Goals

1. **Complete topic enumeration** — `recall_by_topic(topic)`: return ALL memories on a theme (tag-filtered), not the per-turn top-k. Fixes "enumera todo sobre X" gaps.
2. **Provenance / justification** — `why(claim)`: locate the matching insight and follow `derivesFrom` to the source memories, so the agent can cite *why* it believes something.
3. **Topic awareness** — `list_topics()`: the agent can answer "what do you know about me / what topics?" from the actual tag inventory.
4. The agent **knows when to use** these tools (prompt), and grounds answers in what they return.

## 3. Non-Goals

- Changing the automatic per-turn recall injection (unchanged — still injects relevant memory each turn).
- Changing consolidation/clustering/tagging/reflect (SP-B is done).
- A graph-navigation UI. The brain-graph view already exists; this is agent tools, not UI.
- Multi-hop provenance beyond `insight → members` (the only `derivesFrom` chain that exists; memory→summary was deferred in SP-B2).
- Letting the agent WRITE via these tools (all three are read-only).

## 4. Design

**Targeting principle (agent-friendly):** the agent passes **natural language**; the **server resolves** it — `topic` → nearest canonical tag (exact match, else embedding ≤ threshold); `claim` → best-matching insight (FTS, fallback semantic). The agent never needs to know exact canonical tags or node ids.

### 4.1 Server endpoints (GET, under `/v1`, bearer-protected)

- **`GET /v1/memory/tags`** → `{ "tags": [String] }`. Reuses `store.distinctTags()`.
- **`GET /v1/memory/by_topic?topic=<text>&limit=100`** → complete enumeration:
  1. Resolve `topic` to a canonical tag: exact match against `distinctTags()`; else embed the topic and pick the nearest distinct tag within a cosine threshold (≤ 0.2); no match → empty result.
  2. Return ALL nodes carrying that tag (`store.nodesWithTag(tag)` → `store.node(id:)`), capped at `limit` (default 100): `{ "tag": "<resolved or empty>", "nodes": [{kind,label,body}] }`.
- **`GET /v1/memory/why?claim=<text>`** → evidence chain:
  1. Locate the best `insight` node matching `claim`: `store.searchFTS(claim, limit)` filtered to `kind == insight`; fallback to `store.nearest(to: embed(claim))` filtered to insight. Take the top match.
  2. Traverse provenance: `store.edges(from: insight.id)` filtered to `relation == .derivesFrom` → source node ids → `store.node(id:)`.
  3. Return `{ "insight": "<body or empty>", "sources": [{kind,label,body}] }`. No matching insight → empty.

These mirror the existing GET handlers (`window`/`range`/`expand`) in style and registration. No DB migration (all reuse existing tables/edges).

### 4.2 App — `MemoryClient` methods

- `memoryTags() async throws -> [String]` → GET `/v1/memory/tags`.
- `recallByTopic(topic:limit:) async throws -> TopicResult` where `TopicResult{ tag: String; nodes: [TopicNode{kind,label,body}] }` → GET `/v1/memory/by_topic`.
- `why(claim:) async throws -> WhyResult` where `WhyResult{ insight: String; sources: [TopicNode] }` → GET `/v1/memory/why`.
(All decode their JSON; graceful — return empty on transport failure where reasonable, matching `recall`'s degrade-don't-crash convention, except surfacing a clear "memory unavailable" to the tool.)

### 4.3 App — three read tools (ToolRegistry)

- **`list_topics`** (no params) → calls `memoryTags()`, returns the tag list (or "no topics yet").
- **`recall_by_topic`** (param `topic: string`) → calls `recallByTopic`, formats the nodes as `- [kind] label: body` lines (or "nothing remembered about <topic>").
- **`why`** (param `claim: string`) → calls `why`, returns "I believe \"<insight>\" because: <sources>" (or "I can't trace that to a specific memory").

Each follows the `LoadMessagesTool` template: parse `argsJSON`, signal `ToolActivityRelay.started/finished`, access memory via `MemoryToolbox.shared.memory`, cap output length. Registered in `HarnessModel.runAgentTurn` alongside the other memory tools (only when `client != nil`).

### 4.4 App — prompt

One compact paragraph added to `Agent.systemPromptText`: the memory is rich (identity, episodic summaries, topics, derived insights); call `recall_by_topic` for a complete topic list, `why(claim)` to justify a belief and cite the source memories it returns, `list_topics` to report known topics; don't invent what a tool can answer. Preserves the existing JARVIS persona + anti-invention + self/identity + schedule + load_messages rules.

## 5. Data Flow

User: "¿qué sé de finanzas?" → agent calls `recall_by_topic("finanzas")` → server resolves "finanzas"→tag `finanzas` (or nearest) → returns all tagged nodes → agent enumerates them. / User: "¿por qué crees que soy trader?" → agent calls `why("soy trader de opciones")` → server finds the insight "trades options actively" → follows `derivesFrom` to `calls, puts, spreads` → agent answers "Creo que tradeas opciones porque mencionaste calls, puts y spreads."

## 6. Error Handling

- Unknown topic / no tag match → `by_topic` returns empty `nodes` + empty `tag`; the tool says "nothing remembered about <topic>".
- No insight matches the claim → `why` returns empty `insight`; the tool says it can't trace it.
- Memory service down → tools return "memory unavailable" (the client surfaces transport failure), the turn still completes (the agent answers from context).
- `limit` caps `by_topic` to avoid dumping huge topics; if more exist, the cap is silent (acceptable — topics are small at personal scale).

## 7. Testing

- **Server (unit):** `/v1/memory/tags` returns the distinct tags. `/v1/memory/by_topic`: exact tag → all its nodes; a near-synonym topic resolves to the canonical tag (stub/controlled embedder); unknown topic → empty. `/v1/memory/why`: seed an `insight` + `derivesFrom` edges to sources → a claim matching the insight returns those sources; an unmatchable claim → empty.
- **App (unit):** `MemoryClient.memoryTags`/`recallByTopic`/`why` decode (URLProtocol stub). Each tool parses its args, calls the client, and formats output (incl. the empty cases). `Agent.systemPromptText` contains the new guidance. The three tools are registered when `client != nil`.
- **E2E manual (on real memory with clusters/tags/identity):** "¿de qué temas sabes?" → `list_topics`; "¿qué sé de <tema>?" → `recall_by_topic` enumerates; "¿por qué crees <rasgo>?" → `why` cites the source memories.

## 8. Implementation order

1. **Server:** `GET /v1/memory/tags` + `GET /v1/memory/by_topic` (tag resolution + enumeration).
2. **Server:** `GET /v1/memory/why` (insight lookup + `derivesFrom` traversal).
3. **App:** `MemoryClient` methods + decode structs.
4. **App:** the three tools + registration + the prompt line.
5. **Deploy server + manual E2E.**

Server changes need a rebuild/redeploy; the app changes ship in the next build.
