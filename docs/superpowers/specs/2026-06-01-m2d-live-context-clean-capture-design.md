# M2d — Live Context, clean capture & semantic summaries — Design

> **Parent:** macOS pivot `[[macos-mlx-pivot]]`. Builds on M2b (Sleep Consolidation): `MemoryStore` (GRDB), `MemoryRetriever`, `MemoryConsolidationEngine`/`ConsolidationScheduler`, `EpisodeRecorder`, `SaveMemoryTool`, `Agent`, `ServerRuntime`. Implements the multi-level memory the project's `initial_idea.txt` specifies (Layer 1 Live Context … Layer N knowledge) which the current code skipped.
> **Date:** 2026-06-01. **Platform:** native macOS app (Gemma), branch `main`.

## 1. Problem

Three coupled defects in the current chat/memory path:

1. **No short-term memory.** `Agent.run` is called with **only the current prompt** (+ retrieved memory + wakeContext). The model never sees prior turns → no real conversational coherence. The chat leans entirely on the long-term graph for any continuity.
2. **The graph gets polluted.** `EpisodeRecorder` writes **every turn** (user + assistant) as two permanent `conversation` nodes in the episodic layer — un-deduped, never pruned, mixed into the curated knowledge the user inspects.
3. **Saving adds latency on the hot path.** `SaveMemoryTool` runs **synchronously inside the turn**, and worse, it is an **extra generation round-trip** (the model emits a tool call → execute → re-feed → generate again). Embedding + upsert pile on.

The intended model (`initial_idea.txt`): short-term = the conversation window (Layer 1, TTL minutes); a background pass **compacts short-term into the long-term graph to free the context window**; long-term holds *distilled, semantic* knowledge, not raw turns. As the user put it: store **the "ruta" of each chat** (topic/concepts/intent/decisions), embed the **condensed concepts** (not raw turns — a 200-message embedding averages out and loses precision), and let recall be **graded by graph proximity** (talking about Juan → Juan + his closest links by default; distant detail like "what did I message Juan on the 16th" only via drill-down into the raw log).

## 2. Goal

A chat with real **short-term context** and a **clean, semantic long-term memory**, with **zero graph writes on the hot path**:

- **Live turn** = recent conversation window (as `messages`) + **read-only, proximity-graded recall** of long-term memory; **no `save_memory`, no graph writes, no extra round-trip**. The only hot-path write is a cheap local append to a conversation log.
- **Background (idle/sleep) consolidation** reads the conversation log, **distills** durable facts/relations into the graph (existing), and produces a **structured semantic summary** per chat segment (the "ruta"), embedding the **condensed concepts** for precise retrieval; then it **compacts** (drops consolidated turns out of the active window; the raw log is **retained on disk** for drill-down).
- **Tiered recall:** N1 recent window → N2/N3 semantic summaries + entity-centric graph neighborhood (closest links) → N4 drill-down into the raw log on demand → cross-session abstraction (recurring topic → bigger concept).

**Decisions locked (brainstorm 2026-06-01):**
| Decision | Choice |
|---|---|
| Live-turn memory | **Recall (read) yes, writes no.** Tiered, proximity-graded recall injected read-only. All extraction/saving → background. |
| Short-term window | **Rolling, persisted, auto-compacted.** ~last 12 turns or ~1500 tokens (whichever first). Survives app restart. |
| Where raw turns live | **`TranscriptStore`, separate from the node graph.** Raw turns are NEVER graph nodes. |
| Raw log lifetime | **Retained** (not pruned) as the N4 drill-down tier. Only the *in-context window* is bounded. (Optional far-future TTL prune.) |
| Semantic summaries | **In scope.** Consolidation emits structured `summary` nodes `{topic, concepts[], intent, decisions[], importance}` with a **concept-level embedding** + `turnRange` link to the log. |
| Runtime | **Full `messages` API** (system + history + tool-role), not prompt-string formatting. Fixes the M1 bracketed-prompt tool-loop hack. |
| `save_memory` tool | **Removed from the live turn.** Consolidation captures "remember X" from the transcript. |
| Drill-down | **`expand_context` read-tool** the model calls only when it needs verbatim detail (one read round-trip, no save latency). |
| Recall proximity | Entity-centric: entity + **closest** 1-hop high-salience neighborhood by default; distant/low-salience excluded → only via drill-down. (Retriever already does vector+FTS+1-hop+salience; we tune + add summary-first + N4.) |
| Out of scope | **LoRA/adapters, continual/incremental fine-tuning, "cognitive user model in weights."** Documented as a future milestone. |

## 3. Architecture — multi-level memory

| Level | What | Store | Lifetime |
|---|---|---|---|
| **N1 Live Context** | recent turns, verbatim → model `messages` | `TranscriptStore` (recent slice) | in-context window (~12 turns) |
| **N2 Semantic summary** | per-segment `summary` node `{topic, concepts, intent, decisions, importance}` + concept embedding | graph (`summary` kind) | long-term |
| **N3 Knowledge graph** | entities/relations/insights (existing) | graph | long-term |
| **N4 Raw chat log** | full transcript for drill-down | `TranscriptStore` (all) | retained |

