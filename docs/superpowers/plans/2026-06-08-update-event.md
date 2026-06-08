# update_event Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the agent edit an existing calendar event's time/title/location in place (never cancel+recreate), and make a correction never conflict with the event itself, across BOTH the voice/gateway path and the in-app/HTTP path.

**Architecture:** A shared MemoryCore store gains time-first matching (`findEditTarget`), an in-place edit (`applyEventEdit`), and self-excluding conflict detection. On top of it: a gateway tool `update_event` (voice), an HTTP endpoint `POST /v1/schedule/update`, an app `MemoryClient.updateEvent` + app tool, and one prompt rule in both prompt copies.

**Tech Stack:** Swift (MemoryCore + Hummingbird service `gemma-memory/memory-service`), Swift (macOS app `Gemma/`), XCTest. Spec: `docs/superpowers/specs/2026-06-08-update-event-design.md`.

**Conventions (verified against current code):**
- Build/test the server from `gemma-memory/memory-service/`: `swift test --filter <Suite>`.
- Build/test the app from `Gemma/`: `xcodebuild test -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/<Suite>`.
- Events are `Node`s with `kind == NodeKind.event.rawValue`; fields live in `NodeAttributes` (`status`, `startAt`, `endAt`, `allDay`, `location`, `canonicalKey`) parsed via `NodeAttributes.from(node.extra)` and serialized via `.toJSON()`.
- `MemoryStore.node(id:)`, `MemoryStore.upsert(_:)`, `MemoryStore.allNodes()`, `MemoryText.eventCanonicalKey(title:startAt:)`, and `eventsOverlap(_:_:_:_:)` already exist.
- The gateway tool MUST live in `GatewayTools.swift` (it uses the file-private `isoToEpoch`, `epochToHuman`, `eventLine`). The app tool MUST live in `ScheduleTools.swift` (uses the file-private `eventLine`, `obj`, `mem`, `scheduleStatusSuffix`).

---

### Task 1: Store — self-excluding conflicts, time-first match, in-place edit

**Files:**
- Modify: `gemma-memory/memory-service/Sources/MemoryCore/MemoryStore+Schedule.swift`
- Test: `gemma-memory/memory-service/Tests/MemoryCoreTests/ScheduleStoreEditTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

Create `gemma-memory/memory-service/Tests/MemoryCoreTests/ScheduleStoreEditTests.swift`:

```swift
import XCTest
@testable import MemoryCore

final class ScheduleStoreEditTests: XCTestCase {

    private func store() throws -> MemoryStore { try MemoryStore(path: ":memory:", embeddingDim: 8) }

