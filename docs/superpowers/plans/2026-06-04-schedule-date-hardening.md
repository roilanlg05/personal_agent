# Schedule Date Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the agent's schedule handling consistent under gpt-oss-120b: resolve relative dates from clear conventions, treat `query_schedule` as the single source of truth, and never present cancelled events as active.

**Architecture:** App-only (`personal_agent`). Three changes: (1) `query_schedule` gains `includeCancelled` + renders status; (2) the recall injection block marks cancelled events; (3) the system prompt gains week conventions (Mon–Sun / working week Mon–Fri) + a "query_schedule is authoritative" rule. No server change (the recall already returns `extra`). Spec: `docs/superpowers/specs/2026-06-04-schedule-date-hardening-design.md`.

**Tech Stack:** Swift 6 / SwiftUI / Xcode.

**Build/test:** `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -40` (slow). Quick compile: `xcodebuild build -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -15`.
**Synchronized file groups:** new files under `Gemma/...` auto-include; don't edit `project.pbxproj`.
**Known pre-existing failure to IGNORE:** `HarnessModelTests.test_defaultBaseURL_isLocalhost8081`.

---

## File Structure

- Modify `Gemma/Gemma/Memory/ScheduleTools.swift` — shared `scheduleStatusSuffix(_:)`, status in `eventLine`, `includeCancelled` param on `QueryScheduleTool`.
- Modify `Gemma/Gemma/Memory/MemoryClient.swift` — `RecallBundle.injectionBlock()` marks event status.
- Modify `Gemma/Gemma/Agent/Agent.swift` — `scheduleConventions` static + system prompt.
- Tests: `Gemma/GemmaTests/ScheduleStatusTests.swift` (new), `Gemma/GemmaTests/RecallInjectionTests.swift` (new), `Gemma/GemmaTests/AgentPromptTests.swift` (new).

---

## Task 1: `query_schedule` includeCancelled + event status rendering

**Files:**
- Modify: `Gemma/Gemma/Memory/ScheduleTools.swift`
- Test: `Gemma/GemmaTests/ScheduleStatusTests.swift` (create)

### Step 1: Write the failing test — create `Gemma/GemmaTests/ScheduleStatusTests.swift`:

```swift
import XCTest
@testable import Gemma

final class ScheduleStatusTests: XCTestCase {
    func test_statusSuffix_maps() {
        XCTAssertEqual(scheduleStatusSuffix("cancelled"), " (cancelado)")
        XCTAssertEqual(scheduleStatusSuffix("done"), " (hecho)")
        XCTAssertEqual(scheduleStatusSuffix("scheduled"), "")
        XCTAssertEqual(scheduleStatusSuffix(nil), "")
    }
}
```

### Step 2: Run — verify it FAILS ("cannot find 'scheduleStatusSuffix'").

### Step 3: In `ScheduleTools.swift`, add the shared helper (top-level, internal so `MemoryClient.swift` can reuse it) and use it in `eventLine`:

Add near the top of the file (after the existing `private func eventLine`/helpers — make it a NON-private top-level func):
```swift
/// Human suffix for a schedule event status. Active ("scheduled"/nil) → "". Shared by the
/// schedule tools and the recall injection block so cancelled events are never shown as active.
func scheduleStatusSuffix(_ status: String?) -> String {
    switch status {
    case "cancelled": return " (cancelado)"
    case "done": return " (hecho)"
    default: return ""
    }
}
```

Update `eventLine` to append it:
```swift
private func eventLine(_ e: MemoryClient.ScheduleEvent) -> String {
    let loc = (e.location?.isEmpty == false) ? " @ \(e.location!)" : ""
    return "\(e.title): \(ScheduleTime.human(fromEpoch: e.start))–\(ScheduleTime.human(fromEpoch: e.end))\(loc)\(scheduleStatusSuffix(e.status))"
}
```

### Step 4: Add `includeCancelled` to `QueryScheduleTool`. Add the param and forward it:

In `QueryScheduleTool.parameters`, append:
```swift
AgentToolParam(name: "includeCancelled", type: .boolean, description: "true to also list cancelled/past events (shown marked '(cancelado)'). Default false — the normal agenda excludes them.", required: false),
```

In `QueryScheduleTool.run`, replace the `scheduleWindow` call to pass the flag:
```swift
let includeCancelled = (o["includeCancelled"] as? Bool) ?? false
...
let evs = try await m.scheduleWindow(from: f, to: t, includeCancelled: includeCancelled)
```
(The `o` dictionary is already parsed at the top of `run`; add the `includeCancelled` line alongside the `f`/`t` guards, before the `await MainActor.run` activity call. Keep everything else unchanged.)

