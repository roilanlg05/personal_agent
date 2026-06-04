# Agent Prompt Rework (JARVIS) — Design Spec

**Date:** 2026-06-04
**Status:** Approved (brainstorm), pending plan
**Repo:** `personal_agent` (macOS app) — app-only.

---

## 1. Motivation

With gpt-oss-120b (cloud), the agent mishandles dates and confabulates. Real chats showed:
- **Dates wrong/inconsistent:** "next week" rendered as Jun 10–16 in one turn and Jun 1–7 in another (correct = Mon Jun 8 – Sun Jun 14, today = Thu Jun 4).
- **Severe hallucination:** the model invented an entire "automatic rescheduling" system, fake appointments, a fake "rule activated", and huge emoji/table-laden replies — none of it real.

Root cause located in `Agent.systemPrompt()` (`Gemma/Gemma/Agent/Agent.swift`):
1. **A stale hard-coded date example** — `"tomorrow 3pm" → 2026-06-10T15:00`. Today is Jun 4, so "tomorrow" is the 5th, not the 10th. This poisons the model's anchor toward ~Jun 10 and directly explains the "10–16" range.
2. **No anti-invention / concision constraints** — the prompt (tuned for the small on-device Gemma) lets a large, elaborative cloud model invent systems and ramble.
3. **The static date** sits in the prompt prefix and lacks the time of day.

User decisions: do NOT inject computed week/month ranges (gpt-oss computes fine once the prompt isn't poisoned) — just give the real current date **and time** as variable per-turn context, clean up the prompt, keep the agent named **Gemma**, and give it a **JARVIS-style** persona plus anti-invention + concision rules.

## 2. Goals

1. The model always has the correct current date **and time**, refreshed each turn, and no misleading hard-coded date example.
2. The agent never invents events, results, or capabilities; it reports only real tool output.
3. Replies are concise, natural, JARVIS-flavored (no tables/lists/emoji unless asked).
4. The system prompt prefix becomes fully static (better for the local mlx prefix cache).

## 3. Non-Goals

- Injecting pre-computed date ranges/anchors (explicitly rejected — trust the model with correct current date/time).
- A `resolve_date` tool.
- Renaming the agent (stays "Gemma").
- Server / consolidation changes.
- Changing the tool set or the schedule-tool logic (the prior `query_schedule includeCancelled` + conventions stay).

## 4. Design (`Gemma/Gemma/Agent/Agent.swift`, app-only)

### 4.1 Current date/time as per-turn tail context

- **Remove** from `systemPrompt()`: the `Today is \(today)` clause and the hard-coded `"tomorrow 3pm" → 2026-06-10…` example. `systemPrompt()` becomes a pure static string (no `DateFormatter`, no interpolation) → byte-stable prefix.
- **Add** a static helper `nowContext(_ date: Date = Date()) -> String` returning e.g. `Current date and time: 2026-06-04 (Thursday) 14:32 (local).` (local `DateFormatter`, `en_US_POSIX`, `yyyy-MM-dd (EEEE) HH:mm`).
- In `run()`, prepend `nowContext()` to the per-turn `recallTail` (which already rides the tail of the user message alongside recall + wakeContext). So the model gets a fresh, correct date+time every turn, while the system prompt prefix stays static.
- The prompt refers to "the current date/time given to you" for resolving relative dates (instead of an in-prompt `today`).

### 4.2 JARVIS persona + anti-invention + concision (the static prompt)

`systemPrompt()` returns this static text (English; the model replies in the user's language), followed by the existing `Self.scheduleConventions`:

```
You are Gemma, the user's personal assistant — in the spirit of JARVIS: composed, precise,
quietly witty, and always a step ahead. Address the user directly, by name when you know it.

Be brief: reply in 1–3 natural sentences. Do not use tables, bulleted/numbered lists, headers,
markdown sections, or emoji unless the user explicitly asks for that format.

Ground everything in your tools and memory. Report ONLY what your tools actually returned. NEVER
invent events, appointments, reminders, results, or capabilities. You have no automatic-rescheduling
feature — to move or cancel something you must use the tools or ask. If you did not call a tool, do
not claim that you did. When a tool is relevant (the time, the user's schedule, etc.), call it
instead of guessing; after a tool runs, ALWAYS reply with a short sentence confirming what you did
or answering — never end a turn with only a tool call.

Answer only what was asked; don't list unrelated things you remember. But when several remembered
facts match the question (e.g. multiple events), mention all of them with their dates, not only the
most recent.

Scheduling: the calendar lives in the tools. For appointments/meetings/trips, briefly acknowledge,
then call check_schedule, then create_event. Pass times as LOCAL ISO datetimes resolved from the
current date/time you were given. If only a start time is given, ask for the end first. If a span is
vague ("rest of the week"), ask whether it starts now or tomorrow; "rest of the night" means until
06:00 the next day. If create_event reports a conflict, do NOT force it — say what it conflicts with
(consider travel/location, e.g. a meeting in another city during a trip) and ask whether to
reschedule, cancel the other, or book anyway; call create_event with force true only after the user
confirms. Use cancel_events (which only cancels, never deletes) for "cancel my appointments". To-dos
without a fixed time (call mom, gym) are not calendar events.
```

Then `\(Self.scheduleConventions)` (unchanged from the prior fix: week Mon–Sun / working week Mon–Fri, resolve relative→absolute before tools, `query_schedule` is the only source of truth, `includeCancelled` for cancelled/past marked "(cancelado)").

## 5. Data Flow

Per turn: `run()` builds `nowContext()` + recall + wakeContext as the tail appended to the user message; the static JARVIS system prompt is the prefix. The model resolves relative dates from the tail's current date/time and is constrained to tool-grounded, concise replies.

## 6. Error Handling

Unchanged. The anti-invention rule is prompt-level; tool failures still surface their existing error strings.

## 7. Testing

- **Static prompt (unit):** `Agent.systemPrompt()` (make it testable — `internal`/`static` accessor or assert via a known static) contains: "JARVIS", "Report ONLY what your tools actually returned", "NEVER invent", "no automatic-rescheduling", "do not use tables", and (via scheduleConventions) "Monday–Sunday" + "query_schedule is the ONLY source of truth". It must NOT contain "Today is" or "2026-06-10".
- **`nowContext` (unit):** `Agent.nowContext(date:)` for a fixed date → exact `Current date and time: 2026-06-04 (Thursday) 14:32 (local).` format (build the Date in a fixed local calendar in the test).
- **Tail wiring (unit):** `run()` prepends `nowContext` to the tail — assert the per-turn context string starts with "Current date and time:" (test via the smallest seam available; if `run()` is hard to unit-test, at minimum assert `nowContext` is included in the message-building helper).
- **E2E manual (fresh memory):** "¿qué tengo la próxima semana?" → Mon 8 – Sun 14; "bloquea el próximo mes" → July; the agent does NOT invent systems/events; replies are concise JARVIS-style (no tables/emoji).

## 8. Implementation order

1. `nowContext(_:)` static helper + unit test.
2. `systemPrompt()` rewrite (JARVIS + anti-invention + concision; remove date/example) + unit test.
3. `run()` prepends `nowContext()` to the tail.
4. Manual E2E on the fresh memory.

App-only; ships in the next build (⌘R). i3 memory already reset clean.
