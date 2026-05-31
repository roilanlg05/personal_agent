# M2b-1 — Memory Foundations (episodic chat + clean capture + multi-timescale salience + relevance injection) — Design

> **Parent vision:** `docs/superpowers/specs/2026-05-31-sleep-consolidation-vision.md` (§5 M2b-1). This is **phase 1** of the Sleep Consolidation memory system. It builds the *awake* path well and lays the **substrate** (episodic chat + multi-timescale salience) the sleep pass (M2b-2) needs.
> **Date:** 2026-05-31. **Platform:** macOS app + local mlx-lm Gemma 4 26B, GRDB graph memory. **Branch:** `main`.
> **Guiding constraint (user):** quality over token cost — build the best version, don't cut corners (`[[user-prioritizes-quality-over-tokens]]`).

## 1. Problem

Today's memory (S5a, ported to macOS) has three weaknesses M2b-1 fixes:
1. **The chat itself is never stored.** Only extracted facts persist; the raw conversation is lost — so there is nothing to "replay" during sleep and no way to resume an interrupted thread. (The `conversation`/`episode` `NodeKind`s and `episodic` layer exist in the schema but are unused.)
2. **Capture is dual and noisy.** Both an explicit `RememberTool` AND a post-turn `MemoryConsolidator` (a 2nd generation that free-extracts JSON) write memories → double-capture, duplicates, agent-fact noise. The consolidator was a crutch for the weak E4B; the 26B calls tools reliably.
3. **Dedup is string-only and injection over-injects.** `findDuplicate` merges only by canonical `dedupKey`, so semantic variants ("Messi"/"likes Messi") don't merge; and `coreMemories()` (RC6) unions identity **plus top-salience**, dumping everything into the prompt so "what do I like?" surfaces the workplace.

## 2. Goal

- **Persist the conversation** as episodic nodes (a thread-aware log) — the hippocampal substrate.
- **One clean capture path:** a synchronous, structured `SaveMemoryTool` with **semantic dedup**; **delete** the post-turn `MemoryConsolidator` (passive capture returns, smarter, in the M2b-2 sleep pass).
- **Multi-timescale salience (Adam/EMA analogy):** reinforce/forget via an exponential-moving-average with a per-layer β (timescale), so frequently-reinforced facts strengthen and migrate toward identity while one-offs fade.
- **Relevance-scoped injection:** identity-core (small) + query-relevant only.

## 3. Decisions (from the vision guide §4, locked)

