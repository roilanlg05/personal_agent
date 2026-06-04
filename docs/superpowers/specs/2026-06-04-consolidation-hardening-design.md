# Consolidation Hardening — Design Spec

**Date:** 2026-06-04
**Status:** Approved (brainstorm), pending plan
**Repo touched (primary):** `gemma-memory` (i3 memory service). Minor change in `personal_agent` (macOS app → `MemoryClient`).
**Sibling sub-project (separate spec, NOT this one):** Model Router (selectable provider — local Gemma / Gemini / Cerebras / Groq — configurable independently for chat agent and for consolidation). Built after this.

---

## 1. Motivation

A real end-to-end run (chat transcripts + memory inspected directly on the i3 `memory.sqlite`) exposed that SP1's conflict-detection guarantee is defeated, and that consolidation produces corrupt data. Root-cause diagnosis (evidence-backed, by replicating the server's own `scheduleConflicts` / `scheduleWindow` logic against the real stored rows):

- **The server's schedule logic is correct and deterministic.** `scheduleConflicts(meeting)` returns the overlapping Varadero trip; `scheduleWindow(next week)` returns both events. The bug is NOT in SP1's conflict detection.
- **Two uncoordinated event-creation paths exist.** The agent tool `create_event` routes through `scheduleConflicts` (the `/schedule/create` handler blocks on conflict unless `force=true`). But `MemoryConsolidationEngine.consolidate` calls `MemoryStore.upsertEvent` **directly**, bypassing conflict detection entirely. Any event minted by consolidation can silently overlap existing events.
- **Consolidation lets the model compute epochs "in UTC".** The extraction prompt asks the model to emit `attributes.start`/`end` as raw Unix epoch seconds in UTC. The model gets it wrong (stored `1781000000` = `06:13:20`, not the requested `06:00:00` — an LLM arithmetic error) and "UTC" mismatches the local-time convention the rest of the system uses (`ScheduleTime` in the app is local).
- **Hub nodes pollute the `place` category.** The 16 graph hub nodes (`hub:person`, `hub:place`, …, `extra={"hub":true}`) are stored with `kind='place'` instead of `kind='hub'`. Root cause: `ensureKindHubs` only **creates** missing hubs (`if existing == nil`) and never **repairs** an existing hub whose `kind` is wrong; a prior image created them as `place`, and the corrected code leaves the existing rows untouched (matched by id `hub:<kind>`).
- **Insight spam.** Near-duplicate insights accumulate ("manages appointments", "uses the assistant for schedule management", …) because dedup only runs at insert time, not as a sweep over existing insights.

These map to the four fixes below. Model *discipline* failures (not calling tools, hallucinating success, wrong weekday names) are addressed by the separate Model Router sub-project (a more capable model) and are explicitly **out of scope here** — this spec hardens the system so it is correct regardless of model quality.

## 2. Goals

1. **Single, conflict-checked event-creation path.** No code path creates an event without running `scheduleConflicts`.
2. **Deterministic date→epoch.** The model never computes epochs; it emits local wall-clock text and the server converts using the user's timezone.
3. **Hubs stay out of entity categories.** Hub nodes are `kind='hub'`; existing mis-kinded hubs self-heal; extraction can never mint a category word as an entity.
4. **Insights are deduplicated** by a sweep phase, not just at insert.

## 3. Non-Goals

- The Model Router (Gemini/Cerebras/Groq) — separate spec, built next.
- Fixing the agent's live-turn tool discipline / prompt-augmentation tool loop / weekday prose errors — model-quality, out of scope.
- Logging tool-call invocations (useful follow-up, noted in §9, not built here).
- Any change to the agent's `create_event` tool *contract* (its behavior is preserved; only its store backing is centralized).

## 4. Design

### 4.1 Unified event creation with conflict check (fix #1)

**New store method** in `MemoryStore+Schedule.swift`:

```swift
/// Single entry point for creating an event. Always runs scheduleConflicts.
/// Returns (id, []) when created; (nil, conflicts) when blocked by a conflict and force==false.
func createEventChecked(title: String, start: Double, end: Double, allDay: Bool,
                        location: String?, origin: Origin, force: Bool)
    throws -> (id: String?, conflicts: [Node])
```

