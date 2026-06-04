# Schedule Date Hardening — Design Spec

**Date:** 2026-06-04
**Status:** Approved (brainstorm), pending plan
**Repo:** `personal_agent` (macOS app) — **app-only**, no server change.

---

## 1. Motivation

With gpt-oss-120b (via the new Model Router) the agent's schedule handling is inconsistent. Diagnosed from a real chat (threads `24A37115`, `5A78102F`, 2026-06-04) cross-checked against the i3 DB:

- **Wrong / inconsistent "next week" range.** The model said "la próxima semana (del 10 al 16 de junio)" — June 10 is a Wednesday and June 16 a Tuesday; next week (today = Thu Jun 4) is Mon Jun 8 – Sun Jun 14. In another thread it then said "del 8 al 14". The model is left to compute relative ranges and gets them wrong/inconsistent.
- **Created the trip on the wrong week.** "Viaje a Varadero del 10 al 16" (DB confirms `start=2026-06-10`) instead of the intended next week (8–14).
- **Cancelled events presented as active.** The Miami meeting is `status=cancelled`, yet the agent listed it as "dos cosas programadas". `query_schedule` excludes cancelled, but recall still surfaces the event as a remembered fact and the model presents it as active.
- **False "no conflict"** — a downstream effect of the wrong trip dates + treating a cancelled event as active.

Root causes: (1) the model computes relative dates/ranges instead of the system giving it clear conventions; (2) the agent mixes `query_schedule` (authoritative, excludes cancelled) with recall (remembers cancelled events) for "what's on my schedule".

## 2. Goals

1. The agent resolves relative date terms ("próxima semana", "el lunes") to correct, consistent absolute dates before calling schedule tools.
2. `query_schedule` is the single source of truth for "what's on my schedule"; cancelled events never appear as active.
3. Cancelled events remain retrievable when explicitly asked, clearly marked "(cancelado)".

## 3. Non-Goals

- Injecting fully pre-computed week ranges into the prompt (user chose: only today's date + textual conventions).
- Any server / consolidation change (the recall already returns `extra`, so status-marking is done app-side).
- Changing the deterministic ISO→epoch conversion (`ScheduleTime` already correct).
- A configurable week start (fixed Mon–Sun; working week Mon–Fri).

## 4. Design (all in `personal_agent/Gemma/Gemma/`)

### 4.1 Temporal conventions in the system prompt (`Agent/Agent.swift`)

`systemPrompt()` already anchors `Today is <yyyy-MM-dd (EEEE)>`. Add an explicit conventions block (English, matching the existing prompt language; the model replies in the user's language regardless):

- "A week runs Monday–Sunday. The working week runs Monday–Friday."
- "‘This week’ is the Mon–Sun week containing today. ‘Next week’ is the following Mon–Sun week (its Monday is the first Monday after today). A bare weekday (‘el lunes’) means the next occurrence."
- "ALWAYS resolve any relative term to an absolute date (yyyy-MM-dd) from today's date BEFORE calling a schedule tool — never pass terms like ‘next week’ to a tool."
- One worked example anchored to today, e.g. "(if today is Thu 2026-06-04, next week = Mon 2026-06-08 to Sun 2026-06-14)."

Kept byte-stable within a day (the example references the same `today` string already injected), preserving the server prefix-cache behavior the prompt comments care about.

### 4.2 `query_schedule` as the agenda authority (`Agent/Agent.swift` + `Memory/ScheduleTools.swift`)

- **Prompt rule:** for "¿qué tengo? / mi agenda / esta/próxima semana", the agent MUST call `query_schedule` with the resolved range and report ONLY what it returns; never list events from memory/recall as active. Empty result → say there's nothing (don't infer events from memory).
- **`QueryScheduleTool` gains an optional `includeCancelled` bool param (default false).** Passed through to `MemoryClient.scheduleWindow(from:to:includeCancelled:)` (which already supports it). Default false → cancelled invisible for the normal agenda. When the user asks about cancelled/past events, the model sets `includeCancelled:true`.
- **Event render shows status when cancelled:** the tool's `eventLine` appends "(cancelado)" for events whose status is `cancelled` (so the model never confuses active vs cancelled when listing with `includeCancelled:true`). Scheduled events render as today.
- Prompt note: "to show cancelled/past events the user explicitly asks about, call query_schedule with includeCancelled true; they are marked (cancelado)."

### 4.3 Recall marks event status (`Memory/MemoryClient.swift`)

Defensive layer so a cancelled event surfaced via recall is never rendered as active. `RecallNode` already carries `extra` (the server's recall response includes it — verified). In `RecallBundle.injectionBlock()`, for nodes with `kind == "event"`, parse `extra` for `status` and append it when not active, e.g. `- [event] Reunión Miami: ... (cancelado)`. No server change.

## 5. Data Flow

- **"¿qué tengo la próxima semana?"** → model resolves next week = Mon–Sun absolute dates (from §4.1 conventions + today) → `query_schedule(from:to:)` (includeCancelled false) → reports exactly the returned (active) events.
- **"¿qué eventos cancelé / tenía?"** → `query_schedule(..., includeCancelled:true)` → events listed with "(cancelado)".
- **Recall injection** → any event node carries its status text; cancelled ones read "(cancelado)" so the model never treats them as active even if it leans on recall.

## 6. Error Handling

- Unchanged: schedule tools already return clear strings on bad input / memory-unavailable. The conventions + authority rule are prompt-level; if the model still misreads a date, the deterministic `ScheduleTime` conversion at least keeps whatever ISO it passes consistent.

## 7. Testing

- **Prompt (unit):** `systemPrompt()` contains the week conventions ("Monday–Sunday", "working week", "resolve … before calling a schedule tool") and the "query_schedule is the source of truth" rule.
- **`QueryScheduleTool` (unit):** `includeCancelled` defaults false and is forwarded; a cancelled event renders with "(cancelado)", a scheduled one without. (Test the `eventLine`/tool against a stub.)
- **`RecallBundle.injectionBlock()` (unit):** an `event` node whose `extra` has `status:"cancelled"` renders "(cancelado)"; a `scheduled` event does not; non-event nodes unchanged.
- **E2E manual (on the fresh-start memory):** "¿qué tengo la próxima semana?" uses Mon 8 – Sun 14; "agenda el viaje la próxima semana" lands on 8–14; "¿chocan?" detects correctly; a cancelled event never shows as active.

## 8. Implementation order

1. `QueryScheduleTool` — `includeCancelled` param + status in `eventLine`.
2. `RecallBundle.injectionBlock()` — event status marking.
3. `Agent.systemPrompt()` — temporal conventions + query_schedule authority rule.
4. Manual E2E on the fresh memory.

No server deploy. Ships in the next app build (⌘R).