- Synchronous in-tool write (not a deferred queue — writes are ms).
- Drop `MemoryConsolidator`; passive capture → M2b-2 sleep pass.
- Episodic chat capture is IN now ("meter el chat en la sopa").
- EMA salience with per-layer β; additive over the existing `Decay` (don't break it).
- Relevance-scoped injection (identity-core + query-relevant).
- `AgentTool` based; reuse `MemoryStore`/Node/Edge/`Embedder`/`MemoryText`/`MemoryRetriever`; keep RC3 generation serialization.

## 4. Architecture / components

### 4.1 Episodic chat capture — `Memory/EpisodeRecorder.swift` (new)
Records each turn as `conversation` nodes so the chat is replayable/resumable. No schema migration — reuse `Node` + pack thread metadata into `extra` (JSON).
- For each turn, write **two** `conversation` nodes (role-tagged) — one for the user message, one for the assistant reply:
  - `kind = .conversation`, `layer = .episodic`, `label` = a short role+preview (e.g. `"user: ¿qué me gusta?"` truncated), `body` = full message text, `origin = .extracted`, `salience` seeded (e.g. 2), `decayRate = Decay.defaultDecayRate(for: .episodic)`, `lastSeenAt`/`createdAt = now`.
  - `extra` = JSON: `{ "threadId": <session uuid>, "role": "user"|"assistant", "turnIndex": <int>, "status": "open"|"closed" }`.
- A `threadId` = one conversation/session (a UUID minted per app launch in M2b-1; finer threading is M2b-3).
- Optionally link consecutive turns with an `Edge(relation: .mentionedIn or .partOfEpisode)` to a per-thread `episode` node — **deferred to M2b-2** (the sleep pass builds episode structure); M2b-1 only stores the role-tagged `conversation` nodes + threadId in `extra`.
- Called from `Agent.run` right after the final `.completed` (replacing where consolidation fired), or from `HarnessModel.runAgentTurn`. Must not block the reply (fire after emitting `.completed`); serialized vs the engine per RC3 is unnecessary here (no generation), but the write is on `MemoryToolbox.shared.store`.
- **Retention:** M2b-1 stores all turns (no pruning); the sleep pass (M2b-2) compresses/forgets. Episodic decayRate (~90 days) + a future sweep keep it bounded.

### 4.2 `Memory/SaveMemoryTool.swift` (new; replaces `RememberTool`)
`AgentTool` with params: `entity: String` (canonical short noun/name — required), `detail: String?` (free context), `kind: String?` (`person|place|preference|fact`; default `fact`), `permanent: Bool?`.
- `run(argsJSON:)`: parse → guard non-empty entity → `MemoryText.cleanLabel(entity)` + `isJunkLabel` discard → build `Node(kind:, label: cleanedEntity, body: detail ?? entity, layer: permanent ? .identity : .daily, origin: .explicit, …)` → **semantic-dedup upsert** (§4.4) → embed the canonical label → return `"Saved: <entity>"`. Emit `ToolActivityRelay` started/finished (as today).
- Description + few-shot encode the anti-fabrication rules (save only what the user affirmed about themselves; never on a question; never agent/system facts).
- `forget_memory`: keep `ForgetTool`, sharpen its description for contradiction/correction ("call when the user denies/corrects a fact").

### 4.3 Multi-timescale salience — extend `Memory/Decay.swift`
Add (pure, unit-tested), without removing existing functions:
- `static func beta(for layer: MemoryLayer) -> Double` — EMA decay factor / timescale: `live ≈ 0.5` (horizon ~2), `daily ≈ 0.9` (~10), `identity ≈ 0.99` (~100), `episodic ≈ 0.8`. Document horizon ≈ 1/(1−β).
- `static func reinforceEMA(current: Double, signal: Double = 1.0, beta: Double, cap: Double = 10) -> Double` — `min(cap, beta*current + (1-beta)*signal*scale)` (choose `scale` so repeated reinforcement climbs toward cap; document the math). This is the Adam-moment analogy (`m ← β·m + (1−β)·g`).
- `upsertMerging` (§4.4) uses `reinforceEMA(current: existing.salience, beta: beta(for: existing.layer))` instead of the flat additive `reinforce`. (Keep `reinforce` for back-compat / other callers if any.)

### 4.4 Semantic dedup — extend `Memory/MemoryStore+Dedup.swift`
- New `func findSemanticDuplicate(kind: NodeKind, embedding: [Float], threshold: Double) throws -> Node?` — uses `store.nearest`; returns the nearest same-kind non-deleted node within the distance threshold.
- New `func upsertMergingSemantic(_ candidate: Node, embedding: [Float]?, embedder: Embedder?, threshold: Double = <tuned>) throws -> String`:
  1. If `embedding`/`embedder` available, try `findSemanticDuplicate` first; else/also try the existing string `findDuplicate` (canonical key).
  2. On match → reinforce via `reinforceEMA`, `mentionCount++`, `lastSeenAt`, promote per `Decay.shouldPromote`, merge body, `setEmbedding` if new — same merge logic as `upsertMerging` but EMA reinforcement + semantic match.
  3. Else insert + `setEmbedding`.
- The existing `upsertMerging` stays for callers without an embedding (string-match), but its reinforcement also switches to `reinforceEMA` (§4.3) so both merge paths share one reinforcement behavior. `SaveMemoryTool` uses the semantic variant.

### 4.5 Relevance-scoped injection — `MemoryStore.coreMemories()` + retriever
- `coreMemories()` → **identity-layer only** (drop the top-salience union that caused over-injection). A small, always-on core (name + permanent identity facts).
- `MemoryRetriever.retrieve` already puts query-relevant nodes first then unions the core (lines 51-59) — keep that order; with the core now identity-only it stays small. 
- `Agent.systemPrompt`: add "Answer only what the user asked; do not list unrelated memories."

### 4.6 Wiring — `Agent.swift` + `HarnessModel.swift`
- `MemoryServices` drops `consolidator`; becomes `{ retriever }` (the writer/sleep arrives in M2b-2). 
- `Agent.run`: remove the post-turn `consolidator.consolidate(...)` call + the `consolidationTask` machinery (RC3 was to serialize that 2nd generation — no longer needed for capture; KEEP a lightweight equivalent only if M2b-2's sleep pass needs turn-serialization, decided there). After `.completed`, call `EpisodeRecorder.record(threadId:, userText:, assistantText:)`.
- `HarnessModel`: build the registry with `SaveMemoryTool` + `ForgetTool`; mint/hold the `threadId`; keep `MemoryToolbox.shared` wiring.

### 4.7 Removed
- `Memory/MemoryConsolidator.swift` + `GemmaTests/MemoryConsolidatorTests.swift`.
- `Memory/RememberTool.swift` (replaced by `SaveMemoryTool`) + its tests adjusted.

## 5. Data flow
`turn → retrieve (vector+FTS+graph + identity-core) → inject (relevance-scoped) → 26B answers; if the user stated a fact it calls save_memory(entity, …) → tool: clean→embed→semantic-dedup→upsert (EMA reinforce/promote)→"saved" → model finishes the reply → .completed → EpisodeRecorder stores user+assistant conversation nodes (threadId, role, status)`.

## 6. Error handling
- Empty/junk entity → discard, return a benign message. Embedder absent → semantic dedup falls back to string `dedupKey` (degrade). DB failure → log, never break the turn/reply. Episode write failure → log, non-fatal.

## 7. Testing
- **`SaveMemoryTool`** (in-memory store + `FakeEmbedder`): saves a clean node; `permanent`→identity; junk entity discarded; no store → safe message.
- **Semantic dedup** (`FakeEmbedder` mapping 3 phrasings of "Messi" to near vectors): 3 saves → 1 reinforced node (mentionCount=3), not 3 rows.
- **EMA salience** (pure `Decay` tests): `reinforceEMA` climbs toward cap under repeated reinforcement and respects β per layer; `beta(for:)` values + horizon documented.
- **EpisodeRecorder**: a turn writes 2 `conversation`/`episodic` nodes with correct `extra` (threadId/role/turnIndex); `allNodes` shows them; they don't pollute fact retrieval (kind filter).
- **Relevance injection**: with stored {name, workplace, sushi}, `retrieve("¿qué me gusta?")` ranks `preference:sushi` above `fact:workplace`; `coreMemories()` returns identity-only.
- **Wiring/regression**: `Agent` no longer calls a consolidator; `MemoryServices` compiles without it; existing memory suites (store, retriever core, MemoryText, dedup) stay green; the macOS build + full suite green.
- **Device/manual (macOS, real 26B):** state name+preference+person, ask a meta-question → recalls the right thing, no dup, no fabrication on questions; inspector shows the conversation episodes. Record in the report.

## 8. Out of scope (later phases)
- The sleep consolidation pass (replay/extract/edges/promote/forget) — **M2b-2**.
- Reflection/abstraction + interrupted-thread detection & resume — **M2b-3**.
- Episode→episode structure edges, day-node timeline — M2b-2.
- Server embeddings/sync — S5b/S5c.

## 9. File structure
**New:** `Memory/SaveMemoryTool.swift`, `Memory/EpisodeRecorder.swift`; tests `GemmaTests/SaveMemoryToolTests.swift`, `GemmaTests/EpisodeRecorderTests.swift`, additions to `DecayTests`/`MemoryStoreDedupTests`/`MemoryRetrieverTests`.
**Modified:** `Memory/Decay.swift` (EMA), `Memory/MemoryStore+Dedup.swift` (semantic dedup), `Memory/MemoryRetriever.swift` (+ `MemoryStore.coreMemories()` → identity-only), `Agent/Agent.swift` (drop consolidator, record episode, prompt tweak), `Agent/ToolRegistry.swift` / `Harness/HarnessModel.swift` (register SaveMemoryTool), `Memory/MemoryToolbox.swift` if needed.
**Removed:** `Memory/MemoryConsolidator.swift`, `Memory/RememberTool.swift` + their tests.
