# M2d-1 — Live Context & clean capture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the chat real short-term context (recent turns sent to the model) and stop polluting the graph / adding hot-path latency: raw turns go to a new `TranscriptStore` (not the node graph), `save_memory` is removed from the live turn, and `EpisodeRecorder` is replaced + existing conversation nodes purged.

**Architecture:** Add `ChatMessage` + a `history` field on `GenerationOptions` that `ServerRuntime` prepends to its OpenAI `messages` array (no protocol/fake churn). A `TranscriptStore` (new GRDB table, separate from `node`) persists every turn; a pure `ConversationWindow` builds the bounded history from it. `HarnessModel` feeds the window in and appends the turn out; it no longer registers `SaveMemoryTool` nor records episodes as graph nodes. A one-time migration purges existing `conversation` nodes.

**Tech Stack:** Swift 6 / SwiftUI / GRDB / XCTest, mlx_vlm OpenAI-compatible server, Xcode 26.2 (filesystem-synchronized groups → new files auto-included, no `project.pbxproj` edits).

**Spec:** `docs/superpowers/specs/2026-06-01-m2d-live-context-clean-capture-design.md` (this is sub-plan **M2d-1** of §9).

**SCOPE NOTE — read before starting.** This plan deliberately does NOT rewire the consolidation engine's input or add structured `summary` nodes (that is **M2d-2**). After M2d-1, `MemoryStore.unconsolidatedEpisodes()` returns empty (no more conversation nodes), so `MemoryConsolidationEngine.runCycle` early-returns via its `guard !batch.isEmpty` — consolidation is **safely dormant** (no crash). Consequence: between M2d-1 and M2d-2 no NEW long-term memories form, but **recall still works** over previously-distilled knowledge nodes (person/preference/etc. are NOT purged — only raw `conversation` turns are). M2d-2 restores formation by sourcing consolidation from the transcript. This interim is intentional. Also NOT in M2d-1: the tool-role-message tool-loop refactor (the M1 bracketed-prompt loop stays — it works); short-term context is delivered via `GenerationOptions.history`, which is independent of the in-turn tool loop.

**Build/test command (success = "Test Suite … passed"):**
```bash
xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS'
```
Unit suite needs no live server. Live tests are gated by `TEST_RUNNER_GEMMA_LIVE_SERVER=1` (pass it as an ENV-VAR PREFIX to xcodebuild, not a trailing build-setting).

---

### Task 1: `ChatMessage` + `GenerationOptions.history` + `ServerRuntime` prepends history

**Files:**
- Modify: `Gemma/Gemma/Runtime/ModelRuntime.swift` (add `ChatMessage`; add `history` to `GenerationOptions`)
- Modify: `Gemma/Gemma/Runtime/ServerRuntime.swift` (serialize history into `messages`)
- Test: `Gemma/GemmaTests/ServerRuntimeHistoryTests.swift` (new)

- [ ] **Step 1: Write the failing test** `Gemma/GemmaTests/ServerRuntimeHistoryTests.swift`. It uses a `URLProtocol` stub to capture the request body and asserts the `messages` array is `[system, …history, user]`:

