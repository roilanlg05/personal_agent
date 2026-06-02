# Temporal anchoring · event clarification · proactive contact — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make memory time-aware and human-like: (1) anchor relative dates ("tomorrow") to absolute dates; (2) stop silently merging distinct events (two meetings with Carlos) — instead ask the user when consolidation is unsure; (3) recall ALL matching memories, not just the newest; (4) let the agent proactively message the user (in-chat for now) when it has a clarification question or a due reminder — never chit-chat.

**Diagnosis (from live `memory.sqlite`):** the Carlos task is stored as `"…in Florida tomorrow at 10:00"` (relative, no absolute date) and a second meeting (Wednesday) collapsed into one node (semantic dedup of same-kind task) — the agent itself said *"me enfoqué únicamente en la información más reciente."* No current-date is injected anywhere, so relative dates rot.

**Decisions (user, 2026-06-01):** store the absolute date in BOTH the readable body and `extra.date`. Don't blanket-block event merges — the same task can be rephrased/extended; instead the model **asks the user during reflection/sleep when unsure**. Proactive contact: **in-chat this batch, macOS notifications later** (iOS companion app planned).

**Tech Stack:** Swift 6 / SwiftUI / GRDB / XCTest. Consolidation runs thinking-OFF, JSON-only.

**Build/test:** `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS'`. (Transient launch failures: re-run once. SourceKit single-file diagnostics are false positives.)

---

### Task 1: Temporal anchoring (today's date in prompts + absolute dates stored)

**Files:** `Gemma/Gemma/Memory/NodeAttributes.swift`, `Gemma/Gemma/Memory/MemoryConsolidationEngine.swift`, `Gemma/Gemma/Agent/Agent.swift`; tests in `MemoryConsolidationEngineTests.swift` + `AgentSystemPromptTests.swift`.