    /// 2099-03-01 09:00 and 10:00 local, as epoch, for deterministic same-day tests.
    private func epoch(_ iso: String) -> Double {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: iso)!.timeIntervalSince1970
    }

    func test_findEditTarget_found_by_same_day_and_title() throws {
        let s = try store()
        let start = epoch("2099-03-01T09:00"), end = epoch("2099-03-01T10:00")
        _ = try s.upsertEvent(title: "dentist", start: start, end: end, allDay: false, location: nil, origin: .explicit)
        // A slightly-off start on the same day still resolves (tolerant match).
        guard case .found(let n) = try s.findEditTarget(start: epoch("2099-03-01T09:30"), title: "dentist") else {
            return XCTFail("expected .found")
        }
        XCTAssertEqual(n.label, "dentist")
    }

    func test_findEditTarget_none_when_no_event() throws {
        let s = try store()
        guard case .none = try s.findEditTarget(start: epoch("2099-03-01T09:00"), title: nil) else {
            return XCTFail("expected .none")
        }
    }

    func test_findEditTarget_ambiguous_two_same_day_no_exact_match() throws {
        let s = try store()
        _ = try s.upsertEvent(title: "call A", start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"),
                              allDay: false, location: nil, origin: .explicit)
        _ = try s.upsertEvent(title: "call B", start: epoch("2099-03-01T14:00"), end: epoch("2099-03-01T15:00"),
                              allDay: false, location: nil, origin: .explicit)
        // No title, a start matching neither exactly → ambiguous.
        guard case .ambiguous(let list) = try s.findEditTarget(start: epoch("2099-03-01T11:00"), title: nil) else {
            return XCTFail("expected .ambiguous")
        }
        XCTAssertEqual(list.count, 2)
    }

    func test_findEditTarget_exact_minute_disambiguates() throws {
        let s = try store()
        _ = try s.upsertEvent(title: "call A", start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"),
                              allDay: false, location: nil, origin: .explicit)
        _ = try s.upsertEvent(title: "call B", start: epoch("2099-03-01T14:00"), end: epoch("2099-03-01T15:00"),
                              allDay: false, location: nil, origin: .explicit)
        guard case .found(let n) = try s.findEditTarget(start: epoch("2099-03-01T14:00"), title: nil) else {
            return XCTFail("expected .found via exact start")
        }
        XCTAssertEqual(n.label, "call B")
    }

    func test_applyEventEdit_location_only_keeps_id_and_time() throws {
        let s = try store()
        let start = epoch("2099-03-01T09:00"), end = epoch("2099-03-01T10:00")
        let id = try s.upsertEvent(title: "dentist", start: start, end: end, allDay: false, location: nil, origin: .explicit)
        let node = try s.node(id: id)!
        let updated = try s.applyEventEdit(node, location: "Miami")
        XCTAssertEqual(updated.id, id)                                  // same node
        let a = NodeAttributes.from(updated.extra)
        XCTAssertEqual(a.location, "Miami")
        XCTAssertEqual(a.startAt, start)                               // time unchanged
    }

    func test_applyEventEdit_time_move_recomputes_canonicalKey() throws {
        let s = try store()
        let id = try s.upsertEvent(title: "dentist", start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"),
                                   allDay: false, location: nil, origin: .explicit)
        let node = try s.node(id: id)!
        let newStart = epoch("2099-03-01T11:00")
        let updated = try s.applyEventEdit(node, newStart: newStart, newEnd: epoch("2099-03-01T12:00"))
        XCTAssertEqual(updated.id, id)
        let a = NodeAttributes.from(updated.extra)
        XCTAssertEqual(a.startAt, newStart)
        XCTAssertEqual(a.canonicalKey, MemoryText.eventCanonicalKey(title: "dentist", startAt: newStart))
    }

    func test_applyEventEdit_empty_location_clears_it() throws {
        let s = try store()
        let id = try s.upsertEvent(title: "dentist", start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"),
                                   allDay: false, location: "Miami", origin: .explicit)
        let updated = try s.applyEventEdit(try s.node(id: id)!, location: "")
        XCTAssertNil(NodeAttributes.from(updated.extra).location)
    }

    func test_scheduleConflicts_excluding_self() throws {
        let s = try store()
        let id = try s.upsertEvent(title: "dentist", start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"),
                                   allDay: false, location: nil, origin: .explicit)
        // Same slot, excluding the event itself → no conflict.
        let none = try s.scheduleConflicts(start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"), excluding: [id])
        XCTAssertTrue(none.isEmpty)
        // A different overlapping event is still detected.
        _ = try s.upsertEvent(title: "gym", start: epoch("2099-03-01T09:30"), end: epoch("2099-03-01T10:30"),
                              allDay: false, location: nil, origin: .explicit)
        let some = try s.scheduleConflicts(start: epoch("2099-03-01T09:00"), end: epoch("2099-03-01T10:00"), excluding: [id])
        XCTAssertTrue(some.contains { $0.label == "gym" })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd gemma-memory/memory-service && swift test --filter ScheduleStoreEditTests`
Expected: compile failure / FAIL — `findEditTarget`, `applyEventEdit`, and `scheduleConflicts(…excluding:)` don't exist yet.

- [ ] **Step 3: Add the `excluding` param to `scheduleConflicts`**

In `MemoryStore+Schedule.swift`, replace the existing `scheduleConflicts` with:

```swift
    /// Scheduled events overlapping the proposed [start,end). Cancelled/done excluded.
    /// `excluding` drops nodes by id so an edit never conflicts with the event being edited.
    public func scheduleConflicts(start: Double, end: Double, excluding: Set<String> = []) throws -> [Node] {
        let events = try allNodes().filter { $0.kind == NodeKind.event.rawValue }
        return events.filter { node in
            guard !excluding.contains(node.id) else { return false }
            let a = NodeAttributes.from(node.extra)
            guard let s = a.startAt, let e = a.endAt, a.status == "scheduled" else { return false }
            return eventsOverlap(s, e, start, end)
        }
    }
```

- [ ] **Step 4: Add `EditTarget`, `findEditTarget`, `applyEventEdit`**

In `MemoryStore+Schedule.swift`, add at file scope (above `extension MemoryStore`):

```swift
/// Result of resolving which event the user means for an edit (time-first).
public enum EditTarget: Sendable {
    case found(Node)
    case none
    case ambiguous([Node])
}
```

Then inside `extension MemoryStore { … }`, add:

```swift
    /// Resolve which scheduled event the user means for an edit, anchored on TIME.
    /// Candidates = scheduled events on the same calendar day as `start` (server TZ), optionally
    /// filtered by `title` (case-insensitive). One candidate → .found; several → prefer an
    /// exact-minute start match, else .ambiguous; none → .none.
    public func findEditTarget(start: Double, title: String?) throws -> EditTarget {
        let cal = Calendar.current
        let day = Date(timeIntervalSince1970: start)
        var candidates = try allNodes().filter { node in
            guard node.kind == NodeKind.event.rawValue else { return false }
            let a = NodeAttributes.from(node.extra)
            guard a.status == "scheduled", let s = a.startAt else { return false }
            return cal.isDate(Date(timeIntervalSince1970: s), inSameDayAs: day)
        }
        if let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            candidates = candidates.filter { $0.label.caseInsensitiveCompare(title) == .orderedSame }
        }
        if candidates.isEmpty { return .none }
        if candidates.count == 1 { return .found(candidates[0]) }
        let exact = candidates.filter { node in
            guard let s = NodeAttributes.from(node.extra).startAt else { return false }
            return abs(s - start) < 60   // within a minute = the same start
        }
        if exact.count == 1 { return .found(exact[0]) }
        return .ambiguous(candidates)
    }

    /// Edit an event in place: override ONLY the provided fields, keep the same node id, recompute
    /// canonicalKey, stay scheduled. `location == ""` clears it; nil leaves a field unchanged.
    @discardableResult
    public func applyEventEdit(_ node: Node, newTitle: String? = nil, newStart: Double? = nil,
                               newEnd: Double? = nil, location: String? = nil, allDay: Bool? = nil) throws -> Node {
        var node = node
        var a = NodeAttributes.from(node.extra)
        let trimmed = newTitle?.trimmingCharacters(in: .whitespaces)
        let effTitle = (trimmed?.isEmpty == false) ? trimmed! : node.label
        if let newStart { a.startAt = newStart }
        if let newEnd { a.endAt = newEnd }
        if let allDay { a.allDay = allDay }
        if let location { a.location = location.isEmpty ? nil : location }
        a.canonicalKey = MemoryText.eventCanonicalKey(title: effTitle, startAt: a.startAt ?? 0)
        let now = Date().timeIntervalSince1970
        node.label = effTitle; node.body = effTitle
        node.updatedAt = now; node.lastSeenAt = now
        node.extra = a.toJSON(); node.dirty = true
        try upsert(node)
        return node
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd gemma-memory/memory-service && swift test --filter ScheduleStoreEditTests`
Expected: PASS (8 tests).

- [ ] **Step 6: Commit**

```bash
cd gemma-memory/memory-service
git add Sources/MemoryCore/MemoryStore+Schedule.swift Tests/MemoryCoreTests/ScheduleStoreEditTests.swift
git commit -m "feat(schedule-store): findEditTarget + applyEventEdit + self-excluding conflicts"
```

---

### Task 2: Gateway tool `update_event` (voice path)

**Files:**
- Modify: `gemma-memory/memory-service/Sources/MemoryService/Agent/GatewayTools.swift`
- Test: `gemma-memory/memory-service/Tests/MemoryServiceTests/GatewayToolsTests.swift:315-316` (count) + new tests

- [ ] **Step 1: Write the failing tests**

Append to `GatewayToolsTests.swift` (before the final closing `}`):

```swift
    // MARK: - UpdateEventGatewayTool

    private func seedEvent(_ s: Services, title: String, start: String, end: String) async {
        _ = await CreateEventGatewayTool().run(
            argsJSON: #"{"title":"\#(title)","start":"\#(start)","end":"\#(end)"}"#, services: s)
    }

    func test_updateEvent_location_only_applies_without_conflict_check() async throws {
        let s = try await MainActor.run { try services() }
        await seedEvent(s, title: "meeting", start: "2099-06-09T15:00", end: "2099-06-09T16:00")
        let out = await UpdateEventGatewayTool().run(
            argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","location":"Miami"}"#, services: s)
        XCTAssertTrue(out.contains("Updated"), "Expected echo, got: \(out)")
        XCTAssertTrue(out.contains("Miami"), "Expected new location, got: \(out)")
        let ev = try s.store.allNodes().first { $0.kind == NodeKind.event.rawValue }!
        XCTAssertEqual(NodeAttributes.from(ev.extra).location, "Miami")
    }

    func test_updateEvent_not_found_never_creates() async throws {
        let s = try await MainActor.run { try services() }
        let out = await UpdateEventGatewayTool().run(
            argsJSON: #"{"start":"2099-06-09T15:00","title":"ghost","location":"Miami"}"#, services: s)
        XCTAssertTrue(out.lowercased().contains("couldn't find"), "Expected not-found, got: \(out)")
        let events = try s.store.allNodes().filter { $0.kind == NodeKind.event.rawValue }
        XCTAssertTrue(events.isEmpty, "Must not create anything on a missed match")
    }

    func test_updateEvent_time_move_conflict_blocked_then_forced() async throws {
        let s = try await MainActor.run { try services() }
        await seedEvent(s, title: "meeting", start: "2099-06-09T15:00", end: "2099-06-09T16:00")
        await seedEvent(s, title: "dentist", start: "2099-06-09T11:00", end: "2099-06-09T12:00")
        // Move "meeting" onto the dentist slot → blocked.
        let blocked = await UpdateEventGatewayTool().run(
            argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","newStart":"2099-06-09T11:00","newEnd":"2099-06-09T12:00"}"#,
            services: s)
        XCTAssertTrue(blocked.contains("NOT changed"), "Expected conflict refusal, got: \(blocked)")
        XCTAssertTrue(blocked.contains("dentist"), "Expected the conflicting event named, got: \(blocked)")
        // With force → applied.
        let forced = await UpdateEventGatewayTool().run(
            argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","newStart":"2099-06-09T11:00","newEnd":"2099-06-09T12:00","force":true}"#,
            services: s)
        XCTAssertTrue(forced.contains("Updated"), "force should apply, got: \(forced)")
    }

    func test_updateEvent_time_move_no_conflict_excludes_self() async throws {
        let s = try await MainActor.run { try services() }
        await seedEvent(s, title: "meeting", start: "2099-06-09T15:00", end: "2099-06-09T16:00")
        // Shorten within its own old slot — must NOT conflict with itself.
        let out = await UpdateEventGatewayTool().run(
            argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","newEnd":"2099-06-09T15:30"}"#, services: s)
        XCTAssertTrue(out.contains("Updated"), "self-overlap must not block, got: \(out)")
    }
```

Update the count assertions at `GatewayToolsTests.swift:315-316` from `11` to `12`:

```swift
        XCTAssertEqual(GatewayToolRegistry.gatewayTools.count, 12)
        XCTAssertEqual(GatewayToolRegistry.gatewayToolSpecs.count, 12)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd gemma-memory/memory-service && swift test --filter GatewayToolsTests`
Expected: FAIL — `UpdateEventGatewayTool` is undefined; count is 11 not 12.

- [ ] **Step 3: Implement the tool**

In `GatewayTools.swift`, after `CancelEventsGatewayTool` (before `// MARK: - Registry`), add:

```swift
// MARK: - 12. UpdateEventGatewayTool

public struct UpdateEventGatewayTool: GatewayTool {
    public static let name = "update_event"
    public static let description = "Edit an EXISTING calendar event in place — change its time, title, or location. Never cancel+recreate to make a change. Identify the event by its CURRENT start (the time the user named) plus title when known."
    public static let parameters: [GatewayToolParam] = [
        .init(name: "start", type: .string,
              description: "The event's CURRENT local ISO start (the time the user referred to), e.g. 2099-06-09T15:00.",
              required: true),
        .init(name: "title", type: .string,
              description: "The event's current title, to disambiguate if several share that time.",
              required: false),
        .init(name: "newStart", type: .string, description: "New local ISO start, if moving the event.", required: false),
        .init(name: "newEnd", type: .string, description: "New local ISO end, if changing the end.", required: false),
        .init(name: "newTitle", type: .string, description: "New title, if renaming.", required: false),
        .init(name: "location", type: .string, description: "New place (empty string clears it).", required: false),
        .init(name: "allDay", type: .boolean, description: "true/false to change all-day.", required: false),
        .init(name: "force", type: .boolean,
              description: "true to apply despite a conflict with a DIFFERENT event (only after the user confirms).",
              required: false),
    ]
    public init() {}

    public func run(argsJSON: String, services: Services) async -> String {
        let o = Self.args(argsJSON)
        guard let s = (o["start"] as? String).flatMap(isoToEpoch) else {
            return "Which event? Tell me the time of the event you want to change (e.g. 2099-06-09T15:00)."
        }
        let title = (o["title"] as? String)?.trimmingCharacters(in: .whitespaces)
        do {
            let node: Node
            switch try services.store.findEditTarget(start: s, title: (title?.isEmpty == false) ? title : nil) {
            case .none:
                return "I couldn't find that event — want me to check your schedule?"
            case .ambiguous(let list):
                return "I found more than one event around then: " + list.map(eventLine).joined(separator: "; ") + ". Which one?"
            case .found(let n):
                node = n
            }
            let a = NodeAttributes.from(node.extra)
            let newStart = (o["newStart"] as? String).flatMap(isoToEpoch)
            let newEnd = (o["newEnd"] as? String).flatMap(isoToEpoch)
            let newTitle = (o["newTitle"] as? String)?.trimmingCharacters(in: .whitespaces)
            let location = o["location"] as? String      // may be "" to clear
            let allDay = o["allDay"] as? Bool
            let force = (o["force"] as? Bool) ?? false

            if newStart != nil || newEnd != nil {
                let effStart = newStart ?? a.startAt ?? s
                let effEnd = newEnd ?? a.endAt ?? effStart
                let conflicts = try services.store.scheduleConflicts(start: effStart, end: effEnd, excluding: [node.id])
                if !conflicts.isEmpty && !force {
                    return "NOT changed — the new time conflicts with: " + conflicts.map(eventLine).joined(separator: "; ")
                        + ". Ask the user whether to reschedule, cancel the other event, or keep it anyway — if they confirm, call update_event again with force=true."
                }
            }
            let updated = try services.store.applyEventEdit(
                node, newTitle: (newTitle?.isEmpty == false) ? newTitle : nil,
                newStart: newStart, newEnd: newEnd, location: location, allDay: allDay)
            return "Updated: \(eventLine(updated))"
        } catch { return "schedule error: \(error)" }
    }
}
```

- [ ] **Step 4: Register the tool**

In `GatewayToolRegistry.gatewayTools` (the array), add `UpdateEventGatewayTool()` right after `CancelEventsGatewayTool()`:

```swift
        CancelEventsGatewayTool(),
        UpdateEventGatewayTool(),
    ]
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd gemma-memory/memory-service && swift test --filter GatewayToolsTests`
Expected: PASS (existing + 4 new tests; count now 12).

- [ ] **Step 6: Commit**

```bash
cd gemma-memory/memory-service
git add Sources/MemoryService/Agent/GatewayTools.swift Tests/MemoryServiceTests/GatewayToolsTests.swift
git commit -m "feat(gateway): update_event tool — edit events in place (voice path)"
```

---

### Task 3: HTTP endpoint `POST /v1/schedule/update`

**Files:**
- Modify: `gemma-memory/memory-service/Sources/MemoryService/Handlers/ScheduleHandlers.swift`
- Test: `gemma-memory/memory-service/Tests/MemoryServiceTests/ScheduleEndpointsTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `ScheduleEndpointsTests.swift` (before the final closing `}`):

```swift
    func test_update_event_endpoint_move_notfound_conflict() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            let auth: HTTPFields = [.authorization: "Bearer test-token", .contentType: "application/json"]
            // Seed two same-day events: meeting [9000,9600), dentist [3000,3600).
            try await client.execute(uri: "/v1/schedule/create", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"title":"meeting","start":9000,"end":9600,"origin":"user"}"#)) { res in
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":true")) }
            try await client.execute(uri: "/v1/schedule/create", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"title":"dentist","start":3000,"end":3600,"origin":"user"}"#)) { res in
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":true")) }

            // notFound: no event at start=999999.
            try await client.execute(uri: "/v1/schedule/update", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"start":999999,"location":"Miami"}"#)) { res in
                XCTAssertTrue(String(buffer: res.body).contains("\"notFound\":true")) }

            // location-only update on the meeting → updated true.
            try await client.execute(uri: "/v1/schedule/update", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"start":9000,"title":"meeting","location":"Miami"}"#)) { res in
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"updated\":true"))
                XCTAssertTrue(s.contains("Miami")) }

            // time move onto the dentist slot, no force → updated false + conflicts.
            try await client.execute(uri: "/v1/schedule/update", method: .post, headers: auth,
                body: ByteBuffer(string: #"{"start":9000,"title":"meeting","newStart":3000,"newEnd":3600}"#)) { res in
                let s = String(buffer: res.body)
                XCTAssertTrue(s.contains("\"updated\":false"))
                XCTAssertTrue(s.contains("dentist")) }
        }
    }