```swift
import XCTest
@testable import Gemma

final class ServerRuntimeHistoryTests: XCTestCase {
    // Captures the outgoing request body across the test.
    final class BodyCapture: URLProtocol {
        nonisolated(unsafe) static var lastBody: Data?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            BodyCapture.lastBody = request.httpBody ?? request.httpBodyStream.map { s in
                s.open(); defer { s.close() }
                var data = Data(); let n = 65536; var buf = [UInt8](repeating: 0, count: n)
                while s.hasBytesAvailable { let read = s.read(&buf, maxLength: n); if read <= 0 { break }; data.append(buf, count: read) }
                return data
            }
            let json = #"{"choices":[{"message":{"content":"ok"}}]}"#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: json)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [BodyCapture.self]
        return URLSession(configuration: cfg)
    }

    func test_history_is_sent_between_system_and_user() async throws {
        BodyCapture.lastBody = nil
        let rt = ServerRuntime(session: makeSession())
        var opts = GenerationOptions()
        opts.systemPrompt = "SYS"
        opts.history = [ChatMessage(role: .user, content: "turn1 user"),
                        ChatMessage(role: .assistant, content: "turn1 reply")]
        let stream = await rt.generate(prompt: "turn2 user", tools: [], options: opts)
        for try await _ in stream {}   // drive it

        let body = try XCTUnwrap(BodyCapture.lastBody)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let msgs = try XCTUnwrap(obj["messages"] as? [[String: String]])
        XCTAssertEqual(msgs.map { $0["role"] }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(msgs.map { $0["content"] }, ["SYS", "turn1 user", "turn1 reply", "turn2 user"])
    }
}
```

- [ ] **Step 2: Run to verify it fails to compile**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -20`
Expected: COMPILE FAIL — `ChatMessage` undefined; `GenerationOptions` has no `history`.

- [ ] **Step 3: Add `ChatMessage`** to `Runtime/ModelRuntime.swift` (top, after `import Foundation`):

```swift
/// One message in a chat history sent to the model (short-term context, M2d-1).
public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Codable { case system, user, assistant }
    public var role: Role
    public var content: String
    public init(role: Role, content: String) { self.role = role; self.content = content }
}
```

- [ ] **Step 4: Add `history` to `GenerationOptions`** in the same file. Add the stored property and an init parameter (defaulted so every existing call site keeps compiling):

In the property list (after `systemPrompt`):
```swift
    /// Prior conversation turns (short-term context) prepended to the request, oldest first.
    /// Empty = single-shot (legacy behavior).
    public var history: [ChatMessage]
```
In `init`, add `history: [ChatMessage] = []` as the last parameter and `self.history = history` in the body.

- [ ] **Step 5: Prepend history in `ServerRuntime.generate(prompt:tools:options:)`.** Replace the message-assembly block (currently builds `[system?, user]`):

```swift
                    var messages: [[String: Any]] = []
                    if let sys = options.systemPrompt, !sys.isEmpty {
                        messages.append(["role": "system", "content": sys])
                    }
                    for m in options.history {
                        messages.append(["role": m.role.rawValue, "content": m.content])
                    }
                    messages.append(["role": "user", "content": prompt])
```

- [ ] **Step 6: Run to verify it passes**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ServerRuntimeHistoryTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Gemma/Gemma/Runtime/ModelRuntime.swift Gemma/Gemma/Runtime/ServerRuntime.swift Gemma/GemmaTests/ServerRuntimeHistoryTests.swift
git commit -m "feat(m2d-1): ChatMessage + GenerationOptions.history; ServerRuntime sends short-term history

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `TranscriptStore` (raw turns, separate from the node graph)

**Files:**
- Modify: `Gemma/Gemma/Memory/MemoryStore.swift` (add migration `v4-transcript`)
- Create: `Gemma/Gemma/Memory/TranscriptStore.swift`
- Test: `Gemma/GemmaTests/TranscriptStoreTests.swift` (new)

- [ ] **Step 1: Write the failing test** `Gemma/GemmaTests/TranscriptStoreTests.swift`:

```swift
import XCTest
import GRDB
@testable import Gemma

final class TranscriptStoreTests: XCTestCase {
    private func makeStore() throws -> TranscriptStore {
        let mem = try MemoryStore(inMemory: true, embeddingDim: 8)
        return TranscriptStore(dbQueue: mem.dbQueue)
    }

