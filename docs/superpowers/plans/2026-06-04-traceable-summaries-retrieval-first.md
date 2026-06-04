# Traceable Summaries + Retrieval-First Recall (SP-A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every chat message a server-authoritative per-chat number (`seq`), surface each episodic summary with its `summary_id`/`chat_id`/`message_range` in a dedicated recall tier, and let the agent drill down to the exact raw messages via a `load_messages` tool only when a summary is insufficient — with chats split into episodes after 30 min of inactivity.

**Architecture:** Server (`gemma-memory`) adds a `seq` column to `transcript` (assigned in the append write-txn), makes summary ranges + a new `GET /v1/transcript/range` endpoint speak `seq`, and splits a `summaries` tier out of the recall response. The app (`personal_agent`) decodes the new tier, renders it with drill-down refs, replaces `expand_context` with a `load_messages(chat_id, from, to)` tool, adds the prompt principle, and mints a new `chat_id` after 30 min idle.

**Tech Stack:** Swift 6 — server (SwiftPM, GRDB, Hummingbird), app (SwiftUI). Spec: `docs/superpowers/specs/2026-06-04-traceable-summaries-retrieval-first-design.md`.

**Server tests:** `swift test --filter <Name>` in `personal_agent/gemma-memory/memory-service` (clone, branch from `main`).
**App tests:** `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/<Class> 2>&1 | tail -30` in `personal_agent`.
**Known pre-existing app failure to IGNORE:** `HarnessModelTests.test_defaultBaseURL_isLocalhost8081`.

