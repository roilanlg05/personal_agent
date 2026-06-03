# SP1 · Plan 2 — personal_agent: schedule tools + conversational flow

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the macOS agent four schedule tools (`check_schedule`, `create_event`, `query_schedule`, `cancel_events`) over the live `/v1/schedule` endpoints, plus a conversational scheduling flow (clarify → check → create/ask) so it stops double-booking the user.

**Architecture:** Tools are `AgentTool`s that read `MemoryToolbox.shared.memory` (a `MemoryClient`) and call new client methods hitting `/v1/schedule`. **The model passes human ISO-8601 LOCAL datetimes** (e.g. `2026-06-09T08:00`); a pure Swift helper converts them to epoch seconds deterministically before the HTTP call — the model never computes epoch. The deterministic conflict result from the server is surfaced to the model, which adds the common-sense (location/travel) layer per the system prompt. Wake-time for "rest of the night" is a hardcoded `06:00` default in SP1 (full wake schedule is SP5).

**Tech Stack:** Swift 6, SwiftUI app, XCTest with `URLProtocol` mocks. Repo: `personal_agent`, branch `feat/sp1-events-conflict` (has the SP1 spec/plan). Endpoints already deployed to the i3 (`/v1/schedule/{check,create,window,cancel}`).

**Server contract (already live):**
- `POST /v1/schedule/check` `{start,end}` (epoch) → `{conflicts:[Event]}`
- `POST /v1/schedule/create` `{title,start,end,allDay?,location?,origin,force?}` → `{created:Bool, id?:String, conflicts:[Event]}`
- `GET /v1/schedule/window?from=&to=&includeCancelled=` → `{events:[Event]}`
- `POST /v1/schedule/cancel` `{ids?:[String]} | {from,to}` → `{cancelled:Int}`
- `Event` JSON: `{id, title, start, end, allDay, location?, status}` (start/end epoch seconds).

---

## File structure

- `Gemma/Gemma/Memory/MemoryClient.swift` — add `ScheduleEvent` struct + 4 methods.
- `Gemma/Gemma/Agent/ScheduleTime.swift` — **new**: pure ISO↔epoch helpers (testable).
- `Gemma/Gemma/Memory/ScheduleTools.swift` — **new**: the 4 `AgentTool`s.
- `Gemma/Gemma/Harness/HarnessModel.swift` — register the 4 tools (line ~157, the `if client != nil` block).
- `Gemma/Gemma/Agent/Agent.swift` — extend `systemPrompt()` with scheduling rules.
- Tests: `Gemma/GemmaTests/ScheduleTimeTests.swift`, `Gemma/GemmaTests/MemoryClientScheduleTests.swift`.

---

## Task 1: `ScheduleTime` ISO↔epoch helpers (pure, testable)

**Files:**
- Create: `Gemma/Gemma/Agent/ScheduleTime.swift`
- Test: `Gemma/GemmaTests/ScheduleTimeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Gemma/GemmaTests/ScheduleTimeTests.swift`:

```swift
import XCTest
@testable import Gemma

final class ScheduleTimeTests: XCTestCase {
    func test_epoch_parsesLocalDateTime() {
        // 2026-06-09 08:00 local → round-trips back to the same local string
        let e = ScheduleTime.epoch(fromISO: "2026-06-09T08:00")
        XCTAssertNotNil(e)
        XCTAssertEqual(ScheduleTime.iso(fromEpoch: e!), "2026-06-09T08:00")
    }
    func test_epoch_parsesDateOnly_asMidnight() {
        let e = ScheduleTime.epoch(fromISO: "2026-06-09")
        XCTAssertNotNil(e)
        XCTAssertEqual(ScheduleTime.iso(fromEpoch: e!), "2026-06-09T00:00")
    }
    func test_epoch_nilOnGarbage() {
        XCTAssertNil(ScheduleTime.epoch(fromISO: "next thursday"))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/ScheduleTimeTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'ScheduleTime' in scope`.

- [ ] **Step 3: Implement**

Create `Gemma/Gemma/Agent/ScheduleTime.swift`:

```swift
import Foundation

/// Deterministic conversion between human ISO-8601 LOCAL datetimes (what the model emits) and
/// epoch seconds (what the schedule API uses). The model never computes epoch; it passes a
/// local wall-clock string and this converts it in the device's timezone.
enum ScheduleTime {
    private static func df(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }

    /// Parse "yyyy-MM-dd'T'HH:mm" (or with space, or date-only → midnight) in local time → epoch.
    static func epoch(fromISO s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            if let d = df(fmt).date(from: t) { return d.timeIntervalSince1970 }
        }
        if let d = df("yyyy-MM-dd").date(from: t) { return d.timeIntervalSince1970 } // date-only → 00:00
        return nil
    }

    /// Epoch → "yyyy-MM-dd'T'HH:mm" in local time (for echoing events back to the model/user).
    static func iso(fromEpoch e: Double) -> String {
        df("yyyy-MM-dd'T'HH:mm").string(from: Date(timeIntervalSince1970: e))
    }

    /// Human-friendly local rendering for tool result text, e.g. "Tue 2026-06-09 08:00".
    static func human(fromEpoch e: Double) -> String {
        df("EEE yyyy-MM-dd HH:mm").string(from: Date(timeIntervalSince1970: e))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/ScheduleTimeTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Agent/ScheduleTime.swift Gemma/GemmaTests/ScheduleTimeTests.swift
git commit -m "feat(sp1-agent): ScheduleTime ISO<->epoch local-time helpers"
```

---

## Task 2: `MemoryClient` schedule methods

**Files:**
- Modify: `Gemma/Gemma/Memory/MemoryClient.swift` (add struct near the other Decodable structs ~line 40-63; add methods near `byHub` ~line 146-165; reuse the private `post`/`get`/`escape` helpers)
- Test: `Gemma/GemmaTests/MemoryClientScheduleTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Gemma/GemmaTests/MemoryClientScheduleTests.swift`. Mirror the existing MemoryClient URLProtocol-mock test style (read `Gemma/GemmaTests/` for the existing `MemoryClient` test + its mock `URLProtocol` to reuse it; if a reusable mock exists, use it — otherwise include this self-contained one):

```swift
import XCTest
@testable import Gemma

final class MemoryClientScheduleTests: XCTestCase {
    // Minimal stub URLProtocol: maps path → (status, jsonBody).
    final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let path = (request.url?.path ?? "") + (request.url?.query.map { "?\($0)" } ?? "")
            let key = Self.routes.keys.first { path.hasPrefix($0) } ?? path
            let (status, body) = Self.routes[key] ?? (404, "{}")
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> MemoryClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return MemoryClient(baseURL: URL(string: "http://test.local:8081")!, bearerToken: "t",
                            session: URLSession(configuration: cfg))
    }

    func test_createEvent_returnsConflicts_whenNotCreated() async throws {
        StubURLProtocol.routes = ["/v1/schedule/create":
            (200, #"{"created":false,"conflicts":[{"id":"x","title":"Trip","start":1000,"end":2000,"allDay":true,"status":"scheduled"}]}"#)]
        let c = makeClient()
        let r = try await c.createEvent(title: "Meeting", start: 1500, end: 1600, allDay: false, location: nil, force: false)
        XCTAssertFalse(r.created)
        XCTAssertEqual(r.conflicts.first?.title, "Trip")
    }

    func test_scheduleWindow_decodesEvents() async throws {
        StubURLProtocol.routes = ["/v1/schedule/window":
            (200, #"{"events":[{"id":"x","title":"Trip","start":1000,"end":2000,"allDay":true,"location":"Cuba","status":"scheduled"}]}"#)]
        let c = makeClient()
        let evs = try await c.scheduleWindow(from: 0, to: 5000, includeCancelled: false)
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].location, "Cuba")
    }

    func test_cancelEvents_returnsCount() async throws {
        StubURLProtocol.routes = ["/v1/schedule/cancel": (200, #"{"cancelled":2}"#)]
        let c = makeClient()
        let n = try await c.cancelEvents(ids: nil, from: 0, to: 5000)
        XCTAssertEqual(n, 2)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/MemoryClientScheduleTests 2>&1 | tail -20`
Expected: FAIL — `value of type 'MemoryClient' has no member 'createEvent'`.

- [ ] **Step 3: Implement**

In `MemoryClient.swift`, add the struct near the other Decodable structs (after `TranscriptRow`, ~line 63):

```swift
    struct ScheduleEvent: Decodable, Sendable, Identifiable {
        let id: String
        let title: String
        let start: Double
        let end: Double
        let allDay: Bool
        let location: String?
        let status: String
    }
    struct CreateEventResult: Sendable { let created: Bool; let id: String?; let conflicts: [ScheduleEvent] }
```

