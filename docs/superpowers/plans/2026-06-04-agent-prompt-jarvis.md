# Agent Prompt Rework (JARVIS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the agent's date handling and confabulation by reworking the system prompt: remove the stale hard-coded date example, feed the real current date+time as per-turn tail context, give the agent a concise JARVIS persona, and forbid inventing events/results/capabilities.

**Architecture:** App-only, all in `Gemma/Gemma/Agent/Agent.swift`. The system prompt prefix becomes a fully static `static let` (JARVIS persona + anti-invention + concision + the existing schedule conventions). The current date **and time** moves out of the prefix into a per-turn `nowContext()` string prepended to the message tail (where recall/wakeContext already ride), so the prefix stays byte-stable and the model always sees the correct, fresh datetime.

**Tech Stack:** Swift 6 / SwiftUI / Xcode. Spec: `docs/superpowers/specs/2026-06-04-agent-prompt-jarvis-design.md`.

**Build/test:** `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -40` (slow). Quick compile: `xcodebuild build -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -15`.
**Synchronized file groups:** new files under `Gemma/...` auto-include; don't edit `project.pbxproj`.
**Known pre-existing failure to IGNORE:** `HarnessModelTests.test_defaultBaseURL_isLocalhost8081`.

---

## File Structure

- Modify `Gemma/Gemma/Agent/Agent.swift`:
  - Add `static func nowContext(_:)` (current date+time → tail string).
  - Replace `private func systemPrompt()` body with a static `systemPromptText` (no date, JARVIS persona + constraints) and have `systemPrompt()` return it.
  - In `run()`, prepend `nowContext()` to the per-turn `recallTail`.
- Test: `Gemma/GemmaTests/AgentJarvisPromptTests.swift` (new).

The existing `Agent.scheduleConventions` static (from the prior fix) is kept and appended to the static prompt.

---

## Task 1: `nowContext(_:)` — current date+time tail string

**Files:**
- Modify: `Gemma/Gemma/Agent/Agent.swift`
- Test: `Gemma/GemmaTests/AgentJarvisPromptTests.swift` (create)

### Step 1: Write the failing test — create `Gemma/GemmaTests/AgentJarvisPromptTests.swift`:

```swift
import XCTest
@testable import Gemma

@MainActor
final class AgentJarvisPromptTests: XCTestCase {
    func test_nowContext_format() {
        // Build a fixed local date: 2026-06-04 (Thursday) 14:32.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 4; comps.hour = 14; comps.minute = 32
        let date = Calendar.current.date(from: comps)!
        XCTAssertEqual(Agent.nowContext(date),
                       "Current date and time: 2026-06-04 (Thursday) 14:32 (local).")
    }
}
```

### Step 2: Run — verify it FAILS ("type 'Agent' has no member 'nowContext'").
Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "AgentJarvisPromptTests|error:|TEST (SUCCEEDED|FAILED)"`

### Step 3: Add the helper to `Agent` (near `scheduleConventions`):

```swift
/// Current local date + time, injected per-turn on the message tail (NOT in the static prefix),
/// so the model always has the correct "now" to resolve relative dates against.
nonisolated static func nowContext(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd (EEEE) HH:mm"
    return "Current date and time: \(f.string(from: date)) (local)."
}
```

### Step 4: Run — verify PASS.
Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "test_nowContext_format|' failed|TEST (SUCCEEDED|FAILED)"`
Expected: `test_nowContext_format` passes; only the known-unrelated `test_defaultBaseURL_isLocalhost8081` fails.

### Step 5: Commit
```bash
git add Gemma/Gemma/Agent/Agent.swift Gemma/GemmaTests/AgentJarvisPromptTests.swift
git commit -m "feat(agent): nowContext — current date+time for the per-turn tail"
```

---

## Task 2: Static JARVIS system prompt (remove date + stale example)

**Files:**
- Modify: `Gemma/Gemma/Agent/Agent.swift` (`systemPrompt()` → static `systemPromptText`)
- Test: `Gemma/GemmaTests/AgentJarvisPromptTests.swift` (append)