```

Note: same-day matching uses `Calendar.current`; epochs 3000/9000/9600 all fall on 1970-01-01 local, so they share a day — fine for this test.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd gemma-memory/memory-service && swift test --filter ScheduleEndpointsTests`
Expected: FAIL — `/v1/schedule/update` returns 404 (route not registered).

- [ ] **Step 3: Register the route**

In `ScheduleHandlers.register`, add the update route:

```swift
        group.post("/schedule/cancel", use: cancel)
        group.post("/schedule/update", use: update)
    }
```

- [ ] **Step 4: Implement the handler**

In `ScheduleHandlers`, after `cancel(_:_:)`, add:

```swift
    struct UpdateBody: Decodable, Sendable {
        let start: Double
        let title: String?
        let newStart: Double?; let newEnd: Double?; let newTitle: String?
        let location: String?; let allDay: Bool?; let force: Bool?
    }

    @Sendable func update(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let b = await body(req, UpdateBody.self) else {
            return jsonError(.badRequest, "bad_request", "start required")
        }
        do {
            let node: Node
            switch try services.store.findEditTarget(start: b.start, title: b.title) {
            case .none:           return json(["updated": false, "notFound": true])
            case .ambiguous(let l): return json(["updated": false, "ambiguous": l.map(eventJSON)])
            case .found(let n):   node = n
            }
            let a = NodeAttributes.from(node.extra)
            if b.newStart != nil || b.newEnd != nil {
                let effStart = b.newStart ?? a.startAt ?? b.start
                let effEnd = b.newEnd ?? a.endAt ?? effStart
                let conflicts = try services.store.scheduleConflicts(start: effStart, end: effEnd, excluding: [node.id])
                if !conflicts.isEmpty && b.force != true {
                    return json(["updated": false, "conflicts": conflicts.map(eventJSON)])
                }
            }
            let updated = try services.store.applyEventEdit(
                node, newTitle: b.newTitle, newStart: b.newStart, newEnd: b.newEnd,
                location: b.location, allDay: b.allDay)
            return json(["updated": true, "event": eventJSON(updated)])
        } catch { return jsonError(.internalServerError, "store_error", "\(error)") }
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd gemma-memory/memory-service && swift test --filter ScheduleEndpointsTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd gemma-memory/memory-service
git add Sources/MemoryService/Handlers/ScheduleHandlers.swift Tests/MemoryServiceTests/ScheduleEndpointsTests.swift
git commit -m "feat(schedule-api): POST /v1/schedule/update (edit/notFound/conflict/ambiguous)"
```