Add the methods near `byEntity` (~line 165, before the `// MARK: HTTP helpers`):

```swift
    // MARK: schedule (SP1)
    func checkSchedule(start: Double, end: Double) async throws -> [ScheduleEvent] {
        struct B: Encodable { let start: Double; let end: Double }
        struct R: Decodable { let conflicts: [ScheduleEvent] }
        let r: R = try await post("/v1/schedule/check", B(start: start, end: end))
        return r.conflicts
    }

    func createEvent(title: String, start: Double, end: Double, allDay: Bool,
                     location: String?, force: Bool) async throws -> CreateEventResult {
        struct B: Encodable { let title: String; let start: Double; let end: Double
                              let allDay: Bool; let location: String?; let origin: String; let force: Bool }
        struct R: Decodable { let created: Bool; let id: String?; let conflicts: [ScheduleEvent] }
        let r: R = try await post("/v1/schedule/create",
            B(title: title, start: start, end: end, allDay: allDay, location: location, origin: "user", force: force))
        return CreateEventResult(created: r.created, id: r.id, conflicts: r.conflicts)
    }

    func scheduleWindow(from: Double, to: Double, includeCancelled: Bool = false) async throws -> [ScheduleEvent] {
        struct R: Decodable { let events: [ScheduleEvent] }
        let r: R = try await get("/v1/schedule/window?from=\(from)&to=\(to)&includeCancelled=\(includeCancelled)")
        return r.events
    }

    func cancelEvents(ids: [String]?, from: Double?, to: Double?) async throws -> Int {
        struct B: Encodable { let ids: [String]?; let from: Double?; let to: Double? }
        struct R: Decodable { let cancelled: Int }
        let r: R = try await post("/v1/schedule/cancel", B(ids: ids, from: from, to: to))
        return r.cancelled
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/MemoryClientScheduleTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Memory/MemoryClient.swift Gemma/GemmaTests/MemoryClientScheduleTests.swift
git commit -m "feat(sp1-agent): MemoryClient schedule methods (check/create/window/cancel)"
```

---

## Task 3: The four schedule `AgentTool`s + registration

**Files:**
- Create: `Gemma/Gemma/Memory/ScheduleTools.swift`
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift` (~line 157, register inside `if client != nil`)

**Context — pattern:** mirror `SaveMemoryTool` (read it): `static name/description/parameters`, `func run(argsJSON:) async -> String`, parse `argsJSON` via `JSONSerialization`, read `MemoryToolbox.shared.memory`, emit `ToolActivityRelay.shared.started/finished`. Datetime args are LOCAL ISO strings parsed via `ScheduleTime.epoch`. On a parse failure, return a clear message so the model re-asks the user.

- [ ] **Step 1: Implement the tools (no separate unit test — covered by ScheduleTime + MemoryClient tests; this is wiring over tested units)**

Create `Gemma/Gemma/Memory/ScheduleTools.swift`:

```swift
import Foundation

private func mem() async -> MemoryClient? { await MemoryToolbox.shared.memory }
private func obj(_ argsJSON: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
}
private func eventLine(_ e: MemoryClient.ScheduleEvent) -> String {
    let loc = (e.location?.isEmpty == false) ? " @ \(e.location!)" : ""
    return "\(e.title): \(ScheduleTime.human(fromEpoch: e.start))–\(ScheduleTime.human(fromEpoch: e.end))\(loc)"
}

