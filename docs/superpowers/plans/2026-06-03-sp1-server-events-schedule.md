# SP1 · Plan 1 — gemma-memory server: dated events + schedule API

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-class dated `event` nodes to the Memory Service with deterministic time-overlap detection and a `/v1/schedule` API (check / create / window / cancel), plus emit structured events from `consolidate()`.

**Architecture:** Events are `Node`s with `kind="event"` whose structured time fields live in `Node.extra` (JSON, via an extended `NodeAttributes`). Overlap is a pure function over epoch ranges, computed in `MemoryStore`; the service stays deterministic. Endpoints mirror the existing `ConsolidationHandlers` registration pattern.

**Tech Stack:** Swift 6, GRDB 6.x, Hummingbird 2.25, XCTest. Repo: `gemma-memory` (separate from `personal_agent`). Work dir for this plan: the `gemma-memory` clone at `/Users/hashdown/Projects/gemma-memory`.

**Repo note:** This plan is committed in `personal_agent`, but its tasks edit the **`gemma-memory`** repo. All paths below are relative to `/Users/hashdown/Projects/gemma-memory`. Commits in steps are made in that repo.

**Scope:** Server only. Plan 2 (agent tools + conversational flow in `personal_agent`) is a separate plan that depends on this one being deployed. No data migration (memory is wiped — see spec §7).

---

## File structure

- `memory-service/Sources/MemoryCore/MemoryModels.swift` — add `event` to `NodeKind` + its hub label.
- `memory-service/Sources/MemoryCore/NodeAttributes.swift` — add event fields (`startAt`, `endAt`, `allDay`, `location`, `canonicalKey`); `status` reused for event status.
- `memory-service/Sources/MemoryCore/MemoryText.swift` — add `eventCanonicalKey(title:startAt:)`.
- `memory-service/Sources/MemoryCore/MemoryStore+Schedule.swift` — **new**: overlap helper + `scheduleConflicts`, `scheduleWindow`, `upsertEvent`, `cancelEvents`.
- `memory-service/Sources/MemoryService/Handlers/ScheduleHandlers.swift` — **new**: 4 endpoints.
- `memory-service/Sources/MemoryService/App.swift` — register `ScheduleHandlers`.
- `memory-service/Sources/MemoryCore/MemoryConsolidationEngine.swift` — `consolidate()` emits `event` for timed entities.
- Tests: `Tests/MemoryCoreTests/ScheduleStoreTests.swift`, `Tests/MemoryServiceTests/ScheduleEndpointsTests.swift`, plus a case in `Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift`.

---

## Task 1: `event` NodeKind + hub label

**Files:**
- Modify: `memory-service/Sources/MemoryCore/MemoryModels.swift:4` and the `hubLabel` switch (~line 28-43)

- [ ] **Step 1: Add the enum case**

In `MemoryModels.swift` line 4, add `event` to `NodeKind`:

```swift
public enum NodeKind: String, Codable, CaseIterable, Sendable { case person, place, fact, preference, topic, trait, task, plan, event, summary, insight, day, episode, conversation, followUp = "follow_up", clarification }
```

- [ ] **Step 2: Add its hub label**

In the hub-label `switch` (the block with `case .task: return "Tasks"`), add:

```swift
        case .event: return "Events"
```

- [ ] **Step 3: Build**

Run: `cd /Users/hashdown/Projects/gemma-memory/memory-service && swift build`
Expected: builds (the switch is exhaustive again with the new case).

- [ ] **Step 4: Commit**

```bash
git add memory-service/Sources/MemoryCore/MemoryModels.swift
git commit -m "feat(sp1): add event NodeKind + Events hub label"
```

---

## Task 2: Event fields on NodeAttributes

**Files:**
- Modify: `memory-service/Sources/MemoryCore/NodeAttributes.swift`
- Test: `Tests/MemoryCoreTests/ScheduleStoreTests.swift` (new file; first test here)

- [ ] **Step 1: Write the failing test**

Create `memory-service/Tests/MemoryCoreTests/ScheduleStoreTests.swift`:

```swift
import XCTest
@testable import MemoryCore

final class ScheduleStoreTests: XCTestCase {
    func test_nodeAttributes_roundtrip_eventFields() {
        var a = NodeAttributes()
        a.startAt = 1_000; a.endAt = 4_600; a.allDay = false
        a.location = "Miami"; a.status = "scheduled"; a.canonicalKey = "k1"
        let json = a.toJSON()
        XCTAssertNotNil(json)
        let back = NodeAttributes.from(json)
        XCTAssertEqual(back.startAt, 1_000)
        XCTAssertEqual(back.endAt, 4_600)
        XCTAssertEqual(back.allDay, false)
        XCTAssertEqual(back.location, "Miami")
        XCTAssertEqual(back.status, "scheduled")
        XCTAssertEqual(back.canonicalKey, "k1")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /Users/hashdown/Projects/gemma-memory/memory-service && swift test --filter ScheduleStoreTests.test_nodeAttributes_roundtrip_eventFields`
Expected: FAIL — `value of type 'NodeAttributes' has no member 'startAt'`.

- [ ] **Step 3: Add the fields**

Replace the body of `NodeAttributes` (`memory-service/Sources/MemoryCore/NodeAttributes.swift`) with:

```swift
public struct NodeAttributes: Codable, Sendable {
    public var status: String?       // task: "pending"|"done"; event: "scheduled"|"cancelled"|"done"
    public var horizon: String?      // plan: "short"|"long"
    public var date: String?         // task/plan: absolute ISO date (yyyy-MM-dd)
    // event fields:
    public var startAt: Double?      // epoch seconds (UTC)
    public var endAt: Double?        // epoch seconds (UTC)
    public var allDay: Bool?
    public var location: String?
    public var canonicalKey: String? // dedup key for events

    public init(status: String? = nil, horizon: String? = nil, date: String? = nil,
                startAt: Double? = nil, endAt: Double? = nil, allDay: Bool? = nil,
                location: String? = nil, canonicalKey: String? = nil) {
        self.status = status; self.horizon = horizon; self.date = date
        self.startAt = startAt; self.endAt = endAt; self.allDay = allDay
        self.location = location; self.canonicalKey = canonicalKey
    }

    public func toJSON() -> String? {
        guard status != nil || horizon != nil || date != nil || startAt != nil || endAt != nil
            || allDay != nil || location != nil || canonicalKey != nil else { return nil }
        return (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
    public static func from(_ extra: String?) -> NodeAttributes {
        guard let s = extra, let d = s.data(using: .utf8),
              let a = try? JSONDecoder().decode(NodeAttributes.self, from: d) else { return NodeAttributes() }
        return a
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ScheduleStoreTests.test_nodeAttributes_roundtrip_eventFields`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add memory-service/Sources/MemoryCore/NodeAttributes.swift memory-service/Tests/MemoryCoreTests/ScheduleStoreTests.swift
git commit -m "feat(sp1): event fields on NodeAttributes (startAt/endAt/allDay/location/canonicalKey)"
```

---

## Task 3: `eventCanonicalKey` helper

**Files:**
- Modify: `memory-service/Sources/MemoryCore/MemoryText.swift`
- Test: `Tests/MemoryCoreTests/ScheduleStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `ScheduleStoreTests.swift`:

```swift
    func test_eventCanonicalKey_collapsesSameStartAndTitle() {
        // 2026-06-04 10:00 and 10:00:30 round to the same minute; title normalized.
        let k1 = MemoryText.eventCanonicalKey(title: "Dentist Appointment", startAt: 1_780_653_600)
        let k2 = MemoryText.eventCanonicalKey(title: "  dentist   appointment ", startAt: 1_780_653_630)
        XCTAssertEqual(k1, k2)
        let k3 = MemoryText.eventCanonicalKey(title: "dentist appointment", startAt: 1_780_657_200) // +1h
        XCTAssertNotEqual(k1, k3)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter ScheduleStoreTests.test_eventCanonicalKey_collapsesSameStartAndTitle`
Expected: FAIL — `type 'MemoryText' has no member 'eventCanonicalKey'`.

- [ ] **Step 3: Implement the helper**

Add to `MemoryText.swift` (inside the `MemoryText` enum/struct, alongside `dedupKey`):

