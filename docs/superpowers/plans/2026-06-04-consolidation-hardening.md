# Consolidation Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make event creation impossible without a conflict check, make date→epoch deterministic (not model-computed), keep graph hubs out of the `place` category, and deduplicate insights — so consolidation produces correct data regardless of model quality.

**Architecture:** All four fixes live in the `gemma-memory` repo (`memory-service`, the i3 Swift/Hummingbird/GRDB service) except one small change in the macOS app (`personal_agent`). A single store method `createEventChecked` becomes the only event-creation path; the model emits local wall-clock text and the server converts it with a new `MemoryCore.ScheduleTime` using the user's timezone (threaded from the app through the scheduler into the consolidation cycle); `ensureKindHubs` self-heals mis-kinded hub nodes; a new `compress` sleep phase merges near-duplicate insights.

**Tech Stack:** Swift 6 (server: SwiftPM, Hummingbird, NIO, GRDB; app: SwiftUI, Xcode). Spec: `docs/superpowers/specs/2026-06-04-consolidation-hardening-design.md`.

**Where to run server tests:** in a clone of `github.com/roilanlg05/gemma-memory` at `memory-service/` (the repo is gitignored inside `personal_agent`; clone it standalone or edit on the i3 at `~/Projects/gemma-memory`). Command: `swift test --filter <Name>` from `memory-service/`.
**Where to run app tests:** `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS'` in `personal_agent`.

**Conscious deviation from spec §5:** the API carries only `timezone` (the correctness-critical field). `now` is NOT added — the server clock is authoritative, and a client `now` captured at turn-end would go stale across the 15s/180s scheduler timers and cross-restart resume. Date resolution uses the server clock with the user's timezone. (Spec §5 row for `now` is superseded.)

---

## File Structure

**`gemma-memory` / `memory-service`:**
- Create `Sources/MemoryCore/ScheduleTime.swift` — local date/time(+tz) → epoch (mirror of the app helper).
- Modify `Sources/MemoryCore/MemoryStore+Schedule.swift` — add `createEventChecked`.
- Modify `Sources/MemoryCore/MemoryStore+Vector.swift` — expose `cosineDistance`.
- Modify `Sources/MemoryCore/MemoryStore+Dedup.swift` — add `compressInsights`.
- Modify `Sources/MemoryCore/MemoryStore+Hubs.swift` — self-heal in `ensureKindHubs`.
- Modify `Sources/MemoryCore/MemoryText.swift` — reserved-word junk guard.
- Modify `Sources/MemoryCore/MemoryStore.swift` — add `.compress` to `SleepPhase`.
- Modify `Sources/MemoryCore/ConsolidationScheduler.swift` — `timeZone` on protocol + `armTurnEnd`/`runReflectAdHoc` + `launch`.
- Modify `Sources/MemoryCore/MemoryConsolidationEngine.swift` — `currentTimeZone`, new `Attr` schema, prompt, `createEventChecked` + clarification, `compress()` phase, cycle order.
- Modify `Sources/MemoryService/Handlers/ScheduleHandlers.swift` — `create` on `createEventChecked`.
- Modify `Sources/MemoryService/Handlers/ConsolidationHandlers.swift` — decode `timezone` on turn-end/reflect.
- Tests: `Tests/MemoryCoreTests/ScheduleStoreTests.swift`, `MemoryStoreDedupTests.swift`, `MemoryStoreHubsTests.swift`, `MemoryTextTests.swift`, `MemoryConsolidationEngineTests.swift`, `MemoryStoreSleepTests.swift`; `Tests/MemoryServiceTests/ScheduleEndpointsTests.swift`, `ConsolidationEndpointsTests.swift`.

**`personal_agent` (app):**
- Modify `Gemma/Gemma/Memory/MemoryClient.swift` — send `timezone`.
- Modify `Gemma/Gemma/Harness/HarnessModel.swift:211` — (no change needed beyond client; client reads `TimeZone.current`).

---

## Task 1: `ScheduleTime` helper in MemoryCore

**Files:**
- Create: `memory-service/Sources/MemoryCore/ScheduleTime.swift`
- Test: `memory-service/Tests/MemoryCoreTests/ScheduleStoreTests.swift` (append)

- [ ] **Step 1: Write the failing test** — append to `ScheduleStoreTests.swift`:

```swift
func testScheduleTimeEpochLocalExact() {
    let ny = TimeZone(identifier: "America/New_York")!
    // 2026-06-09 06:00 local → exact, minute-aligned (no 06:13:20 UTC drift)
    let e = ScheduleTime.epoch(date: "2026-06-09", time: "06:00", tz: ny)!
    var cal = Calendar(identifier: .gregorian); cal.timeZone = ny
    let comps = cal.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: e))
    XCTAssertEqual(comps.hour, 6); XCTAssertEqual(comps.minute, 0); XCTAssertEqual(comps.second, 0)
}

func testScheduleTimeDateOnlyIsMidnight() {
    let ny = TimeZone(identifier: "America/New_York")!
    let e = ScheduleTime.epoch(date: "2026-06-09", time: nil, tz: ny)!
    var cal = Calendar(identifier: .gregorian); cal.timeZone = ny
    XCTAssertEqual(cal.dateComponents([.hour], from: Date(timeIntervalSince1970: e)).hour, 0)
}

func testScheduleTimeBadInputIsNil() {
    XCTAssertNil(ScheduleTime.epoch(date: "not-a-date", time: "06:00", tz: .current))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ScheduleStoreTests/testScheduleTimeEpochLocalExact`
Expected: FAIL — "cannot find 'ScheduleTime' in scope".

