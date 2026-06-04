# Recent-Turns Recall + Debounced Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make recent un-consolidated turns from other threads part of the semantic recall (so cross-chat context is available before consolidation), and run consolidation once per conversation burst (debounced, only when new data) to save cloud tokens.

**Architecture:** Server-heavy (`gemma-memory`) + small app change (`personal_agent`). Transcript turns get embedded at append into a new `transcript_embedding` table; recall does an extra vector search over recent un-consolidated turns (other threads); the consolidation scheduler replaces recurring pause/idle timers with a single 45s debounce; the app passes the current thread id and renders the returned recent turns.

**Tech Stack:** Swift 6 — server (SwiftPM, Hummingbird, GRDB), app (SwiftUI, Xcode). Spec: `docs/superpowers/specs/2026-06-04-recent-turns-recall-cloud-efficiency-design.md`.

**Server tests:** `swift test --filter <Name>` in `personal_agent/gemma-memory/memory-service` (dev clone, on `main`).
**App tests:** `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -40` in `personal_agent`.
**Known pre-existing app failure to IGNORE:** `HarnessModelTests.test_defaultBaseURL_isLocalhost8081`.
**Reuse:** `MemoryStore.cosineDistance(_:_:)`, `floatsToBlob`/`blobToFloats`, `embeddingDim` already exist in `MemoryStore+Vector.swift`.

---

## File Structure

**Server (`gemma-memory/memory-service/Sources/`):**
- `MemoryCore/MemoryStore.swift` — `v7-transcript-embedding` migration.
- `MemoryCore/MemoryStore+Vector.swift` — `setTranscriptEmbedding`/`nearestTranscript`/`deleteTranscriptEmbeddings`.
- `MemoryCore/TranscriptStore.swift` — `append` returns id; `markConsolidated` deletes embeddings.
- `MemoryService/Handlers/TranscriptHandlers.swift` — embed at append.
- `MemoryCore/ConsolidationScheduler.swift` — debounce single cycle.
- `MemoryCore/MemoryRetriever.swift` — `retrieve(queryVector:)`.
- `MemoryService/Handlers/MemoryHandlers.swift` — recall recent-turns + `threadId` + `recentTurns`.

**App (`personal_agent/Gemma/Gemma/`):**
- `Memory/MemoryClient.swift` — `recall(threadId:)` + `RecallBundle.recentTurns` + `injectionBlock`.
- `Harness/HarnessModel.swift` — pass current thread id to recall.

---

# PART A — SERVER

## Task 1: `transcript_embedding` table + store methods + `append` returns id

**Files:** `MemoryStore.swift`, `MemoryStore+Vector.swift`, `TranscriptStore.swift`; Test: `Tests/MemoryCoreTests/TranscriptEmbeddingTests.swift` (create).

- [ ] **Step 1: Migration.** In `MemoryStore.swift` `migrator`, after `v6-service-config`:
```swift
m.registerMigration("v7-transcript-embedding") { db in
    try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS transcript_embedding (
            turn_id TEXT PRIMARY KEY NOT NULL,
            embedding BLOB NOT NULL
        )
        """)
}
```

- [ ] **Step 2: Failing test** — `Tests/MemoryCoreTests/TranscriptEmbeddingTests.swift`:
```swift
import XCTest
import GRDB
@testable import MemoryCore

final class TranscriptEmbeddingTests: XCTestCase {
    private func vec(_ i: Int) -> [Float] { var v = [Float](repeating: 0, count: 1024); v[i] = 1; return v }

    func test_set_nearest_delete_roundTrip() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        try store.setTranscriptEmbedding(turnId: "a", vec(0))
        try store.setTranscriptEmbedding(turnId: "b", vec(500))
        let hits = try store.nearestTranscript(to: vec(0), k: 2)
        XCTAssertEqual(hits.first?.turnId, "a")
        try store.deleteTranscriptEmbeddings(turnIds: ["a"])
        XCTAssertEqual(try store.nearestTranscript(to: vec(0), k: 2).first?.turnId, "b")
    }

    func test_append_returns_id_and_markConsolidated_deletes_embedding() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let t = TranscriptStore(dbQueue: store.dbQueue)
        let id = try t.append(threadId: "x", turnIndex: 0, role: "user", text: "hola")
        try store.setTranscriptEmbedding(turnId: id, vec(1))
        XCTAssertEqual(try store.nearestTranscript(to: vec(1), k: 1).first?.turnId, id)
        try t.markConsolidated(ids: [id])
        XCTAssertTrue(try store.nearestTranscript(to: vec(1), k: 1).isEmpty)
    }
}
```

