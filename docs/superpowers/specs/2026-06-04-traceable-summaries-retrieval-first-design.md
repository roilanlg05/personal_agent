# Traceable Summaries + Retrieval-First Recall (SP-A) — Design Spec

**Date:** 2026-06-04
**Status:** Approved (brainstorm), pending plan
**Repos:** `gemma-memory` (i3 server) + `personal_agent` (app).
**Source vision:** `logs.txt` (memory contributions only — the research layers are out of scope, deferred).

---

## 1. Motivation

The assistant should follow **retrieval-first cognition**: a small context window, with real memory living outside the prompt and retrieved selectively. Today recall blends everything into one query and there is no clean, agent-driven path from an episodic summary down to the exact original messages. The principle to honor: **the summary is enough most of the time; raw messages are loaded only when the summary doesn't answer, and only the exact range needed** (`logs.txt` Retrieval Pipeline step 4: "Solo si hace falta: cargar mensajes originales específicos").

This is the **read path** (sub-project A). The **write path** — restructuring consolidation into the 7-stage pipeline (adding tagging + clustering + provenance) — is a separate spec (SP-B), deferred.

## 2. Goals

1. **Server-authoritative per-chat message numbering** (`seq`, 1..N per `chat_id`) so every message has a stable, deterministic number and summary ranges are unambiguous.
2. **Traceable summaries:** recall surfaces each episodic summary with its `summary_id`, `chat_id`, and `message_range`, so the agent can drill down precisely.
3. **Graduated retrieval-first recall:** present memory in explicit tiers — persistent identity → relevant atomic memories → episodic summaries (with refs) → raw messages on demand only.
4. **Agent-driven drill-down:** a `load_messages(chat_id, from, to)` tool the agent calls *only* when a summary is insufficient, returning just that range (capped).
5. **Episode boundaries by inactivity:** the app mints a new `chat_id` after >30 min of inactivity, so episodes/summaries/`seq` are naturally bounded; same-topic continuity is carried by retrieval, not by chat identity.

## 3. Non-Goals

- The SP-B consolidation pipeline restructure (tagging, clustering, embeddings-as-phase, provenance `derivesFrom`). Separate spec.
- The research architecture from `logs.txt` (chunking, working summary, final synthesis). Deferred.
- Changing the existing atomic-memory extraction, association, reflect/detect/clarify/shy phases.
- Server-side auto-expansion of raw messages (rejected — drill-down is agent-driven).

## 4. Design

### 4.1 Server-authoritative message numbering (`seq`)

- Add a `seq: Int` column to the `transcript` table (GRDB migration `v8-transcript-seq`; backfill existing rows via per-`threadId` row-number ordered by `turnIndex, createdAt` — production transcript is empty post-reset, but dev DBs are handled).
- On `append`, the server computes `seq = (max seq for that threadId) + 1` (1-based, monotonic per chat) **inside the write transaction**, independent of any caller-supplied `turnIndex`. `append` returns the assigned `seq`.
- `seq` is THE per-chat message number used everywhere a "message range" is meant. The legacy `turnIndex` is retained only for intra-turn user→assistant ordering on equal timestamps; it is no longer used for ranges.

### 4.2 Traceable summaries

- Each `summary` node already has `id` (= `summary_id`), and stores `threadId` (= `chat_id`) + a turn range in `extra`. Change `summarize` to record the range as **`message_range: [fromSeq, toSeq]`** computed from the consolidated rows' `seq` values (not `turnIndex`).
- A merged/re-summarized thread adopts the latest `chat_id` + `message_range` (existing behavior, kept).

### 4.3 Graduated recall (4 tiers)

The recall HTTP response and the app's injection are restructured into explicit tiers:

- **Tier 1 — Persistent identity (CAPA 4):** self node + `identity`-layer facts. Always injected. (= existing `core`/`coreMemories()`, unchanged.)
- **Tier 2 — Relevant atomic memories (CAPA 3):** query-relevant facts/preferences/etc., ranked. (= existing `recall`, but with summaries removed from it.)
- **Tier 3 — Episodic summaries (CAPA 2):** top-K relevant summaries, **cross-chat**, each annotated with its refs. New dedicated `summaries` array in the recall response: `{ summary_id, chat_id, message_range: [from, to], text, score }`.
- **Tier 4 — Raw messages (CAPA 1):** never injected; available only via the `load_messages` tool.

Recall response shape becomes `{ core, recall, summaries, recentTurns }`. `recentTurns` (the short cross-chat continuity window) is unchanged — it is the always-on minimal raw slice for immediate continuity after an episode boundary, distinct from on-demand historical drill-down.

App `injectionBlock` renders the tiers with labels; Tier 3 example:
```
Episodic summaries (load the underlying messages only if a summary doesn't answer):
- [chat g7y · msgs 21-56] El usuario hace trading de opciones semanales; decidió…
- [chat k3p · msgs 4-12] Viaje a Varadero con esposa e hija…
```

### 4.4 Agent-driven drill-down