### Step 0: Read the current `systemPrompt()` in `Agent.swift` (the `private func` that builds `Today is \(today)` and the `"tomorrow 3pm" → 2026-06-10…` example). It will be replaced by a static string.

### Step 1: Append the failing test:

```swift
func test_systemPrompt_isJarvis_constrained_dateless() {
    let p = Agent.systemPromptText
    XCTAssertTrue(p.contains("JARVIS"), "persona")
    XCTAssertTrue(p.contains("Report ONLY what your tools actually returned"), "anti-invent")
    XCTAssertTrue(p.contains("NEVER invent"), "anti-invent")
    XCTAssertTrue(p.localizedCaseInsensitiveContains("automatic-rescheduling"), "no fake feature")
    XCTAssertTrue(p.localizedCaseInsensitiveContains("do not use tables"), "concision")
    XCTAssertTrue(p.contains("Monday–Sunday"), "schedule conventions kept")
    XCTAssertTrue(p.localizedCaseInsensitiveContains("query_schedule is the ONLY source of truth"), "authority kept")
    // The poison must be gone:
    XCTAssertFalse(p.contains("Today is"), "no static date in prefix")
    XCTAssertFalse(p.contains("2026-06-10"), "no hard-coded date example")
}
```

### Step 2: Run — verify it FAILS ("type 'Agent' has no member 'systemPromptText'").

### Step 3: In `Agent.swift`, add the static prompt and make `systemPrompt()` return it. Add this `static let` (alongside `scheduleConventions`):

```swift
/// Fully static system prompt prefix (no date — the current date/time rides the per-turn tail via
/// nowContext()). JARVIS persona + anti-invention + concision; schedule conventions appended.
nonisolated static let systemPromptText: String = """
You are Gemma, the user's personal assistant — in the spirit of JARVIS: composed, precise, \
quietly witty, and always a step ahead. Address the user directly, by name when you know it. \
Be brief: reply in 1–3 natural sentences. Do not use tables, bulleted or numbered lists, headers, \
markdown sections, or emoji unless the user explicitly asks for that format. \
Ground everything in your tools and memory. Report ONLY what your tools actually returned. NEVER \
invent events, appointments, reminders, results, or capabilities. You have no automatic-rescheduling \
feature — to move or cancel something you must use the tools or ask. If you did not call a tool, do \
not claim that you did. When a tool is relevant (the time, the user's schedule, etc.), call it \
instead of guessing; after a tool runs, ALWAYS reply with a short sentence confirming what you did or \
answering — never end a turn with only a tool call. \
Answer only what was asked; don't list unrelated things you remember. But when several remembered \
facts match the question (e.g. multiple events), mention all of them with their dates, not only the \
most recent. \
Scheduling: the calendar lives in the tools. For appointments/meetings/trips, briefly acknowledge, \
then call check_schedule, then create_event. Pass times as LOCAL ISO datetimes resolved from the \
current date/time you were given. If only a start time is given, ask for the end first. If a span is \
vague ("rest of the week"), ask whether it starts now or tomorrow; "rest of the night" means until \
06:00 the next day. If create_event reports a conflict, do NOT force it — say what it conflicts with \
(consider travel/location, e.g. a meeting in another city during a trip) and ask whether to \
reschedule, cancel the other, or book anyway; call create_event with force true only after the user \
confirms. Use cancel_events (which only cancels, never deletes) for "cancel my appointments". To-dos \
without a fixed time (call mom, gym) are not calendar events.
\(scheduleConventions)
"""
```

Replace the body of `systemPrompt()` so it just returns the static (drop the `DateFormatter`/`today` lines entirely):
```swift
private func systemPrompt() -> String { Self.systemPromptText }
```