```
LIVE TURN (fast, no graph writes)
 user msg
   → recall = MemoryRetriever (vector+FTS+entity-neighborhood, summary-first)   [read]
   → messages = [ system(+recall block), …window from TranscriptStore (N1), user ]
   → runtime.generate(messages, tools)   // 1 generation; tool-loop via role=tool
       tools: time, reflect, expand_context (N4 drill-down), forget_memory  — NO save_memory
   → answer
   → TranscriptStore.append(user); append(assistant)        // only hot-path write (local, cheap)

BACKGROUND (idle/sleep) — MemoryConsolidationEngine over unconsolidated transcript turns
 segment by idle gap → NREM distill facts→graph (existing)
   + NEW summarize segment → structured `summary` node (concept embedding, turnRange link)
   + detect / REM associate / reflect (abstract recurring topics) / curate / SHY (existing)
 → mark those transcript turns consolidated (leave the active window; raw log retained)
```

## 4. Components

### 4.1 `TranscriptStore` (new — `Memory/TranscriptStore.swift`)
GRDB table `transcript(id TEXT PK, threadId TEXT, turnIndex INT, role TEXT, text TEXT, createdAt REAL, consolidated INT)`, separate from `node`. API:
- `append(threadId:turnIndex:role:text:)` — best-effort, swallows errors (never breaks a reply).
- `recent(threadId:maxTurns:maxChars:)` → ordered turns for the N1 window (cap by turns AND a char/token budget).
- `range(threadId:fromTurn:toTurn:)` → N4 drill-down for `expand_context`.
- `unconsolidated(limit:)` / `markConsolidated(ids:)` → consolidation input + compaction.
Replaces `EpisodeRecorder` (which is deleted; it wrote `conversation` graph nodes).

### 4.2 Runtime `messages` API (`Runtime/ToolCallingRuntime.swift`, `ServerRuntime.swift`, `DummyRuntime.swift`)
A small message value type:
```swift
public struct ChatMessage: Sendable { public enum Role: String { case system, user, assistant, tool }
    public var role: Role; public var content: String
    public var toolName: String?; public var toolCallId: String?   // for tool-role / assistant tool calls
}
```
`ToolCallingRuntime.generate(messages: [ChatMessage], tools: [AgentTool], options:)`. `ServerRuntime` already builds an OpenAI `messages` array internally — it now serializes the full history (and tool-role results) instead of `[system, user]`. The **client-side tool loop moves from bracketed-prompt augmentation to proper `assistant`(tool_call) + `tool`(result) messages** appended to the history and re-sent. (Resolves the M1 TODO in `Agent.swift`.)

### 4.3 `Agent` (`Agent/Agent.swift`)
- Accepts the conversation `history: [ChatMessage]` (the N1 window) for the turn.
- Builds `messages = [system(base + recall block + wakeContext)] + history + [user(prompt)]`.
- Tool loop uses tool-role messages. **No `save_memory`** in the registry; recall is read-only via `MemoryRetriever`.
- Recall block: summary-first + entity neighborhood (see 4.6).

### 4.4 Live write path (`Harness/HarnessModel.runAgentTurn`)
After the turn: `transcriptStore.append(user)`, `append(assistant)`. That is the only synchronous persistence. No embedding, no graph upsert, no extra generation. The window for the *next* turn is `transcriptStore.recent(...)`.