    func test_append_and_recent_ordered_oldestFirst() throws {
        let s = try makeStore()
        try s.append(threadId: "t", turnIndex: 0, role: "user", text: "hola", now: 1)
        try s.append(threadId: "t", turnIndex: 0, role: "assistant", text: "buenas", now: 2)
        try s.append(threadId: "t", turnIndex: 1, role: "user", text: "que tal", now: 3)
        let rows = try s.recent(threadId: "t", maxTurns: 10, maxChars: 10_000)
        XCTAssertEqual(rows.map { $0.role }, ["user", "assistant", "user"])
        XCTAssertEqual(rows.map { $0.text }, ["hola", "buenas", "que tal"])
    }

    func test_recent_caps_by_turns_keepingNewest() throws {
        let s = try makeStore()
        for i in 0..<5 { try s.append(threadId: "t", turnIndex: i, role: "user", text: "m\(i)", now: Double(i)) }
        let rows = try s.recent(threadId: "t", maxTurns: 2, maxChars: 10_000)
        XCTAssertEqual(rows.map { $0.text }, ["m3", "m4"], "keeps the newest, still oldest-first")
    }

    func test_recent_caps_by_chars_keepingNewest() throws {
        let s = try makeStore()
        try s.append(threadId: "t", turnIndex: 0, role: "user", text: "aaaa", now: 1)   // 4
        try s.append(threadId: "t", turnIndex: 1, role: "user", text: "bbbb", now: 2)   // 4
        let rows = try s.recent(threadId: "t", maxTurns: 10, maxChars: 5)               // only newest fits
        XCTAssertEqual(rows.map { $0.text }, ["bbbb"])
    }

    func test_range_returnsInclusiveTurnSlice() throws {
        let s = try makeStore()
        for i in 0..<4 { try s.append(threadId: "t", turnIndex: i, role: "user", text: "m\(i)", now: Double(i)) }
        let rows = try s.range(threadId: "t", fromTurn: 1, toTurn: 2)
        XCTAssertEqual(rows.map { $0.text }, ["m1", "m2"])
    }