**Two design decisions locked here (deviations from the spec's optional bits, for YAGNI/low-churn):**
- The summary's range is stored in the node `extra` under the EXISTING key `turnRange`, now holding **seq** values (no JSON-key rename, no rewrite of stored nodes). The recall response surfaces it as `message_range`.
- `OutSummary` omits a numeric `score` (the `summaries` array is already relevance-ordered by the retriever) and the `summary_id` shortcut on `load_messages` is **not** implemented (the agent always has `chat_id`+range from the Tier-3 refs). `append` keeps returning the row `id` (not `seq`) to stay non-breaking.

---

## File Structure

**Server (`gemma-memory/memory-service/Sources/`):**
- `MemoryCore/TranscriptStore.swift` — `TranscriptRow.seq`; `append` assigns `seq`; `range(threadId:from:to:)` filters by `seq`.
- `MemoryCore/MemoryStore.swift` — migration `v8-transcript-seq`.
- `MemoryCore/MemoryConsolidationEngine.swift` — summary grouping uses `seq` (extracted testable helper).
- `MemoryService/Handlers/MemoryHandlers.swift` — recall `summaries` tier.
- `MemoryService/Handlers/TranscriptHandlers.swift` — `GET /v1/transcript/range`.
- `MemoryService/App.swift` — `expandContext` call site updated to `from:to:`.

**App (`personal_agent/Gemma/Gemma/`):**
- `Memory/MemoryClient.swift` — `RecallSummary`, `RecallBundle.summaries`, `loadMessages`, `injectionBlock` tiers.
- `Memory/LoadMessagesTool.swift` (create; replaces `ExpandContextTool.swift`, delete the latter).
- `Agent/Agent.swift` — prompt line.
- `Harness/HarnessModel.swift` — episode boundary; `threadId` becomes `var`.
- `Harness/ChatSession.swift` (create) — pure `shouldStartNewChat` helper.

---

# PART A — SERVER

## Task 1: `seq` column + monotonic-per-chat assignment + range-by-seq

**Files:** `Sources/MemoryCore/TranscriptStore.swift`, `Sources/MemoryCore/MemoryStore.swift`; Test: `Tests/MemoryCoreTests/TranscriptSeqTests.swift` (create).

### Step 0: Read `Sources/MemoryCore/TranscriptStore.swift` (the `TranscriptRow` struct + `append` + `range`) and the `migrator` in `Sources/MemoryCore/MemoryStore.swift` (last migration is `v7-transcript-embedding`). Confirm how existing transcript tests build a store (look in `Tests/MemoryCoreTests/` for a transcript test; reuse its store constructor — `try MemoryStore(inMemory: true, embeddingDim: 1024)` per other tests, and `store.transcript` or a `TranscriptStore(dbQueue:)`).

### Step 1: Write the failing test — `Tests/MemoryCoreTests/TranscriptSeqTests.swift`:
```swift
import XCTest
import GRDB
@testable import MemoryCore

final class TranscriptSeqTests: XCTestCase {
    func test_append_assigns_monotonic_seq_per_thread() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 1024)
        let ts = store.transcript   // if there is no such accessor, use TranscriptStore(dbQueue: store.dbQueue)
        _ = try ts.append(threadId: "A", turnIndex: 0, role: "user", text: "a1")
        _ = try ts.append(threadId: "A", turnIndex: 0, role: "assistant", text: "a2")
        _ = try ts.append(threadId: "B", turnIndex: 0, role: "user", text: "b1")
        _ = try ts.append(threadId: "A", turnIndex: 1, role: "user", text: "a3")
        let aRows = try ts.range(threadId: "A", from: 1, to: 99)
        XCTAssertEqual(aRows.map { $0.seq }, [1, 2, 3])       // per-thread 1..N
        XCTAssertEqual(aRows.map { $0.text }, ["a1", "a2", "a3"])
        let bRows = try ts.range(threadId: "B", from: 1, to: 99)
        XCTAssertEqual(bRows.map { $0.seq }, [1])             // independent thread restarts at 1
        let mid = try ts.range(threadId: "A", from: 2, to: 2) // single-message range
        XCTAssertEqual(mid.map { $0.text }, ["a2"])
    }
}
```
(If `store.transcript` doesn't exist, replace with `let ts = TranscriptStore(dbQueue: store.dbQueue)` — match what the existing transcript tests use.)

### Step 2: Run → FAIL: `swift test --filter TranscriptSeqTests` (no `seq`, `range` labels are `fromTurn:toTurn:`).

### Step 3a: Add the migration. In `MemoryStore.swift`'s `migrator`, AFTER the `"v7-transcript-embedding"` migration (before `return m`):
```swift
m.registerMigration("v8-transcript-seq") { db in
    try db.alter(table: "transcript") { t in
        t.add(column: "seq", .integer).notNull().defaults(to: 0)
    }
    // Backfill per-thread 1..N (prod transcript is empty post-reset; this handles dev DBs).
    try db.execute(sql: """
        WITH ordered AS (
            SELECT id, ROW_NUMBER() OVER (PARTITION BY threadId ORDER BY createdAt ASC, turnIndex ASC, id ASC) AS rn
            FROM transcript
        )
        UPDATE transcript SET seq = (SELECT rn FROM ordered WHERE ordered.id = transcript.id)
        WHERE EXISTS (SELECT 1 FROM ordered WHERE ordered.id = transcript.id)
        """)
    try db.create(indexOn: "transcript", columns: ["threadId", "seq"])
}
```

### Step 3b: Add `seq` to `TranscriptRow` (in `TranscriptStore.swift`). Add the stored property + init param (keep existing fields/order; insert `seq` right after `turnIndex`):
```swift
public var turnIndex: Int
public var seq: Int
```
and in the initializer add `seq: Int` after `turnIndex` and `self.seq = seq`. (GRDB maps the property name to the new column automatically.)

### Step 3c: `append` assigns `seq` in the write transaction. Replace the body:
```swift
@discardableResult
public func append(threadId: String, turnIndex: Int, role: String, text: String,
                   now: Double = Date().timeIntervalSince1970) throws -> String {
    let id = UUID().uuidString
    try dbQueue.write { db in
        let maxSeq = try Int.fetchOne(db,
            sql: "SELECT COALESCE(MAX(seq), 0) FROM transcript WHERE threadId = ?",
            arguments: [threadId]) ?? 0
        let row = TranscriptRow(id: id, threadId: threadId, turnIndex: turnIndex, seq: maxSeq + 1,
                                role: role, text: text, createdAt: now, consolidated: false)
        try row.insert(db)
    }
    return id
}
```

### Step 3d: `range` filters/orders by `seq` and renames its labels. Replace:
```swift
public func range(threadId: String, from: Int, to: Int) throws -> [TranscriptRow] {
    try dbQueue.read { db in
        try TranscriptRow
            .filter(Column("threadId") == threadId)
            .filter(Column("seq") >= from && Column("seq") <= to)
            .order(Column("seq").asc)
            .fetchAll(db)
    }
}
```
Then fix the one caller: in `Sources/MemoryService/App.swift` `expandContext`, change `transcript.range(threadId: threadId, fromTurn: tr[0], toTurn: tr[1])` → `transcript.range(threadId: threadId, from: tr[0], to: tr[1])`.

### Step 4: Run → PASS: `swift test --filter TranscriptSeqTests`, then full `swift test` (green; fix any other `range(...fromTurn:toTurn:)` call sites the compiler flags by switching to `from:to:`).

### Step 5: Commit
```bash
git add Sources/MemoryCore/TranscriptStore.swift Sources/MemoryCore/MemoryStore.swift Sources/MemoryService/App.swift Tests/MemoryCoreTests/TranscriptSeqTests.swift
git commit -m "feat(transcript): server-authoritative per-chat seq + range-by-seq"
```

---

## Task 2: Summaries record their range in `seq`

**Files:** `Sources/MemoryCore/MemoryConsolidationEngine.swift`; Test: `Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift` (append).

### Step 0: Read the `.summarize` case in `runCycle` (it groups `rows` by `threadId` and computes `range = (turns.min())...(turns.max())` from `$0.turnIndex`) and the `summarize(episodeTexts:threadId:turnRange:)` method (stores `"turnRange": [lower, upper]` in `extra`).

### Step 1: Write the failing test — append to `Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift`. This tests the new pure helper that the runCycle grouping will use:
```swift
func test_summaryGroups_uses_seq_for_range() throws {
    let rows = [
        TranscriptRow(id: "1", threadId: "A", turnIndex: 0, seq: 1, role: "user", text: "hola", createdAt: 1, consolidated: false),
        TranscriptRow(id: "2", threadId: "A", turnIndex: 0, seq: 2, role: "assistant", text: "qué tal", createdAt: 2, consolidated: false),
        TranscriptRow(id: "3", threadId: "A", turnIndex: 1, seq: 3, role: "user", text: "bien", createdAt: 3, consolidated: false),
        TranscriptRow(id: "4", threadId: "B", turnIndex: 0, seq: 1, role: "user", text: "otro chat", createdAt: 4, consolidated: false),
    ]
    let groups = MemoryConsolidationEngine.summaryGroups(rows)
    let a = groups.first { $0.threadId == "A" }
    XCTAssertEqual(a?.range, 1...3)                 // seq-based, not turnIndex (which is 0..1)
    XCTAssertEqual(a?.texts.count, 3)
    let b = groups.first { $0.threadId == "B" }
    XCTAssertEqual(b?.range, 1...1)
}
```

### Step 2: Run → FAIL (`summaryGroups` doesn't exist).

### Step 3a: Add the pure helper to `MemoryConsolidationEngine` (e.g. just above `summarize`):
```swift
/// Group consolidated transcript rows into one summary unit per thread, with the seq-based
/// message range and role-prefixed texts. Pure (testable without a model/db).
static func summaryGroups(_ rows: [TranscriptRow]) -> [(threadId: String, range: ClosedRange<Int>, texts: [String])] {
    Dictionary(grouping: rows, by: { $0.threadId })
        .sorted { ($0.value.map(\.createdAt).min() ?? 0) < ($1.value.map(\.createdAt).min() ?? 0) }
        .map { threadId, tRows in
            let seqs = tRows.map { $0.seq }
            let range = (seqs.min() ?? 0)...(seqs.max() ?? 0)
            let texts = tRows.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
            return (threadId, range, texts)
        }
}
```

### Step 3b: Use it in `runCycle`'s `.summarize` case — replace the grouping block with:
```swift
case .summarize:
    let rows = (try? transcriptStore.rows(ids: state.episodeIds)) ?? []
    for g in MemoryConsolidationEngine.summaryGroups(rows) {
        await summarize(episodeTexts: g.texts, threadId: g.threadId, turnRange: g.range)
    }
```
(The `summarize` method is unchanged — it already stores `extra["turnRange"] = [range.lowerBound, range.upperBound]`; those are now seq values.)

### Step 4: Run → PASS: `swift test --filter test_summaryGroups_uses_seq_for_range`, then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryCore/MemoryConsolidationEngine.swift Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(consolidation): summary message range uses per-chat seq"
```

---

## Task 3: Recall response gains a `summaries` tier

**Files:** `Sources/MemoryService/Handlers/MemoryHandlers.swift`; Test: `Tests/MemoryServiceTests/MemoryEndpointsTests.swift` (append).

### Step 0: Read the `recall` handler (the `OutNode`/`Payload` structs + how `recallNodes` is built). Note `makeAppWithServices()` + `app.test(.live)` test pattern in `MemoryEndpointsTests.swift`, and how a node is seeded (`services.store.upsert` + `services.store.setEmbedding`).

### Step 1: Failing test — append to `Tests/MemoryServiceTests/MemoryEndpointsTests.swift`:
```swift
func test_recall_returns_summaries_tier_with_refs() async throws {
    let (app, services) = try await makeAppWithServices()
    let extra = #"{"concepts":["opciones"],"intent":"","decisions":[],"importance":0.6,"threadId":"g7y","turnRange":[21,56]}"#
    let summary = Node(id: "sum1", kind: NodeKind.summary.rawValue, label: "trading opciones",
                       body: "El usuario hace trading de opciones", layer: .daily, createdAt: 1, updatedAt: 1,
                       lastSeenAt: 1, salience: 4, decayRate: 0, confidence: .probable, mentionCount: 1,
                       ttlExpiresAt: nil, sourceRef: "g7y", origin: .extracted, serverId: nil,
                       dirty: true, deleted: false, extra: extra)
    try services.store.upsert(summary)
    try services.store.setEmbedding(nodeId: "sum1", services.embedder.embed("trading opciones"))
    struct Out: Decodable { struct S: Decodable { let summaryId: String; let chatId: String; let messageRange: [Int]; let text: String }
        struct N: Decodable { let kind: String }
        let recall: [N]; let summaries: [S] }
    try await app.test(.live) { client in
        try await client.execute(uri: "/v1/memory/recall", method: .post,
            headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
            body: ByteBuffer(string: #"{"query":"trading opciones"}"#)) { res in
            XCTAssertEqual(res.status, .ok)
            let out = try JSONDecoder().decode(Out.self, from: Data(buffer: res.body))
            XCTAssertEqual(out.summaries.first?.summaryId, "sum1")
            XCTAssertEqual(out.summaries.first?.chatId, "g7y")
            XCTAssertEqual(out.summaries.first?.messageRange, [21, 56])
            XCTAssertFalse(out.recall.contains { $0.kind == "summary" }, "summaries must be split out of recall")
        }
    }
}
```
(Match `Data(buffer:)`/`res.body` decoding to how sibling tests in the file read the response body; if they use a helper, reuse it.)

### Step 2: Run → FAIL (no `summaries` key; summary still in `recall`).

### Step 3: In the `recall` handler, after `let recallNodes = retrieved.filter { !coreIds.contains($0.id) }`, split summaries out and add the tier. Replace the `OutNode`/`Payload`/`payload` block with:
```swift
let summaryKind = NodeKind.summary.rawValue
let atomicNodes = recallNodes.filter { $0.kind != summaryKind }
let summaryNodes = recallNodes.filter { $0.kind == summaryKind }

struct OutNode: Encodable { let id: String; let kind: String; let label: String; let body: String; let extra: String? }
struct OutSummary: Encodable { let summaryId: String; let chatId: String; let messageRange: [Int]; let text: String }
struct OutTurn: Encodable { let role: String; let text: String }
struct Payload: Encodable { let core: [OutNode]; let recall: [OutNode]; let summaries: [OutSummary]; let recentTurns: [OutTurn] }
func toOut(_ n: Node) -> OutNode { OutNode(id: n.id, kind: n.kind, label: n.label, body: n.body, extra: n.extra) }
func toSummary(_ n: Node) -> OutSummary? {
    guard let raw = n.extra?.data(using: .utf8),
          let any = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let chatId = any["threadId"] as? String,
          let tr = any["turnRange"] as? [Int], tr.count == 2 else { return nil }
    return OutSummary(summaryId: n.id, chatId: chatId, messageRange: tr, text: n.body.isEmpty ? n.label : n.body)
}
let payload = Payload(core: coreNodes.map(toOut), recall: atomicNodes.map(toOut),
                      summaries: summaryNodes.compactMap(toSummary),
                      recentTurns: recentTurns.map { OutTurn(role: $0.role, text: $0.text) })
```
(Leave the `let data = try JSONEncoder().encode(payload)` + `Response(...)` lines as they are.)

### Step 4: Run → PASS: `swift test --filter test_recall_returns_summaries_tier_with_refs`, then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryService/Handlers/MemoryHandlers.swift Tests/MemoryServiceTests/MemoryEndpointsTests.swift
git commit -m "feat(recall): dedicated summaries tier with summary_id/chat_id/message_range refs"
```

---

## Task 4: `GET /v1/transcript/range` endpoint (cap 80)

**Files:** `Sources/MemoryService/Handlers/TranscriptHandlers.swift`; Test: `Tests/MemoryServiceTests/TranscriptEndpointsTests.swift` (append).

### Step 0: Read `Sources/MemoryService/Handlers/TranscriptHandlers.swift` — its `register(on:)` (it has `/transcript/append`) and how an existing handler reads query/body + builds a `Response` (mirror `MemoryHandlers.expand` for the query-param + JSON-encode pattern). Read `TranscriptEndpointsTests.swift` for the app/auth test helpers.

### Step 1: Failing test — append to `Tests/MemoryServiceTests/TranscriptEndpointsTests.swift` (mirror the file's existing app construction + auth header helpers):
```swift
func test_transcript_range_returns_rows_by_seq_and_caps_at_80() async throws {
    let (app, services) = try await makeAppWithServices()   // use the file's real helper name
    for i in 1...100 { _ = try services.transcript.append(threadId: "g7y", turnIndex: i, role: "user", text: "m\(i)") }
    struct Out: Decodable { struct R: Decodable { let seq: Int; let role: String; let text: String }
        let messages: [R]; let truncated: Bool }
    try await app.test(.live) { client in
        // small explicit range
        try await client.execute(uri: "/v1/transcript/range?chat_id=g7y&from=21&to=23", method: .get,
            headers: [.authorization: "Bearer test-token"]) { res in
            XCTAssertEqual(res.status, .ok)
            let out = try JSONDecoder().decode(Out.self, from: Data(buffer: res.body))
            XCTAssertEqual(out.messages.map { $0.seq }, [21, 22, 23])
            XCTAssertFalse(out.truncated)
        }
        // oversized range clamps to 80
        try await client.execute(uri: "/v1/transcript/range?chat_id=g7y&from=1&to=100", method: .get,
            headers: [.authorization: "Bearer test-token"]) { res in
            let out = try JSONDecoder().decode(Out.self, from: Data(buffer: res.body))
            XCTAssertEqual(out.messages.count, 80)
            XCTAssertTrue(out.truncated)
        }
    }
}
```

### Step 2: Run → FAIL (route 404 / not found).

### Step 3a: Register the route. In `TranscriptHandlers.register(on:)`, add next to the append line:
```swift
group.get("/transcript/range", use: range)
```

### Step 3b: Add the handler to `TranscriptHandlers` (mirror `MemoryHandlers.expand`'s query-param + encode style):
```swift
@Sendable func range(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
    let q = req.uri.queryParameters
    guard let chatId = q["chat_id"].map(String.init),
          let from = q["from"].flatMap({ Int(String($0)) }) else {
        return jsonError(.badRequest, "bad_request", "chat_id and from required")
    }
    let toRaw = q["to"].flatMap { Int(String($0)) } ?? from
    let cappedTo = min(toRaw, from + 79)        // max 80 messages
    let truncated = toRaw > cappedTo
    let rows = (try? services.transcript.range(threadId: chatId, from: from, to: cappedTo)) ?? []
    struct OutRow: Encodable { let seq: Int; let role: String; let text: String; let createdAt: Double }
    struct Payload: Encodable { let messages: [OutRow]; let truncated: Bool }
    let payload = Payload(messages: rows.map { OutRow(seq: $0.seq, role: $0.role, text: $0.text, createdAt: $0.createdAt) },
                          truncated: truncated)
    let data = try JSONEncoder().encode(payload)
    return Response(status: .ok, headers: [.contentType: "application/json"],
                    body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
}
```
(If `jsonError`/`BasicRequestContext`/`services` are referenced differently in this handler file, match the file's existing conventions — copy them from the `append` handler in the same file.)

### Step 4: Run → PASS, then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryService/Handlers/TranscriptHandlers.swift Tests/MemoryServiceTests/TranscriptEndpointsTests.swift
git commit -m "feat(transcript): GET /v1/transcript/range — deterministic drill-down by chat_id+seq (cap 80)"
```

---

# PART B — APP

## Task 5: Client decodes the `summaries` tier + `loadMessages` + tiered injection

**Files:** `Gemma/Gemma/Memory/MemoryClient.swift`; Test: `Gemma/GemmaTests/RecallInjectionTests.swift` + `Gemma/GemmaTests/MemoryClientTests.swift`.

### Step 0: Read `Memory/MemoryClient.swift` — `RecallNode`, `RecentTurn`, `RecallBundle` (+ `injectionBlock`, `static let empty`), `recall(...)`, `expand(...)`, `ExpandResult`, and the private `get`/`post`/`escape` helpers. Read `RecallInjectionTests.swift` + `MemoryClientTests.swift` for how `RecallBundle` is built/decoded in tests.

### Step 1: Failing tests.
Append to `RecallInjectionTests.swift`:
```swift
func test_summaries_tier_renders_with_drilldown_refs() {
    let bundle = MemoryClient.RecallBundle(
        core: [], recall: [],
        summaries: [MemoryClient.RecallSummary(summaryId: "s1", chatId: "g7y", messageRange: [21, 56],
                                               text: "trading de opciones semanales")],
        recentTurns: [])
    let block = bundle.injectionBlock()
    XCTAssertTrue(block.contains("Episodic summaries"), block)
    XCTAssertTrue(block.contains("[chat g7y · msgs 21-56]"), block)
    XCTAssertTrue(block.contains("trading de opciones semanales"), block)
}
```
Append to `MemoryClientTests.swift` (this file's existing `test_recall_decodes_core_and_recall_lists` mock must also be updated — see Step 3c):
```swift
func test_recall_decodes_summaries_tier() async throws {
    StubProtocol.stub = { req in
        let payload = #"{"core":[],"recall":[],"summaries":[{"summaryId":"s1","chatId":"g7y","messageRange":[21,56],"text":"opciones"}],"recentTurns":[]}"#.data(using: .utf8)!
        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"])!, payload)
    }
    let bundle = try await makeClient().recall(query: "opciones", scope: nil, limit: nil)
    XCTAssertEqual(bundle.summaries.first?.chatId, "g7y")
    XCTAssertEqual(bundle.summaries.first?.messageRange, [21, 56])
}

func test_loadMessages_hits_range_endpoint() async throws {
    StubProtocol.stub = { req in
        XCTAssertEqual(req.url?.path, "/v1/transcript/range")
        XCTAssertTrue(req.url?.query?.contains("chat_id=g7y") ?? false)
        let data = #"{"messages":[{"seq":21,"role":"user","text":"hola"}],"truncated":false}"#.data(using: .utf8)!
        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"])!, data)
    }
    let r = try await makeClient().loadMessages(chatId: "g7y", from: 21, to: 56)
    XCTAssertEqual(r.messages.first?.text, "hola")
}
```

### Step 2: Run → FAIL: `xcodebuild ... -only-testing:GemmaTests/RecallInjectionTests -only-testing:GemmaTests/MemoryClientTests`.

### Step 3a: Add the summary type + bundle field + loadMessages. In `MemoryClient.swift`, add near `RecallNode`:
```swift
struct RecallSummary: Decodable, Sendable {
    let summaryId: String; let chatId: String; let messageRange: [Int]; let text: String
}
struct RangeRow: Decodable, Sendable { let seq: Int; let role: String; let text: String }
struct RangeResult: Decodable, Sendable { let messages: [RangeRow]; let truncated: Bool }
```
In `RecallBundle`, add `summaries` to the stored properties and `empty`:
```swift
let core: [RecallNode]; let recall: [RecallNode]; let summaries: [RecallSummary]; let recentTurns: [RecentTurn]
static let empty = RecallBundle(core: [], recall: [], summaries: [], recentTurns: [])
```
Add the client method (near `recall`/`expand`):
```swift
func loadMessages(chatId: String, from: Int, to: Int?) async throws -> RangeResult {
    let toq = to.map { "&to=\($0)" } ?? ""
    return try await get("/v1/transcript/range?chat_id=\(escape(chatId))&from=\(from)\(toq)")
}
```

### Step 3b: Rewrite `injectionBlock` to render summaries from the new tier (and stop pulling `kind=="summary"` out of `merged`):
```swift
func injectionBlock() -> String {
    let all = recall + core.filter { c in !recall.contains(where: { $0.label == c.label && $0.kind == c.kind }) }
    let selfNode = all.first { $0.kind == "self" }
    let merged = all.filter { $0.kind != "self" }
    let lines = merged.map { n -> String in
        let base = "- [\(n.kind)] \(n.label): \(n.body.isEmpty ? n.label : n.body)"
        guard n.kind == "event", let extra = n.extra,
              let data = extra.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? String else { return base }
        return base + scheduleStatusSuffix(status)
    }
    var out = ""
    if let s = selfNode, !s.label.isEmpty {
        out = "You are speaking with \(s.label) (the user)." + (s.body.isEmpty ? "" : " \(s.body)\(s.body.hasSuffix(".") ? "" : ".")")
    }
    if !merged.isEmpty {
        out += (out.isEmpty ? "" : "\n") + "What you remember about the user (use if relevant):\n" + lines.joined(separator: "\n")
    }
    if !summaries.isEmpty {
        let sl = summaries.map { s in
            let r = s.messageRange.count == 2 ? "\(s.messageRange[0])-\(s.messageRange[1])" : "\(s.messageRange.first ?? 0)"
            return "- [chat \(s.chatId) · msgs \(r)] \(s.text)"
        }.joined(separator: "\n")
        out += (out.isEmpty ? "" : "\n\n") + "Episodic summaries (load the underlying messages only if a summary doesn't answer):\n" + sl
    }
    if !recentTurns.isEmpty {
        let rt = recentTurns.map { "- \($0.role): \($0.text)" }.joined(separator: "\n")
        out += (out.isEmpty ? "" : "\n\n") + "Recent conversation (other chats):\n" + rt
    }
    return out
}
```

### Step 3c: Fix the existing recall-decode mock. In `MemoryClientTests.swift` `test_recall_decodes_core_and_recall_lists`, the mock JSON payload lacks `summaries`; add `"summaries":[],` to it so it decodes against the new required field. (Search the file for `"recentTurns":[]` inside that test and add `"summaries":[],` before it.)

### Step 4: Run → PASS (both test classes). The known `HarnessModelTests.test_defaultBaseURL_isLocalhost8081` may still fail; nothing else.

### Step 5: Commit
```bash
git add Gemma/Gemma/Memory/MemoryClient.swift Gemma/GemmaTests/RecallInjectionTests.swift Gemma/GemmaTests/MemoryClientTests.swift
git commit -m "feat(app): decode summaries tier, render drill-down refs, add loadMessages client"
```

---

## Task 6: `load_messages` tool (replaces `expand_context`) + prompt principle

**Files:** Create `Gemma/Gemma/Memory/LoadMessagesTool.swift`; Delete `Gemma/Gemma/Memory/ExpandContextTool.swift`; Modify `Gemma/Gemma/Agent/Agent.swift` + `Gemma/Gemma/Harness/HarnessModel.swift` (registration); Test: `Gemma/GemmaTests/AgentJarvisPromptTests.swift` (append) + `Gemma/GemmaTests/MemoryToolsTests.swift` (append, if it covers tools).

### Step 0: Read `Memory/ExpandContextTool.swift` (the tool template) + how it's registered in `Harness/HarnessModel.swift` (`registry.register(ExpandContextTool())`). Read `Agent/Agent.swift` `systemPromptText`.

### Step 1: Failing test — append to `AgentJarvisPromptTests.swift`:
```swift
func test_prompt_has_summary_first_drilldown_rule() {
    XCTAssertTrue(Agent.systemPromptText.localizedCaseInsensitiveContains("load_messages"), Agent.systemPromptText)
    XCTAssertTrue(Agent.systemPromptText.localizedCaseInsensitiveContains("only when a summary"), Agent.systemPromptText)
}
```

### Step 2: Run → FAIL.

### Step 3a: Create `Gemma/Gemma/Memory/LoadMessagesTool.swift` (modeled on `ExpandContextTool`):
```swift
import Foundation

/// Drill-down (CAPA 1): given a summary's refs (chat_id + message range), return the verbatim
/// chat messages behind it. A READ tool — the model calls it ONLY when a summary lacks the
/// detail it needs, reading just that range. Delegates to `/v1/transcript/range`.
struct LoadMessagesTool: AgentTool {
    static let name = "load_messages"
    static let description = """
    Load the exact past messages behind an episodic summary, ONLY when a summary doesn't contain \
    the detail you need. Pass the summary's chat_id and the message range (from/to) shown next to it. \
    Read just that range — never a whole chat.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "chat_id", type: .string, description: "The chat id shown with the summary, e.g. \"g7y\".", required: true),
        AgentToolParam(name: "from", type: .integer, description: "First message number (seq) of the range.", required: true),
        AgentToolParam(name: "to", type: .integer, description: "Last message number (seq); omit for a single message.", required: false),
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let chatId = ((obj["chat_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let from = (obj["from"] as? Int) ?? (obj["from"] as? Double).map(Int.init) ?? 0
        let to = (obj["to"] as? Int) ?? (obj["to"] as? Double).map(Int.init)
        guard !chatId.isEmpty, from > 0 else { return "need chat_id and from" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "\(chatId):\(from)-\(to ?? from)") }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
            do {
                let r = try await mem.loadMessages(chatId: chatId, from: from, to: to)
                guard !r.messages.isEmpty else { return "no messages found for chat \(chatId) range \(from)-\(to ?? from)" }
                let lines = r.messages.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
                let body = lines.joined(separator: "\n")
                return String((r.truncated ? body + "\n…(truncated at 80)" : body).prefix(4000))
            } catch { return "no messages found for chat \(chatId)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
```
(If `AgentToolParam` has no `.integer` case, use `.string` for `from`/`to` and parse with `Int($0)` in `run`. Check `Agent/AgentTool.swift` for the available `type` cases in Step 0.)

### Step 3b: Delete `Gemma/Gemma/Memory/ExpandContextTool.swift` (`git rm`). In `Harness/HarnessModel.swift`, change the registration line `registry.register(ExpandContextTool())` → `registry.register(LoadMessagesTool())`. If `MemoryClient.expand`/`ExpandResult` are now unreferenced (grep the app for `\.expand(` and `ExpandResult`), remove them from `MemoryClient.swift`; if anything else references them, leave them.

### Step 3c: Add the prompt principle. In `Agent.systemPromptText`, after the sentence ending "...not only the most recent." (the recall-completeness sentence), insert:
```
You may be given episodic summaries, each tagged with its source chat and message range. Answer from a summary when it suffices; call load_messages(chat_id, from, to) ONLY when a summary lacks the detail you need, and read just that range — never a whole chat, and never load raw messages you don't need. \
```
(Keep the `\` line-continuation so the literal stays valid.)

### Step 4: Run → PASS: `AgentJarvisPromptTests`; build the app (the tool compiles, ExpandContextTool gone). Then a fuller run; only the known failure may remain.

### Step 5: Commit
```bash
git add Gemma/Gemma/Memory/LoadMessagesTool.swift Gemma/Gemma/Agent/Agent.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/AgentJarvisPromptTests.swift
git rm Gemma/Gemma/Memory/ExpandContextTool.swift
git commit -m "feat(app): load_messages drill-down tool (replaces expand_context) + summary-first prompt rule"
```

---

## Task 7: Episode boundary — new chat after 30 min idle

**Files:** Create `Gemma/Gemma/Harness/ChatSession.swift`; Modify `Gemma/Gemma/Harness/HarnessModel.swift`; Test: create `Gemma/GemmaTests/ChatSessionTests.swift`.

### Step 0: Read `Harness/HarnessModel.swift` — the `threadId` (`let threadId = UUID().uuidString`), `turnIndex`, `lastTurnEndedAt`, and the start of `runAgentTurn` where `let now = Date().timeIntervalSince1970` is computed (~line 234, the `isWake` area).

### Step 1: Failing test — `Gemma/GemmaTests/ChatSessionTests.swift`:
```swift
import XCTest
@testable import Gemma

final class ChatSessionTests: XCTestCase {
    func test_starts_new_chat_after_idle_gap() {
        let gap = 1800.0
        // first ever turn: no previous activity → keep the chat
        XCTAssertFalse(ChatSession.shouldStartNewChat(lastActivity: 0, now: 100, gapSeconds: gap))
        // within the window → same chat
        XCTAssertFalse(ChatSession.shouldStartNewChat(lastActivity: 1000, now: 1000 + 1799, gapSeconds: gap))
        // past the window → new chat
        XCTAssertTrue(ChatSession.shouldStartNewChat(lastActivity: 1000, now: 1000 + 1801, gapSeconds: gap))
    }
}
```

### Step 2: Run → FAIL (`ChatSession` doesn't exist).

### Step 3a: Create `Gemma/Gemma/Harness/ChatSession.swift`:
```swift
import Foundation

/// Episode boundary: a conversation that has been idle longer than `gapSeconds` starts a new
/// chat (new chat_id, seq restarts), so episodic summaries stay bounded. Pure + testable.
enum ChatSession {
    static let defaultGapSeconds: Double = 1800   // 30 minutes

    static func shouldStartNewChat(lastActivity: Double, now: Double, gapSeconds: Double = defaultGapSeconds) -> Bool {
        lastActivity > 0 && (now - lastActivity) > gapSeconds
    }
}
```

### Step 3b: Wire it into `HarnessModel.swift`.
- Change `private let threadId = UUID().uuidString` → `private var threadId = UUID().uuidString`.
- In `runAgentTurn`, right after `let now = Date().timeIntervalSince1970` (the `isWake` block), add:
```swift
if ChatSession.shouldStartNewChat(lastActivity: lastTurnEndedAt, now: now) {
    threadId = UUID().uuidString   // new episode → new chat_id; server restarts seq at 1
    turnIndex = 0
}
```

### Step 4: Run → PASS: `ChatSessionTests`. Build the app (HarnessModel compiles with `var threadId`).

### Step 5: Commit
```bash
git add Gemma/Gemma/Harness/ChatSession.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/ChatSessionTests.swift
git commit -m "feat(app): start a new chat after 30 min idle (bounded episodes)"
```

---

## Task 8: Deploy server + manual E2E

- [ ] **Deploy:** `ssh HomeLab 'cd ~/Projects/gemma-memory && git pull --ff-only origin main && docker compose build memory && docker compose up -d memory'`. Verify `curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/healthz` = 200 and the `v8-transcript-seq` migration applied (a fresh `save`+`recall` still works).
- [ ] **Smoke (curl on i3):** append two turns to a thread via `/v1/transcript/append`, then `GET /v1/transcript/range?chat_id=<t>&from=1&to=2` returns 2 rows with `seq` 1,2.
- [ ] **App build (⌘R) on fresh memory:** converse about a topic in chat A (enough turns to summarize) → let consolidation run → trigger a new chat (relaunch / wait past 30 min, or temporarily lower `ChatSession.defaultGapSeconds` for the test) → ask a detail only present in chat A. Confirm: the agent answers from the Tier-3 summary when it suffices; when it doesn't, it calls `load_messages` with chat A's `chat_id`+range and answers from that range. Confirm it does NOT call `load_messages` when the summary already answers.
- [ ] **Record** the result.

---

## Self-Review

**Spec coverage:** §4.1 seq numbering → Task 1. §4.2 summary range in seq → Task 2. §4.3 graduated recall + `summaries` tier → Task 3 (server) + Task 5 (app render). §4.4 drill-down endpoint + tool + prompt → Task 4 (endpoint), Task 5 (client), Task 6 (tool+prompt). §4.5 episode boundary → Task 7. §7 testing → unit tests in Tasks 1–7 + manual E2E Task 8. §8 order → Tasks 1–8. Documented deviations (turnRange key holds seq; no `score`; no `summary_id` shortcut; `append` returns id) are stated in the header. ✓

**Placeholder scan:** No TBD/TODO. Each code step shows full before/after. The "match the file's helper" notes (test app construction, `Data(buffer:)`, `AgentToolParam` type cases, `jsonError` conventions) point to concrete existing patterns to mirror, not invented APIs — Step 0 of each task reads them first.

**Type consistency:** `seq: Int` on `TranscriptRow` (T1) used by `summaryGroups` (T2), the range endpoint (T4), and `RangeRow` (T5/T6). `range(threadId:from:to:)` (T1) called by `expandContext` (T1), the endpoint (T4). `OutSummary{summaryId,chatId,messageRange,text}` (T3) ↔ app `RecallSummary{summaryId,chatId,messageRange,text}` (T5) — same field names, matched in the decode test. `RangeResult{messages:[RangeRow{seq,role,text}],truncated}` server (T4) ↔ app (T5) ↔ consumed by `LoadMessagesTool` (T6). `RecallBundle` gains `summaries` (T5) consumed by `injectionBlock` (T5) — `static let empty` + the `MemoryClientTests` mock updated in the same task. `ChatSession.shouldStartNewChat` (T7) signature matches its test + call site. `threadId` `let`→`var` (T7).