```swift
    /// Canonical dedup key for an event: normalized title + start rounded to the minute.
    /// Collapses "10am"/"10:00"/"10:00:30" on the same title into one key.
    public static func eventCanonicalKey(title: String, startAt: Double) -> String {
        let minute = Int((startAt / 60.0).rounded(.down))
        let normTitle = dedupKey(title)   // existing lowercase/whitespace/punct normalizer
        return "\(minute)|\(normTitle)"
    }
```

(If `dedupKey` is not `public`, make it `public`, or inline its normalization: lowercased, collapse whitespace, trim. Verify by reading `MemoryText.swift` for the existing `dedupKey` signature before editing.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ScheduleStoreTests.test_eventCanonicalKey_collapsesSameStartAndTitle`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add memory-service/Sources/MemoryCore/MemoryText.swift memory-service/Tests/MemoryCoreTests/ScheduleStoreTests.swift
git commit -m "feat(sp1): eventCanonicalKey for event dedup"
```

---

## Task 4: Pure overlap function

**Files:**
- Create: `memory-service/Sources/MemoryCore/MemoryStore+Schedule.swift`
- Test: `Tests/MemoryCoreTests/ScheduleStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `ScheduleStoreTests.swift`:

```swift
    func test_eventsOverlap_rules() {
        // [0,10) vs [10,20) touch at the edge → NO overlap
        XCTAssertFalse(eventsOverlap(0, 10, 10, 20))
        // [0,10) vs [5,15) → overlap
        XCTAssertTrue(eventsOverlap(0, 10, 5, 15))
        // nested [0,100) vs [10,20) → overlap
        XCTAssertTrue(eventsOverlap(0, 100, 10, 20))
        // identical → overlap
        XCTAssertTrue(eventsOverlap(5, 6, 5, 6))
        // disjoint → no overlap
        XCTAssertFalse(eventsOverlap(0, 5, 100, 200))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ScheduleStoreTests.test_eventsOverlap_rules`
Expected: FAIL — `cannot find 'eventsOverlap' in scope`.

- [ ] **Step 3: Implement**

Create `memory-service/Sources/MemoryCore/MemoryStore+Schedule.swift`:

```swift
import Foundation
import GRDB

/// Half-open interval overlap: [s1,e1) intersects [s2,e2) iff s1 < e2 ∧ s2 < e1.
/// Touching at an edge (e1 == s2) is NOT an overlap.
public func eventsOverlap(_ s1: Double, _ e1: Double, _ s2: Double, _ e2: Double) -> Bool {
    s1 < e2 && s2 < e1
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ScheduleStoreTests.test_eventsOverlap_rules`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add memory-service/Sources/MemoryCore/MemoryStore+Schedule.swift memory-service/Tests/MemoryCoreTests/ScheduleStoreTests.swift
git commit -m "feat(sp1): pure eventsOverlap half-open interval rule"
```

---

## Task 5: `scheduleWindow` + `scheduleConflicts` in the store

**Files:**
- Modify: `memory-service/Sources/MemoryCore/MemoryStore+Schedule.swift`
- Test: `Tests/MemoryCoreTests/ScheduleStoreTests.swift`

Helper for tests — add this factory at the top of `ScheduleStoreTests` (after the class opening brace):

```swift
    private func makeStore() throws -> MemoryStore { try MemoryStore(path: ":memory:", embeddingDim: 8) }

    @discardableResult
    private func addEvent(_ store: MemoryStore, _ title: String, _ start: Double, _ end: Double,
                          status: String = "scheduled", location: String? = nil) throws -> String {
        var attrs = NodeAttributes(status: status, startAt: start, endAt: end, location: location,
                                   canonicalKey: MemoryText.eventCanonicalKey(title: title, startAt: start))
        let id = UUID().uuidString; let t = start
        let node = Node(id: id, kind: NodeKind.event.rawValue, label: title, body: title, layer: .daily,
                        createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3, decayRate: 0,
                        confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                        origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: attrs.toJSON())
        try store.upsert(node)
        return id
    }
```

- [ ] **Step 1: Write the failing tests**

Add to `ScheduleStoreTests.swift`:

```swift
    func test_scheduleWindow_returnsScheduledInRange_sortedByStart() throws {
        let s = try makeStore()
        try addEvent(s, "B", 200, 260)
        try addEvent(s, "A", 100, 160)
        try addEvent(s, "Out", 10_000, 10_060)
        try addEvent(s, "Cancelled", 120, 180, status: "cancelled")
        let win = try s.scheduleWindow(from: 0, to: 1_000, includeCancelled: false)
        XCTAssertEqual(win.map { $0.label }, ["A", "B"])   // sorted by start, cancelled excluded, Out excluded
        let withCancelled = try s.scheduleWindow(from: 0, to: 1_000, includeCancelled: true)
        XCTAssertEqual(withCancelled.count, 3)
    }

    func test_scheduleConflicts_findsOverlappingScheduledOnly() throws {
        let s = try makeStore()
        try addEvent(s, "Trip", 0, 1_000)
        try addEvent(s, "CancelledTrip", 0, 1_000, status: "cancelled")
        let conflicts = try s.scheduleConflicts(start: 500, end: 600)
        XCTAssertEqual(conflicts.map { $0.label }, ["Trip"])   // cancelled not a conflict
        XCTAssertEqual(try s.scheduleConflicts(start: 2_000, end: 2_100).count, 0)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ScheduleStoreTests`
Expected: FAIL — `value of type 'MemoryStore' has no member 'scheduleWindow'`.

- [ ] **Step 3: Implement**

Append to `MemoryStore+Schedule.swift`:

```swift
extension MemoryStore {
    /// All `event` nodes whose [start,end) intersects [from,to), sorted by start ascending.
    /// Excludes cancelled unless `includeCancelled`. Pure read.
    public func scheduleWindow(from: Double, to: Double, includeCancelled: Bool = false) throws -> [Node] {
        let events = try allNodes().filter { $0.kind == NodeKind.event.rawValue }
        return events.compactMap { node -> (Node, Double)? in
            let a = NodeAttributes.from(node.extra)
            guard let s = a.startAt, let e = a.endAt else { return nil }
            if !includeCancelled, a.status == "cancelled" { return nil }
            guard eventsOverlap(s, e, from, to) else { return nil }
            return (node, s)
        }
        .sorted { $0.1 < $1.1 }
        .map { $0.0 }
    }

    /// Scheduled events overlapping the proposed [start,end). Cancelled/done excluded.
    public func scheduleConflicts(start: Double, end: Double) throws -> [Node] {
        let events = try allNodes().filter { $0.kind == NodeKind.event.rawValue }
        return events.filter { node in
            let a = NodeAttributes.from(node.extra)
            guard let s = a.startAt, let e = a.endAt, a.status == "scheduled" else { return false }
            return eventsOverlap(s, e, start, end)
        }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter ScheduleStoreTests`
Expected: PASS (all ScheduleStoreTests).

- [ ] **Step 5: Commit**

```bash
git add memory-service/Sources/MemoryCore/MemoryStore+Schedule.swift memory-service/Tests/MemoryCoreTests/ScheduleStoreTests.swift
git commit -m "feat(sp1): scheduleWindow + scheduleConflicts store queries"
```

---

## Task 6: `upsertEvent` (dedup by canonicalKey) + `cancelEvents`

**Files:**
- Modify: `memory-service/Sources/MemoryCore/MemoryStore+Schedule.swift`
- Test: `Tests/MemoryCoreTests/ScheduleStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `ScheduleStoreTests.swift`:

```swift
    func test_upsertEvent_dedupsByCanonicalKey() throws {
        let s = try makeStore()
        let id1 = try s.upsertEvent(title: "dentist", start: 1_780_653_600, end: 1_780_657_200,
                                    allDay: false, location: nil, origin: .explicit)
        let id2 = try s.upsertEvent(title: "  Dentist ", start: 1_780_653_630, end: 1_780_657_200,
                                    allDay: false, location: "clinic", origin: .explicit)
        XCTAssertEqual(id1, id2, "same canonicalKey → update, not duplicate")
        let events = try s.allNodes().filter { $0.kind == NodeKind.event.rawValue }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(NodeAttributes.from(events[0].extra).location, "clinic", "update applied")
    }

    func test_cancelEvents_byWindow_softCancels() throws {
        let s = try makeStore()
        try addEvent(s, "A", 100, 160)
        try addEvent(s, "Out", 10_000, 10_060)
        let n = try s.cancelEvents(from: 0, to: 1_000)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try s.scheduleConflicts(start: 100, end: 160).count, 0, "cancelled no longer conflicts")
        let still = try s.allNodes().filter { $0.kind == NodeKind.event.rawValue }
        XCTAssertEqual(still.count, 2, "cancelled is retained, not deleted")
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ScheduleStoreTests`
Expected: FAIL — `value of type 'MemoryStore' has no member 'upsertEvent'`.

- [ ] **Step 3: Implement**

Append to the `extension MemoryStore` in `MemoryStore+Schedule.swift`:

```swift
    /// Create or update an event, deduping by canonicalKey. Returns the node id.
    @discardableResult
    public func upsertEvent(title: String, start: Double, end: Double, allDay: Bool,
                            location: String?, origin: Origin) throws -> String {
        let key = MemoryText.eventCanonicalKey(title: title, startAt: start)
        let existing = try allNodes().first { node in
            node.kind == NodeKind.event.rawValue && NodeAttributes.from(node.extra).canonicalKey == key
        }
        let now = Date().timeIntervalSince1970
        var attrs = NodeAttributes(status: "scheduled", startAt: start, endAt: end,
                                   allDay: allDay, location: location, canonicalKey: key)
        if let existing {
            // preserve a non-scheduled status only if caller isn't rescheduling; here we re-arm to scheduled
            var node = existing
            node.label = title; node.body = title; node.updatedAt = now; node.lastSeenAt = now
            node.extra = attrs.toJSON(); node.dirty = true
            try upsert(node)
            return existing.id
        } else {
            let id = UUID().uuidString
            let node = Node(id: id, kind: NodeKind.event.rawValue, label: title, body: title, layer: .daily,
                            createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3, decayRate: 0,
                            confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                            origin: origin, serverId: nil, dirty: true, deleted: false, extra: attrs.toJSON())
            try upsert(node)
            return id
        }
    }

    /// Soft-cancel: set status="cancelled" on the given ids, or on all scheduled events in [from,to).
    /// Returns the count changed. Cancelled events are retained (for future notifications).
    @discardableResult
    public func cancelEvents(ids: [String]? = nil, from: Double? = nil, to: Double? = nil) throws -> Int {
        let targets: [Node]
        if let ids {
            targets = try ids.compactMap { try node(id: $0) }.filter { $0.kind == NodeKind.event.rawValue }
        } else if let from, let to {
            targets = try scheduleWindow(from: from, to: to, includeCancelled: false)
        } else {
            return 0
        }
        var changed = 0
        let now = Date().timeIntervalSince1970
        for var node in targets {
            var a = NodeAttributes.from(node.extra)
            guard a.status != "cancelled" else { continue }
            a.status = "cancelled"
            node.extra = a.toJSON(); node.updatedAt = now; node.dirty = true
            try upsert(node)
            changed += 1
        }
        return changed
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter ScheduleStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add memory-service/Sources/MemoryCore/MemoryStore+Schedule.swift memory-service/Tests/MemoryCoreTests/ScheduleStoreTests.swift
git commit -m "feat(sp1): upsertEvent (dedup) + cancelEvents (soft-cancel)"
```

---

## Task 7: `/v1/schedule` endpoints

**Files:**
- Create: `memory-service/Sources/MemoryService/Handlers/ScheduleHandlers.swift`
- Modify: `memory-service/Sources/MemoryService/App.swift` (register, next to `ConsolidationHandlers(services: services).register(on: v1)`)
- Test: `Tests/MemoryServiceTests/ScheduleEndpointsTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `memory-service/Tests/MemoryServiceTests/ScheduleEndpointsTests.swift`:

```swift
import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Foundation
@testable import MemoryService
@testable import MemoryCore

final class ScheduleEndpointsTests: XCTestCase {
    private func makeApp() async throws -> some ApplicationProtocol {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        let services = await Services(store: store,
                                      transcript: TranscriptStore(dbQueue: store.dbQueue),
                                      embedder: FakeEmbedder(dimension: 8),
                                      bearerToken: "test-token")
        return try await buildApp(services: services, port: 0)
    }
    private let auth: HTTPField = .init(name: .authorization, value: "Bearer test-token")

    func test_create_then_check_conflict_then_window() async throws {
        let app = try await makeApp()
        try await app.test(.live) { client in
            // create a trip [1000,2000)
            try await client.execute(uri: "/v1/schedule/create", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"title":"Trip","start":1000,"end":2000,"allDay":true,"origin":"user"}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":true"))
            }
            // check a conflicting slot [1500,1600)
            try await client.execute(uri: "/v1/schedule/check", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"start":1500,"end":1600}"#)) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("Trip"))
            }
            // create conflicting without force → not created
            try await client.execute(uri: "/v1/schedule/create", method: .post,
                headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"title":"Meeting","start":1500,"end":1600,"origin":"user","force":false}"#)) { res in
                XCTAssertTrue(String(buffer: res.body).contains("\"created\":false"))
            }
            // window returns the trip
            try await client.execute(uri: "/v1/schedule/window?from=0&to=5000", method: .get,
                headers: [.authorization: "Bearer test-token"]) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(String(buffer: res.body).contains("Trip"))
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/hashdown/Projects/gemma-memory/memory-service && swift test --filter ScheduleEndpointsTests`
Expected: FAIL — 404 on `/v1/schedule/create` (handler not registered → `created` not in body).

- [ ] **Step 3: Implement the handlers**

Create `memory-service/Sources/MemoryService/Handlers/ScheduleHandlers.swift` (mirror `ConsolidationHandlers` structure):

```swift
import Foundation
import Hummingbird
import NIOCore
import HTTPTypes
import MemoryCore

/// `/v1/schedule` — dated events with deterministic overlap detection.
struct ScheduleHandlers {
    let services: Services

    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/schedule/check",  use: check)
        group.post("/schedule/create", use: create)
        group.get ("/schedule/window", use: window)
        group.post("/schedule/cancel", use: cancel)
    }

    private func eventJSON(_ n: Node) -> [String: Any] {
        let a = NodeAttributes.from(n.extra)
        return ["id": n.id, "title": n.label, "start": a.startAt ?? 0, "end": a.endAt ?? 0,
                "allDay": a.allDay ?? false, "location": a.location as Any, "status": a.status ?? "scheduled"]
    }
    private func json(_ obj: Any, _ status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
    private func body<T: Decodable>(_ req: Request, _ type: T.Type) async -> T? {
        guard let buf = try? await req.body.collect(upTo: 16_000) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(buf.readableBytesView))
    }

    struct CheckBody: Decodable { let start: Double; let end: Double }
    @Sendable func check(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let b = await body(req, CheckBody.self) else { return jsonError(.badRequest, "bad_request", "start/end required") }
        let conflicts = (try? services.store.scheduleConflicts(start: b.start, end: b.end)) ?? []
        return json(["conflicts": conflicts.map(eventJSON)])
    }

    struct CreateBody: Decodable {
        let title: String; let start: Double; let end: Double
        let allDay: Bool?; let location: String?; let origin: String?; let force: Bool?
    }
    @Sendable func create(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let b = await body(req, CreateBody.self) else { return jsonError(.badRequest, "bad_request", "title/start/end required") }
        let conflicts = (try? services.store.scheduleConflicts(start: b.start, end: b.end)) ?? []
        if !conflicts.isEmpty, b.force != true {
            return json(["created": false, "conflicts": conflicts.map(eventJSON)])
        }
        let origin: Origin = (b.origin == "extracted") ? .extracted : .explicit
        let id = try services.store.upsertEvent(title: b.title, start: b.start, end: b.end,
                                                allDay: b.allDay ?? false, location: b.location, origin: origin)
        return json(["created": true, "id": id, "conflicts": conflicts.map(eventJSON)])
    }

    @Sendable func window(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let q = req.uri.queryParameters
        let from = q["from"].flatMap { Double($0) } ?? 0
        let to = q["to"].flatMap { Double($0) } ?? (from + 7 * 86_400)
        let incl = q["includeCancelled"] == "true"
        let events = (try? services.store.scheduleWindow(from: from, to: to, includeCancelled: incl)) ?? []
        return json(["events": events.map(eventJSON)])
    }

    struct CancelBody: Decodable { let ids: [String]?; let from: Double?; let to: Double? }
    @Sendable func cancel(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        guard let b = await body(req, CancelBody.self) else { return jsonError(.badRequest, "bad_request", "ids or from/to required") }
        let n = (try? services.store.cancelEvents(ids: b.ids, from: b.from, to: b.to)) ?? 0
        return json(["cancelled": n])
    }
}
```

(Verify `jsonError` and `req.uri.queryParameters` exist by reading `ConsolidationHandlers.swift` / another handler — they are used there. If `jsonError`'s signature differs, match it.)

- [ ] **Step 4: Register the handler**

In `memory-service/Sources/MemoryService/App.swift`, find:

```swift
    ConsolidationHandlers(services: services).register(on: v1)
```

Add immediately after it:

```swift
    ScheduleHandlers(services: services).register(on: v1)
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter ScheduleEndpointsTests`
Expected: PASS.

- [ ] **Step 6: Run the whole suite (no regressions)**

Run: `cd /Users/hashdown/Projects/gemma-memory/memory-service && swift test`
Expected: all green (existing + new).

- [ ] **Step 7: Commit**

```bash
git add memory-service/Sources/MemoryService/Handlers/ScheduleHandlers.swift memory-service/Sources/MemoryService/App.swift memory-service/Tests/MemoryServiceTests/ScheduleEndpointsTests.swift
git commit -m "feat(sp1): /v1/schedule endpoints (check/create/window/cancel)"
```

---

## Task 8: `consolidate()` emits structured events

**Files:**
- Modify: `memory-service/Sources/MemoryCore/MemoryConsolidationEngine.swift` (the `consolidate()` loop, ~lines 81-112)
- Test: `Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift`

**Context:** Today `consolidate()` maps extracted entities to `task`/`plan`/`fact` nodes with `attributes.date` (date only). When the model returns a `task`/`plan` with a `date` AND a time can be derived, we want an `event` with `startAt`/`endAt` instead. Keep it minimal: when the extracted entity kind is `task`/`plan` and `attributes.date` is present, treat it as an event with `start` = that date at the time the model provides (the prompt already asks for `attributes.date`; extend the prompt to also ask for `attributes.start`/`attributes.end` epoch). The cleanest minimal change: extend the entity schema with optional `start`/`end` epoch and, when present, create an `event` via `upsertEvent`.

- [ ] **Step 1: Write the failing test**

Add to `MemoryConsolidationEngineTests.swift` a test using a fake `ModelTextClient` that returns an entities JSON with `start`/`end`:

```swift
    func test_consolidate_emitsStructuredEvent_whenStartEndPresent() async throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 8)
        // Fake runtime returns one event-like entity with epoch start/end.
        final class EventRuntime: ModelTextClient, @unchecked Sendable {
            func generate(prompt: String, options: ModelTextOptions) async throws -> String {
                #"{"entities":[{"entity":"dentist appointment","kind":"task","detail":"dentist","attributes":{"status":"pending","date":"2026-06-04","start":1780653600,"end":1780657200}}]}"#
            }
        }
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 8),
                                               runtime: EventRuntime(), transcriptStore: TranscriptStore(dbQueue: store.dbQueue))
        await engine.consolidate(episodeTexts: ["User: dentista jueves 10am"])
        let events = try store.allNodes().filter { $0.kind == NodeKind.event.rawValue }
        XCTAssertEqual(events.count, 1)
        let a = NodeAttributes.from(events[0].extra)
        XCTAssertEqual(a.startAt, 1_780_653_600)
        XCTAssertEqual(a.endAt, 1_780_657_200)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MemoryConsolidationEngineTests.test_consolidate_emitsStructuredEvent_whenStartEndPresent`
Expected: FAIL — 0 events (the entity becomes a `task`, not an `event`).

- [ ] **Step 3: Implement**

In `MemoryConsolidationEngine.swift`:

(a) Extend the decoded attributes struct `EntitiesOut.E.Attr` (~line 59) to include epoch start/end:

```swift
            struct Attr: Decodable { let status: String?; let horizon: String?; let date: String?; let start: Double?; let end: Double? }
```

(b) In the `for e in out.entities` loop (~line 81), BEFORE the existing node-construction, add an event short-circuit:

```swift
            // Structured event: a timed task/plan with epoch start/end → first-class `event`.
            if let st = e.attributes?.start, let en = e.attributes?.end, en > st {
                let evLabel = MemoryText.canonicalEntityLabel(e.entity)
                if !MemoryText.isJunkLabel(evLabel) {
                    _ = try? store.upsertEvent(title: evLabel, start: st, end: en,
                                               allDay: false, location: e.detail, origin: .extracted)
                    added += 1
                }
                continue
            }
```

(c) Extend the `consolidate` prompt (the string at ~line 67-77) to ask for epoch start/end. Append to the schema-instruction line:

```
For appointments/meetings/trips (things with a time), also fill attributes.start and attributes.end as Unix epoch seconds (UTC) for the resolved date+time; assume 1 hour duration if only a start time is given.
```

And update the `Schema:` line to include `"start":0,"end":0` inside `attributes`.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter MemoryConsolidationEngineTests.test_consolidate_emitsStructuredEvent_whenStartEndPresent`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add memory-service/Sources/MemoryCore/MemoryConsolidationEngine.swift memory-service/Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(sp1): consolidate() emits structured event nodes for timed entities"
```

---

## Task 9: Deploy to the i3 + live smoke test

**Files:** none (ops). Requires the user (i3 docker access is restricted for the agent).

- [ ] **Step 1: Push gemma-memory main** (or open PR per user preference)

```bash
cd /Users/hashdown/Projects/gemma-memory && git push origin main
```

- [ ] **Step 2: Rebuild + restart on the i3** (user runs, in the i3 repo dir)

```bash
git pull && docker compose up -d --build memory
```

- [ ] **Step 3: Live smoke (from the Mac)**

```bash
TOK="<bearer>"; B="http://192.168.1.50:8081"
curl -sS -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"title":"Trip","start":1781000000,"end":1781400000,"allDay":true,"origin":"user"}' $B/v1/schedule/create
curl -sS -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"title":"Meeting","start":1781100000,"end":1781103600,"origin":"user","force":false}' $B/v1/schedule/create
```
Expected: first `{"created":true,...}`, second `{"created":false,"conflicts":[{"title":"Trip"...}]}`.

- [ ] **Step 4: Clean up the smoke event**

```bash
curl -sS -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -d '{"from":1780000000,"to":1782000000}' $B/v1/schedule/cancel
```

---

## Self-review notes (author)

- **Spec coverage:** event model (Task 1-3) ✓; deterministic overlap (Task 4) ✓; check/create/window/cancel API (Task 7) ✓ — matches spec §4; soft-cancel retention (Task 6) ✓; consolidate() structured events (Task 8) ✓ — spec §6; no migration (correct — memory wiped). Hybrid layer + conversational flow are **Plan 2** (agent), out of scope here.
- **Placeholder scan:** none — every step has code/commands. Two "verify the existing signature" notes (Task 3 `dedupKey` visibility, Task 7 `jsonError`/`queryParameters`) are explicit verification instructions, not placeholders.
- **Type consistency:** `upsertEvent(title:start:end:allDay:location:origin:)`, `scheduleConflicts(start:end:)`, `scheduleWindow(from:to:includeCancelled:)`, `cancelEvents(ids:from:to:)`, `eventCanonicalKey(title:startAt:)`, `eventsOverlap(_:_:_:_:)`, `NodeAttributes.startAt/endAt/allDay/location/canonicalKey` — used consistently across tasks and the handler.
- **Open verification at execution:** confirm `MemoryStore` initializer label (`MemoryStore(path:embeddingDim:)` per existing tests) and `Services` test-init signature (per `ConsolidationEndpointsTests`) before running — both are mirrored from existing tests.