- [ ] **Step 1: failing tests.**
In `Gemma/GemmaTests/MemoryConsolidationEngineTests.swift` append:
```swift
    func test_consolidate_stores_absolute_date_for_a_task() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "mañana reunión con Carlos", now: 1)
        let runtime = CannedRuntime([
            #"{"entities":[{"entity":"reunión con Carlos","kind":"task","detail":"meeting","attributes":{"status":"pending","date":"2026-06-02"}}]}"#
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.consolidate(episodeTexts: ["User: mañana reunión con Carlos"])
        let task = try XCTUnwrap(try store.allNodes().first { $0.kind == NodeKind.task.rawValue })
        XCTAssertEqual(NodeAttributes.from(task.extra).date, "2026-06-02", "absolute date stored in extra")
        XCTAssertTrue(task.body.contains("2026-06-02"), "absolute date also folded into the body")
    }
```
In `Gemma/GemmaTests/AgentSystemPromptTests.swift` append (reuse the file's `CapturingRuntime`):
```swift
    func test_system_prompt_includes_todays_date() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry(), memory: nil)
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        XCTAssertTrue(rt.capturedSystem.contains(df.string(from: Date())), "system prompt must state today's date")
    }
```

- [ ] **Step 2: run → expect FAIL/compile-fail.**
`xcodebuild test ... -only-testing:GemmaTests/MemoryConsolidationEngineTests -only-testing:GemmaTests/AgentSystemPromptTests 2>&1 | tail -20`

- [ ] **Step 3: `NodeAttributes` — add `date`.** Add `var date: String?     // task/plan: absolute ISO date (yyyy-MM-dd), resolved from relative refs` and include it in the `toJSON()` non-nil guard: `guard status != nil || horizon != nil || date != nil else { return nil }`.

- [ ] **Step 4: consolidate — inject today's date, parse + store `date`.** In `MemoryConsolidationEngine`:
  - Add a helper:
```swift
    private func todayString() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd (EEEE)"
        return f.string(from: Date(timeIntervalSince1970: now()))
    }
```
  - In `EntitiesOut.E.Attr`, add `let date: String?`.
  - Prompt: prepend a line `Today is \(todayString()). Resolve any relative date (today/tomorrow/a weekday) to an absolute date and put it in attributes.date as "yyyy-MM-dd".` and add `"date":"yyyy-MM-dd"` to the schema's attributes example.
  - Set `attrs.date = e.attributes?.date`.
  - Fold the date into the body so recall/FTS sees it:
```swift
            let baseBody = e.detail ?? label
            let body = (attrs.date != nil) ? baseBody + " (fecha: \(attrs.date!))" : baseBody
```
    and use `body` in the Node init (replace `body: e.detail ?? label`).

- [ ] **Step 5: `summarize` — inject today's date** too: prepend `Today is \(todayString()). ` to the summarize prompt (so summaries anchor dates). (Keep the rest from the prior batch.)

- [ ] **Step 6: `Agent.systemPrompt` — state today's date.** In `systemPrompt(memoryBlock:)`, prepend to `base` a dated line. Compute once at call time:
```swift
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd (EEEE)"
        let today = df.string(from: Date())
        let base = """
        You are Gemma, a helpful on-device assistant. Today is \(today). \
        You can call tools to get real information. ...
        """
```
(Keep the rest of `base` verbatim — just prepend the "Today is …" sentence after "assistant.")

- [ ] **Step 7: run → expect PASS**, then full suite green. Commit:
```bash
git add Gemma/Gemma/Memory/NodeAttributes.swift Gemma/Gemma/Memory/MemoryConsolidationEngine.swift Gemma/Gemma/Agent/Agent.swift Gemma/GemmaTests/MemoryConsolidationEngineTests.swift Gemma/GemmaTests/AgentSystemPromptTests.swift
git commit -m "feat(memory): temporal anchoring — today's date in prompts; absolute dates on tasks/plans"
```

---

### Task 2: Don't silently merge distinct events

**Files:** `Gemma/Gemma/Memory/MemoryConsolidationEngine.swift` (`consolidate`); test in `MemoryConsolidationEngineTests.swift`.

- [ ] **Step 1: failing test.**
```swift
    func test_distinct_tasks_are_not_merged() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "T", turnIndex: 0, role: "user", text: "x", now: 1)
        let runtime = CannedRuntime([
            #"{"entities":[{"entity":"reunión con Carlos","kind":"task","detail":"mañana","attributes":{"status":"pending","date":"2026-06-02"}},{"entity":"reunión con Carlos","kind":"task","detail":"miércoles","attributes":{"status":"pending","date":"2026-06-04"}}]}"#
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.consolidate(episodeTexts: ["User: x"])
        let tasks = try store.allNodes().filter { $0.kind == NodeKind.task.rawValue }
        XCTAssertEqual(tasks.count, 2, "two distinct meetings (different dates) must NOT collapse into one")
    }
```
> NOTE: with `embedder: nil`, no semantic dedup runs, but `findDuplicate` (by canonical label) would still merge two same-label tasks. The fix (Step 3) must make task/plan skip BOTH merge paths → plain `upsert`. Confirm the test fails today: two same-label tasks currently merge via `findDuplicate` → count 1.

- [ ] **Step 2: run → expect FAIL** (count == 1 today).

- [ ] **Step 3: implement.** In `consolidate`'s loop, replace the final write with an event-kind branch:
```swift
            let eventKinds: Set<String> = [NodeKind.task.rawValue, NodeKind.plan.rawValue]
            if eventKinds.contains(kind) {
                // Events are distinct occurrences — never auto-merge (would lose a meeting).
                // Ambiguous same-vs-different is resolved by clarify() asking the user (Task 3).
                do { try store.upsert(node); if let emb { try store.setEmbedding(nodeId: node.id, emb) }; added += 1 } catch {}
            } else if (try? store.upsertMergingSemantic(node, embedding: emb, embedder: embedder)) != nil {
                added += 1
            }
```
(Confirm `store.setEmbedding(nodeId:_:)` exists — it's used in `MemoryStore+Dedup`. If its label differs, match it.)

- [ ] **Step 4: run → expect PASS** (count == 2) + full suite green. Commit:
```bash
git add Gemma/Gemma/Memory/MemoryConsolidationEngine.swift Gemma/GemmaTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(memory): events (task/plan) are distinct — stop silently merging meetings"
```

---

### Task 3: Clarification — consolidation asks when unsure

**Files:** `Gemma/Gemma/Memory/MemoryModels.swift` (NodeKind), `Gemma/Gemma/Memory/MemoryStore.swift` (SleepPhase + pendingClarifications), `Gemma/Gemma/Memory/MemoryConsolidationEngine.swift` (`clarify()` + wire into cycle/light); tests.

- [ ] **Step 1: failing test** (engine emits a clarification node from a canned response):
```swift
    func test_clarify_emits_clarification_node_when_unsure() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        // two similar tasks already in the graph
        func task(_ id: String, _ label: String, _ detail: String) -> Node {
            Node(id: id, kind: NodeKind.task.rawValue, label: label, body: detail, layer: .daily, createdAt: 1, updatedAt: 1,
                 lastSeenAt: 1, salience: 3, decayRate: 0.1, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                 sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        }
        try store.upsert(task("t1", "reunión con Carlos", "mañana"))
        try store.upsert(task("t2", "reunión con Carlos", "miércoles"))
        let runtime = CannedRuntime([
            #"{"questions":["¿La reunión con Carlos del miércoles es la misma que la de mañana o son dos distintas?"]}"#
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.clarify()
        let q = try store.allNodes().first { $0.kind == NodeKind.clarification.rawValue }
        XCTAssertNotNil(q, "an ambiguous pair should produce a clarification question")
        XCTAssertTrue(q!.body.contains("Carlos"))
        XCTAssertEqual(NodeAttributes.from(q!.extra).status, "pending")
    }
```

- [ ] **Step 2: run → expect COMPILE FAIL** (`NodeKind.clarification`, `clarify()` undefined).

- [ ] **Step 3: add `clarification` to `NodeKind`** (`MemoryModels.swift`): insert `clarification` (e.g. after `followUp`): `..., conversation, followUp = "follow_up", clarification`.

- [ ] **Step 4: implement `clarify()` in the engine.** Gather task/plan (+other) nodes, ask the model for genuine ambiguities, store each as a `clarification` node (status pending):
```swift
    private struct ClarifyOut: Decodable { let questions: [String] }

    /// During reflection/sleep: if consolidation is unsure whether two memories are the same
    /// (e.g. a task rephrased/extended vs a genuinely new one), ask the USER instead of guessing.
    /// Emits pending `clarification` nodes (surfaced proactively in chat — Task 5). Never invents.
    func clarify() async {
        let events = ((try? store.allNodes()) ?? [])
            .filter { $0.kind == NodeKind.task.rawValue || $0.kind == NodeKind.plan.rawValue }
        guard events.count >= 2 else { return }
        let list = events.map { "- [\($0.kind)] \($0.label): \($0.body)" }.joined(separator: "\n")
        let prompt = """
        Today is \(todayString()). These are the user's tasks/plans. ONLY if two of them might be the SAME thing
        described twice (a rephrase/extension) and you are genuinely UNSURE, write a short question to ask the user
        to disambiguate. If everything is clearly distinct, return an empty list. Output JSON only. Never invent.
        Schema: {"questions":["<short question>"]}
        Items:
        \(list)
        JSON:
        """
        guard let out = parse(await generate(prompt, maxTokens: 256), ClarifyOut.self) else { return }
        let existing = Set(((try? store.allNodes()) ?? [])
            .filter { $0.kind == NodeKind.clarification.rawValue }.map { MemoryText.dedupKey($0.body) })
        var added = 0
        for q in out.questions {
            let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || existing.contains(MemoryText.dedupKey(text)) { continue }
            var attrs = NodeAttributes(); attrs.status = "pending"
            let t = now()
            let node = Node(id: UUID().uuidString, kind: NodeKind.clarification.rawValue, label: String(text.prefix(60)),
                            body: text, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 4,
                            decayRate: Decay.defaultDecayRate(for: .daily), confidence: .probable, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false,
                            extra: attrs.toJSON())
            try? store.upsert(node); added += 1
        }
        if added > 0 { onProgress?("+\(added) question\(added == 1 ? "" : "s")") }
    }
```

- [ ] **Step 5: wire `clarify()` into consolidation.** Add `clarify` to the `SleepPhase` enum (`MemoryStore.swift`): `case nrem, summarize, detect, rem, reflect, clarify, curate, shy` (insert `clarify` before `curate`). In `runCycle`'s `order` add `.clarify` in the same position, and a `case .clarify: await clarify()` in the switch. Also call `await clarify()` in `runLight` after `reflect()`.

- [ ] **Step 6: add `MemoryStore.pendingClarifications()`** (for Task 5):
```swift
    func pendingClarifications(limit: Int = 5) throws -> [Node] {
        try dbQueue.read { db in
            try Node.filter(Column("kind") == NodeKind.clarification.rawValue && Column("deleted") == false)
                .order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }.filter { NodeAttributes.from($0.extra).status != "done" }
    }
```

- [ ] **Step 7: run → expect PASS** + full suite green. Commit:
```bash
git add Gemma/Gemma/Memory/MemoryModels.swift Gemma/Gemma/Memory/MemoryStore.swift Gemma/Gemma/Memory/MemoryConsolidationEngine.swift Gemma/GemmaTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(memory): clarify() — consolidation asks the user when unsure about merging events"
```

---

### Task 4: Recall completeness (prompt)

**Files:** `Gemma/Gemma/Agent/Agent.swift`; test in `AgentSystemPromptTests.swift`.

- [ ] **Step 1: failing test.**
```swift
    func test_system_prompt_asks_to_mention_all_matching_memories() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry(), memory: nil)
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedSystem.localizedCaseInsensitiveContains("all of them"),
                      "prompt should tell the model to mention all matching memories, not only the newest")
    }
```

- [ ] **Step 2: run → expect FAIL.**

- [ ] **Step 3: implement.** In `Agent.systemPrompt`'s `base`, change the existing "Answer only what the user asked; do not list unrelated things you remember." sentence to ALSO require completeness for matching memories:
```swift
        Answer only what the user asked; do not list unrelated things you remember. \
        But when several remembered facts match the question (e.g. multiple meetings or events), \
        mention ALL of them with their dates — never answer with only the most recent. \
```
(Keep the rest verbatim. Preserve the existing "Answer only what the user asked" substring so the prior test still passes.)

- [ ] **Step 4: run → expect PASS** + full suite green. Commit:
```bash
git add Gemma/Gemma/Agent/Agent.swift Gemma/GemmaTests/AgentSystemPromptTests.swift
git commit -m "feat(agent): recall completeness — mention all matching memories, not just the newest"
```

---

### Task 5: Proactive in-chat contact (clarifications + due reminders)

**Files:** `Gemma/Gemma/Memory/MemoryStore.swift` (`dueReminders`), `Gemma/Gemma/Harness/HarnessModel.swift` (pure builder + surface + wire), `Gemma/Gemma/Harness/AgentChatView.swift` (indicator); tests for the pure builder.

- [ ] **Step 1: failing test** for a PURE builder on HarnessModel (testable without spawning the server):
```swift
import XCTest
@testable import Gemma

final class ProactiveMessagesTests: XCTestCase {
    func test_builds_messages_from_clarifications_and_due_reminders() {
        let clar = "¿La reunión con Carlos del miércoles es la misma que la de mañana?"
        let due = "Reunión con Carlos (fecha: 2026-06-02)"
        let msgs = HarnessModel.proactiveMessages(clarifications: [clar], dueReminders: [due])
        XCTAssertTrue(msgs.contains { $0.contains(clar) }, "surfaces the clarification question")
        XCTAssertTrue(msgs.contains { $0.contains("Carlos") }, "surfaces the due reminder")
        XCTAssertTrue(HarnessModel.proactiveMessages(clarifications: [], dueReminders: []).isEmpty)
    }
}
```

- [ ] **Step 2: run → expect COMPILE FAIL.**

- [ ] **Step 3: `MemoryStore.dueReminders(now:)`** — pending task/plan whose `extra.date` is today or earlier:
```swift
    /// Pending tasks/plans whose absolute date (extra.date, yyyy-MM-dd) is today or past.
    func dueReminders(today: String) throws -> [Node] {
        let kinds: Set<String> = [NodeKind.task.rawValue, NodeKind.plan.rawValue]
        return try allNodes().filter {
            kinds.contains($0.kind) && !$0.deleted
            && NodeAttributes.from($0.extra).status != "done"
            && (NodeAttributes.from($0.extra).date.map { $0 <= today } ?? false)
        }
    }
```
(ISO `yyyy-MM-dd` strings compare lexicographically == chronologically.)

- [ ] **Step 4: HarnessModel — pure builder + surface + wire.**
Pure builder (static, testable):
```swift
    /// Compose agent-initiated chat lines from pending clarifications + due reminders. Empty when
    /// there's nothing to say (the agent never speaks for chit-chat).
    static func proactiveMessages(clarifications: [String], dueReminders: [String]) -> [String] {
        var out: [String] = []
        for r in dueReminders { out.append("gemma: ⏰ Recordatorio: \(r)") }
        for c in clarifications { out.append("gemma: ❓ \(c)") }
        return out
    }
```
Add an observed flag + a surface method:
```swift
    var hasProactive: Bool = false

    /// Post the agent's pending clarifications + due reminders into the chat (no-op if none, and
    /// no-op while a turn is running so it never interrupts the user mid-answer).
    func surfaceProactive() {
        guard !agentRunning, let store = memoryStore else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        let clar = ((try? store.pendingClarifications()) ?? []).map { $0.body }
        let due = ((try? store.dueReminders(today: today)) ?? []).map { $0.body }
        let msgs = Self.proactiveMessages(clarifications: clar, dueReminders: due)
        guard !msgs.isEmpty else { return }
        agentLog.append(contentsOf: msgs)
        hasProactive = true
    }
```
Wire it: after a consolidation cycle finishes, surface. In `ensureMemory()` where `engine.onProgress` is set, ALSO surface on "done" — simplest: in the `ConsolidationScheduler`'s completion the state becomes `.done`; have HarnessModel call `surfaceProactive()` then. Add to the scheduler init a callback OR (simpler) call `surfaceProactive()` at the START of the NEXT `runAgentTurn` (so pending items show when the user returns) AND expose `consolidateNow` to also surface after. For THIS task, the reliable hook: at the top of `runAgentTurn`, BEFORE appending the user line, call `surfaceProactive()` (shows anything pending from the last idle consolidation). That guarantees the user sees pending questions/reminders when they return, with no new background-trigger plumbing.
```swift
    public func runAgentTurn(_ prompt: String) async {
        surfaceProactive()
        agentRunning = true; defer { agentRunning = false }
        ...
```
(Resetting `hasProactive`: clear it when the user reads — set `hasProactive = false` at the end of `surfaceProactive` consumption is tricky; for now leave `hasProactive` as a "there are pending items" hint the UI can show; Task is in-chat so the messages themselves are the surfacing.)

- [ ] **Step 5: AgentChatView indicator (optional, light).** If `model.hasProactive`, you may show a small "💡 Gemma te dejó notas" caption above the input. Minimal; skip if it complicates — the proactive `gemma:` lines already render in the transcript.

- [ ] **Step 6: run → expect PASS** (the pure-builder test) + full suite green. Commit:
```bash
git add Gemma/Gemma/Memory/MemoryStore.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/Gemma/Harness/AgentChatView.swift Gemma/GemmaTests/ProactiveMessagesTests.swift
git commit -m "feat(agent): proactive in-chat contact — surface clarifications + due reminders when the user returns"
```

---

### Task 6: Verification + graphify

- [ ] **Step 1:** full suite → ** TEST SUCCEEDED **.
- [ ] **Step 2 (optional, gated real-26B):** ⌘R: say "mañana tengo reunión con Carlos", later (new session, after consolidation) ask "¿cuándo es mi reunión con Carlos?" → should give the absolute/relative date correctly; add a 2nd meeting and confirm both are recalled / a clarification is asked.
- [ ] **Step 3:** `graphify update .`
- [ ] **Step 4:** commit graph (`git add graphify-out ':!graphify-out/cache/ast'`).

---

## Self-Review
**Coverage:** temporal anchoring (T1), no-silent-merge of events (T2), clarify-when-unsure (T3), recall completeness (T4), proactive in-chat (T5), verify (T6). All four user requirements covered; macOS notifications explicitly deferred.
**Placeholder scan:** none.
**Type consistency:** `NodeAttributes.date`, `EntitiesOut.E.Attr.date`, `todayString()`, `NodeKind.clarification`, `SleepPhase.clarify`, `clarify()`, `pendingClarifications()`, `dueReminders(today:)`, `HarnessModel.proactiveMessages(clarifications:dueReminders:)`/`surfaceProactive()`/`hasProactive` — consistent across tasks.
**Notes:** confirm `store.setEmbedding(nodeId:_:)` exists (used in MemoryStore+Dedup) for Task 2's event upsert; if a consolidation test asserts a canned-response count, adding `clarify()` to runCycle/runLight shifts the LIGHT path's generate-call sequence (summarizeRecent, associate, reflect, clarify) — align any such test's `CannedRuntime` list. Keep the prior batch's "answer only what asked" substring intact in Agent prompt (Task 4 augments, not replaces).