- **Server endpoint** `GET /v1/transcript/range?chat_id=<id>&from=<seq>&to=<seq>` → returns that chat's rows in `[from, to]` ordered by `seq`: `[{ seq, role, text, createdAt }]`. Range is clamped to a **maximum of 80 messages** (if a larger span is requested, return the first 80 of the range and flag truncation). Reuses the existing internal `transcript.range(threadId, from, to)`, now keyed by `seq`.
- **App tool** `load_messages` (ToolRegistry): params `chat_id` (required), `from` (seq, required), `to` (seq, optional → single message when omitted or `from == to`), `summary_id` (optional shortcut; the server resolves it to that summary's `chat_id`+`message_range`). Calls the range endpoint via `MemoryClient`; returns the rows to the agent. Respects the 80-cap.
- **The topic-keyed `/v1/memory/expand` path is deprecated/removed** in favor of the deterministic refs-based one (the agent now has exact refs from Tier 3, no fuzzy topic matching needed). Its app-side `expand_context` tool is replaced by `load_messages`.
- **Prompt principle** (`Agent.systemPromptText`): "You are given episodic summaries with their source refs (chat + message range). Answer from a summary when it suffices. Call `load_messages(chat_id, from, to)` ONLY when a summary lacks the detail you need — and read just that range, never the whole chat. Never load raw messages you don't need."

### 4.5 Episode boundary by inactivity (app)

- The app tracks the last-activity timestamp of the current thread. When a new user message arrives **>30 min** (configurable, default 30) after the last activity in the current thread, the app mints a **new `chat_id`** (threadId) and `seq` restarts at 1 for the new chat. Within the window, the same chat continues.
- Same-topic continuity across the boundary is preserved by Tier 2/3 cross-chat retrieval + `recentTurns`, not by chat identity (retrieval-first: the chat is not the memory).

## 5. Data Flow

User talks in chat `g7y` (messages get `seq` 1..N) → after the turn/idle, consolidation `summarize` writes a `summary` node with `chat_id=g7y`, `message_range=[21,56]` → 35 min later the user returns; app mints chat `k3p` (seq resets to 1) → user asks a detail from the trading discussion → recall returns Tier 3 `[chat g7y · msgs 21-56] …` → if the summary answers, the agent replies from it; if not, the agent calls `load_messages(chat_id="g7y", from=21, to=56)` → server returns those 36 messages → agent answers from the exact range, without reading the whole chat.

## 6. Error Handling

- `load_messages` with an unknown `chat_id`/empty range → returns an empty list (agent falls back to the summary / says it can't find it); never errors the turn.
- Requested range > 80 → first 80 returned + truncated flag; the agent can request the next window.
- `summary_id` shortcut that doesn't resolve → treated as not found (empty), agent uses explicit `chat_id`/range or the summary text.
- Recall with the new `summaries` tier degrades gracefully if empty (no Tier 3 section rendered), mirroring the existing empty-bundle behavior.
- `append` seq computation is inside the write transaction → concurrent appends to the same thread stay monotonic.

## 7. Testing

**Server (unit):**
- `append` assigns `seq` monotonically per `chat_id` (1,2,3…); independent threads don't interfere; returns the assigned `seq`. Migration backfills existing rows' `seq` per thread.
- `summarize` records `message_range = [minSeq, maxSeq]` of the consolidated rows.
- `recall` returns the dedicated `summaries` array `{summary_id, chat_id, message_range, text, score}`, separate from `core`/`recall`; summaries are no longer mixed into `recall`.
- `GET /v1/transcript/range` returns rows in `[from,to]` ordered by `seq`, only for that chat, clamped to 80 (+truncated flag on overflow).

**App (unit):**
- `injectionBlock` renders Tier 3 summaries as `- [chat <id> · msgs a-b] <text>` under the drill-down header, distinct from atomic-fact lines; renders nothing extra when there are no summaries.
- `load_messages` tool: params parsed (`chat_id`/`from`/`to`/optional `summary_id`); calls the range endpoint; returns rows; respects the cap.
- `Agent.systemPromptText` contains the summary-first / load-only-if-needed instruction.
- Session boundary: a user message >30 min after last activity mints a new `chat_id` (seq resets); ≤30 min keeps the chat. (App-side timer unit-tested with injected clock.)

**E2E manual (fresh memory):** converse about a topic in chat A → let consolidation summarize → trigger a new chat (or wait past the boundary) → ask a detail only in chat A → the agent answers from the Tier 3 summary when sufficient; when not, it calls `load_messages` with chat A's `chat_id`+range and answers from that range. Confirm it does NOT load raw when the summary suffices.

## 8. Implementation Order

1. **Server:** `seq` column + migration/backfill + `append` assigns/returns `seq`; `transcript.range` keyed by `seq`.
2. **Server:** `summarize` records `message_range` from `seq`.
3. **Server:** recall response gains the `summaries` tier (pulled out of `recall`).
4. **Server:** `GET /v1/transcript/range` endpoint (cap 80); deprecate topic `expand`.
5. **App:** `MemoryClient` decodes `summaries` + a `range` call; `injectionBlock` renders the tiers; `load_messages` tool replaces `expand_context`; `Agent` prompt line.
6. **App:** episode boundary (30-min inactivity → new `chat_id`).
7. Deploy server + manual E2E.

Server changes need a rebuild/redeploy; the app changes ship in the next build.