### Step 5: Run — verify PASS + suite builds (ignore the known-unrelated failure).
Run: `xcodebuild test ... 2>&1 | grep -E "ScheduleStatusTests|' failed|TEST (SUCCEEDED|FAILED)"`

### Step 6: Commit
```bash
git add Gemma/Gemma/Memory/ScheduleTools.swift Gemma/GemmaTests/ScheduleStatusTests.swift
git commit -m "feat(schedule): query_schedule includeCancelled + render event status (cancelado)"
```

---

## Task 2: Recall injection marks cancelled events

**Files:**
- Modify: `Gemma/Gemma/Memory/MemoryClient.swift` (`RecallBundle.injectionBlock()`)
- Test: `Gemma/GemmaTests/RecallInjectionTests.swift` (create)

### Step 1: Write the failing test — create `Gemma/GemmaTests/RecallInjectionTests.swift`:

```swift
import XCTest
@testable import Gemma

final class RecallInjectionTests: XCTestCase {
    private func node(_ kind: String, _ label: String, _ body: String, _ extra: String?) -> MemoryClient.RecallNode {
        MemoryClient.RecallNode(kind: kind, label: label, body: body, extra: extra)
    }

    func test_cancelledEvent_isMarked() {
        let bundle = MemoryClient.RecallBundle(core: [], recall: [
            node("event", "Reunión Miami", "9-jun 8am", #"{"status":"cancelled","startAt":1}"#)
        ])
        let block = bundle.injectionBlock()
        XCTAssertTrue(block.contains("Reunión Miami"))
        XCTAssertTrue(block.contains("(cancelado)"), block)
    }

    func test_scheduledEvent_notMarked() {
        let bundle = MemoryClient.RecallBundle(core: [], recall: [
            node("event", "Dentista", "11-jun 9am", #"{"status":"scheduled"}"#)
        ])
        XCTAssertFalse(bundle.injectionBlock().contains("(cancelado)"))
    }

    func test_nonEventNode_unchanged() {
        let bundle = MemoryClient.RecallBundle(core: [], recall: [
            node("preference", "sushi", "le gusta el sushi", nil)
        ])
        let block = bundle.injectionBlock()
        XCTAssertTrue(block.contains("sushi"))
        XCTAssertFalse(block.contains("(cancelado)"))
    }
}
```
NOTE: `RecallNode` and `RecallBundle` are nested in `MemoryClient` with memberwise inits (they are `Decodable` structs with stored `let`s, so the synthesized memberwise init is internal — usable from the test target via `@testable`). If the memberwise init is not accessible, add explicit `init`s to both structs in Step 3.

### Step 2: Run — verify it FAILS (no "(cancelado)" marking yet).

### Step 3: In `MemoryClient.swift`, update `RecallBundle.injectionBlock()` to mark event status. Replace the `lines` mapping:

```swift
let lines = (summaries + rest).map { n -> String in
    let base = "- [\(n.kind)] \(n.label): \(n.body.isEmpty ? n.label : n.body)"
    guard n.kind == "event", let extra = n.extra,
          let data = extra.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let status = obj["status"] as? String else { return base }
    return base + scheduleStatusSuffix(status)
}
```
(`scheduleStatusSuffix` is the top-level helper added in Task 1 — same module, no import needed.)

### Step 4: Run — verify PASS + suite builds.
Run: `xcodebuild test ... 2>&1 | grep -E "RecallInjectionTests|' failed|TEST (SUCCEEDED|FAILED)"`

### Step 5: Commit
```bash
git add Gemma/Gemma/Memory/MemoryClient.swift Gemma/GemmaTests/RecallInjectionTests.swift
git commit -m "feat(schedule): recall marks cancelled events so they never read as active"
```

---

## Task 3: System prompt — week conventions + query_schedule authority

**Files:**
- Modify: `Gemma/Gemma/Agent/Agent.swift`
- Test: `Gemma/GemmaTests/AgentPromptTests.swift` (create)

### Step 0: Read `Gemma/Gemma/Agent/Agent.swift` — find `private func systemPrompt()` (it builds a multi-line string with `Today is \(today)` and a "Scheduling: …" paragraph). Note the access level (`private`).

### Step 1: Write the failing test — create `Gemma/GemmaTests/AgentPromptTests.swift`:

```swift
import XCTest
@testable import Gemma

final class AgentPromptTests: XCTestCase {
    func test_conventions_present() {
        let c = Agent.scheduleConventions
        XCTAssertTrue(c.contains("Monday") && c.contains("Sunday"), c)   // week = Mon–Sun
        XCTAssertTrue(c.localizedCaseInsensitiveContains("working week"), c)
        XCTAssertTrue(c.localizedCaseInsensitiveContains("absolute date"), c) // resolve before tool
        XCTAssertTrue(c.localizedCaseInsensitiveContains("query_schedule"), c) // authority rule
    }
}
```

### Step 2: Run — verify it FAILS ("type 'Agent' has no member 'scheduleConventions'").

### Step 3: In `Agent.swift`, add a static constant with the conventions + authority rule, and interpolate it into `systemPrompt()`:

Add as a `static let` on `Agent` (module-internal so the test can read it):
```swift
/// Schedule conventions injected into the system prompt. Static (date-independent) so it is
/// testable and stays byte-stable for the server prefix cache.
static let scheduleConventions = """
Time conventions: a week runs Monday–Sunday; the working week runs Monday–Friday. \
"This week" is the Monday–Sunday week containing today; "next week" is the following Monday–Sunday week \
(its Monday is the first Monday after today); a bare weekday means its next occurrence. \
ALWAYS resolve any relative term to an absolute date (yyyy-MM-dd) from today's date BEFORE calling a \
schedule tool — never pass terms like "next week" to a tool. \
For "what's on my schedule / this week / next week", query_schedule is the ONLY source of truth: call it \
with the resolved range and report exactly what it returns; never list events from memory as if active, \
and if it returns nothing, say there is nothing. To show cancelled/past events the user explicitly asks \
about, call query_schedule with includeCancelled true; they are shown marked "(cancelado)".
"""
```

Then interpolate `\(Self.scheduleConventions)` into the `systemPrompt()` string, immediately after the existing "Scheduling: …" paragraph (keep that paragraph; append the conventions). Example — within the existing multi-line literal, after the line ending `…don't create_event for them.` add:
```
\(Self.scheduleConventions)
```
Keep `Today is \(today)` where it is (the conventions reference "today's date" textually, no interpolation needed inside the static).

### Step 4: Run — verify PASS + suite builds.
Run: `xcodebuild test ... 2>&1 | grep -E "AgentPromptTests|' failed|TEST (SUCCEEDED|FAILED)"`

### Step 5: Commit
```bash
git add Gemma/Gemma/Agent/Agent.swift Gemma/GemmaTests/AgentPromptTests.swift
git commit -m "feat(schedule): system prompt — week conventions + query_schedule authority"
```

---

## Task 4: Manual E2E on the fresh-start memory

**Files:** none.

The i3 memory was reset clean (transcript=0, events=0). Relaunch the app (⌘. then ⌘R) and verify in chat (today = Thu 2026-06-04, so next week = Mon Jun 8 – Sun Jun 14):

- [ ] "¿qué tengo la próxima semana?" → agent calls query_schedule for **Jun 8–14** (not 10–16) and reports correctly (nothing yet).
- [ ] "agéndame un viaje a Varadero toda la próxima semana" → event created spanning **Jun 8–14** (Mon–Sun), not 10–16.
- [ ] "agéndame una reunión el martes 9 de junio 8am en Miami" → conflict detected against the trip (the trip now correctly covers the 9) → agent asks instead of double-booking.
- [ ] Cancel the trip, then "¿qué tengo la próxima semana?" → "nothing" (cancelled trip does NOT show as active).
- [ ] "¿qué eventos cancelé?" → trip listed marked "(cancelado)".

Record the result. If a relative-date range is still wrong, the prompt conventions need tightening (prompt-driven; iterate on `scheduleConventions`).

---

## Self-Review

**Spec coverage:** §4.1 conventions → Task 3; §4.2 query_schedule authority + includeCancelled + status render → Tasks 1, 3; §4.3 recall marks status → Task 2; §7 testing → unit tests in Tasks 1–3 + manual E2E Task 4; §8 order (tool → recall → prompt → E2E) → Tasks 1–4. ✓ No server change (matches "app-only"). ✓

**Placeholder scan:** No TBD/TODO; every code step is concrete. The `RecallNode`/`RecallBundle` init note (Task 2 Step 1) is an explicit conditional instruction, not a placeholder.

**Type consistency:** `scheduleStatusSuffix(_ status: String?) -> String` defined in Task 1, reused in Task 2 (same module). `MemoryClient.ScheduleEvent.status`, `RecallNode.extra`, `scheduleWindow(from:to:includeCancelled:)` match the real declarations. `Agent.scheduleConventions` defined and consumed in Task 3, read in its test. Status strings ("cancelled"/"done") match the server's `NodeAttributes.status` values.