- [ ] **Step 3: Write minimal implementation** — create `ScheduleTime.swift`:

```swift
import Foundation

/// Deterministic conversion from a LOCAL wall-clock date/time (what the model emits as text) to
/// epoch seconds, in the user's timezone. The model never computes epochs; this does it exactly.
/// Mirror of the macOS app's `ScheduleTime` (kept separate per-target, same semantics).
public enum ScheduleTime {
    /// `date` = "yyyy-MM-dd"; `time` = "HH:mm" (24h) or nil → midnight. Returns nil on bad input.
    public static func epoch(date: String, time: String?, tz: TimeZone) -> Double? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        if let time, !time.isEmpty {
            f.dateFormat = "yyyy-MM-dd HH:mm"
            if let d = f.date(from: "\(date) \(time)") { return d.timeIntervalSince1970 }
        }
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: date)?.timeIntervalSince1970
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ScheduleStoreTests`
Expected: PASS (all three new tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MemoryCore/ScheduleTime.swift Tests/MemoryCoreTests/ScheduleStoreTests.swift
git commit -m "feat(consolidation): deterministic local date/time->epoch helper (MemoryCore.ScheduleTime)"
```

---

## Task 2: `createEventChecked` — single conflict-checked event-creation path

**Files:**
- Modify: `memory-service/Sources/MemoryCore/MemoryStore+Schedule.swift`
- Test: `memory-service/Tests/MemoryCoreTests/ScheduleStoreTests.swift` (append)

- [ ] **Step 1: Write the failing test**:

```swift
func testCreateEventCheckedBlocksOnConflict() throws {
    let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
    _ = try store.upsertEvent(title: "Trip", start: 1000, end: 5000, allDay: true,
                              location: "Varadero", origin: .explicit)
    let r = try store.createEventChecked(title: "Meeting", start: 2000, end: 3000, allDay: false,
                                         location: "Miami", origin: .explicit, force: false)
    XCTAssertNil(r.id)
    XCTAssertEqual(r.conflicts.map(\.label), ["Trip"])
    XCTAssertEqual(try store.scheduleWindow(from: 0, to: 9999).count, 1) // meeting NOT written
}

func testCreateEventCheckedForceWritesAndReturnsConflicts() throws {
    let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
    _ = try store.upsertEvent(title: "Trip", start: 1000, end: 5000, allDay: true,
                              location: "Varadero", origin: .explicit)
    let r = try store.createEventChecked(title: "Meeting", start: 2000, end: 3000, allDay: false,
                                         location: "Miami", origin: .explicit, force: true)
    XCTAssertNotNil(r.id)
    XCTAssertEqual(r.conflicts.map(\.label), ["Trip"])
    XCTAssertEqual(try store.scheduleWindow(from: 0, to: 9999).count, 2)
}

func testCreateEventCheckedNoConflictWrites() throws {
    let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
    let r = try store.createEventChecked(title: "Solo", start: 2000, end: 3000, allDay: false,
                                         location: nil, origin: .explicit, force: false)
    XCTAssertNotNil(r.id); XCTAssertTrue(r.conflicts.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ScheduleStoreTests/testCreateEventCheckedBlocksOnConflict`
Expected: FAIL — "value of type 'MemoryStore' has no member 'createEventChecked'".

- [ ] **Step 3: Write minimal implementation** — add to the `extension MemoryStore` in `MemoryStore+Schedule.swift` (after `scheduleConflicts`):

```swift
/// The ONLY supported way to create an event. Always runs scheduleConflicts.
/// Returns (id, conflicts) on create; (nil, conflicts) when blocked by a conflict and !force.
@discardableResult
public func createEventChecked(title: String, start: Double, end: Double, allDay: Bool,
                               location: String?, origin: Origin, force: Bool)
    throws -> (id: String?, conflicts: [Node]) {
    let conflicts = try scheduleConflicts(start: start, end: end)
    if !conflicts.isEmpty && !force { return (nil, conflicts) }
    let id = try upsertEvent(title: title, start: start, end: end,
                             allDay: allDay, location: location, origin: origin)
    return (id, conflicts)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ScheduleStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MemoryCore/MemoryStore+Schedule.swift Tests/MemoryCoreTests/ScheduleStoreTests.swift
git commit -m "feat(consolidation): createEventChecked — single conflict-checked event path"
```

---

## Task 3: Rewrite `/schedule/create` handler on `createEventChecked`

**Files:**
- Modify: `memory-service/Sources/MemoryService/Handlers/ScheduleHandlers.swift` (`create`)
- Test: `memory-service/Tests/MemoryServiceTests/ScheduleEndpointsTests.swift` (verify existing pass; behavior preserved)

- [ ] **Step 1: Run the existing endpoint tests to capture the current green baseline**

Run: `swift test --filter ScheduleEndpointsTests`
Expected: PASS (record which tests exist; behavior must stay identical).

- [ ] **Step 2: Replace the body of `create`** in `ScheduleHandlers.swift` with:

```swift
@Sendable func create(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
    guard let b = await body(req, CreateBody.self) else {
        return jsonError(.badRequest, "bad_request", "title/start/end required")
    }
    let origin: Origin = (b.origin == "extracted") ? .extracted : .explicit
    let result: (id: String?, conflicts: [Node])
    do {
        result = try services.store.createEventChecked(title: b.title, start: b.start, end: b.end,
                                                       allDay: b.allDay ?? false, location: b.location,
                                                       origin: origin, force: b.force == true)
    } catch { return jsonError(.internalServerError, "store_error", "\(error)") }
    if let id = result.id {
        return json(["created": true, "id": id, "conflicts": result.conflicts.map(eventJSON)])
    }
    return json(["created": false, "conflicts": result.conflicts.map(eventJSON)])
}
```

- [ ] **Step 3: Run tests to verify identical behavior**

Run: `swift test --filter ScheduleEndpointsTests`
Expected: PASS (same as baseline — created:false+conflicts when conflicting, created:true otherwise).

- [ ] **Step 4: Commit**

```bash
git add Sources/MemoryService/Handlers/ScheduleHandlers.swift
git commit -m "refactor(schedule): /schedule/create routes through createEventChecked (behavior preserved)"
```

---

## Task 4: Thread the user's timezone into consolidation

**Files:**
- Modify: `memory-service/Sources/MemoryCore/ConsolidationScheduler.swift` (protocol, `armTurnEnd`, `runReflectAdHoc`, `launch`, stored tz)
- Modify: `memory-service/Sources/MemoryCore/MemoryConsolidationEngine.swift` (`currentTimeZone`, `runCycle`/`runLight` signatures, `todayString`)
- Modify: `memory-service/Sources/MemoryService/Handlers/ConsolidationHandlers.swift` (decode `timezone`)
- Test: `memory-service/Tests/MemoryServiceTests/ConsolidationEndpointsTests.swift` (append)

- [ ] **Step 1: Write the failing test** — append to `ConsolidationEndpointsTests.swift` a test that turn-end with a `timezone` is accepted and recorded. (Adapt to the file's existing app/harness setup — the existing tests already build a test `App`/router; reuse that helper.)

```swift
func testTurnEndAcceptsTimezone() async throws {
    // Uses the file's existing `makeApp()`/router test helper (see other tests here).
    let app = try makeTestApp()
    let res = try await app.executeRequest(
        uri: "/v1/consolidation/turn-end", method: .post,
        headers: authHeaders(app),
        body: ByteBuffer(string: #"{"threadId":"t1","timezone":"America/New_York"}"#))
    XCTAssertEqual(res.status, .ok)
    let tz = await app.services.scheduler.lastTimeZone
    XCTAssertEqual(tz.identifier, "America/New_York")
}
```

> If the file's existing helper names differ, mirror an existing test in this file for app construction, auth headers, and request execution — do not invent new infrastructure.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConsolidationEndpointsTests/testTurnEndAcceptsTimezone`
Expected: FAIL — `lastTimeZone` missing and/or `timezone` ignored.

- [ ] **Step 3a: Change the protocol + scheduler** in `ConsolidationScheduler.swift`.

Protocol:
```swift
public protocol ConsolidationRunning: AnyObject, Sendable {
    func runLight(isCancelled: @escaping () -> Bool, timeZone: TimeZone) async
    func runCycle(isCancelled: @escaping () -> Bool, timeZone: TimeZone) async
}
```

Add stored tz (near `lastTurnEndThread`):
```swift
/// Most recent timezone reported by the app (turn-end/reflect). Used for date resolution in
/// consolidation cycles that fire from timers or resume after restart. Defaults to the server tz.
public private(set) var lastTimeZone: TimeZone = .current
```

`armTurnEnd` gains the param:
```swift
public func armTurnEnd(threadId: String, timeZone: TimeZone = .current) {
    lastTurnEndThread = threadId
    lastTimeZone = timeZone
    noteTurnEnded()
}
```

`runReflectAdHoc` gains the param:
```swift
public func runReflectAdHoc(timeZone: TimeZone = .current) -> String? {
    guard isReady(), running == nil, !isUserBusy() else { return nil }
    lastTimeZone = timeZone
    let cycleId = "reflect-\(Int(Date().timeIntervalSince1970 * 1000))"
    launch(light: true)
    return cycleId
}
```

`launch` passes the stored tz to the runner:
```swift
private func launch(light: Bool) {
    guard isReady(), running == nil, !isUserBusy() else { return }
    cancelFlag.set(false)
    let isCancelled: @Sendable () -> Bool = { [cancelFlag] in cancelFlag.get() }
    let tz = lastTimeZone
    state = light ? .reflecting : .sleeping("nrem")
    running = Task { [weak self, runner] in
        if light { await runner.runLight(isCancelled: isCancelled, timeZone: tz) }
        else { await runner.runCycle(isCancelled: isCancelled, timeZone: tz) }
        await MainActor.run {
            guard let self else { return }
            self.running = nil
            if self.state != .idle { self.state = .done(light ? "reflecting" : "sleeping") }
        }
    }
}
```

- [ ] **Step 3b: Update the engine** in `MemoryConsolidationEngine.swift`.

Add stored tz (near `private let now`):
```swift
/// Timezone for the in-flight cycle (set by runCycle/runLight). Cycles are serialized by the
/// scheduler, so a single instance var is safe. Defaults to server tz for direct phase tests.
private var currentTimeZone: TimeZone = .current
```

`todayString` honors it:
```swift
private func todayString() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd (EEEE)"; f.timeZone = currentTimeZone
    return f.string(from: Date(timeIntervalSince1970: now()))
}
```

Change `runCycle`/`runLight` signatures to accept `timeZone` and set it first. At the top of `runCycle(isCancelled:)` change the declaration to `public func runCycle(isCancelled: @escaping () -> Bool, timeZone: TimeZone = .current) async {` and add `currentTimeZone = timeZone` as the first line. Do the same for `runLight`: `public func runLight(isCancelled: @escaping () -> Bool, timeZone: TimeZone = .current) async {` with `currentTimeZone = timeZone` first.

- [ ] **Step 3c: Decode `timezone` in the handlers** in `ConsolidationHandlers.swift`.

Replace `TurnEndBody` + `turnEnd`:
```swift
struct TurnEndBody: Decodable, Sendable { let threadId: String; let timezone: String? }

@Sendable func turnEnd(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
    let buf = (try? await req.body.collect(upTo: 4_000)) ?? ByteBuffer()
    guard let body = try? JSONDecoder().decode(TurnEndBody.self, from: Data(buf.readableBytesView)) else {
        return jsonError(.badRequest, "bad_request", "threadId required")
    }
    let tz = body.timezone.flatMap { TimeZone(identifier: $0) } ?? .current
    await services.scheduler.armTurnEnd(threadId: body.threadId, timeZone: tz)
    return Response(status: .ok, headers: [.contentType: "application/json"],
                    body: ResponseBody(byteBuffer: ByteBuffer(string: "{}")))
}
```

Replace `reflect` to read an optional `timezone` body:
```swift
struct ReflectBody: Decodable, Sendable { let timezone: String? }

@Sendable func reflect(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
    let buf = (try? await req.body.collect(upTo: 1_000)) ?? ByteBuffer()
    let tz = (try? JSONDecoder().decode(ReflectBody.self, from: Data(buf.readableBytesView)))?
        .timezone.flatMap { TimeZone(identifier: $0) } ?? .current
    let id = await services.scheduler.runReflectAdHoc(timeZone: tz) ?? ""
    let payload = #"{"cycleId":"\#(id)"}"#
    return Response(status: .ok, headers: [.contentType: "application/json"],
                    body: ResponseBody(byteBuffer: ByteBuffer(string: payload)))
}
```

- [ ] **Step 3d: Fix all `ConsolidationRunning` conformances/spies.** Search the test target for spies conforming to `ConsolidationRunning` (e.g. in `Tests/MemoryCoreTests/MemoryStoreSleepTests.swift` or a scheduler test) and update their `runLight`/`runCycle` to the new signature `(isCancelled:, timeZone:)`. The engine is already updated in 3b.

Run: `grep -rn "ConsolidationRunning\|func runCycle\|func runLight" Tests/` and fix each.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConsolidationEndpointsTests` then `swift test`
Expected: PASS (whole suite green — protocol change compiles everywhere).

- [ ] **Step 5: Commit**

```bash
git add Sources/MemoryCore/ConsolidationScheduler.swift Sources/MemoryCore/MemoryConsolidationEngine.swift Sources/MemoryService/Handlers/ConsolidationHandlers.swift Tests/
git commit -m "feat(consolidation): thread user timezone into cycles (turn-end/reflect -> scheduler -> engine)"
```

---

## Task 5: Consolidation events — deterministic epochs + conflict-checked creation + clarification

**Files:**
- Modify: `memory-service/Sources/MemoryCore/MemoryConsolidationEngine.swift` (`EntitiesOut.E.Attr`, `consolidate` prompt + event branch, new `emitConflictClarification`)
- Test: `memory-service/Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift` (append; uses the file's fake `ModelTextClient`)

- [ ] **Step 1: Write the failing tests** — append to `MemoryConsolidationEngineTests.swift`. Use the file's existing fake-runtime pattern (a `ModelTextClient` returning a canned JSON string).

```swift
func testConsolidateCleanEventUsesExactLocalEpoch() async throws {
    let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
    let json = #"{"entities":[{"entity":"Dentist","kind":"event","attributes":{"date":"2026-06-11","startTime":"09:00","endTime":"10:00","location":"Clinic"}}]}"#
    let engine = MemoryConsolidationEngine(store: store, embedder: nil,
                                           runtime: CannedClient(reply: json),
                                           transcriptStore: TranscriptStore(dbQueue: store.dbQueue))
    await engine.runCycle(isCancelled: { false }, timeZone: TimeZone(identifier: "America/New_York")!)
    // Re-run consolidate directly is also fine; here we assert the event exists at exact 09:00.
    let evs = try store.scheduleWindow(from: 0, to: 1e11)
    XCTAssertEqual(evs.count, 1)
    let a = NodeAttributes.from(evs[0].extra)
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
    XCTAssertEqual(cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: a.startAt!)).hour, 9)
    XCTAssertEqual(cal.dateComponents([.minute], from: Date(timeIntervalSince1970: a.startAt!)).minute, 0)
}

func testConsolidateConflictingEventEmitsClarificationNotEvent() async throws {
    let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
    // Pre-existing scheduled trip covering 2026-06-09 all day.
    let st = ScheduleTime.epoch(date: "2026-06-09", time: "06:00", tz: TimeZone(identifier: "America/New_York")!)!
    let en = ScheduleTime.epoch(date: "2026-06-13", time: "06:00", tz: TimeZone(identifier: "America/New_York")!)!
    _ = try store.upsertEvent(title: "Varadero trip", start: st, end: en, allDay: true, location: "Varadero", origin: .explicit)
    let json = #"{"entities":[{"entity":"Miami meeting","kind":"event","attributes":{"date":"2026-06-09","startTime":"08:00","endTime":"09:00","location":"Miami"}}]}"#
    let engine = MemoryConsolidationEngine(store: store, embedder: nil,
                                           runtime: CannedClient(reply: json),
                                           transcriptStore: TranscriptStore(dbQueue: store.dbQueue))
    await engine.consolidate(episodeTexts: ["User: meeting in Miami June 9 8am"])
    // No second event created (still just the trip).
    XCTAssertEqual(try store.scheduleWindow(from: 0, to: 1e11).count, 1)
    // One clarification node, linked to the trip via `clarifies`.
    let clar = try store.allNodes().filter { $0.kind == NodeKind.clarification.rawValue }
    XCTAssertEqual(clar.count, 1)
    let edges = try store.edges(from: clar[0].id).filter { $0.relation == .clarifies }
    XCTAssertEqual(edges.count, 1)
}
```

> If the file does not already define a canned `ModelTextClient`, add a minimal one in the test file:
> ```swift
> struct CannedClient: ModelTextClient {
>     let reply: String
>     func generate(prompt: String, options: ModelTextOptions) async throws -> String { reply }
> }
> ```
> (Match `ModelTextClient`'s actual requirements — check `Sources/MemoryCore/ModelTextClient.swift`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MemoryConsolidationEngineTests/testConsolidateConflictingEventEmitsClarificationNotEvent`
Expected: FAIL — model output `start/end` removed → no event path yet; clarification not emitted; or compile error on new `Attr` fields.

- [ ] **Step 3a: Update the `Attr` schema** in `EntitiesOut`:

```swift
private struct EntitiesOut: Decodable {
    struct E: Decodable { let entity: String; let kind: String?; let detail: String?; let permanent: Bool?
        struct Attr: Decodable { let status: String?; let horizon: String?; let date: String?
            let startTime: String?; let endTime: String?; let allDay: Bool?; let location: String? }
        let attributes: Attr? }
    let entities: [E]
}
```

- [ ] **Step 3b: Update the extraction prompt** in `consolidate` — replace the epoch line with local-text instructions and update the Schema line:

```swift
For appointments/meetings/trips (things with a time), put the LOCAL calendar date in attributes.date \
("yyyy-MM-dd"), the local start time in attributes.startTime ("HH:mm", 24-hour), and the end time in \
attributes.endTime ("HH:mm"). If only a start is given, omit endTime (1 hour is assumed). Set \
attributes.allDay true for all-day/multi-day events. NEVER output epoch numbers. If the event has a \
place (venue, address, city), fill attributes.location with a short place name only (not prose).
Schema: {"entities":[{"entity":"...","kind":"...","detail":"...","permanent":false,"attributes":{"status":"pending|done","horizon":"short|long","date":"yyyy-MM-dd","startTime":"HH:mm","endTime":"HH:mm","allDay":false,"location":"..."}}]}
```

- [ ] **Step 3c: Replace the event branch** at the top of the `for e in out.entities` loop:

```swift
// Structured event: a timed entity with a local date+time → first-class `event`, conflict-checked.
if let date = e.attributes?.date, let startTime = e.attributes?.startTime,
   let st = ScheduleTime.epoch(date: date, time: startTime, tz: currentTimeZone) {
    let en = e.attributes?.endTime.flatMap { ScheduleTime.epoch(date: date, time: $0, tz: currentTimeZone) } ?? (st + 3600)
    let evLabel = MemoryText.canonicalEntityLabel(e.entity)
    if !MemoryText.isJunkLabel(evLabel), en > st {
        let allDay = e.attributes?.allDay ?? false
        if let result = try? store.createEventChecked(title: evLabel, start: st, end: en, allDay: allDay,
                                                       location: e.attributes?.location, origin: .extracted, force: false) {
            if let evId = result.id {
                if let emb = (try? embedder?.embed(evLabel)) ?? nil { try? store.setEmbedding(nodeId: evId, emb) }
                added += 1
            } else {
                emitConflictClarification(title: evLabel, date: date, time: startTime, conflicts: result.conflicts)
            }
        }
    }
    continue
}
```

- [ ] **Step 3d: Add the clarification helper** as a private method on the engine (place it near `clarify()`):

```swift
/// A consolidated event collides with an existing one → don't create it; ask the user (reuses the
/// existing clarification surfacing). Dedups against existing clarification bodies.
private func emitConflictClarification(title: String, date: String, time: String, conflicts: [Node]) {
    let others = conflicts.map { $0.label }.joined(separator: ", ")
    let body = "Mencionaste «\(title)» el \(date) a las \(time), pero choca con \(others). ¿Lo agendo igual, lo reprogramo, o cancelo el otro?"
    let existing = Set(((try? store.allNodes()) ?? [])
        .filter { $0.kind == NodeKind.clarification.rawValue }.map { MemoryText.dedupKey($0.body) })
    if existing.contains(MemoryText.dedupKey(body)) { return }
    var attrs = NodeAttributes(); attrs.status = "pending"
    let t = now(); let id = UUID().uuidString
    let node = Node(id: id, kind: NodeKind.clarification.rawValue, label: String(body.prefix(60)),
                    body: body, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 4,
                    decayRate: Decay.defaultDecayRate(for: .daily), confidence: .probable, mentionCount: 1,
                    ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true,
                    deleted: false, extra: attrs.toJSON())
    try? store.upsert(node)
    for c in conflicts {
        try? store.upsert(Edge(id: UUID().uuidString, srcId: id, dstId: c.id, relation: .clarifies,
                               weight: 1, confidence: .probable, createdAt: t, updatedAt: t,
                               dirty: true, deleted: false, extra: nil))
    }
    onProgress?("+1 conflict question")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MemoryConsolidationEngineTests` then `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MemoryCore/MemoryConsolidationEngine.swift Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(consolidation): events use deterministic local epochs + createEventChecked + clarify on conflict"
```

---

## Task 6: `ensureKindHubs` self-heals mis-kinded hubs

**Files:**
- Modify: `memory-service/Sources/MemoryCore/MemoryStore+Hubs.swift` (`ensureKindHubs`)
- Test: `memory-service/Tests/MemoryCoreTests/MemoryStoreHubsTests.swift` (append)

- [ ] **Step 1: Write the failing test**:

```swift
func testEnsureKindHubsRepairsMisKindedHub() throws {
    let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
    try store.ensureKindHubs()
    // Corrupt: force the person hub to kind="place" (the production bug we observed).
    try store.dbQueue.write { db in
        try db.execute(sql: "UPDATE node SET kind = 'place' WHERE id = 'hub:person'")
    }
    _ = try store.ensureKindHubs()  // idempotent re-run must repair
    let hub = try store.node(id: "hub:person")
    XCTAssertEqual(hub?.kind, HubKind.hub.rawValue)
    // A place query must not surface the hub.
    let places = try store.allNodes().filter { $0.kind == NodeKind.place.rawValue }
    XCTAssertFalse(places.contains { $0.id == "hub:person" })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MemoryStoreHubsTests/testEnsureKindHubsRepairsMisKindedHub`
Expected: FAIL — hub stays `kind='place'` (create-if-missing only).

- [ ] **Step 3: Add the repair branch** in `ensureKindHubs`'s per-kind loop. Replace the `if existing == nil { … }` block with:

```swift
let existing = try Node.fetchOne(db, key: hubID)
if existing == nil {
    let hub = Node(id: hubID,
                   kind: HubKind.hub.rawValue,
                   label: kind.hubLabel,
                   body: "Hub for \(kind.hubLabel.lowercased()) — auto-managed.",
                   layer: .identity,
                   createdAt: now, updatedAt: now, lastSeenAt: now,
                   salience: 0, decayRate: 0, confidence: .sure,
                   mentionCount: 0, ttlExpiresAt: nil, sourceRef: nil,
                   origin: .explicit, serverId: nil, dirty: false, deleted: false,
                   extra: #"{"managesKind":"\#(kind.rawValue)","hub":true}"#)
    try hub.insert(db)
    created += 1
} else if existing!.kind != HubKind.hub.rawValue {
    // Self-heal: an older build created this hub with the wrong kind (e.g. "place").
    var fixed = existing!
    fixed.kind = HubKind.hub.rawValue
    fixed.dirty = false
    try fixed.update(db)
    // Remove any belongsToHub edge that wrongly treated this hub as a spoke node.
    try db.execute(sql: "DELETE FROM edge WHERE dstId = ? AND relation = ?",
                   arguments: [hubID, Relation.belongsToHub.rawValue])
    created += 1
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MemoryStoreHubsTests` then `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MemoryCore/MemoryStore+Hubs.swift Tests/MemoryCoreTests/MemoryStoreHubsTests.swift
git commit -m "fix(hubs): ensureKindHubs self-heals hubs mis-kinded as place (idempotent on startup)"
```

---

## Task 7: Reserved-word junk guard at extraction

**Files:**
- Modify: `memory-service/Sources/MemoryCore/MemoryText.swift` (`isJunkLabel`)
- Test: `memory-service/Tests/MemoryCoreTests/MemoryTextTests.swift` (append)

- [ ] **Step 1: Write the failing test**:

```swift
func testIsJunkLabelRejectsCategoryWords() {
    // NodeKind rawValues and hub labels must never become entities.
    XCTAssertTrue(MemoryText.isJunkLabel("People"))
    XCTAssertTrue(MemoryText.isJunkLabel("place"))
    XCTAssertTrue(MemoryText.isJunkLabel("Conversations"))
    XCTAssertTrue(MemoryText.isJunkLabel("Tasks"))
    // Real names still pass.
    XCTAssertFalse(MemoryText.isJunkLabel("Roilan"))
    XCTAssertFalse(MemoryText.isJunkLabel("Varadero"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MemoryTextTests/testIsJunkLabelRejectsCategoryWords`
Expected: FAIL — "People"/"Tasks" currently accepted.

- [ ] **Step 3: Extend `isJunkLabel`** in `MemoryText.swift`:

```swift
public static func isJunkLabel(_ raw: String) -> Bool {
    let k = dedupKey(raw)
    if k.isEmpty { return true }
    let junk: Set<String> = [
        "me gusta", "me gustan", "le gusta", "i like", "like", "likes", "gusta",
        "preferences", "preferencias", "preference", "stuff", "things", "cosas",
        "it", "that", "this", "eso", "esto", "user", "usuario"
    ]
    if junk.contains(k) { return true }
    // Reserved: NodeKind raw values and their hub labels are categories, never entities.
    let reserved = Set(NodeKind.allCases.map { $0.rawValue.lowercased() }
                     + NodeKind.allCases.map { $0.hubLabel.lowercased() })
    return reserved.contains(k)
}
```

> `dedupKey` lowercases, so compare against lowercased reserved words.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MemoryTextTests` then `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MemoryCore/MemoryText.swift Tests/MemoryCoreTests/MemoryTextTests.swift
git commit -m "fix(consolidation): reject NodeKind/hub category words as junk entity labels"
```

---

## Task 8: `compress` sleep phase — deduplicate insights

**Files:**
- Modify: `memory-service/Sources/MemoryCore/MemoryStore+Vector.swift` (expose `cosineDistance`)
- Modify: `memory-service/Sources/MemoryCore/MemoryStore+Dedup.swift` (`compressInsights`)
- Modify: `memory-service/Sources/MemoryCore/MemoryStore.swift` (`SleepPhase` add `.compress`)
- Modify: `memory-service/Sources/MemoryCore/MemoryConsolidationEngine.swift` (`compress()` + cycle order)
- Test: `memory-service/Tests/MemoryCoreTests/MemoryStoreDedupTests.swift` (append)

- [ ] **Step 1: Write the failing test**:

```swift
func testCompressInsightsMergesNearDuplicates() throws {
    let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
    // Two near-identical + one distinct insight, each with an embedding.
    func ins(_ id: String, _ label: String, _ vec: [Float], salience: Double) throws {
        let n = Node(id: id, kind: NodeKind.insight.rawValue, label: label, body: label, layer: .daily,
                     createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: salience, decayRate: 0,
                     confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                     origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        try store.upsert(n); try store.setEmbedding(nodeId: id, vec)
    }
    var a = [Float](repeating: 0, count: 1024); a[0] = 1
    var aPrime = [Float](repeating: 0, count: 1024); aPrime[0] = 0.999; aPrime[1] = 0.044 // ~identical
    var b = [Float](repeating: 0, count: 1024); b[500] = 1                                 // distinct
    try ins("i1", "manages appointments", a, salience: 5)
    try ins("i2", "uses the assistant for schedule management", aPrime, salience: 3)
    try ins("i3", "likes sushi", b, salience: 4)

    let merged = try store.compressInsights(embedder: nil, threshold: 0.15)
    XCTAssertEqual(merged, 1)
    let live = try store.allNodes().filter { $0.kind == NodeKind.insight.rawValue }
    XCTAssertEqual(live.count, 2)                                   // i1 (canonical) + i3
    XCTAssertTrue(live.contains { $0.id == "i1" && $0.mentionCount == 2 })
    XCTAssertNil(live.first { $0.id == "i2" })                      // soft-deleted
    // sameAs edge i2 -> i1
    XCTAssertTrue(try store.edges(from: "i2").contains { $0.relation == .sameAs && $0.dstId == "i1" })
    // idempotent: second run merges nothing
    XCTAssertEqual(try store.compressInsights(embedder: nil, threshold: 0.15), 0)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MemoryStoreDedupTests/testCompressInsightsMergesNearDuplicates`
Expected: FAIL — `compressInsights` and `cosineDistance` missing.

- [ ] **Step 3a: Expose a reusable cosine** — add to the `extension MemoryStore` in `MemoryStore+Vector.swift`:

```swift
/// Cosine distance (1 - cosine) between two equal-length vectors. 2.0 if mismatched/zero.
public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 2 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    let denom = Double(sqrt(na)) * Double(sqrt(nb))
    return denom > 0 ? 1.0 - Double(dot) / denom : 2.0
}
```

- [ ] **Step 3b: Add `compressInsights`** to the `extension MemoryStore` in `MemoryStore+Dedup.swift`:

```swift
/// Sweep existing insight nodes and merge near-duplicates (cosine distance <= threshold).
/// Keeps the highest-salience node as canonical, sums mentionCount, soft-deletes the rest with a
/// `sameAs` edge to the canonical. Non-destructive. Idempotent. Returns the number merged.
@discardableResult
public func compressInsights(embedder: Embedder?, threshold: Double = 0.15) throws -> Int {
    let insights = try allNodes()
        .filter { $0.kind == NodeKind.insight.rawValue }
        .sorted { ($0.salience, $0.mentionCount) > ($1.salience, $1.mentionCount) }
    var kept: [(id: String, emb: [Float])] = []
    var merged = 0
    let t = Date().timeIntervalSince1970
    for n in insights {
        guard let emb = try embeddingFor(nodeId: n.id, label: n.label, embedder: embedder) else {
            continue  // can't compare without a vector; leave it
        }
        if let hit = kept.first(where: { Self.cosineDistance($0.emb, emb) <= threshold }) {
            if var canon = try node(id: hit.id) {
                canon.mentionCount += n.mentionCount
                canon.salience = max(canon.salience, n.salience)
                canon.updatedAt = t; canon.dirty = true
                try upsert(canon)
            }
            try softDelete(nodeId: n.id)
            try upsert(Edge(id: UUID().uuidString, srcId: n.id, dstId: hit.id, relation: .sameAs,
                            weight: 1, confidence: .probable, createdAt: t, updatedAt: t,
                            dirty: true, deleted: false, extra: nil))
            merged += 1
        } else {
            try setEmbedding(nodeId: n.id, emb)
            kept.append((n.id, emb))
        }
    }
    return merged
}

/// Stored embedding for a node, else freshly embedded from its label, else nil.
private func embeddingFor(nodeId: String, label: String, embedder: Embedder?) throws -> [Float]? {
    let stored: Data? = try dbQueue.read { db in
        try Row.fetchOne(db, sql: "SELECT embedding FROM node_embedding WHERE node_id = ?", arguments: [nodeId])?
            ["embedding"] as Data?
    }
    if let stored { return Self.blobToFloats(stored) }
    return try embedder?.embed(label)
}
```

- [ ] **Step 3c: Add the phase enum case** in `MemoryStore.swift` line 4:

```swift
public enum SleepPhase: String, Codable, CaseIterable, Sendable { case nrem, summarize, detect, rem, reflect, compress, clarify, curate, shy }
```

- [ ] **Step 3d: Wire the phase into the engine** in `MemoryConsolidationEngine.swift`.

Add the phase method near `clarify()`:
```swift
// MARK: Compress — merge near-duplicate insights into one canonical node
public func compress() async {
    let n = (try? store.compressInsights(embedder: embedder)) ?? 0
    if n > 0 { onProgress?("-\(n) duplicate insight\(n == 1 ? "" : "s")") }
}
```

Update the cycle order and switch in `runCycle`:
```swift
let order: [SleepPhase] = [.nrem, .summarize, .detect, .rem, .reflect, .compress, .clarify, .curate, .shy]
```
and add the case in the `switch phase` block (after `.reflect`):
```swift
case .compress: await compress()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MemoryStoreDedupTests` then `swift test`
Expected: PASS (the new `.compress` case in the persisted-resume `order` does not break existing sleep tests; old `sleep_cycle` rows with prior phases still decode).

- [ ] **Step 5: Commit**

```bash
git add Sources/MemoryCore/MemoryStore+Vector.swift Sources/MemoryCore/MemoryStore+Dedup.swift Sources/MemoryCore/MemoryStore.swift Sources/MemoryCore/MemoryConsolidationEngine.swift Tests/MemoryCoreTests/MemoryStoreDedupTests.swift
git commit -m "feat(consolidation): compress phase — dedup near-duplicate insights (non-destructive)"
```

---

## Task 9: App sends the user's timezone on consolidation triggers

**Files:**
- Modify: `personal_agent/Gemma/Gemma/Memory/MemoryClient.swift` (`consolidationTurnEnd`, `reflect`)
- Test: `personal_agent/Gemma/GemmaTests/` (add a small encode test if a MemoryClient test target exists; otherwise rely on the server endpoint test from Task 4)

- [ ] **Step 1: Update `consolidationTurnEnd`** in `MemoryClient.swift`:

```swift
func consolidationTurnEnd(threadId: String) async throws {
    struct B: Encodable { let threadId: String; let timezone: String }
    let _: EmptyOK = try await post("/v1/consolidation/turn-end",
                                    B(threadId: threadId, timezone: TimeZone.current.identifier))
}
```

- [ ] **Step 2: Update `reflect`** in `MemoryClient.swift` to send the timezone:

```swift
func reflect() async throws -> String? {
    struct B: Encodable { let timezone: String }
    struct R: Decodable { let cycleId: String }
    let r: R = try await post("/v1/consolidation/reflect", B(timezone: TimeZone.current.identifier))
    return r.cycleId.isEmpty ? nil : r.cycleId
}
```

- [ ] **Step 3: Build + test the app**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS'`
Expected: "Test Suite … passed" (no behavioral regression; the server tolerates the new field).

- [ ] **Step 4: Commit**

```bash
git add Gemma/Gemma/Memory/MemoryClient.swift
git commit -m "feat(app): send local timezone on consolidation turn-end/reflect"
```

---

## Task 10: Rebuild + redeploy the i3 memory service, verify the hub repair

**Files:** none (deploy + verification).

- [ ] **Step 1: Deploy the new server image to the i3**

Run (on the i3 / against its compose project):
```bash
ssh HomeLab 'cd ~/Projects/gemma-memory && git pull && docker compose build memory && docker compose up -d memory'
```
Expected: image rebuilds, `gemma-memory-memory-1` restarts healthy.

- [ ] **Step 2: Verify hubs are repaired** (self-heal ran at startup)

Run:
```bash
scp HomeLab:/home/hashdown/Projects/gemma-memory/docker-data/memory/memory.sqlite /tmp/i3_verify.sqlite
sqlite3 /tmp/i3_verify.sqlite "SELECT kind, count(*) FROM node WHERE id LIKE 'hub:%' GROUP BY kind;"
```
Expected: a single row `hub|16` (every hub now `kind='hub'`); **no** `place` hubs.

- [ ] **Step 3: Verify no hub leaks into the place category**

Run:
```bash
sqlite3 /tmp/i3_verify.sqlite "SELECT count(*) FROM node WHERE kind='place' AND id LIKE 'hub:%';"
```
Expected: `0`.

- [ ] **Step 4: Manual E2E re-test (the original failing scenario)**

In the macOS app chat (fresh thread): "agéndame un viaje a Varadero 5 días desde el 9 a las 6am", then "agéndame una reunión el 9 de junio a las 8am en Miami". Expected: the meeting create is conflict-blocked (or, if mentioned in passing and only consolidated, a clarification surfaces) — the agent does NOT silently double-book. Then ask "¿qué tengo la próxima semana?" → both events listed.

- [ ] **Step 5: Commit (docs only, if any notes captured)** — no code commit; record the verification result in the session/memory.

---

## Self-Review

**Spec coverage:**
- §4.1 unified conflict-checked creation → Tasks 2, 3 (store + handler), 5 (consolidation path + clarification). ✓
- §4.2 deterministic epochs + tz from app → Tasks 1 (ScheduleTime), 4 (tz threading), 5 (prompt + Attr + conversion), 9 (app sends tz). ✓
- §4.3 hub self-heal + redeploy + junk guard → Tasks 6 (self-heal), 10 (redeploy), 7 (junk guard). ✓
- §4.4 compress phase → Task 8. ✓
- §5 API changes → Tasks 4 (server bodies), 9 (app). `now` consciously dropped (see header deviation note). ✓
- §7 testing → unit + endpoint + engine tests across Tasks 1-9. ✓
- §8 deployment → Task 10. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; test code is concrete. The only soft references ("reuse the file's existing test helper" in Tasks 4 & 5) are explicit instructions to mirror existing patterns rather than invent infra — acceptable because the exact helper names live in those test files and must be matched, not guessed.

**Type consistency:** `createEventChecked` signature identical in Tasks 2, 3, 5. `ScheduleTime.epoch(date:time:tz:)` identical in Tasks 1, 5. `compressInsights(embedder:threshold:)` and `cosineDistance` consistent in Task 8. `runCycle/runLight(isCancelled:timeZone:)` consistent across Tasks 4, 5 and the engine. `armTurnEnd(threadId:timeZone:)` consistent in Tasks 4. `TurnEndBody{threadId,timezone}` matches the app `B{threadId,timezone}` in Task 9.
