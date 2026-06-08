# update_event — Design

**Date:** 2026-06-08
**Status:** Approved (pending implementation plan)

## Goal

Let the agent EDIT an existing calendar event's time, title, or location **in place** —
never cancel-and-recreate — and make a correction never conflict with the event itself.

Fixes the worst dialogue bugs from the 2026-06-08 voice review (see
`memory/agent-behavior-failure-modes.md`):

- #2 (WORST): "change the location" → the agent **cancelled** the event because no
  `update_event` tool existed.
- #3: a correction was treated as a scheduling **conflict** (it overlapped the event's own
  old slot).

## Background (current state)

The calendar is reached by **two parallel paths**, both backed by the same store on the i3:

1. **Voice** → server-side `AgentLoop` + `GatewayTools` (`GatewayTools.swift`), which call the
   store directly.
2. **In-app chat** → app `ScheduleTools.swift` → HTTP endpoints in `ScheduleHandlers.swift`
   (`/schedule/check|create|window|cancel`) on the i3, via `MemoryClient`.

Store facts (`MemoryCore/MemoryStore+Schedule.swift`):

- Events are `Node`s with `kind == event`; `NodeAttributes` already carries `status`, `startAt`,
  `endAt`, `allDay`, `location`, `canonicalKey`.
- `upsertEvent(title,start,…)` dedups by `canonicalKey = eventCanonicalKey(title, startAt)` — so
  changing the title or start currently creates a **new** event rather than editing.
- `createEventChecked` runs `scheduleConflicts(start,end)` and blocks unless `force`.
- `cancelEvents(ids?, from?, to?)` soft-cancels (status=`cancelled`).
- The schedule tools/endpoints expose **no event ids** to the agent — events are printed as
  `title: start–end @ loc (status)`. The user references an event by **time** ("the 3pm one
  tomorrow"), so the design matches on time, not ids.

## Design

### 1. Store (MemoryCore, shared by both paths)

**`findEditTarget(start: Double, title: String?) -> EditTarget`** (pure read)
where `enum EditTarget { case found(Node); case none; case ambiguous([Node]) }`.

- Candidates = events with `status == "scheduled"` whose `startAt` falls on the **same calendar
  day** as `start` (in the server's `TimeZone.current` — tolerant of the model passing `8:00` vs
  `08:00`, or rounding seconds).
- If `title` is non-empty, keep candidates whose `label` matches case-insensitively (trimmed).
- Tie-break to the start nearest the provided `start`:
  - exactly 1 candidate → `.found`.
  - more than 1 → keep those whose `startAt` equals the provided `start` to the minute; if that
    leaves exactly 1 → `.found`, else `.ambiguous(candidates)`.
  - 0 candidates → `.none`.

**`applyEventEdit(id: String, newTitle: String?, newStart: Double?, newEnd: Double?, location: String?, allDay: Bool?) -> Node`**
(write)

- Loads the node by `id`, overrides ONLY the provided fields (nil = unchanged), recomputes
  `canonicalKey = eventCanonicalKey(effectiveTitle, effectiveStart)`, keeps the **same node id**,
  keeps `status == "scheduled"`, sets `updatedAt`/`lastSeenAt`/`dirty`. Returns the updated node.
- `location` semantics: a provided empty string clears the location; nil leaves it unchanged.

**`scheduleConflicts(start: Double, end: Double, excluding: Set<String> = [])`**

- Add the `excluding` parameter (default empty → existing callers unchanged). Filters out nodes
  whose `id ∈ excluding` so an edit never conflicts with the event being edited.

### 2. Gateway tool `update_event` (voice path)

`GatewayTools.swift`, registered in `GatewayToolRegistry` (becomes 12 tools).

Params:

- `start` (string, **required**) — local ISO of the event's CURRENT start (the time the user
  named).
- `title` (string, optional) — current title, to disambiguate and to echo back as confirmation.
- `newStart`, `newEnd` (string, optional) — new local ISO time.
- `newTitle` (string, optional) — rename.
- `location` (string, optional) — set/replace location.
- `allDay` (boolean, optional).
- `force` (boolean, optional) — apply despite a conflict with a DIFFERENT event.

Logic:

1. Resolve `findEditTarget(start, title)`.
   - `.none` → `"I couldn't find that event — want me to check your schedule?"` (NEVER
     creates/cancels).
   - `.ambiguous(list)` → `"I found more than one: <list>. Which one?"`.
   - `.found(node)` → continue.
2. Compute effective new values (old node overridden by provided params).
   `timeChanged = newStart != nil || newEnd != nil`.
3. If `timeChanged`: `conflicts = scheduleConflicts(effStart, effEnd, excluding: [node.id])`.
   - non-empty && !force → return `"NOT changed — conflicts with: <eventLine…>. Ask whether to
     reschedule, cancel the other, or keep it anyway — if they confirm, call update_event again
     with force=true."` (do NOT apply).
   - otherwise → apply.
4. If not `timeChanged` (location/title/allDay only) → apply directly, no conflict check.
5. On apply → `applyEventEdit(...)`; success message **echoes the resolved event**, e.g.
   `"Updated: meeting with Carlos — 4:00 PM–5:00 PM @ Miami."`

### 3. HTTP endpoint `POST /schedule/update`

`ScheduleHandlers.swift`, registered alongside the others. Request body:
`{ start, title?, newStart?, newEnd?, newTitle?, location?, allDay?, force? }` (ISO strings for
times). Response mirrors `/schedule/create`'s shape:

- found + applied → `{ "updated": true, "event": {…} }`
- time conflict, not forced → `{ "updated": false, "conflicts": [ {…} ] }`
- not found → `{ "updated": false, "notFound": true }`
- ambiguous → `{ "updated": false, "ambiguous": [ {…} ] }`

`eventJSON` (already in the handler) is reused for `event`/`conflicts`/`ambiguous`.

### 4. App (in-app chat path)

- `MemoryClient.updateEvent(...)` → `POST /schedule/update`, decoding the response above.
- An `update_event` tool in `ScheduleTools.swift` mirroring the gateway tool's params and
  messages, reusing the existing `ScheduleTime` ISO resolution; registered in the app's tool
  registry. Same not-found / ambiguous / conflict / echo behavior.

### 5. Prompt (BOTH copies, kept byte-in-sync)

`AgentPrompt.swift` (gateway) and `Agent.swift` (app). Add one rule to the Scheduling paragraph:

> To change an existing event's time, title, or location, call update_event — never cancel and
> recreate. Identify it by the time the user named (start) plus the title when known, and confirm
> by naming the event back. A time change is conflict-checked like create_event (excluding the
> event itself).

## Error handling

- Missing required `start` → tool returns a short ask for the event's time; endpoint → 400.
- Store/DB error → tool returns `"schedule error: …"` (matches create); endpoint → 500-style JSON
  error (matches existing handlers).
- `.none` / `.ambiguous` are normal (not errors) — surfaced as conversational replies; the agent
  never falls back to cancel+recreate.

## Testing

**MemoryCore (`MemoryStore+Schedule` tests):**

- `findEditTarget`: found (exact + same-day-tolerant), none, ambiguous (two events same
  title/day), title filter narrows, cancelled/done excluded.
- `applyEventEdit`: location-only edit (others unchanged), rename, time move — all keep the same
  node id and recompute `canonicalKey`; empty-string location clears it.
- `scheduleConflicts(excluding:)`: a moved event does not conflict with itself; still detects a
  different overlapping event.

**Gateway tool (`GatewayToolsTests`):**

- location-only → applied, NO conflict check, echo message.
- time move, no conflict → applied + echo.
- time move that overlaps another event → `NOT changed`, asks; with `force=true` → applied.
- not found → the check-your-schedule message; nothing created/cancelled.
- ambiguous → lists candidates and asks.

**Endpoint (`ScheduleEndpointsTests`):** `/schedule/update` happy, conflict (not forced),
notFound.

**App:** `ScheduleTools` update tool against a mock client (happy/conflict/notFound/ambiguous);
`MemoryClient.updateEvent` decodes each response shape.

**Prompt:** both gateway and app prompt tests assert the prompt mentions `update_event`.

## Scope / non-goals

- Covers BOTH the voice (gateway) and in-app (HTTP + app tool) paths in this one spec.
- No event ids exposed to the model (time-first matching makes them unnecessary).
- No recurring-event editing, no drag-style multi-event bulk edit — out of scope.