- [ ] **Step 3: Run → FAIL** (`setTranscriptEmbedding` missing): `swift test --filter TranscriptEmbeddingTests`.

- [ ] **Step 4a: Vector methods.** In `MemoryStore+Vector.swift` `extension MemoryStore`:
```swift
public func setTranscriptEmbedding(turnId: String, _ vector: [Float]) throws {
    precondition(vector.count == embeddingDim, "embedding dim mismatch")
    try dbQueue.write { db in
        try db.execute(sql: "INSERT OR REPLACE INTO transcript_embedding(turn_id, embedding) VALUES (?, ?)",
                       arguments: [turnId, Self.floatsToBlob(vector)])
    }
}

/// KNN over recent transcript-turn embeddings. distance = 1 - cosine, ascending.
public func nearestTranscript(to vector: [Float], k: Int) throws -> [(turnId: String, distance: Double)] {
    let rows: [(String, [Float])] = try dbQueue.read { db in
        try Row.fetchAll(db, sql: "SELECT turn_id, embedding FROM transcript_embedding")
            .map { ($0["turn_id"] as String, Self.blobToFloats($0["embedding"] as Data)) }
    }
    return rows.map { (turnId: $0.0, distance: Self.cosineDistance($0.1, vector)) }
        .sorted { $0.distance < $1.distance }
        .prefix(k).map { $0 }
}

public func deleteTranscriptEmbeddings(turnIds: [String]) throws {
    guard !turnIds.isEmpty else { return }
    try dbQueue.write { db in
        let ph = turnIds.map { _ in "?" }.joined(separator: ",")
        try db.execute(sql: "DELETE FROM transcript_embedding WHERE turn_id IN (\(ph))",
                       arguments: StatementArguments(turnIds))
    }
}
```
> Confirm `floatsToBlob`, `blobToFloats`, `cosineDistance`, `embeddingDim` exist in this file (they do). If `Self.floatsToBlob` is named differently, match the one `setEmbedding` uses.

- [ ] **Step 4b: `append` returns id.** In `TranscriptStore.swift`, change `append` to:
```swift
@discardableResult
public func append(threadId: String, turnIndex: Int, role: String, text: String,
                   now: Double = Date().timeIntervalSince1970) throws -> String {
    let id = UUID().uuidString
    let row = TranscriptRow(id: id, threadId: threadId, turnIndex: turnIndex,
                            role: role, text: text, createdAt: now, consolidated: false)
    try dbQueue.write { try row.insert($0) }
    return id
}
```

- [ ] **Step 4c: `markConsolidated` deletes embeddings.** In `TranscriptStore.swift`:
```swift
public func markConsolidated(ids: [String]) throws {
    guard !ids.isEmpty else { return }
    try dbQueue.write { db in
        try TranscriptRow.filter(ids.contains(Column("id")))
            .updateAll(db, Column("consolidated").set(to: true))
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        try db.execute(sql: "DELETE FROM transcript_embedding WHERE turn_id IN (\(ph))",
                       arguments: StatementArguments(ids))
    }
}
```

- [ ] **Step 5: Run → PASS** + `swift test` (whole suite green; existing `append` call sites still compile — `@discardableResult` keeps them valid).

- [ ] **Step 6: Commit**
```bash
git add Sources/MemoryCore/MemoryStore.swift Sources/MemoryCore/MemoryStore+Vector.swift Sources/MemoryCore/TranscriptStore.swift Tests/MemoryCoreTests/TranscriptEmbeddingTests.swift
git commit -m "feat(recall): transcript_embedding table + store methods; append returns id; cleanup on consolidate"
```

