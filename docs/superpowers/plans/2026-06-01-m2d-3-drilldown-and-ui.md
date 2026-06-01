# M2d-3 — Drill-down (`expand_context`) + Transcript UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Close the M2d memory loop: add an `expand_context` read-tool so the model can drill from a semantic summary into the verbatim chat log (N4) when the user asks for specifics, surface the raw conversation in a Transcript inspector tab, and tidy the two M2d-2 follow-ups (per-thread summarize + a clarifying comment).

**Architecture:** `expand_context` (a read tool, like `ForgetTool`) takes a `topic`, finds the matching `summary` node, reads its `extra` (`threadId`/`turnRange`), and returns the verbatim turns from `TranscriptStore.range(...)` (capped). Tools reach the transcript via a new `MemoryToolbox.transcriptStore` (set by `HarnessModel`, same pattern as `store`/`embedder`). The `MemoryView` inspector gains a **Transcript** tab backed by the `TranscriptStore` (the graph/list tabs are already knowledge-only since M2d-1 purged conversation nodes). The M2d-2 summarize phase is split per `threadId` so each session gets its own "ruta".

**Tech Stack:** Swift 6 / SwiftUI / GRDB / XCTest. mlx_vlm server. New files auto-included (filesystem-synchronized groups).

**Spec:** `docs/superpowers/specs/2026-06-01-m2d-live-context-clean-capture-design.md` (sub-plan **M2d-3** of §9). **Builds on M2d-1/M2d-2 (merged).**

**Key current facts (verified):**
- `MemoryToolbox` (`Memory/MemoryToolbox.swift`, `@MainActor final class`, `.shared`): has `var store: MemoryStore?`, `var embedder: Embedder?`, `var reflectionRequest: (() -> Void)?`. Set by `HarnessModel.ensureMemory()`.
- Tool pattern (`Memory/ForgetTool.swift`): `struct X: AgentTool { static let name/description/parameters; func run(argsJSON:) async -> String }`; reads `MemoryToolbox.shared.store`; wraps work in `await MainActor.run`; emits `ToolActivityRelay.shared.started/finished`. `AgentToolParam(name:type:description:required:)`, `type: .string`.
- `TranscriptStore` (`Memory/TranscriptStore.swift`): `range(threadId:fromTurn:toTurn:) -> [TranscriptRow]`, `recent(threadId:maxTurns:maxChars:)`, `rows(ids:)`, etc. `TranscriptRow{id,threadId,turnIndex,role,text,createdAt,consolidated}`. Built from `MemoryStore.dbQueue`.
- `summary` nodes: `kind == NodeKind.summary.rawValue`, `label = topic`, `extra` JSON has `threadId` + `turnRange:[lo,hi]`. `MemoryStore.searchFTS(query:limit:) -> [Node]` and `allNodes()` exist; `MemoryText.dedupKey(_)` for label matching.
- `HarnessModel.runAgentTurn` registers tools when `memory != nil`: `registry.register(ForgetTool()); registry.register(ReflectTool())`. `ensureMemory()` sets `MemoryToolbox.shared.store/embedder` and builds `transcriptStore`.
- `MemoryView` (`Harness/MemoryView.swift`): a `Picker` over `enum Mode { lista, grafo }` → `MemoryInspectorView(store:)` / `MemoryGraphView(store:)`.
- `MemoryConsolidationEngine.runCycle` `.summarize` case currently summarizes the whole batch as ONE summary (`rows.first?.threadId`, global turnRange).

**Build/test command (success = "Test Suite … passed"):**
```bash
xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS'
```

---

### Task 1: Summarize per `threadId` (M2d-2 follow-up)

**Files:**
- Modify: `Gemma/Gemma/Memory/MemoryConsolidationEngine.swift` (the `.summarize` case in `runCycle`)
- Test: `Gemma/GemmaTests/MemoryConsolidationEngineTests.swift`

- [ ] **Step 1: Write the failing test** — append to `MemoryConsolidationEngineTests`:

```swift
    func test_summarize_groups_by_thread_one_summary_per_session() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        // two distinct sessions in one unconsolidated batch
        try ts.append(threadId: "A", turnIndex: 0, role: "user", text: "quiero ir a Japón", now: 1)
        try ts.append(threadId: "B", turnIndex: 0, role: "user", text: "me gusta el ajedrez", now: 2)
        // one summarize response per thread group (order: A then B by first appearance/createdAt)
        let runtime = ScriptedRuntime(responses: [
            #"{"entities":[]}"#,  // nrem
            #"{"topic":"viaje Japón","concepts":["Japón"],"summary":"viaje"}"#,   // summarize thread A
            #"{"topic":"ajedrez","concepts":["ajedrez"],"summary":"hobby"}"#,      // summarize thread B
            #"{"followUps":[]}"#, #"{"edges":[]}"#, #"{"insights":[]}"#, #"{"map":{}}"#
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.runCycle(isCancelled: { false })
        let summaries = try store.allNodes().filter { $0.kind == NodeKind.summary.rawValue }
        XCTAssertEqual(Set(summaries.map { $0.label }), ["viaje Japón", "ajedrez"], "one summary per thread")
    }
```
> If `ScriptedRuntime` returns canned responses positionally, the per-thread order must be deterministic — implement the grouping to iterate threads sorted by each group's min `createdAt` (so thread "A" then "B"). The test relies on that order.

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryConsolidationEngineTests/test_summarize_groups_by_thread_one_summary_per_session 2>&1 | tail -20`
Expected: FAIL — current code makes ONE summary for the whole batch (only one label present).

- [ ] **Step 3: Update the `.summarize` case** in `runCycle` to group by thread (deterministic order by each group's earliest `createdAt`):

```swift
            case .summarize:
                let rows = (try? transcriptStore.rows(ids: state.episodeIds)) ?? []
                // One summary per session (threadId). user+assistant of a turn share a turnIndex
                // by design, so a single-turn group yields turnRange i...i.
                let groups = Dictionary(grouping: rows, by: { $0.threadId })
                    .sorted { ($0.value.map(\.createdAt).min() ?? 0) < ($1.value.map(\.createdAt).min() ?? 0) }
                for (threadId, tRows) in groups {
                    let turns = tRows.map { $0.turnIndex }
                    let range = (turns.min() ?? 0)...(turns.max() ?? 0)
                    let texts = tRows.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
                    await summarize(episodeTexts: texts, threadId: threadId, turnRange: range)
                }
```

- [ ] **Step 4: Run to verify it passes** (+ the existing engine tests still pass — the single-thread tests now go through the one-group path):

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryConsolidationEngineTests 2>&1 | tail -20`
Expected: PASS (all, including the existing single-thread runCycle/summarize tests). Then full suite green.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Memory/MemoryConsolidationEngine.swift Gemma/GemmaTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(m2d-3): summarize one node per thread (session) in a consolidation batch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `MemoryToolbox.transcriptStore` + `expand_context` tool

**Files:**
- Modify: `Gemma/Gemma/Memory/MemoryToolbox.swift` (add `transcriptStore`)
- Create: `Gemma/Gemma/Memory/ExpandContextTool.swift`
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift` (set `MemoryToolbox.shared.transcriptStore`; register the tool)
- Test: `Gemma/GemmaTests/ExpandContextToolTests.swift` (new)

- [ ] **Step 1: Write the failing test** `Gemma/GemmaTests/ExpandContextToolTests.swift`:

```swift
import XCTest
@testable import Gemma

