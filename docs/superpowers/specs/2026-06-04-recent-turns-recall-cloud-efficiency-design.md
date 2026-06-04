# Recent-Turns Recall + Debounced Consolidation (Cloud Efficiency) — Design Spec

**Date:** 2026-06-04
**Status:** Approved (brainstorm), pending plan
**Repos:** `gemma-memory` (i3 server — most of it) + small change in `personal_agent` (app).

---

## 1. Motivation

Two cloud-related gaps in cross-chat memory:

1. **Cross-chat awareness lags.** `recall(query)` is a semantic search run before every reply, but it only searches **consolidated** memory (summary/fact nodes). Raw recent turns that haven't been consolidated yet aren't searchable, so a chat opened seconds after another doesn't "remember" it. (Observed: trip mentioned in chat A, forgotten in chat B.)
2. **Consolidation runs too often for cloud.** The scheduler arms recurring timers per turn-end (light reflection ~15s pause, full cycle ~180s idle). With the local model that was free; with cloud providers each cycle costs API tokens, so repeated cycles during active use waste money.

Fixes, both token-efficient: make recent un-consolidated turns part of the semantic recall (relevance-gated top-k, bounded tokens), and run consolidation **once per conversation burst, only when there is new data**.

## 2. Goals

1. Recall surfaces relevant recent un-consolidated turns from **other** threads, so cross-chat context is available before consolidation runs.
2. Token cost stays bounded (top-k relevant turns, not a history dump).
3. Consolidation/reflection runs **once** after the user stops (debounced) and only if there are new un-consolidated turns — no recurring cloud calls during active use.

## 3. Non-Goals

- Embedding/searching the **current** thread's turns (already sent as the conversation window).
- Changing the consolidation phases themselves.
- A configurable week/debounce UI (debounce is a fixed constant, ~45s).
- Replacing the manual "Consolidar"/reflect triggers (kept).

## 4. Design

### 4.1 Embed turns at append (server, `gemma-memory`)

- **Migration `v7-transcript-embedding`:** `CREATE TABLE transcript_embedding(turn_id TEXT PRIMARY KEY NOT NULL, embedding BLOB NOT NULL)`.
- `MemoryStore+Vector`: add `setTranscriptEmbedding(turnId:_ vector:)`, `nearestTranscript(to:k:) -> [(turnId: String, distance: Double)]` (mirror `setEmbedding`/`nearest`; reuse `floatsToBlob`/`blobToFloats`/cosine), and `deleteTranscriptEmbeddings(turnIds:)`.
- `TranscriptStore.append(...)` returns the new row `id` (currently discards it).
- `TranscriptHandlers.append`: after storing the row, best-effort embed the turn text (`services.embedder.embed`) and `setTranscriptEmbedding(turnId: id, vector)`. On embed failure, the turn is still stored (just not searchable until consolidated). This runs after the user's reply (the app appends post-turn) → off the critical path.
- **Cleanup:** `TranscriptStore.markConsolidated(ids:)` also deletes those turns' embeddings (via `store.deleteTranscriptEmbeddings`), so the table only holds recent un-consolidated turns; once consolidated, the summary node represents them.

### 4.2 Debounced single consolidation cycle (server, `ConsolidationScheduler`)

- Replace the recurring `pauseTask` (15s light) + `idleTask` (180s full) with a single `debounceTask` (`debounceInterval = .seconds(45)`). `armTurnEnd`/`noteTurnEnded` cancels any pending debounce and starts a fresh 45s timer; each new turn resets it. `noteUserActivity` cancels it.
- When the debounce fires (user has been quiet 45s) → `launch(light: false)` — **one** full cycle. `runCycle` already `guard`s on `unconsolidated.isEmpty` (no-op when there's no new data — kept). The `hasPendingCycle` resume check still applies (an interrupted cycle resumes on the next debounce).
- Drop the recurring light-reflection. Manual `consolidateNow()` / `runReflectAdHoc()` stay.
- Net: ~1 cloud consolidation call per conversation burst; zero when nothing new was said.

### 4.3 Recall retrieves recent relevant turns (server, `MemoryRetriever` + recall handler)

- The recall handler embeds the query **once** and reuses the vector: `MemoryRetriever.retrieve(query:k:now:queryVector:)` gains an optional precomputed `queryVector` (skips re-embedding); the handler also calls `store.nearestTranscript(to: qv, k:)`.
- Recent-turn selection: from `nearestTranscript` hits, fetch the turns, keep those with `consolidated == false` AND `threadId != currentThreadId`, rank by distance (+ recency), take top **4**.
- The recall request gains `threadId` (the current thread to exclude). The recall response gains `recentTurns: [{role, text}]`.

### 4.4 App: pass thread + render recent turns (`personal_agent`)

- `MemoryClient.recall(query:scope:limit:threadId:)` sends `threadId`. `HarnessModel.runAgentTurn` passes the current thread id.
- `RecallBundle` gains `recentTurns: [RecentTurn]` (`role`, `text`). `injectionBlock()` appends a compact section `Recent conversation (other chats):\n- <role>: <text>` after the remembered-facts lines (empty when none).

## 5. Data Flow

Per turn: app → `recall(query, threadId)` → server embeds query once → node retrieval (consolidated knowledge) + `nearestTranscript` (recent un-consolidated, other threads) → returns `{core, recall, recentTurns}` → app injects all on the message tail (bounded top-k). After the user goes quiet 45s → one consolidation cycle folds the new turns into summary nodes and deletes their transcript embeddings.

## 6. Error Handling

- Embed-at-append failure → turn stored without an embedding (degrades to "not searchable until consolidated"); never blocks append.
- Recall transcript search failure → falls back to node-only recall (existing behavior).
- Debounce: if the process restarts mid-debounce, the next turn re-arms it; `hasPendingCycle` covers an interrupted cycle.

## 7. Testing

- **Server (unit):** `nearestTranscript` returns the nearest turn id; `setTranscriptEmbedding`/`deleteTranscriptEmbeddings` round-trip; `markConsolidated` deletes embeddings; recall recent-turn selection excludes the current thread and consolidated turns and caps at 4; `append` returns the id.
- **Scheduler (unit):** one `armTurnEnd` arms a single debounce; a second `armTurnEnd` before it fires resets it (only one cycle runs); firing triggers a full cycle; `noteUserActivity` cancels it; cycle is a no-op when there's no un-consolidated data. (Use a short test debounce + the existing spy `ConsolidationRunning`.)
- **App (unit):** `recall` sends `threadId`; `RecallBundle.injectionBlock()` renders a "Recent conversation (other chats):" section from `recentTurns` (and nothing when empty).
- **E2E manual (fresh memory):** chat A "la próxima semana voy a Varadero"; immediately chat B "¿qué planes tengo?" → agent recalls it (recent-turns recall, pre-consolidation). Confirm consolidation runs once ~45s after the last message, not repeatedly.

## 8. Implementation order

1. `transcript_embedding` migration + store methods (set/nearest/delete) + `append` returns id.
2. Embed at append (handler) + cleanup in `markConsolidated`.
3. Debounced single-cycle scheduler.
4. `retrieve(queryVector:)` + recall handler recent-turns selection + `threadId` + `recentTurns` response.
5. App: `MemoryClient.recall(threadId:)` + `RecallBundle.recentTurns` + injectionBlock + `HarnessModel` passes thread.
6. Deploy server (rebuild image) + manual E2E.

Server changes need a rebuild/redeploy; the app change ships in the next build.