### 4.5 Consolidation (modified — `Memory/MemoryConsolidationEngine.swift`, `ConsolidationScheduler`)
- **Input source changes** from `conversation` graph nodes to `TranscriptStore.unconsolidated`. Segment by idle gap (reuse the scheduler's wake-gap notion) → a "chat segment".
- **NREM** distills durable facts → graph nodes (existing prompt/flow).
- **NEW — Summarize phase:** one LLM pass per segment → structured summary `{topic, concepts[], intent, decisions[], importance}`; write a `summary` node: `label = topic`, `body = prose`, `extra = JSON(concepts,intent,decisions,importance,threadId,turnRange)`, `layer = .episodic`→semantic, embedding computed from **`topic` + `concepts`** (condensed, not raw turns), `sourceRef = threadId`.
- **detect / REM / reflect / curate / SHY** unchanged; reflect/REM additionally **merge recurring summaries** into higher-level concept/insight nodes (cross-session abstraction).
- After the cycle: `markConsolidated(ids:)` on the processed turns (they leave the active window; raw log stays for N4).

### 4.6 Tiered, proximity-graded recall (`Memory/MemoryRetriever.swift`)
The retriever already does vector + FTS + **1-hop graph spreading** + salience×recency + identity-core union. Adjustments:
- It now ranks over **summary + entity/relation** nodes (no more `conversation` nodes).
- **Summary-first:** summaries (compact "ruta") are preferred for the injection block; entity neighborhood (closest 1-hop, high salience) supplies the "who/what" detail. Distant/low-salience nodes stay out of default recall.
- Injection block stays compact (the model gets *what it knows*, not transcripts).

### 4.7 `expand_context` tool (new — `Memory/ExpandContextTool.swift`)
A **read** tool: given a topic/summary reference (or threadId + turnRange surfaced by a summary), returns the verbatim slice from `TranscriptStore.range(...)`. The model calls it only when the user asks for specifics the summary doesn't carry ("what exactly did I tell Juan on the 16th"). One read round-trip, fires rarely — not a hot-path cost like the old save.

### 4.8 Cleanup / migration (`Memory/MemoryStore.swift`, `MemoryView`)
- Stop creating `conversation` nodes (EpisodeRecorder gone).
- **Migration:** purge existing `conversation`-kind nodes from the graph (one-time, on store open or a dedicated migration).
- `MemoryView` shows curated knowledge only (no raw turns); optionally a separate read-only "Transcript" view backed by `TranscriptStore`.

## 5. Data flow

**Per turn:** see §3 (fast path). Window assembled from `TranscriptStore.recent`; recall read-only; one generation; append two transcript rows.

**Background:** scheduler (idle ~180s / sleep) → consolidation over `unconsolidated` turns → distill + summarize + abstract → `markConsolidated`. Frees the window; raw log retained.

**Recall (graded):** N1 (already in `messages`) → N2/N3 retriever injection (summary-first + entity neighborhood) → N4 `expand_context` on demand → cross-session abstraction via reflect.

## 6. Error handling / edge cases
- `TranscriptStore.append` best-effort; a storage error must never break the reply.
- Window cap enforced by BOTH turn count and char/token budget to avoid context overflow on long turns; if a single turn is huge, truncate oldest first.
- Drill-down (`expand_context`) bounded (max turns/chars returned) so it can't blow the context window.
- Consolidation must be idempotent over `consolidated` flags (a crash mid-cycle re-processes only unconsolidated turns; existing resumable `runCycle` persists progress).
- Migration purge is one-time and guarded (no-op if already clean).

## 7. Testing
- `TranscriptStore`: append/recent (caps), range, unconsolidated/markConsolidated round-trips (in-memory GRDB).
- Runtime messages: `ServerRuntime` serializes full history + tool-role (URLProtocol mock asserts the `messages` array); tool-loop drives via tool-role, not bracketed prompt.
- `Agent`: builds messages with history; no `save_memory` in registry; recall block injected; multi-turn coherence (turn 2 sees turn 1 via window) with a fake runtime.
- Consolidation: reads transcript (not nodes); produces a structured `summary` node with concept embedding + `turnRange`; marks turns consolidated; existing entity/edge/insight extraction still works. Real-26B E2E (gated): seeded multi-turn chat → cycle yields summary + entities + links; recall after consolidation returns the summary.
- Retriever: summary-first, entity-neighborhood, no conversation nodes; proximity (close links ranked above distant).
- `expand_context`: returns the right verbatim slice for a turnRange.
- Migration: existing `conversation` nodes purged; knowledge nodes untouched.
- Live E2E (gated): two-turn chat is coherent without any graph write during turns; graph stays clean; after idle, consolidation populates summary/graph.

## 8. Out of scope (future milestones)
LoRA/adapters, incremental/continual fine-tuning, "cognitive user model" baked into weights, big-model-as-offline-compressor pipeline beyond consolidation, voice/"Hey Gemma" session control, multi-conversation UI, per-node multi-vector embeddings (topic+intent+decision as separate vectors — we embed one condensed concept vector for now).

## 9. Decomposition (for the implementation plan)
Large but one coherent feature; suggest **three sub-plans**, each shippable & testable:
- **M2d-1 — Live Context + clean capture:** `TranscriptStore`; runtime `messages` API + tool-role loop; `Agent` history + remove `save_memory`; `HarnessModel` append; remove `EpisodeRecorder`; migration purge. (Fixes the 3 reported defects.)
- **M2d-2 — Semantic summaries + consolidation source:** consolidation reads transcript, summarize phase → `summary` nodes (concept embedding, turnRange), cross-session abstraction; retriever summary-first/proximity.
- **M2d-3 — Drill-down + UI:** `expand_context` tool; `MemoryView` knowledge-only + optional Transcript view.

## 10. File structure
- Create: `Memory/TranscriptStore.swift`, `Memory/ExpandContextTool.swift`, `Runtime/ChatMessage.swift` (or fold into ToolCallingRuntime.swift).
- Modify: `Runtime/ToolCallingRuntime.swift`, `Runtime/ServerRuntime.swift`, `Runtime/DummyRuntime.swift`, `Agent/Agent.swift`, `Harness/HarnessModel.swift`, `Memory/MemoryConsolidationEngine.swift`, `Memory/ConsolidationScheduler.swift` (input source), `Memory/MemoryRetriever.swift`, `Memory/MemoryStore.swift` (transcript table + migration), `Harness/AgentChatView.swift`/`MemoryView` (UI).
- Remove/replace: `Memory/EpisodeRecorder.swift`; drop `SaveMemoryTool` registration (file may stay unused or be deleted).
- Tests: `TranscriptStoreTests`, runtime messages tests, `Agent` history/no-save tests, consolidation summary tests, retriever proximity tests, `ExpandContextTool` tests, migration test, gated live E2E.

## 11. Resultado M2d (a completar al verificar)
_(pending implementation)_