@MainActor
final class ExpandContextToolTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.store = nil
        MemoryToolbox.shared.transcriptStore = nil
        super.tearDown()
    }

    func test_expand_returns_verbatim_turns_for_a_summary_topic() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "quiero ir a Japón en abril", now: 1)
        try ts.append(threadId: "T", turnIndex: 0, role: "assistant", text: "buena idea", now: 2)
        // a summary node referencing that thread + turn range
        let extra = #"{"concepts":["Japón"],"threadId":"T","turnRange":[0,0]}"#
        let summary = Node(id: "s1", kind: NodeKind.summary.rawValue, label: "viaje a Japón", body: "Plan a trip",
                           layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 4, decayRate: 0.1,
                           confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: "T",
                           origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: extra)
        try store.upsert(summary)
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.transcriptStore = ts

        let out = await ExpandContextTool().run(argsJSON: #"{"topic":"viaje a Japón"}"#)
        XCTAssertTrue(out.contains("quiero ir a Japón en abril"), "must return the verbatim user turn; got: \(out)")
        XCTAssertTrue(out.contains("buena idea"), "must include the assistant turn")
    }

    func test_expand_unknown_topic_is_safe() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        MemoryToolbox.shared.store = store
        MemoryToolbox.shared.transcriptStore = TranscriptStore(dbQueue: store.dbQueue)
        let out = await ExpandContextTool().run(argsJSON: #"{"topic":"inexistente"}"#)
        XCTAssertFalse(out.isEmpty)   // a graceful "no detail found" message, never a crash
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ExpandContextToolTests 2>&1 | tail -20`
Expected: COMPILE FAIL — `MemoryToolbox.transcriptStore` and `ExpandContextTool` undefined.

- [ ] **Step 3: Add `transcriptStore` to `MemoryToolbox`** (after `embedder`):
```swift
    var transcriptStore: TranscriptStore?
```

- [ ] **Step 4: Create `Gemma/Gemma/Memory/ExpandContextTool.swift`:**
```swift
import Foundation

/// Drill-down (N4): given a topic the model already knows from a summary, return the verbatim
/// chat turns behind it. A READ tool — fires only when the user asks for specifics the summary
/// doesn't carry. Resolves the topic to a `summary` node, reads its threadId + turnRange, and
/// returns the raw turns from the TranscriptStore (capped).
struct ExpandContextTool: AgentTool {
    static let name = "expand_context"
    static let description = """
    Retrieve the exact past messages behind a remembered topic, when the user asks for specific \
    details a summary doesn't contain (e.g. "what exactly did I say about X"). Pass the topic.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "topic", type: .string, description: "The topic/summary to expand into verbatim past messages.", required: true)
    ]

    private struct Ref: Decodable { let threadId: String?; let turnRange: [Int]? }

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let topic = ((obj["topic"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return "no topic given" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: topic) }
        let result: String = await MainActor.run {
            guard let store = MemoryToolbox.shared.store, let ts = MemoryToolbox.shared.transcriptStore else {
                return "memory unavailable"
            }
            // Find the best-matching summary node (FTS, else label dedupKey match).
            let key = MemoryText.dedupKey(topic)
            let summaries = ((try? store.allNodes()) ?? []).filter { $0.kind == NodeKind.summary.rawValue }
            let match = (try? store.searchFTS(query: topic, limit: 10))?.first { $0.kind == NodeKind.summary.rawValue }
                ?? summaries.first { MemoryText.dedupKey($0.label) == key }
                ?? summaries.first { $0.label.localizedCaseInsensitiveContains(topic) }
            guard let node = match, let raw = node.extra?.data(using: .utf8),
                  let ref = try? JSONDecoder().decode(Ref.self, from: raw),
                  let threadId = ref.threadId, let tr = ref.turnRange, tr.count == 2 else {
                return "no detail found for \"\(topic)\""
            }
            let rows = (try? ts.range(threadId: threadId, fromTurn: tr[0], toTurn: tr[1])) ?? []
            guard !rows.isEmpty else { return "no detail found for \"\(topic)\"" }
            let lines = rows.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
            return String(lines.joined(separator: "\n").prefix(4000))
        }
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
```

- [ ] **Step 5: Wire it in `HarnessModel`.** In `ensureMemory()`, where `MemoryToolbox.shared.store`/`embedder` are set, also set the transcript store (the local `transcriptStore` is built just above in that method):
```swift
        MemoryToolbox.shared.transcriptStore = transcriptStore
```
And in `runAgentTurn`, register the tool alongside the other memory tools:
```swift
        if memory != nil {
            registry.register(ForgetTool()); registry.register(ReflectTool()); registry.register(ExpandContextTool())
        }
```

- [ ] **Step 6: Run to verify it passes**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ExpandContextToolTests 2>&1 | tail -20`
Expected: PASS. Then full suite green.

- [ ] **Step 7: Commit**

```bash
git add Gemma/Gemma/Memory/MemoryToolbox.swift Gemma/Gemma/Memory/ExpandContextTool.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/ExpandContextToolTests.swift
git commit -m "feat(m2d-3): expand_context drill-down tool (summary -> verbatim turns)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Transcript inspector tab

**Files:**
- Modify: `Gemma/Gemma/Memory/TranscriptStore.swift` (add `allRecent(limit:)`)
- Create: `Gemma/Gemma/Harness/TranscriptInspectorView.swift`
- Modify: `Gemma/Gemma/Harness/MemoryView.swift` (add a Transcript tab)
- Test: `Gemma/GemmaTests/TranscriptStoreTests.swift` (add an `allRecent` test)

- [ ] **Step 1: Write the failing test** — append to `TranscriptStoreTests`:
```swift
    func test_allRecent_returnsNewestFirst_acrossThreads() throws {
        let s = try makeStore()
        try s.append(threadId: "a", turnIndex: 0, role: "user", text: "one", now: 1)
        try s.append(threadId: "b", turnIndex: 0, role: "user", text: "two", now: 2)
        let rows = try s.allRecent(limit: 10)
        XCTAssertEqual(rows.map { $0.text }, ["two", "one"], "newest first across all threads")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/TranscriptStoreTests/test_allRecent_returnsNewestFirst_acrossThreads 2>&1 | tail -20`
Expected: COMPILE FAIL — `allRecent` undefined.

- [ ] **Step 3: Add `allRecent(limit:)` to `TranscriptStore`** (after `recent(...)`):
```swift
    /// Newest-first turns across all threads — for the read-only Transcript inspector.
    func allRecent(limit: Int) throws -> [TranscriptRow] {
        try dbQueue.read { db in
            try TranscriptRow.order(Column("createdAt").desc, Column("turnIndex").desc).limit(limit).fetchAll(db)
        }
    }
```

- [ ] **Step 4: Create `Gemma/Gemma/Harness/TranscriptInspectorView.swift`:**
```swift
import SwiftUI

/// Read-only view of the raw conversation log (the N4 substrate), newest-first. Separate from
/// the knowledge graph/list tabs (which show distilled memory only).
struct TranscriptInspectorView: View {
    let store: MemoryStore?
    @State private var rows: [TranscriptRow] = []

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView("Sin conversación", systemImage: "text.bubble",
                                       description: Text("Aún no hay turnos guardados en el transcript."))
            } else {
                List(rows, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.role == "assistant" ? "Gemma" : "Tú")
                            .font(.caption).foregroundStyle(row.role == "assistant" ? .blue : .secondary)
                        Text(row.text).textSelection(.enabled)
                    }
                }
            }
        }
        .task {
            guard let store else { return }
            rows = (try? TranscriptStore(dbQueue: store.dbQueue).allRecent(limit: 200)) ?? []
        }
    }
}
```

- [ ] **Step 5: Add a Transcript tab to `MemoryView`.** Extend the `Mode` enum and switch:
```swift
    private enum Mode: String, CaseIterable { case lista = "Lista", grafo = "Grafo", transcript = "Transcript" }
```
and in the `switch mode`:
```swift
            case .transcript: TranscriptInspectorView(store: store)
```

- [ ] **Step 6: Build + full suite**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:" | tail -8`
Expected: ** TEST SUCCEEDED **.

- [ ] **Step 7: Commit**

```bash
git add Gemma/Gemma/Memory/TranscriptStore.swift Gemma/Gemma/Harness/TranscriptInspectorView.swift Gemma/Gemma/Harness/MemoryView.swift Gemma/GemmaTests/TranscriptStoreTests.swift
git commit -m "feat(m2d-3): read-only Transcript inspector tab

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Final verification + graphify

- [ ] **Step 1: Full suite**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED" | tail -2`
Expected: ** TEST SUCCEEDED **.

- [ ] **Step 2: (Optional, gated real-26B) drill-down smoke check.** Start the server (`cd spike-mlx && .venv-vlm/bin/python serve_mlx_vlm.py --model unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit --draft-model guardiangate1775/gemma-4-26B-A4B-it-assistant-4bit --draft-kind mtp --draft-block-size 3 --port 8080`), then in Xcode (⌘R): have a conversation, trigger consolidation (or wait idle), then ask "¿qué te dije exactamente sobre <topic>?" → confirm the model calls `expand_context` and answers with verbatim detail. Kill the server after.

- [ ] **Step 3: graphify** — `graphify update .`

- [ ] **Step 4: Commit graph**
```bash
git add graphify-out ':!graphify-out/cache/ast'
git commit -m "chore(m2d-3): graphify update"
```

---

## Self-Review

**Spec coverage (M2d-3, spec §9):**
- `expand_context` drill-down tool → Task 2. ✓
- `MemoryView` knowledge-only → already true since M2d-1 (conversation nodes purged/not created); Transcript tab added → Task 3. ✓
- M2d-2 follow-up: per-thread summarize → Task 1; turnRange comment → added in Task 1's `.summarize` code. ✓

**Placeholder scan:** none — concrete code/commands throughout.

**Type consistency:** `MemoryToolbox.transcriptStore`, `ExpandContextTool` (name "expand_context", param `topic`), `Ref{threadId,turnRange}` decoding the summary `extra` written by M2d-2's `summarize`, `TranscriptStore.range(threadId:fromTurn:toTurn:)`/`allRecent(limit:)`, `MemoryView.Mode.transcript`, `TranscriptInspectorView(store:)` — all consistent. The `extra` keys (`threadId`, `turnRange:[lo,hi]`) match exactly what M2d-2 `summarize` writes.

**Notes for the implementer:**
- `ScriptedRuntime` in `MemoryConsolidationEngineTests` returns canned responses positionally; Task 1's per-thread grouping iterates threads ordered by earliest `createdAt`, so the test's response order (thread A, then B) is deterministic.
- `MemoryToolbox` is `@MainActor`; `ExpandContextTool.run` already hops via `await MainActor.run` (matches `ForgetTool`). Reset the toolbox singleton in test `tearDown` (the test does).
- New files auto-included (filesystem-synchronized groups) — no `project.pbxproj` edits.