/// check_schedule — read-only: are there conflicts in [start,end)?
struct CheckScheduleTool: AgentTool {
    static let name = "check_schedule"
    static let description = "Check whether a time slot conflicts with existing events. Call BEFORE creating an event. Pass local ISO datetimes like 2026-06-09T08:00."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "start", type: .string, description: "Local ISO datetime, e.g. 2026-06-09T08:00", required: true),
        AgentToolParam(name: "end", type: .string, description: "Local ISO datetime; the end of the slot.", required: true),
    ]
    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        guard let s = (o["start"] as? String).flatMap(ScheduleTime.epoch),
              let e = (o["end"] as? String).flatMap(ScheduleTime.epoch) else {
            return "I need a start and end time (e.g. 2026-06-09T08:00)."
        }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "") }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do {
                let c = try await m.checkSchedule(start: s, end: e)
                return c.isEmpty ? "No conflicts." : "Conflicts: " + c.map(eventLine).joined(separator: "; ")
            } catch { return "schedule error: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// create_event — books an event; refuses on conflict unless force=true.
struct CreateEventTool: AgentTool {
    static let name = "create_event"
    static let description = "Create a calendar event (meeting/appointment/trip). Pass local ISO datetimes. If it conflicts with an existing event, it will NOT be created unless force=true — tell the user about the conflict and ask before forcing."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Short event title, e.g. \"dentist\", \"Miami meeting\".", required: true),
        AgentToolParam(name: "start", type: .string, description: "Local ISO datetime, e.g. 2026-06-09T08:00.", required: true),
        AgentToolParam(name: "end", type: .string, description: "Local ISO datetime end. If the user gave only a start, ASK for the end first.", required: true),
        AgentToolParam(name: "allDay", type: .boolean, description: "true for all-day/multi-day (e.g. trips).", required: false),
        AgentToolParam(name: "location", type: .string, description: "Place only (city/venue), not prose.", required: false),
        AgentToolParam(name: "force", type: .boolean, description: "true to book despite a conflict (only after the user confirms).", required: false),
    ]
    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        let title = ((o["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty,
              let s = (o["start"] as? String).flatMap(ScheduleTime.epoch),
              let e = (o["end"] as? String).flatMap(ScheduleTime.epoch) else {
            return "I need a title, start, and end (e.g. 2026-06-09T08:00). If you only gave a start, what's the end time?"
        }
        let allDay = (o["allDay"] as? Bool) ?? false
        let location = (o["location"] as? String)?.trimmingCharacters(in: .whitespaces)
        let force = (o["force"] as? Bool) ?? false
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: title) }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do {
                let r = try await m.createEvent(title: title, start: s, end: e, allDay: allDay,
                                                location: (location?.isEmpty == false) ? location : nil, force: force)
                if r.created { return "Scheduled: \(title) (\(ScheduleTime.human(fromEpoch: s)))" }
                return "NOT scheduled — conflicts with: " + r.conflicts.map(eventLine).joined(separator: "; ")
                     + ". Ask the user whether to reschedule, cancel the other, or force it."
            } catch { return "schedule error: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// query_schedule — list events in a window.
struct QueryScheduleTool: AgentTool {
    static let name = "query_schedule"
    static let description = "List the user's events between two local ISO datetimes (use this for \"what's on my schedule this week\"). Pass dates like 2026-06-09 or 2026-06-09T00:00."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "from", type: .string, description: "Local ISO datetime/date for the window start.", required: true),
        AgentToolParam(name: "to", type: .string, description: "Local ISO datetime/date for the window end.", required: true),
    ]
    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        guard let f = (o["from"] as? String).flatMap(ScheduleTime.epoch),
              let t = (o["to"] as? String).flatMap(ScheduleTime.epoch) else {
            return "I need a from/to range (e.g. 2026-06-09 to 2026-06-16)."
        }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "") }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do {
                let evs = try await m.scheduleWindow(from: f, to: t, includeCancelled: false)
                return evs.isEmpty ? "Nothing scheduled in that range." : evs.map(eventLine).joined(separator: "; ")
            } catch { return "schedule error: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// cancel_events — soft-cancel events in a window (kept, not deleted).
struct CancelEventsTool: AgentTool {
    static let name = "cancel_events"
    static let description = "Cancel the user's events in a local ISO datetime range (e.g. \"cancel my appointments this week\"). Events are kept (cancelled), not deleted."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "from", type: .string, description: "Local ISO datetime/date window start.", required: true),
        AgentToolParam(name: "to", type: .string, description: "Local ISO datetime/date window end.", required: true),
    ]
    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        guard let f = (o["from"] as? String).flatMap(ScheduleTime.epoch),
              let t = (o["to"] as? String).flatMap(ScheduleTime.epoch) else {
            return "I need a from/to range to cancel."
        }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "") }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do { let n = try await m.cancelEvents(ids: nil, from: f, to: t); return "Cancelled \(n) event(s)." }
            catch { return "schedule error: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
```

- [ ] **Step 2: Register the tools**

In `Gemma/Gemma/Harness/HarnessModel.swift`, find the `if client != nil {` block (~line 156-159) that registers `ForgetTool()/ReflectTool()/ExpandContextTool()/SaveMemoryTool()`. Add after `registry.register(SaveMemoryTool())`:

```swift
            registry.register(CheckScheduleTool()); registry.register(CreateEventTool())
            registry.register(QueryScheduleTool()); registry.register(CancelEventsTool())
```

- [ ] **Step 3: Build + run the existing tool/client tests (no regressions)**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/ScheduleTimeTests -only-testing:GemmaTests/MemoryClientScheduleTests 2>&1 | tail -15`
Expected: BUILD SUCCEEDED, tests PASS (the new tools compile + register).

- [ ] **Step 4: Commit**

```bash
git add Gemma/Gemma/Memory/ScheduleTools.swift Gemma/Gemma/Harness/HarnessModel.swift
git commit -m "feat(sp1-agent): 4 schedule tools (check/create/query/cancel) + register"
```

---

## Task 4: Conversational scheduling rules in the system prompt

**Files:**
- Modify: `Gemma/Gemma/Agent/Agent.swift` (`systemPrompt()` ~line 39-47)

- [ ] **Step 1: Extend the prompt**

In `systemPrompt()`, append these instructions inside the returned string (after the existing lines, before the closing `"""`):

```
        Scheduling: the user's calendar lives in tools. For appointments/meetings/trips, FIRST acknowledge briefly ("let me check your schedule"), then call check_schedule, then create_event. \
        Pass times as LOCAL ISO datetimes using today's date above (e.g. "tomorrow 3pm" → 2026-..-..T15:00). \
        If the user gives only a start time, ASK for the end before creating. If a time span is vague ("rest of the week"), ASK whether it starts now or tomorrow; "rest of the night" means until 06:00 the next day. \
        If create_event reports a conflict, do NOT force it: tell the user what it conflicts with (consider travel/location too — e.g. a meeting in another city during a trip) and ask whether to reschedule, cancel the other, or book anyway. \
        Use query_schedule for "what's on my schedule"; use cancel_events (which only cancels, never deletes) for "cancel my appointments". To-dos without a fixed time (call mom, gym) are save_memory, not events.
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Gemma/Gemma/Agent/Agent.swift
git commit -m "feat(sp1-agent): conversational scheduling rules in system prompt"
```

---

## Task 5: Live end-to-end (manual, with the app)

**Files:** none. Requires rebuilding/relaunching the macOS app (Xcode Stop/Run) so it picks up the new tools, with the i3 reachable and mlx on 0.0.0.0.

- [ ] **Step 1:** Relaunch the app from Xcode (Stop ⌘. then Run ⌘R).
- [ ] **Step 2:** In chat: "schedule a trip to Varadero for 5 days starting next Monday" → agent creates an all-day multi-day event.
- [ ] **Step 3:** "schedule a meeting June 9 8am in Miami" → agent checks, finds the trip conflict, and ASKS instead of booking (the original failure, now prevented).
- [ ] **Step 4:** "what's on my schedule next week?" → agent lists the trip via query_schedule.
- [ ] **Step 5 (cleanup):** cancel the test events via chat ("cancel everything next week") or the schedule API.

---

## Self-review notes (author)

- **Spec coverage (spec §5):** 4 tools ✓ (Task 3), conversational flow + clarify + hybrid-location + soft-cancel + wake-06:00 ✓ (Task 4 prompt), client methods ✓ (Task 2), deterministic ISO→epoch so the model needn't compute epoch ✓ (Task 1). check-before-create enforced via prompt + tool descriptions.
- **Placeholder scan:** none — full code in every code step. Task 2 Step 1 instructs reusing an existing URLProtocol mock if present (a real verification, not a placeholder).
- **Type consistency:** `ScheduleTime.epoch(fromISO:)`/`iso(fromEpoch:)`/`human(fromEpoch:)`; `MemoryClient.ScheduleEvent`, `CreateEventResult`; methods `checkSchedule(start:end:)`, `createEvent(title:start:end:allDay:location:force:)`, `scheduleWindow(from:to:includeCancelled:)`, `cancelEvents(ids:from:to:)` — used identically in the tools.
- **Open verification at execution:** confirm `ToolActivityRelay.shared.started/finished` signatures (read `SaveMemoryTool` — used there) and that `MemoryClient(baseURL:bearerToken:session:)` + private `post`/`get` are reachable from the test target (`@testable import Gemma`). Confirm the simulator/destination: macOS app uses `-destination 'platform=macOS'`.