- Runs `scheduleConflicts(start:end:)`. If non-empty and `!force` → returns `(nil, conflicts)` without writing. Else → `upsertEvent(...)` and returns `(id, [])`.
- **`/schedule/create` handler is rewritten on top of this method** — behavior identical to today (it already blocks on conflict unless `force`; this just removes the duplicated conflict query).
- **`MemoryConsolidationEngine.consolidate`** calls `createEventChecked(..., force: false)` instead of `upsertEvent`:
  - **No conflict:** event created (origin `.extracted`), embedded, linked to hub — as today.
  - **Conflict:** the event is **NOT created**. Instead, reuse the existing clarify mechanism:
    - Create a `kind=.clarification` node whose body states the conflict in natural language (e.g. *"Mencionaste «\<title\>» el \<fecha local\> \<hora\>, pero choca con «\<otro evento\>» (\<su fecha/hora\>). ¿Lo agendo igual, lo reprogramo, o cancelo el otro?"*).
    - Add `clarifies` edges from the clarification node to both conflicting event nodes (the existing event(s) returned in `conflicts`). The mentioned-but-unbooked event has no node, so the clarification body carries its details; on user confirmation the agent calls `create_event` (with `force` if the user says "book anyway").
    - `pendingClarifications(limit:)` + the existing proactive-contact flow surface it when the user returns. **No new surfacing mechanism is introduced.**

**Boundary:** `upsertEvent` stays (used by `createEventChecked` and by tests), but no production caller invokes it directly anymore.

### 4.2 Deterministic date/epoch resolution (fix #2)

- **Prompt change** (`consolidate` extraction prompt, `MemoryConsolidationEngine`): remove the instruction to emit `attributes.start`/`end` as Unix epoch UTC. The model emits **local wall-clock text only**:
  - `attributes.date` = `"yyyy-MM-dd"` (already resolved from relative dates against "Today is …")
  - `attributes.startTime` = `"HH:mm"` (24h local)
  - `attributes.endTime` = `"HH:mm"` (optional; absent → +1h)
  - `attributes.allDay` = bool
  - The `EntitiesOut.E.Attr` struct loses `start`/`end: Double?` and gains `startTime`/`endTime: String?`.
- **Timezone delivered by the app.** `TurnEndBody` (and the reflect trigger) gain:
  - `timezone: String` — IANA id from `TimeZone.current.identifier` (macOS app).
  - `now: Double?` — client epoch (optional; server falls back to its own clock).
  The macOS `MemoryClient.consolidationTurnEnd(threadId:)` is updated to send both.
- **Server-side conversion.** New helper in `MemoryCore` mirroring the app's `ScheduleTime`:

```swift
enum ScheduleTime {
    static func epoch(date: String, time: String?, tz: TimeZone) -> Double?   // "yyyy-MM-dd","HH:mm"
}
```

  The engine builds `start`/`end` from `(date, startTime/endTime, tz)`. `todayString()` and all relative-date resolution use the **passed tz**, not the container's (`MemoryConsolidationEngine` gains an injected `timeZone: TimeZone` per cycle, defaulting to `.current` for tests).
- Result: "6:00 am" stores `06:00:00` exact in the user's tz.

### 4.3 Hub kind self-heal + extraction junk guard (fix #3)

- **`ensureKindHubs` becomes self-healing.** For each `NodeKind`, after the create-if-missing step, if an existing `hub:<kind>` node has `kind != HubKind.hub.rawValue`, update it to the correct hub kind (preserve id/label/extra/edges). Idempotent; runs on every startup (`Services.init` already calls `ensureKindHubs`). This repairs the 16 existing mis-kinded nodes on next deploy — **no manual migration, no memory reset.**
- **Rebuild + redeploy** the i3 `memory` image (the running image predates the hub-kind fix and the changes in this spec).
- **Defensive junk guard at extraction** (`MemoryText.isJunkLabel` + `consolidate` prompt):
  - `isJunkLabel` rejects any label matching a reserved word (case-insensitive): every `NodeKind.rawValue` and its `hubLabel` ("person"/"People", "place"/"Places", …).
  - Prompt clarifies: `entity` is a real-world name/thing, **never** a category/meta word ("People", "Tasks", "Conversations" are categories, not entities).
- Verify hubs remain excluded from entity reads (`byEntity`/`byHub` already exclude `HubKind.hub` per commit `6a3716b`); add a regression test that a `place` query never returns a `hub:*` node.

### 4.4 Insight dedup sweep (fix #4)