---

## Task 2: Embed turns at append (handler)

**Files:** `MemoryService/Handlers/TranscriptHandlers.swift`; Test: `Tests/MemoryServiceTests/TranscriptEndpointsTests.swift` (append).

- [ ] **Step 1: Failing test** — append (mirror the file's existing app/auth helpers):
```swift
func test_append_embeds_turn_for_recall() async throws {
    let app = try makeTestApp()   // mirror sibling tests' setup; embedder must be a real/fake non-nil Embedder
    _ = try await app.executeRequest(uri: "/v1/transcript/append", method: .post, headers: authHeaders(app),
        body: ByteBuffer(string: #"{"threadId":"t","role":"user","text":"voy a Varadero","turnIndex":0}"#))
    // The embedding exists → nearestTranscript finds the turn.
    let qv = try app.services.embedder.embed("Varadero")
    let hits = try app.services.store.nearestTranscript(to: qv, k: 1)
    XCTAssertEqual(hits.count, 1)
}
```
> Use the same `Services`/`buildApp` + `FakeEmbedder` the sibling endpoint tests use (a `FakeEmbedder` that returns deterministic vectors is fine — the test only checks a row was embedded+stored).

- [ ] **Step 2: Run → FAIL** (no embedding stored yet).

- [ ] **Step 3:** In `TranscriptHandlers.append`, capture the id and embed:
```swift
let id = try services.transcript.append(threadId: body.threadId, turnIndex: body.turnIndex,
                                        role: body.role, text: body.text,
                                        now: Date().timeIntervalSince1970)
if let vec = try? services.embedder.embed(body.text) {
    try? services.store.setTranscriptEmbedding(turnId: id, vec)
}
```
(`services.embedder` and `services.store` are already on `Services`.)

- [ ] **Step 4: Run → PASS** + `swift test`.

- [ ] **Step 5: Commit**
```bash
git add Sources/MemoryService/Handlers/TranscriptHandlers.swift Tests/MemoryServiceTests/TranscriptEndpointsTests.swift
git commit -m "feat(recall): embed each turn at append (best-effort) for recent-turn recall"
```

---

## Task 3: Debounced single-cycle consolidation scheduler

**Files:** `MemoryCore/ConsolidationScheduler.swift`; Test: update its existing tests (find them — `grep -rl ConsolidationScheduler Tests/`).

- [ ] **Step 0: Read** `ConsolidationScheduler.swift` (`pauseInterval`/`idleInterval`, `pauseTask`/`idleTask`, `scheduleTimers()`, `noteTurnEnded()`, `noteUserActivity()`, `launch(_:)`) and its test file.

- [ ] **Step 1: Failing test** — in the scheduler test file, add (use a short debounce + the existing spy runner):
```swift
@MainActor
func test_debounce_runs_single_full_cycle_and_resets() async throws {
    let spy = SpyRunner()   // existing ConsolidationRunning spy in this test file
    let sched = ConsolidationScheduler(runner: spy, isReady: { true }, hasPendingCycle: { false },
                                       debounceInterval: .milliseconds(80))
    sched.armTurnEnd(threadId: "a")
    try await Task.sleep(for: .milliseconds(40))
    sched.armTurnEnd(threadId: "a")            // resets the debounce
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(spy.fullCycles, 0)          // not yet (was reset)
    try await Task.sleep(for: .milliseconds: 80)
    XCTAssertEqual(spy.fullCycles, 1)          // one cycle after quiet
    XCTAssertEqual(spy.lightCycles, 0)         // no recurring light reflection
}
```
> Adapt to the spy's actual counter names (`runCycle`/`runLight` call counts). If the spy doesn't exist, add a minimal `ConsolidationRunning` spy that counts `runCycle`/`runLight` calls. The init gains a `debounceInterval` param — see Step 3.

- [ ] **Step 2: Run → FAIL** (`debounceInterval` param missing).

- [ ] **Step 3: Rewrite the timers.** In `ConsolidationScheduler`:
- Replace the stored `pauseInterval`/`idleInterval` + `pauseTask`/`idleTask` with:
```swift
private let debounceInterval: Duration
private var debounceTask: Task<Void, Never>?
```
- Init: replace the `pauseInterval`/`idleInterval` params with `debounceInterval: Duration = .seconds(45)` and store it.
- `noteTurnEnded()`:
```swift
public func noteTurnEnded() {
    debounceTask?.cancel()
    debounceTask = Task { [weak self, debounceInterval] in
        try? await Task.sleep(for: debounceInterval)
        guard let self, !Task.isCancelled else { return }
        // One full cycle after the user goes quiet. runCycle() no-ops if there's no new data;
        // hasPendingCycle resumes an interrupted cycle.
        self.launch(light: false)
    }
}
```
- `noteUserActivity()`: cancel `debounceTask` (in addition to `running?.cancel()` etc.) and drop references to `pauseTask`/`idleTask`.
- Delete `scheduleTimers()` and all `pauseTask`/`idleTask` references. Keep `launch`, `consolidateNow()`, `requestLightReflection()`, `runReflectAdHoc()`, `armTurnEnd`.

- [ ] **Step 4: Update `App.swift` construction** if it passed `pauseInterval`/`idleInterval` (`grep -n "ConsolidationScheduler(" Sources/MemoryService/App.swift`). Use the default (or pass `debounceInterval:`). Remove now-invalid args.

- [ ] **Step 5: Run** the scheduler tests → PASS, then `swift test`. Old tests that asserted pause/idle behavior must be updated to the debounce model (rename/rewrite to assert the single-cycle behavior — do not leave them asserting removed timers).

- [ ] **Step 6: Commit**
```bash
git add Sources/MemoryCore/ConsolidationScheduler.swift Sources/MemoryService/App.swift Tests/
git commit -m "feat(consolidation): debounced single cycle (45s) instead of recurring pause/idle timers — cloud-token-efficient"
```

---

## Task 4: Recall returns recent relevant turns

**Files:** `MemoryCore/MemoryRetriever.swift`, `MemoryService/Handlers/MemoryHandlers.swift`; Test: `Tests/MemoryServiceTests/MemoryEndpointsTests.swift` (append).

- [ ] **Step 1: `retrieve(queryVector:)`.** In `MemoryRetriever.retrieve`, add an optional precomputed vector to avoid re-embedding. Change the signature to:
```swift
public func retrieve(query: String, k: Int = 8, now: Double = Date().timeIntervalSince1970,
                     queryVector: [Float]? = nil) throws -> [Node] {
```
and change the vector step to:
```swift
let qv = queryVector ?? (embedder.flatMap { try? $0.embed(query) })
if let qv {
    for hit in (try? store.nearest(to: qv, k: k * 2)) ?? [] {
        if let n = try store.node(id: hit.id), !n.deleted { pool[n.id] = n; sim[n.id] = 1.0 / (1.0 + hit.distance) }
    }
}
```

- [ ] **Step 2: Failing endpoint test** — append to `MemoryEndpointsTests.swift` (mirror its helpers). Seed two threads' turns with embeddings, recall from thread "B" excluding it:
```swift
func test_recall_returns_recent_turns_from_other_threads_only() async throws {
    let app = try makeTestApp()
    // Thread A turn (embedded), thread B turn (embedded).
    let aId = try app.services.transcript.append(threadId: "A", turnIndex: 0, role: "user", text: "voy a Varadero la próxima semana")
    try app.services.store.setTranscriptEmbedding(turnId: aId, app.services.embedder.embed("voy a Varadero la próxima semana"))
    let bId = try app.services.transcript.append(threadId: "B", turnIndex: 0, role: "user", text: "hola")
    try app.services.store.setTranscriptEmbedding(turnId: bId, app.services.embedder.embed("hola"))
    let res = try await app.executeRequest(uri: "/v1/memory/recall", method: .post, headers: authHeaders(app),
        body: ByteBuffer(string: #"{"query":"qué planes tengo","threadId":"B"}"#))
    let body = String(buffer: res.body)
    XCTAssertTrue(body.contains("recentTurns"))
    XCTAssertTrue(body.contains("Varadero"), body)   // from thread A
    XCTAssertFalse(body.contains("\"text\":\"hola\""), body) // current thread B excluded
}
```

- [ ] **Step 3: Run → FAIL.**

- [ ] **Step 4: Handler.** In `MemoryHandlers.recall`:
- Add `threadId` to `RecallBody`: `struct RecallBody: Decodable, Sendable { let query: String; let scope: String?; let limit: Int?; let threadId: String? }`.
- Embed the query once and reuse + select recent turns:
```swift
let qv = try? services.embedder.embed(body.query)
let retrieved: [Node]
do { retrieved = try services.retriever.retrieve(query: body.query, k: limit, queryVector: qv) }
catch { return jsonError(.internalServerError, "recall_failed", "\(error)") }

var recentTurns: [(role: String, text: String)] = []
if let qv {
    let hits = (try? services.store.nearestTranscript(to: qv, k: limit * 3)) ?? []
    let turns = (try? services.transcript.rows(ids: hits.map { $0.turnId })) ?? []
    let byId = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for hit in hits {
        guard let t = byId[hit.turnId], !t.consolidated, t.threadId != body.threadId else { continue }
        recentTurns.append((t.role, t.text))
        if recentTurns.count >= 4 { break }
    }
}
```
- Extend the response `Payload` + `toOut` mapping with `recentTurns`:
```swift
struct OutTurn: Encodable { let role: String; let text: String }
struct Payload: Encodable { let core: [OutNode]; let recall: [OutNode]; let recentTurns: [OutTurn] }
let payload = Payload(core: coreNodes.map(toOut), recall: recallNodes.map(toOut),
                      recentTurns: recentTurns.map { OutTurn(role: $0.role, text: $0.text) })
```

- [ ] **Step 5: Run → PASS** + `swift test`.

- [ ] **Step 6: Commit**
```bash
git add Sources/MemoryCore/MemoryRetriever.swift Sources/MemoryService/Handlers/MemoryHandlers.swift Tests/MemoryServiceTests/MemoryEndpointsTests.swift
git commit -m "feat(recall): return recent relevant turns from other threads (pre-consolidation cross-chat memory)"
```

---

# PART B — APP

## Task 5: App passes thread + renders recent turns

**Files:** `personal_agent/Gemma/Gemma/Memory/MemoryClient.swift`, `Gemma/Gemma/Harness/HarnessModel.swift`; Test: `Gemma/GemmaTests/RecallInjectionTests.swift` (append).

- [ ] **Step 1: `RecallBundle.recentTurns` + injection.** In `MemoryClient.swift`:
- Add a nested struct and field:
```swift
struct RecentTurn: Decodable, Sendable { let role: String; let text: String }
```
- `RecallBundle` gains `let recentTurns: [RecentTurn]`. Update `static let empty = RecallBundle(core: [], recall: [], recentTurns: [])`. (It's `Decodable` — the server now always sends `recentTurns`; if any test constructs it, add the arg.)
- In `injectionBlock()`, after the existing `lines`, append a recent-turns section:
```swift
var out = merged.isEmpty ? "" : "What you remember about the user (use if relevant):\n" + lines.joined(separator: "\n")
if !recentTurns.isEmpty {
    let rt = recentTurns.map { "- \($0.role): \($0.text)" }.joined(separator: "\n")
    out += (out.isEmpty ? "" : "\n\n") + "Recent conversation (other chats):\n" + rt
}
return out
```
(Restructure the existing `return` to build `out` as above; keep the empty-when-nothing behavior — return "" when both `merged` and `recentTurns` are empty.)

- [ ] **Step 2: `recall(threadId:)`.** In `MemoryClient.swift` `recall`, add a `threadId` param and include it in the body:
```swift
func recall(query: String, scope: String? = nil, limit: Int? = nil, threadId: String? = nil) async throws -> RecallBundle {
    struct B: Encodable { let query: String; let scope: String?; let limit: Int?; let threadId: String? }
    return try await post("/v1/memory/recall", B(query: query, scope: scope, limit: limit, threadId: threadId))
}
```

- [ ] **Step 3: HarnessModel passes the thread.** In `HarnessModel.runAgentTurn`, change the recall call (currently `client.recall(query: prompt)`) to pass the current thread id used for the transcript (the same `threadId` used in `conversationWindow`/`appendTranscript` in that method):
```swift
let bundle = (try? await client.recall(query: prompt, threadId: threadId)) ?? .empty
```

- [ ] **Step 4: Failing test → impl → pass.** Append to `RecallInjectionTests.swift`:
```swift
func test_recentTurns_render_in_block() {
    let bundle = MemoryClient.RecallBundle(core: [], recall: [],
        recentTurns: [MemoryClient.RecentTurn(role: "user", text: "voy a Varadero")])
    let block = bundle.injectionBlock()
    XCTAssertTrue(block.contains("Recent conversation (other chats):"), block)
    XCTAssertTrue(block.contains("voy a Varadero"))
}
func test_empty_bundle_still_empty() {
    XCTAssertEqual(MemoryClient.RecallBundle(core: [], recall: [], recentTurns: []).injectionBlock(), "")
}
```
Update the existing `RecallInjectionTests` `RecallBundle(...)` constructions to include `recentTurns: []`. Run the app suite → these pass; only the known-unrelated failure remains.

- [ ] **Step 5: Commit**
```bash
git add Gemma/Gemma/Memory/MemoryClient.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/RecallInjectionTests.swift
git commit -m "feat(app): pass thread id to recall + render recent cross-chat turns"
```

---

## Task 6: Deploy server + manual E2E

**Files:** none.

- [ ] **Step 1: Deploy** (after server tasks merged to `gemma-memory` main):
```bash
ssh HomeLab 'cd ~/Projects/gemma-memory && git pull && docker compose build memory && docker compose up -d memory'
```
Verify `/healthz` 200; the `v7-transcript-embedding` migration runs at startup.

- [ ] **Step 2: App build (⌘R)** and manual E2E on the fresh memory:
  - Chat A: "la próxima semana voy a Varadero." Then **immediately** open Chat B: "¿qué planes tengo la próxima semana?" → the agent recalls the trip (via recent-turns recall, before consolidation).
  - Stop typing ~45s → confirm consolidation runs **once** (the status banner reflects one cycle), not repeatedly. Say nothing new → no further cycle.

- [ ] **Step 3: Record** the result.

---

## Self-Review

**Spec coverage:** §4.1 embed-at-append + table + cleanup → Tasks 1, 2. §4.2 debounce → Task 3. §4.3 retrieve(queryVector) + recent-turns + threadId + recentTurns → Task 4. §4.4 app → Task 5. §7 testing → unit tests in Tasks 1–5 + manual E2E Task 6. §8 order → Tasks 1–6. ✓

**Placeholder scan:** No TBD/TODO; every code step is concrete. The "mirror the sibling test helpers" notes (Tasks 2, 4) are explicit instructions to reuse existing endpoint-test infrastructure (`buildApp`/`FakeEmbedder`/auth), whose exact names live in those files — match, don't invent. Task 3's "adapt to the spy's counter names" is the same.

**Type consistency:** `setTranscriptEmbedding(turnId:_:)`, `nearestTranscript(to:k:) -> [(turnId,distance)]`, `deleteTranscriptEmbeddings(turnIds:)` consistent across Tasks 1, 2, 4. `TranscriptStore.append(...) -> String` (Task 1) used in Tasks 2, 4. `markConsolidated` cleanup (Task 1) tested in Task 1. `retrieve(query:k:now:queryVector:)` (Task 4 Step 1) called in the handler (Step 4). `RecallBody.threadId`, `Payload.recentTurns`, `OutTurn{role,text}` consistent (Task 4) with app `RecentTurn{role,text}` + `RecallBundle.recentTurns` + `recall(threadId:)` (Task 5). `ConsolidationScheduler(debounceInterval:)` (Task 3) replaces `pauseInterval`/`idleInterval` everywhere (App.swift updated in Step 4).