    func test_unconsolidated_and_mark() throws {
        let s = try makeStore()
        try s.append(threadId: "t", turnIndex: 0, role: "user", text: "x", now: 1)
        try s.append(threadId: "t", turnIndex: 0, role: "assistant", text: "y", now: 2)
        let pending = try s.unconsolidated(limit: 100)
        XCTAssertEqual(pending.count, 2)
        try s.markConsolidated(ids: pending.map { $0.id })
        XCTAssertEqual(try s.unconsolidated(limit: 100).count, 0)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/TranscriptStoreTests 2>&1 | tail -20`
Expected: COMPILE FAIL — `TranscriptStore` undefined.

- [ ] **Step 3: Add the migration** in `MemoryStore.swift` `migrator`, after `m.registerMigration("v3-sleep-focus")`:

```swift
        m.registerMigration("v4-transcript") { db in
            try db.create(table: "transcript") { t in
                t.primaryKey("id", .text)
                t.column("threadId", .text).notNull()
                t.column("turnIndex", .integer).notNull()
                t.column("role", .text).notNull()      // "user" | "assistant"
                t.column("text", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("consolidated", .boolean).notNull().defaults(to: false)
            }
            try db.create(indexOn: "transcript", columns: ["threadId", "createdAt"])
            try db.create(indexOn: "transcript", columns: ["consolidated"])
        }
```

- [ ] **Step 4: Create `Gemma/Gemma/Memory/TranscriptStore.swift`:**

```swift
import Foundation
import GRDB

/// One raw conversation turn. Lives in the `transcript` table, SEPARATE from the knowledge
/// graph (`node`). This is Layer 1 (short-term window source) + Layer 4 (drill-down log).
struct TranscriptRow: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "transcript"
    var id: String
    var threadId: String
    var turnIndex: Int
    var role: String
    var text: String
    var createdAt: Double
    var consolidated: Bool
}

/// Persists raw chat turns. Reuses the MemoryStore `DatabaseQueue` (one DB file) but never
/// touches `node`. Replaces `EpisodeRecorder` (which wrote graph nodes per turn).
nonisolated final class TranscriptStore {
    private let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    /// Append one turn. Best-effort at the call site (callers swallow errors so a reply never breaks).
    func append(threadId: String, turnIndex: Int, role: String, text: String,
                now: Double = Date().timeIntervalSince1970) throws {
        let row = TranscriptRow(id: UUID().uuidString, threadId: threadId, turnIndex: turnIndex,
                                role: role, text: text, createdAt: now, consolidated: false)
        try dbQueue.write { try row.insert($0) }
    }

    /// Recent turns for the short-term window, oldest-first, capped by BOTH turn count and a
    /// char budget (newest kept when capping).
    func recent(threadId: String, maxTurns: Int, maxChars: Int) throws -> [TranscriptRow] {
        let newestFirst: [TranscriptRow] = try dbQueue.read { db in
            try TranscriptRow
                .filter(Column("threadId") == threadId)
                .order(Column("createdAt").desc, Column("turnIndex").desc)
                .limit(maxTurns)
                .fetchAll(db)
        }
        var kept: [TranscriptRow] = []
        var chars = 0
        for r in newestFirst {
            chars += r.text.count
            if chars > maxChars, !kept.isEmpty { break }
            kept.append(r)
        }
        return kept.reversed()   // oldest-first for the prompt
    }

    /// Inclusive slice of a thread by turnIndex — for N4 drill-down (M2d-3).
    func range(threadId: String, fromTurn: Int, toTurn: Int) throws -> [TranscriptRow] {
        try dbQueue.read { db in
            try TranscriptRow
                .filter(Column("threadId") == threadId)
                .filter(Column("turnIndex") >= fromTurn && Column("turnIndex") <= toTurn)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    /// Turns not yet consolidated, oldest-first — the consolidation input source (used in M2d-2).
    func unconsolidated(limit: Int) throws -> [TranscriptRow] {
        try dbQueue.read { db in
            try TranscriptRow
                .filter(Column("consolidated") == false)
                .order(Column("createdAt").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func markConsolidated(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            try TranscriptRow.filter(ids.contains(Column("id")))
                .updateAll(db, Column("consolidated").set(to: true))
        }
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/TranscriptStoreTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Gemma/Gemma/Memory/MemoryStore.swift Gemma/Gemma/Memory/TranscriptStore.swift Gemma/GemmaTests/TranscriptStoreTests.swift
git commit -m "feat(m2d-1): TranscriptStore — raw turns in a separate table, not the node graph

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `ConversationWindow` — pure builder (rows → `[ChatMessage]`)

**Files:**
- Create: `Gemma/Gemma/Memory/ConversationWindow.swift`
- Test: `Gemma/GemmaTests/ConversationWindowTests.swift` (new)

- [ ] **Step 1: Write the failing test** `Gemma/GemmaTests/ConversationWindowTests.swift`:

```swift
import XCTest
@testable import Gemma

final class ConversationWindowTests: XCTestCase {
    private func row(_ role: String, _ text: String, _ t: Double) -> TranscriptRow {
        TranscriptRow(id: "\(t)", threadId: "x", turnIndex: Int(t), role: role, text: text, createdAt: t, consolidated: false)
    }

    func test_maps_rows_to_chat_messages_in_order() {
        let rows = [row("user", "hola", 1), row("assistant", "buenas", 2)]
        let msgs = ConversationWindow.messages(from: rows)
        XCTAssertEqual(msgs, [ChatMessage(role: .user, content: "hola"),
                              ChatMessage(role: .assistant, content: "buenas")])
    }

    func test_unknown_role_is_treated_as_user() {
        let msgs = ConversationWindow.messages(from: [row("system", "x", 1)])
        XCTAssertEqual(msgs, [ChatMessage(role: .user, content: "x")])
    }

    func test_empty_rows_empty_messages() {
        XCTAssertTrue(ConversationWindow.messages(from: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ConversationWindowTests 2>&1 | tail -20`
Expected: COMPILE FAIL — `ConversationWindow` undefined.

- [ ] **Step 3: Create `Gemma/Gemma/Memory/ConversationWindow.swift`:**

```swift
import Foundation

/// Pure mapping from persisted transcript rows to the chat history (`[ChatMessage]`) the model
/// receives as short-term context. Rows are assumed oldest-first (as `TranscriptStore.recent`
/// returns them). Caps are applied by the store; this is just the role/text mapping.
enum ConversationWindow {
    /// Default short-term window bounds (see spec §2): ~12 turns or ~1500 chars, newest kept.
    static let defaultMaxTurns = 12
    static let defaultMaxChars = 1500

    static func messages(from rows: [TranscriptRow]) -> [ChatMessage] {
        rows.map { row in
            let role: ChatMessage.Role = (row.role == "assistant") ? .assistant : .user
            return ChatMessage(role: role, content: row.text)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ConversationWindowTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Memory/ConversationWindow.swift Gemma/GemmaTests/ConversationWindowTests.swift
git commit -m "feat(m2d-1): ConversationWindow — rows to chat history mapping

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `Agent` system prompt — drop the `save_memory` instruction

**Files:**
- Modify: `Gemma/Gemma/Agent/Agent.swift` (`systemPrompt(memoryBlock:)`)
- Test: `Gemma/GemmaTests/AgentSystemPromptTests.swift` (new)

> `save_memory` is removed from the live turn (Task 5 unregisters the tool). The system prompt must stop telling the model to call it (otherwise it calls a non-existent tool). Recall ("what you remember") and "answer only what was asked" stay.

- [ ] **Step 1: Write the failing test** `Gemma/GemmaTests/AgentSystemPromptTests.swift`:

```swift
import XCTest
@testable import Gemma

@MainActor
final class AgentSystemPromptTests: XCTestCase {
    // Minimal ToolCallingRuntime that records the system prompt it was given, then completes.
    final class CapturingRuntime: ToolCallingRuntime {
        var capturedSystem: String = ""
        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            capturedSystem = options.systemPrompt ?? ""
            return AsyncThrowingStream { c in
                c.yield(.completed(GenerationResult(text: "ok", metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    func test_system_prompt_has_no_save_memory_instruction() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry(), memory: nil)
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertFalse(rt.capturedSystem.lowercased().contains("save_memory"),
                       "live-turn system prompt must not instruct the model to call save_memory")
        XCTAssertTrue(rt.capturedSystem.contains("Answer only what the user asked"),
                      "the answer-only guidance stays")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/AgentSystemPromptTests 2>&1 | tail -20`
Expected: FAIL — current prompt contains "save_memory".

- [ ] **Step 3: Update `systemPrompt(memoryBlock:)`** in `Agent.swift` — replace the `base` string with one that drops the save/remember sentences (keep the rest verbatim):

```swift
        let base = """
        You are Gemma, a helpful on-device assistant. You can call tools to get real information. \
        When a tool is relevant (e.g. the user asks the time), call it instead of guessing. \
        Answer only what the user asked; do not list unrelated things you remember. \
        IMPORTANT: after any tool runs, ALWAYS reply to the user in a short, natural sentence — \
        confirm what you did or answer their question. Never end your turn with only a tool call.
        """
```

(Removed the two sentences: "Use the save_memory tool to store durable facts the user states about themselves." and "Save people, places, preferences, personality traits, tasks (things to do), and plans as memories with save_memory. You may call reflect to connect what you've learned." — the `reflect` capability remains available as a tool; we simply stop instructing memory-saving in the live turn.)

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/AgentSystemPromptTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Agent/Agent.swift Gemma/GemmaTests/AgentSystemPromptTests.swift
git commit -m "feat(m2d-1): drop save_memory instruction from the live-turn system prompt

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `HarnessModel` — wire short-term window in, append turns out, remove save_memory + EpisodeRecorder

**Files:**
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift`

> No new unit test (HarnessModel builds the real `ServerRuntime`; verified by build + the live E2E in Task 7). Keep edits surgical.

- [ ] **Step 1: Add a `TranscriptStore`, built lazily from the same DB as the memory store.** In `ensureMemory()`, right after `memoryStore` is created and unwrapped (where `let store = memoryStore` is available), build the transcript store once. Add a stored property near the other `@ObservationIgnored` vars:

```swift
    @ObservationIgnored private var transcriptStore: TranscriptStore?
```
and inside `ensureMemory()` after `guard let store = memoryStore else { return nil }`:
```swift
        if transcriptStore == nil { transcriptStore = TranscriptStore(dbQueue: store.dbQueue) }
```

- [ ] **Step 2: Remove the `SaveMemoryTool` registration.** In `runAgentTurn`, change the registration line:
```swift
        if memory != nil {
            registry.register(SaveMemoryTool()); registry.register(ForgetTool()); registry.register(ReflectTool())
        }
```
to (drop `SaveMemoryTool`):
```swift
        if memory != nil {
            registry.register(ForgetTool()); registry.register(ReflectTool())
        }
```

- [ ] **Step 3: Feed the short-term window into the turn.** Where `makeGenerationOptions()` is called to build the options for the `Agent` (in `runAgentTurn`), set the history from the transcript. Replace the options construction so it carries the window. Concretely, after `let agent = Agent(...)` is built and BEFORE `agent.run`, build options with history:

Change `makeGenerationOptions()` to accept history:
```swift
    private func makeGenerationOptions(history: [ChatMessage] = []) -> GenerationOptions {
        GenerationOptions(maxTokens: settings.maxOutputTokens, temperature: settings.temperature,
                          topP: settings.topP, topK: settings.topK,
                          systemPrompt: settings.systemPrompt.isEmpty ? nil : settings.systemPrompt,
                          history: history)
    }
```
And in `runAgentTurn`, build the window before the agent loop:
```swift
        let history: [ChatMessage] = {
            guard let ts = transcriptStore else { return [] }
            let rows = (try? ts.recent(threadId: threadId,
                                       maxTurns: ConversationWindow.defaultMaxTurns,
                                       maxChars: ConversationWindow.defaultMaxChars)) ?? []
            return ConversationWindow.messages(from: rows)
        }()
```
and pass it: change `agent.run(prompt: prompt, options: makeGenerationOptions())` to `agent.run(prompt: prompt, options: makeGenerationOptions(history: history))`.

- [ ] **Step 4: Append the turn to the transcript (replaces EpisodeRecorder).** Replace the episode-recording block (the `if memory != nil, let store = memoryStore { EpisodeRecorder.record(...) turnIndex += 1 }` block) with a transcript append:

```swift
        if let ts = transcriptStore {
            let now = Date().timeIntervalSince1970
            try? ts.append(threadId: threadId, turnIndex: turnIndex, role: "user", text: prompt, now: now)
            if !answer.isEmpty {
                try? ts.append(threadId: threadId, turnIndex: turnIndex, role: "assistant", text: answer, now: now)
            }
            turnIndex += 1
        }
```

- [ ] **Step 5: Build to verify it compiles** (and the full suite still passes; `EpisodeRecorder` still exists until Task 6, so no break):

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:" | tail -10`
Expected: ** TEST SUCCEEDED **. If a compile error mentions `EpisodeRecorder` is now unused, ignore (unused-import/func is not an error); it is deleted in Task 6.

- [ ] **Step 6: Commit**

```bash
git add Gemma/Gemma/Harness/HarnessModel.swift
git commit -m "feat(m2d-1): HarnessModel feeds short-term window, appends turns to transcript, drops save_memory

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Remove `EpisodeRecorder` + purge existing `conversation` nodes

**Files:**
- Delete: `Gemma/Gemma/Memory/EpisodeRecorder.swift`
- Delete: `Gemma/GemmaTests/EpisodeRecorderTests.swift` (if present)
- Modify: `Gemma/Gemma/Memory/MemoryStore.swift` (add migration `v5-purge-conversation-nodes`)
- Test: `Gemma/GemmaTests/PurgeConversationNodesTests.swift` (new)

- [ ] **Step 1: Write the failing test** `Gemma/GemmaTests/PurgeConversationNodesTests.swift`. It seeds a conversation node + a knowledge node directly, runs the purge, and asserts only the conversation node is gone:

```swift
import XCTest
import GRDB
@testable import Gemma

final class PurgeConversationNodesTests: XCTestCase {
    func test_purge_removes_conversation_nodes_keeps_knowledge() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let t = 1.0
        let convo = Node(id: "c1", kind: NodeKind.conversation.rawValue, label: "user: hi", body: "hi",
                         layer: .episodic, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 2,
                         decayRate: 0.1, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil,
                         sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        let fact = Node(id: "f1", kind: NodeKind.preference.rawValue, label: "sushi", body: "likes sushi",
                        layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3,
                        decayRate: 0.1, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil,
                        sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil)
        try store.upsert(convo)
        try store.upsert(fact)

        try store.purgeConversationNodes()

        let all = try store.allNodes()
        XCTAssertNil(all.first { $0.id == "c1" }, "conversation node must be purged")
        XCTAssertNotNil(all.first { $0.id == "f1" }, "knowledge node must remain")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/PurgeConversationNodesTests 2>&1 | tail -20`
Expected: COMPILE FAIL — `purgeConversationNodes` undefined.

- [ ] **Step 3: Add `purgeConversationNodes()` to `MemoryStore`** (near the other CRUD methods). It deletes conversation/episode raw-turn nodes and their satellites (FTS rows, embeddings, dangling edges):

```swift
    /// One-time cleanup (M2d-1): raw turns are no longer graph nodes. Delete legacy
    /// `conversation`/`episode` nodes and their FTS rows, embeddings, and dangling edges.
    func purgeConversationNodes() throws {
        try dbQueue.write { db in
            let kinds = [NodeKind.conversation.rawValue, NodeKind.episode.rawValue]
            let ids = try String.fetchAll(db, sql: "SELECT id FROM node WHERE kind IN (?, ?)", arguments: StatementArguments(kinds))
            guard !ids.isEmpty else { return }
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let args = StatementArguments(ids)
            try db.execute(sql: "DELETE FROM node WHERE id IN (\(placeholders))", arguments: args)
            try db.execute(sql: "DELETE FROM node_fts WHERE node_id IN (\(placeholders))", arguments: args)
            try db.execute(sql: "DELETE FROM node_embedding WHERE node_id IN (\(placeholders))", arguments: args)
            try db.execute(sql: "DELETE FROM edge WHERE srcId IN (\(placeholders)) OR dstId IN (\(placeholders))",
                           arguments: StatementArguments(ids + ids))
        }
    }
```

- [ ] **Step 4: Run it once on store open via migration.** In `migrator`, after `v4-transcript`, register a migration that calls the same SQL so existing installs get cleaned automatically:

```swift
        m.registerMigration("v5-purge-conversation-nodes") { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM node WHERE kind IN ('conversation','episode')")
            guard !ids.isEmpty else { return }
            let ph = ids.map { _ in "?" }.joined(separator: ",")
            let a = StatementArguments(ids)
            try db.execute(sql: "DELETE FROM node WHERE id IN (\(ph))", arguments: a)
            try db.execute(sql: "DELETE FROM node_fts WHERE node_id IN (\(ph))", arguments: a)
            try db.execute(sql: "DELETE FROM node_embedding WHERE node_id IN (\(ph))", arguments: a)
            try db.execute(sql: "DELETE FROM edge WHERE srcId IN (\(ph)) OR dstId IN (\(ph))",
                           arguments: StatementArguments(ids + ids))
        }
```

- [ ] **Step 5: Delete `EpisodeRecorder`.** Remove the file and any test:
```bash
git rm Gemma/Gemma/Memory/EpisodeRecorder.swift
git rm Gemma/GemmaTests/EpisodeRecorderTests.swift 2>/dev/null || true
```
Then search for any remaining reference and confirm there are none (HarnessModel's call was removed in Task 5):
```bash
grep -rn "EpisodeRecorder" Gemma/Gemma Gemma/GemmaTests || echo "no references"
```
Expected: `no references`. (If a reference remains, remove it — it must be unused after Task 5.)

- [ ] **Step 6: Run the full suite to verify it builds and passes**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:" | tail -10`
Expected: ** TEST SUCCEEDED **.

- [ ] **Step 7: Commit**

```bash
git add -A Gemma/Gemma/Memory/MemoryStore.swift Gemma/GemmaTests/PurgeConversationNodesTests.swift
git commit -m "feat(m2d-1): purge legacy conversation nodes (migration + method); remove EpisodeRecorder

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Final verification + graphify

- [ ] **Step 1: Run the complete suite**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED" | tail -2`
Expected: ** TEST SUCCEEDED **.

- [ ] **Step 2: (Optional, manual) live two-turn coherence + clean-graph check.** Requires the venv + cached model; kill anything on 8080 first. This is a manual smoke check (no automated assertion):
```bash
lsof -ti tcp:8080 | xargs -r kill
# In Xcode (⌘R): say "me llamo Roilan", then in a SECOND turn ask "¿cómo me llamo?".
# Expect: it answers "Roilan" from short-term context (no save_memory tool fired, no graph write).
# Open the Memory inspector: NO raw conversation nodes appear.
```

- [ ] **Step 3: Update the knowledge graph** (per CLAUDE.md, AST-only, no API cost)

Run: `graphify update .`

- [ ] **Step 4: Commit graph changes**

```bash
git add graphify-out ':!graphify-out/cache/ast'
git commit -m "chore(m2d-1): graphify update"
```

---

## Self-Review

**Spec coverage (M2d-1 slice, spec §9):**
- TranscriptStore (separate from graph) → Task 2. ✓
- Runtime short-term history (messages) → Task 1 (via `GenerationOptions.history`; full tool-role refactor explicitly deferred per SCOPE NOTE). ✓
- Agent history + remove save_memory → Tasks 3 (system prompt) + 5 (unregister tool) + window fed in Task 5. ✓
- HarnessModel append → Task 5. ✓
- Remove EpisodeRecorder + migration purge → Task 6. ✓
- Consolidation source swap + structured summaries → **deferred to M2d-2** (documented SCOPE NOTE; consolidation left safely dormant). ✓ (intentional gap)

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `ChatMessage(role:content:)`, `ChatMessage.Role {system,user,assistant}`, `GenerationOptions.history`, `TranscriptRow` fields (`id,threadId,turnIndex,role,text,createdAt,consolidated`), `TranscriptStore.{append,recent,range,unconsolidated,markConsolidated}`, `ConversationWindow.{messages,defaultMaxTurns,defaultMaxChars}`, `MemoryStore.purgeConversationNodes` — all used consistently across tasks. `recent` returns oldest-first; `ConversationWindow.messages` preserves order; `ServerRuntime` appends history between system and user — consistent.

**Note for the implementer:** Xcode 26.2 filesystem-synchronized groups auto-include new files under `Gemma/Gemma/Memory/` and `Gemma/GemmaTests/` — no `project.pbxproj` edits. `MemoryStore.dbQueue` is already accessible (internal `let dbQueue`); `TranscriptStore` reuses it. If a `EpisodeRecorderTests.swift` does not exist, the `git rm … || true` in Task 6 Step 5 is a no-op.