- **New sleep phase `compress`**, inserted after `reflect` in the cycle order (`nrem, summarize, detect, rem, reflect, compress, clarify, curate, shy`).
- `compress` sweeps existing `kind=.insight` nodes: groups by cosine similarity of their embeddings; within a group above threshold, keeps the highest `(salience, confidence)` as canonical, sums `mentionCount`, soft-deletes the rest (`deleted=1`) with a `sameAs` edge to the canonical — same non-destructive pattern as `upsertMergingSemantic`.
- Threshold starts at **0.15 cosine distance** (tunable constant). Reuses the existing embedding + nearest-neighbor utilities; this is a batch sweep over stored insights, not an insert-time check.
- Idempotent: a second run with no new insights merges nothing.

## 5. API / Contract Changes

| Endpoint / type | Change |
|---|---|
| `POST /v1/consolidation/turn-end` | `TurnEndBody` gains `timezone: String`, `now: Double?` |
| `POST /v1/consolidation/reflect` | same tz/now fields (so reflect-triggered cycles resolve dates correctly) |
| App `MemoryClient.consolidationTurnEnd` | sends `timezone` (+ `now`) |
| `EntitiesOut.E.Attr` (internal) | drop `start/end: Double?`; add `startTime/endTime: String?` |

No change to `/schedule/*`, recall, graph, transcript, or the agent's tools.

## 6. Data Model Impact

- No schema migration. Hubs are repaired in place by `ensureKindHubs` (kind string update). Insight dedup uses existing `deleted` flag + `sameAs` edges. Clarification nodes + `clarifies` edges already exist.

## 7. Testing

- **Unit (MemoryCore):**
  - `createEventChecked`: no-conflict creates; conflict + `force=false` returns conflicts and writes nothing; conflict + `force=true` writes.
  - `ScheduleTime.epoch(date:time:tz:)`: "2026-06-09","06:00", America/New_York → exact `06:00:00`; DST boundary case; missing time → midnight; missing endTime → +1h.
  - `ensureKindHubs` self-heal: seed a `hub:person` row with `kind='place'` → after `ensureKindHubs`, `kind='hub'`, edges/label intact; idempotent on re-run.
  - `isJunkLabel`: rejects "People"/"person"/"Tasks"/… ; accepts real names.
  - `compress`: three near-identical insights → one canonical, summed `mentionCount`, two soft-deleted + `sameAs`; no-op on second run.
- **Engine/integration:** `consolidate` over a transcript that states a conflicting event → no event node created, one `clarification` node with `clarifies` edge to the existing event. `consolidate` with a clean event → event node with exact local epoch (no UTC drift).
- **Endpoint:** `turn-end` with `timezone`/`now` resolves "tomorrow 6am" to the correct local epoch.
- **Regression:** a `byEntity`/place query never returns a `hub:*` node.
- All existing gemma-memory tests stay green.

## 8. Deployment

1. Land changes in `gemma-memory`; bump tests green.
2. `docker compose build memory` + `up -d` on the i3 (rebuild is required — the running image is stale).
3. On startup, `ensureKindHubs` repairs the 16 hub nodes. Verify via inspector that no `kind='place'` hub remains and `kind='hub'` count = `NodeKind.allCases.count`.
4. App change (tz/now) ships with the next macOS build; until then the server falls back to its own clock/tz (degraded but functional).

## 9. Risks / Open Questions / Follow-ups

- **Stale-image confirmation:** root cause is consistent with the running image predating the hub-kind fix; self-heal + rebuild fixes it regardless of the exact provenance.
- **Server timezone fallback:** if an old app build omits `timezone`, the server uses its container tz — dates may drift until the app ships. Acceptable interim.
- **Compress threshold (0.15):** may need tuning after observing real merges; it's a single constant.
- **Tool-call logging (follow-up, not here):** the `transcript` table stores only user/assistant text, so we cannot audit which tools the model actually invoked (e.g., whether it sent `force=true`). Worth adding later to close the audit gap.
- **Mentioned-but-unbooked conflicting event:** has no node, so its details live only in the clarification body; if the user confirms, the agent re-derives and calls `create_event`. Acceptable — avoids creating phantom event nodes.

## 10. Sub-project boundary

This spec is **Sub-project B** of the user's request. **Sub-project A — Model Router** (selectable provider for chat and, separately, for consolidation: local Gemma / Gemini / Cerebras / Groq, all OpenAI-compatible; API keys in settings) is a separate spec authored after B lands. B is intentionally model-agnostic so it stands on its own.