---

### Task 4: App `MemoryClient.updateEvent`

**Files:**
- Modify: `Gemma/Gemma/Memory/MemoryClient.swift:243-272`
- Test: `Gemma/GemmaTests/MemoryClientScheduleTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `MemoryClientScheduleTests.swift` (before the final closing `}`):

```swift
    func test_updateEvent_decodes_updated_event() async throws {
        StubURLProtocol.routes = ["/v1/schedule/update":
            (200, #"{"updated":true,"event":{"id":"x","title":"meeting","start":9000,"end":9600,"allDay":false,"location":"Miami","status":"scheduled"}}"#)]
        let c = makeClient()
        let r = try await c.updateEvent(start: 9000, title: "meeting", newStart: nil, newEnd: nil,
                                        newTitle: nil, location: "Miami", allDay: nil, force: false)
        XCTAssertTrue(r.updated)
        XCTAssertEqual(r.event?.location, "Miami")
    }

    func test_updateEvent_decodes_notFound() async throws {
        StubURLProtocol.routes = ["/v1/schedule/update": (200, #"{"updated":false,"notFound":true}"#)]
        let c = makeClient()
        let r = try await c.updateEvent(start: 1, title: nil, newStart: nil, newEnd: nil,
                                        newTitle: nil, location: nil, allDay: nil, force: false)
        XCTAssertFalse(r.updated)
        XCTAssertTrue(r.notFound)
    }

    func test_updateEvent_decodes_conflicts() async throws {
        StubURLProtocol.routes = ["/v1/schedule/update":
            (200, #"{"updated":false,"conflicts":[{"id":"d","title":"dentist","start":3000,"end":3600,"allDay":false,"status":"scheduled"}]}"#)]
        let c = makeClient()
        let r = try await c.updateEvent(start: 9000, title: "meeting", newStart: 3000, newEnd: 3600,
                                        newTitle: nil, location: nil, allDay: nil, force: false)
        XCTAssertFalse(r.updated)
        XCTAssertEqual(r.conflicts.first?.title, "dentist")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Gemma && xcodebuild test -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/MemoryClientScheduleTests 2>&1 | tail -20`
Expected: compile failure — `updateEvent` / `UpdateEventResult` undefined.

- [ ] **Step 3: Add the result type and method**

In `MemoryClient.swift`, after `CreateEventResult` (line 114), add:

```swift
    struct UpdateEventResult: Sendable {
        let updated: Bool
        let event: ScheduleEvent?
        let conflicts: [ScheduleEvent]
        let notFound: Bool
        let ambiguous: [ScheduleEvent]
    }
```

In the `// MARK: schedule (SP1)` section, after `cancelEvents(...)`, add:

```swift
    func updateEvent(start: Double, title: String?, newStart: Double?, newEnd: Double?,
                     newTitle: String?, location: String?, allDay: Bool?, force: Bool) async throws -> UpdateEventResult {
        struct B: Encodable { let start: Double; let title: String?; let newStart: Double?; let newEnd: Double?
                              let newTitle: String?; let location: String?; let allDay: Bool?; let force: Bool }
        struct R: Decodable { let updated: Bool; let event: ScheduleEvent?; let conflicts: [ScheduleEvent]?
                              let notFound: Bool?; let ambiguous: [ScheduleEvent]? }
        let r: R = try await post("/v1/schedule/update",
            B(start: start, title: title, newStart: newStart, newEnd: newEnd, newTitle: newTitle,
              location: location, allDay: allDay, force: force))
        return UpdateEventResult(updated: r.updated, event: r.event, conflicts: r.conflicts ?? [],
                                 notFound: r.notFound ?? false, ambiguous: r.ambiguous ?? [])
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Gemma && xcodebuild test -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/MemoryClientScheduleTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Memory/MemoryClient.swift Gemma/GemmaTests/MemoryClientScheduleTests.swift
git commit -m "feat(app-client): MemoryClient.updateEvent + UpdateEventResult"
```

---

### Task 5: App `update_event` tool + registration

**Files:**
- Modify: `Gemma/Gemma/Memory/ScheduleTools.swift`
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift:280-285` (registration)
- Test: `Gemma/GemmaTests/MemoryToolsTests.swift`

- [ ] **Step 1: Write the failing test**

App tools are unit-tested by injecting a stub client via `MemoryToolbox.shared.memory = makeStubMemoryClient { req in (status, Data) }` (a `@MainActor` helper available to `GemmaTests`; see `MemoryToolsTests.swift`). Create `Gemma/GemmaTests/UpdateEventToolTests.swift`:

```swift
import XCTest
@testable import Gemma

@MainActor
final class UpdateEventToolTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    func test_update_event_tool_reports_not_found() async {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            XCTAssertEqual(req.url?.path, "/v1/schedule/update")
            return (200, #"{"updated":false,"notFound":true}"#.data(using: .utf8)!)
        }
        let out = await UpdateEventTool().run(argsJSON: #"{"start":"2099-06-09T15:00","title":"ghost"}"#)
        XCTAssertTrue(out.lowercased().contains("couldn't find"), "Expected not-found copy, got: \(out)")
    }

    func test_update_event_tool_echoes_updated_event() async {
        MemoryToolbox.shared.memory = makeStubMemoryClient { _ in
            (200, #"{"updated":true,"event":{"id":"x","title":"meeting","start":9000,"end":9600,"allDay":false,"location":"Miami","status":"scheduled"}}"#.data(using: .utf8)!)
        }
        let out = await UpdateEventTool().run(argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","location":"Miami"}"#)
        XCTAssertTrue(out.contains("Updated"), "got: \(out)")
        XCTAssertTrue(out.contains("Miami"), "got: \(out)")
    }

    func test_update_event_tool_conflict_asks() async {
        MemoryToolbox.shared.memory = makeStubMemoryClient { _ in
            (200, #"{"updated":false,"conflicts":[{"id":"d","title":"dentist","start":3000,"end":3600,"allDay":false,"status":"scheduled"}]}"#.data(using: .utf8)!)
        }
        let out = await UpdateEventTool().run(argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","newStart":"2099-06-09T11:00","newEnd":"2099-06-09T12:00"}"#)
        XCTAssertTrue(out.contains("NOT changed"), "got: \(out)")
        XCTAssertTrue(out.contains("dentist"), "got: \(out)")
    }

    func test_update_event_tool_no_client_is_safe() async {
        let out = await UpdateEventTool().run(argsJSON: #"{"start":"2099-06-09T15:00"}"#)
        XCTAssertEqual(out, "memory unavailable")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Gemma && xcodebuild test -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/UpdateEventToolTests 2>&1 | tail -20` (or `-only-testing:GemmaTests/MemoryToolsTests` if placed there)
Expected: FAIL — `UpdateEventTool` undefined.

- [ ] **Step 3: Implement the tool**

In `ScheduleTools.swift`, after `CancelEventsTool` (end of file, before nothing — it's the last struct), add:

```swift
/// update_event — edit an existing event in place (time/title/location); never cancel+recreate.
struct UpdateEventTool: AgentTool {
    static let name = "update_event"
    static let description = "Edit an EXISTING calendar event in place — change its time, title, or location. Never cancel+recreate to make a change. Identify it by its CURRENT start (the time the user named) plus title when known."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "start", type: .string, description: "The event's CURRENT local ISO start (the time the user referred to), e.g. 2099-06-09T15:00.", required: true),
        AgentToolParam(name: "title", type: .string, description: "The event's current title, to disambiguate if several share that time.", required: false),
        AgentToolParam(name: "newStart", type: .string, description: "New local ISO start, if moving the event.", required: false),
        AgentToolParam(name: "newEnd", type: .string, description: "New local ISO end, if changing the end.", required: false),
        AgentToolParam(name: "newTitle", type: .string, description: "New title, if renaming.", required: false),
        AgentToolParam(name: "location", type: .string, description: "New place (empty string clears it).", required: false),
        AgentToolParam(name: "allDay", type: .boolean, description: "true/false to change all-day.", required: false),
        AgentToolParam(name: "force", type: .boolean, description: "true to apply despite a conflict with a DIFFERENT event (only after the user confirms).", required: false),
    ]
    func run(argsJSON: String) async -> String {
        let o = obj(argsJSON)
        guard let s = (o["start"] as? String).flatMap(ScheduleTime.epoch) else {
            return "Which event? Tell me the time of the event you want to change (e.g. 2099-06-09T15:00)."
        }
        let title = (o["title"] as? String)?.trimmingCharacters(in: .whitespaces)
        let newStart = (o["newStart"] as? String).flatMap(ScheduleTime.epoch)
        let newEnd = (o["newEnd"] as? String).flatMap(ScheduleTime.epoch)
        let newTitle = (o["newTitle"] as? String)?.trimmingCharacters(in: .whitespaces)
        let location = o["location"] as? String
        let allDay = o["allDay"] as? Bool
        let force = (o["force"] as? Bool) ?? false
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: title ?? ScheduleTime.human(fromEpoch: s)) }
        let result: String = await {
            guard let m = await mem() else { return "memory unavailable" }
            do {
                let r = try await m.updateEvent(start: s, title: (title?.isEmpty == false) ? title : nil,
                                                newStart: newStart, newEnd: newEnd,
                                                newTitle: (newTitle?.isEmpty == false) ? newTitle : nil,
                                                location: location, allDay: allDay, force: force)
                if r.notFound { return "I couldn't find that event — want me to check your schedule?" }
                if !r.ambiguous.isEmpty {
                    return "I found more than one event around then: " + r.ambiguous.map(eventLine).joined(separator: "; ") + ". Which one?"
                }
                if !r.updated {
                    return "NOT changed — the new time conflicts with: " + r.conflicts.map(eventLine).joined(separator: "; ")
                         + ". Ask the user whether to reschedule, cancel the other event, or keep it anyway — if they confirm, call update_event again with force=true."
                }
                if let e = r.event { return "Updated: \(eventLine(e))" }
                return "Updated the event."
            } catch { return "schedule error: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
```

- [ ] **Step 4: Register the tool**

In `HarnessModel.swift`, inside the `if client != nil { … }` block, add `UpdateEventTool()` next to the other schedule tools:

```swift
            registry.register(CheckScheduleTool()); registry.register(CreateEventTool())
            registry.register(QueryScheduleTool()); registry.register(CancelEventsTool())
            registry.register(UpdateEventTool())
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Gemma && xcodebuild test -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/UpdateEventToolTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Memory/ScheduleTools.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/UpdateEventToolTests.swift
git commit -m "feat(app): update_event tool + register (in-app path)"
```

---

### Task 6: Prompt rule (both copies) + prompt tests

**Files:**
- Modify: `gemma-memory/memory-service/Sources/MemoryService/Agent/AgentPrompt.swift` (scheduling paragraph)
- Modify: `Gemma/Gemma/Agent/Agent.swift` (identical scheduling paragraph)
- Test: `gemma-memory/memory-service/Tests/MemoryServiceTests/AgentPromptTests.swift` + `Gemma/GemmaTests/AgentJarvisPromptTests.swift`

- [ ] **Step 1: Write the failing prompt tests**

In `gemma-memory/memory-service/Tests/MemoryServiceTests/AgentPromptTests.swift`, inside `test_systemPrompt_has_jarvis_and_tools_guidance`, add:

```swift
        XCTAssertTrue(p.contains("update_event"), "edit-in-place tool taught")
```

In `Gemma/GemmaTests/AgentJarvisPromptTests.swift`, inside `test_prompt_mentions_topic_and_why_tools` (which already binds `let p = Agent.systemPromptText`), add:

```swift
        XCTAssertTrue(p.localizedCaseInsensitiveContains("update_event"), p)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd gemma-memory/memory-service && swift test --filter AgentPromptTests`
Expected: FAIL — prompt has no `update_event` yet.

- [ ] **Step 3: Add the rule to the GATEWAY prompt**

In `AgentPrompt.swift`, in the Scheduling paragraph, insert this sentence immediately before `cancel_events only \`:

```
    To change an existing event's time, title, or location, call update_event — never cancel and \
    recreate; identify it by the time the user named (start) plus the title when known, confirm by \
    naming the event back, and a time change is conflict-checked like create_event (excluding the \
    event itself). \
```

(The line being modified currently reads `... reschedule, cancel the other, or book anyway (force true only after they confirm). cancel_events only \`. Keep the `\` line-continuation style so the asserted substrings stay intact.)

- [ ] **Step 4: Add the identical rule to the APP prompt**

In `Gemma/Gemma/Agent/Agent.swift`, make the exact same insertion in its Scheduling paragraph (the prompt body is kept byte-in-sync with the gateway). Place the same sentence immediately before `cancel_events only \`.

- [ ] **Step 5: Run both prompt test suites to verify they pass**

Run: `cd gemma-memory/memory-service && swift test --filter AgentPromptTests`
Expected: PASS.

Run: `cd Gemma && xcodebuild test -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/AgentJarvisPromptTests 2>&1 | tail -15`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd gemma-memory/memory-service
git add Sources/MemoryService/Agent/AgentPrompt.swift Tests/MemoryServiceTests/AgentPromptTests.swift
git commit -m "feat(prompt): teach update_event (gateway copy)"
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Agent/Agent.swift Gemma/GemmaTests/AgentJarvisPromptTests.swift
git commit -m "feat(prompt): teach update_event (app copy)"
```

---

### Task 7: Full suites + deploy

**Files:** none (verification + deploy)

- [ ] **Step 1: Full server suite**

Run: `cd gemma-memory/memory-service && swift test 2>&1 | tail -8`
Expected: all tests pass (the suite was 228 before; new tests add to it). 0 failures.

- [ ] **Step 2: Full app suite**

Run: `cd Gemma && xcodebuild test -scheme Gemma -destination 'platform=macOS' 2>&1 | tail -15`
Expected: `** TEST SUCCEEDED **` (the known-failing `HarnessModelTests.test_defaultBaseURL` is pre-existing; everything else green).

- [ ] **Step 3: Push gemma-memory**

```bash
cd gemma-memory/memory-service && cd .. && git push origin main
```

- [ ] **Step 4: Deploy to the i3**

```bash
ssh HomeLab 'cd ~/Projects/gemma-memory && git pull --ff-only && docker compose up -d --build memory'
```

- [ ] **Step 5: Smoke the new endpoint on the i3**

```bash
ssh HomeLab 'TOKEN=$(grep -E "^MEMORY_BEARER_TOKEN=" ~/Projects/gemma-memory/.env | cut -d= -f2-);
curl -fsS http://localhost:8081/healthz; echo;
curl -fsS -X POST http://localhost:8081/v1/schedule/update -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"start\":999999,\"location\":\"X\"}"'
```
Expected: `{"status":"ok"}` then `{"updated":false,"notFound":true}` (no event at that epoch).

- [ ] **Step 6: Commit the app push**

```bash
cd /Users/hashdown/Projects/personal_agent && git push origin main
```

---

## Self-Review

**Spec coverage:**
- Store `findEditTarget` / `applyEventEdit` / `scheduleConflicts(excluding:)` → Task 1. ✓
- Gateway tool `update_event` (not-found / ambiguous / conflict / force / echo) → Task 2. ✓
- HTTP `POST /schedule/update` with the four response shapes → Task 3. ✓
- App `MemoryClient.updateEvent` + result decoding → Task 4. ✓
- App `update_event` tool + registration → Task 5. ✓
- Prompt rule in BOTH copies + tests → Task 6. ✓
- Both paths covered; deploy → Task 7. ✓

**Type consistency:** `findEditTarget(start:title:) -> EditTarget`, `applyEventEdit(_:newTitle:newStart:newEnd:location:allDay:) -> Node`, `scheduleConflicts(start:end:excluding:)`, `MemoryClient.UpdateEventResult{updated,event,conflicts,notFound,ambiguous}`, response keys `updated|event|conflicts|notFound|ambiguous` — used identically in store, gateway tool, endpoint, client, and app tool.

**No placeholders:** every code step shows complete code. The only judgement call is in Task 5 Step 1 (match the codebase's existing app-tool injection pattern for the tool-level test) — the implementer is told to mirror `MemoryClientScheduleTests`'s `StubURLProtocol`/`MemoryToolbox` wiring and that the decode coverage in Task 4 is the guaranteed-correct floor.

**Scope:** single subsystem (edit-an-event) across its two delivery paths. No recurring events, no id exposure to the model — both explicit non-goals in the spec.