### Step 4: Run — verify PASS + suite builds.
Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "test_systemPrompt_isJarvis|' failed|TEST (SUCCEEDED|FAILED)"`
Expected: passes; only the known-unrelated failure remains.

### Step 5: Commit
```bash
git add Gemma/Gemma/Agent/Agent.swift Gemma/GemmaTests/AgentJarvisPromptTests.swift
git commit -m "feat(agent): static JARVIS prompt — anti-invention + concision, no stale date example"
```

---

## Task 3: Feed `nowContext()` into the per-turn tail

**Files:**
- Modify: `Gemma/Gemma/Agent/Agent.swift` (`run()`)

### Step 0: Read `run()` — find the block that builds `recallTail` (it starts `var recallTail = self.recallTail` and folds in `wakeContext`), before `opts.systemPrompt = systemPrompt()`.

### Step 1: Prepend `nowContext()` to the tail. Right after the existing `recallTail`/`wakeContext` folding (and before `opts.systemPrompt = …`), add:

```swift
// The current date/time rides the tail (not the static prefix) so the model always has a fresh,
// correct "now" to resolve relative dates against, while the prefix stays byte-stable.
let nowCtx = Self.nowContext()
recallTail = recallTail.isEmpty ? nowCtx : nowCtx + "\n\n" + recallTail
```
(`recallTail` is already a `var` in `run()`. Do not change how `recallTail` is later appended to the user prompt — only prepend `nowCtx` here.)

### Step 2: Build to verify it compiles.
Run: `xcodebuild build -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. (run() is an async streaming method exercised by the manual E2E; the pure pieces are unit-tested in Tasks 1–2.)

### Step 3: Run the full suite to confirm no regression.
Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "' failed|TEST (SUCCEEDED|FAILED)"`
Expected: only the known-unrelated `test_defaultBaseURL_isLocalhost8081` fails.

### Step 4: Commit
```bash
git add Gemma/Gemma/Agent/Agent.swift
git commit -m "feat(agent): prepend current date+time to the per-turn message tail"
```

---

## Task 4: Manual E2E on the fresh memory

**Files:** none. The i3 memory is reset clean (transcript=0, events=0). Relaunch (⌘. then ⌘R), today = Thu 2026-06-04 → next week = Mon Jun 8 – Sun Jun 14:

- [ ] "¿qué tengo la próxima semana?" → query_schedule for **Jun 8–14** (not 10–16), concise reply.
- [ ] "bloquéame todo el próximo mes" → an event/range in **July 2026** (next month), not June.
- [ ] "agéndame una reunión el martes 9 de junio 8am en Miami" then "el viaje a Varadero toda la próxima semana" → conflict on the 9 detected; agent asks, doesn't double-book or invent.
- [ ] Replies are **concise, JARVIS-style** — no tables, no emoji, no invented "automatic rescheduling" system.

Record the result. Remaining date mistakes are prompt-driven (iterate on `systemPromptText`/`scheduleConventions`).

---

## Self-Review

**Spec coverage:** §4.1 (date/time on tail, remove static date + example, static prefix) → Tasks 1 (nowContext) + 2 (remove date from prompt) + 3 (tail wiring). §4.2 (JARVIS persona + anti-invention + concision + kept conventions) → Task 2. §7 testing → Tasks 1–2 unit + Task 4 E2E (run() wiring verified by build + E2E, noted). §8 order → Tasks 1–4. ✓ App-only, no server. ✓

**Placeholder scan:** No TBD/TODO; every code step is concrete (full prompt text, full helper). Task 3's "verified by build + E2E" is an explicit, justified test-scope note (run() is an async stream that the pure helpers + manual E2E cover), not a placeholder.

**Type consistency:** `Agent.nowContext(_ date: Date = Date()) -> String` defined in Task 1, used in Task 3 and asserted in its test. `Agent.systemPromptText` (static let) defined in Task 2, consumed by `systemPrompt()` and asserted in its test. `Agent.scheduleConventions` (pre-existing) referenced inside `systemPromptText`. The test asserts both the new content (JARVIS/anti-invent/concision) and the removal of the poison ("Today is", "2026-06-10").
