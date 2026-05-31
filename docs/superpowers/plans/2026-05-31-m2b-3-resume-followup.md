# M2b-3 — Conscious resume + proactive follow-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user returns, the agent resumes its interrupted reflection promptly + consciously, and proactively follows up on pending tasks and dropped conversational threads.

**Architecture:** Persist a short `focus` with the sleep cycle (what it's reflecting on). Add a `detect` phase that mines unresolved threads into `follow_up` nodes. The scheduler resumes an interrupted cycle on the short pause timer. `HarnessModel` injects a per-turn `wakeContext` (the reflection focus + pending follow-ups) into the `Agent`'s system prompt so the agent raises them naturally.

**Tech Stack:** Swift, SwiftUI, XCTest, GRDB, local mlx-lm Gemma 4 26B.

## Spec
`docs/superpowers/specs/2026-05-31-m2b-3-resume-followup-design.md`. Builds on M2b-2 (`…m2b-2-sleep-consolidation-design.md`).

## Conventions
- Build/test on macOS, ABSOLUTE project path: `xcodebuild test -scheme Gemma -project /Users/hashdown/Projects/personal_agent/Gemma/Gemma.xcodeproj -destination 'platform=macOS'`. Success = "TEST SUCCEEDED"/"BUILD SUCCEEDED".
- New `.swift` files auto-add. SourceKit "No such module"/"Cannot find type" diagnostics are spurious if xcodebuild succeeds. `@MainActor` test classes use `async` methods.
- LLM phases use `runtime.generate(prompt:options:)` + the engine's existing `extractJSON`/`parse`. Unit tests inject the `CannedRuntime` fake (defined in `MemoryConsolidationEngineTests.swift`).
- Commit after each task with the trailer (blank line then): `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Commit only task files; never the unrelated dirty files (graphify-out, logs.txt, .gitignore, CLAUDE.md, Xcode user state). Run `graphify update .` after code changes (ignore errors).

## Current state (verified APIs from M2b-2)
- `Memory/MemoryModels.swift`: `enum NodeKind: String { person, place, fact, preference, topic, trait, task, plan, insight, day, episode, conversation }`. `Node.kind: String`. `Relation`/`Confidence`/`Origin` enums. `NodeAttributes{status,horizon}` with `toJSON()`/`from(_:)`.
- `Memory/MemoryStore.swift`: `enum SleepPhase: String, Codable, CaseIterable { nrem, rem, reflect, curate, shy }`; `struct SleepCycleState { var phase: SleepPhase; var episodeIds: [String]; var startedAt: Double }` (Equatable). Migrator has `v1-core`, `v2-sleep`. Helpers: `loadSleepCycle()/saveSleepCycle(_:)/clearSleepCycle()`, `unconsolidatedEpisodes()`, `markEpisodesConsolidated(ids:)`, `distinctKinds()`, `reassignKind(from:to:)`, `pruneDanglingEdges()`, `allNodes()`, `node(id:)`, `upsert(Node)`, `nearest(to:k:)`.
- `Memory/MemoryConsolidationEngine.swift`: `nonisolated final class … : ConsolidationRunning`. Methods `consolidate(episodeTexts:)`, `associate()`, `reflect()`, `curateKinds()`, `forget()`, `runCycle(isCancelled: @escaping () -> Bool)`, `runLight(isCancelled:)`. Has `static func extractJSON`, private `generate(_:maxTokens:)`, private `parse<T>`, `var onProgress: ((String)->Void)?`. `runCycle` order array `[.nrem, .rem, .reflect, .curate, .shy]`; starts a cycle with `SleepCycleState(phase: .nrem, episodeIds: batch, startedAt: now())`.
- `Memory/ConsolidationScheduler.swift`: `protocol ConsolidationRunning { runLight(isCancelled:)/runCycle(isCancelled:) }`. `@MainActor @Observable ConsolidationScheduler(runner:isReady:pauseInterval:idleInterval:)`. Pause timer → `launch(light:true)`; idle timer → `launch(light:false)`. `launch(light:)` guards `isReady() && running == nil`.
- `Agent/Agent.swift`: `@MainActor final class Agent`, `init(runtime:registry:memory:)`. `private func systemPrompt(memoryBlock:) -> String` (base + memoryBlock). `run(prompt:options:)` overwrites `opts.systemPrompt = systemPrompt(memoryBlock:)`.
- `Harness/HarnessModel.swift`: `runAgentTurn`, `ensureMemory()` (builds `MemoryConsolidationEngine`+`ConsolidationScheduler` once; returns `MemoryServices(retriever:)`), `consolidateNow()`, `threadId`, `turnIndex`, `memoryStore`, `consolidationScheduler`. Registers Save/Forget/Reflect/CurrentTime tools.

## File structure (after M2b-3)
**Modified:** `Memory/MemoryModels.swift` (+`followUp` kind), `Memory/MemoryStore.swift` (`SleepCycleState.focus` + `v3-sleep-focus` migration + `pendingFollowUps`), `Memory/MemoryConsolidationEngine.swift` (`detectFollowUps` + `.detect` phase + set `focus`), `Memory/ConsolidationScheduler.swift` (`hasPendingCycle` → resume on pause), `Agent/Agent.swift` (`wakeContext`), `Harness/HarnessModel.swift` (`buildWakeContext`+`lastTurnEndedAt`+wiring). **New tests:** additions to `MemoryStoreSleepTests`, `MemoryConsolidationEngineTests`, `ConsolidationSchedulerTests`, `AgentMemoryTests`; new `GemmaTests/WakeContextTests.swift`.

---

## Task 1: Persist reflection `focus` on the sleep cycle

**Files:** Modify `Memory/MemoryStore.swift`. Test: add to `GemmaTests/MemoryStoreSleepTests.swift`.

- [ ] **Step 1: Add a failing test** to `MemoryStoreSleepTests.swift`:
```swift
func test_sleep_cycle_round_trips_focus() throws {
    let store = try MemoryStore(inMemory: true, embeddingDim: 4)
    try store.saveSleepCycle(SleepCycleState(phase: .nrem, episodeIds: ["e1"], startedAt: 1, focus: "sushi, fútbol"))
    XCTAssertEqual(try store.loadSleepCycle()?.focus, "sushi, fútbol")
}
```
(The existing `test_sleep_cycle_round_trip_and_clear` constructs `SleepCycleState(phase:episodeIds:startedAt:)` — it will need the new `focus:` arg; update it to pass `focus: ""`.)

- [ ] **Step 2: Run → fail** (`-only-testing:GemmaTests/MemoryStoreSleepTests`): missing `focus`.

- [ ] **Step 3: Implement.** In `Memory/MemoryStore.swift`:
  - Add `var focus: String = ""` to `struct SleepCycleState`.
  - Add a migration AFTER `v2-sleep`:
```swift
        m.registerMigration("v3-sleep-focus") { db in
            try db.alter(table: "sleep_cycle") { t in
                t.add(column: "focus", .text).notNull().defaults(to: "")
            }
        }
```
  - In `loadSleepCycle()`, read the new column and pass it: change the SELECT to `"SELECT phase, episodeIds, startedAt, focus FROM sleep_cycle WHERE id=1"` and build `SleepCycleState(phase: phase, episodeIds: ids, startedAt: row["startedAt"], focus: row["focus"] ?? "")`.
  - In `saveSleepCycle(_:)`, add `focus` to the INSERT: `"INSERT OR REPLACE INTO sleep_cycle(id, phase, episodeIds, startedAt, focus) VALUES (1, ?, ?, ?, ?)"` with `arguments: [s.phase.rawValue, ids, s.startedAt, s.focus]`.

- [ ] **Step 4: Run → pass.** Also `-only-testing:GemmaTests/MemoryStoreTests` (migration regression) → green.

- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(m2b-3): persist reflection focus on the sleep cycle (v3-sleep-focus)"`

---

## Task 2: `detect` phase + `follow_up` kind in the engine

**Files:** Modify `Memory/MemoryModels.swift`, `Memory/MemoryStore.swift` (SleepPhase enum lives there), `Memory/MemoryConsolidationEngine.swift`. Test: add to `GemmaTests/MemoryConsolidationEngineTests.swift`.

- [ ] **Step 1: Add failing tests** to `MemoryConsolidationEngineTests.swift`:
```swift
    func test_detect_creates_followup_nodes() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let rt = CannedRuntime([#"{"followUps":[{"text":"finish telling the story about the trip","sources":[]},{"text":"decide where to travel","sources":[]}]}"#])
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: rt)
        await engine.detectFollowUps(episodeTexts: ["I was about to tell you about my trip but then..."])
        let fu = try store.allNodes().filter { $0.kind == NodeKind.followUp.rawValue }
        XCTAssertEqual(fu.count, 2)
        XCTAssertTrue(fu.allSatisfy { NodeAttributes.from($0.extra).status == "pending" })
    }
    func test_detect_dedups_repeats() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let json = #"{"followUps":[{"text":"call the dentist back","sources":[]}]}"#
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime([json, json]))
        await engine.detectFollowUps(episodeTexts: ["x"])
        await engine.detectFollowUps(episodeTexts: ["x"])
        XCTAssertEqual(try store.allNodes().filter { $0.kind == NodeKind.followUp.rawValue }.count, 1)
    }
    func test_runCycle_includes_detect_and_sets_focus() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let meta = EpisodeRecorder.Meta(threadId: "T", role: "user", turnIndex: 0, status: "closed")
        let extra = String(data: try JSONEncoder().encode(meta), encoding: .utf8)
        let now = Date().timeIntervalSince1970
        try store.upsert(Node(id: "e1", kind: NodeKind.conversation.rawValue, label: "u", body: "me gusta el sushi", layer: .episodic, createdAt: now, updatedAt: now, lastSeenAt: now, salience: 2, decayRate: 0.001, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil, sourceRef: "T", origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: extra))
        // start at .detect so only detect+rest run; assert focus was set when the cycle started.
        let engine = MemoryConsolidationEngine(store: store, embedder: FakeEmbedder(dimension: 4), runtime: CannedRuntime(["{}","{}","{}","{}","{}"]))
        await engine.runCycle(isCancelled: { false })
        // cycle completed: episodes consolidated + cleared
        XCTAssertNil(try store.loadSleepCycle())
        XCTAssertEqual(EpisodeRecorder.meta(from: try store.node(id: "e1")!)?.status, "consolidated")
    }
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement.**
  - `Memory/MemoryModels.swift`: add `case followUp = "follow_up"` to `enum NodeKind`.
  - `Memory/MemoryStore.swift`: add `.detect` to `enum SleepPhase`: `enum SleepPhase: String, Codable, CaseIterable { case nrem, detect, rem, reflect, curate, shy }`.
  - `Memory/MemoryConsolidationEngine.swift`:
    - Add the phase method:
```swift
    private struct FollowUpsOut: Decodable { struct F: Decodable { let text: String; let sources: [String]? }; let followUps: [F] }

    /// Detect unresolved intents / open conversational threads from the recent episodes,
    /// storing them as pending `follow_up` nodes for proactive surfacing on wake.
    func detectFollowUps(episodeTexts: [String]) async {
        guard !episodeTexts.isEmpty else { return }
        let convo = episodeTexts.joined(separator: "\n")
        let prompt = """
        This is a recent conversation with ONE user. List anything LEFT UNRESOLVED that's worth following up on later: tasks/intentions the user mentioned, open questions, or a topic/story they started but didn't finish. Output JSON only. Don't invent; only genuine loose ends.
        Example: user said "tengo que llamar al dentista" and "te iba a contar de mi viaje pero…" → {"followUps":[{"text":"call the dentist","sources":[]},{"text":"hear about the user's trip","sources":[]}]}
        Schema: {"followUps":[{"text":"<short follow-up>","sources":["<entity label>"]}]}
        Conversation:
        \(convo)
        JSON:
        """
        guard let out = parse(await generate(prompt), FollowUpsOut.self) else { return }
        var existing = Set(((try? store.allNodes()) ?? []).filter { $0.kind == NodeKind.followUp.rawValue }.map { MemoryText.dedupKey($0.body) })
        var added = 0
        for f in out.followUps {
            let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = MemoryText.dedupKey(text)
            if text.isEmpty || existing.contains(key) { continue }
            existing.insert(key)
            let t = now()
            var attrs = NodeAttributes(); attrs.status = "pending"
            let node = Node(id: UUID().uuidString, kind: NodeKind.followUp.rawValue, label: String(text.prefix(60)),
                            body: text, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3,
                            decayRate: Decay.defaultDecayRate(for: .daily), confidence: .probable, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: attrs.toJSON())
            try? store.upsert(node)
            added += 1
        }
        onProgress?("+\(added) follow-ups")
    }
```
    - In `runCycle`, (a) compute + set `focus` when STARTING a fresh cycle, and (b) add `.detect` to the order + the `switch`:
      - When starting a fresh cycle (the `else` branch that builds `SleepCycleState(phase: .nrem, ...)`), compute focus from the batch episode bodies:
```swift
            let texts0 = batch.compactMap { (try? store.node(id: $0))?.body }
            let focus = String(texts0.joined(separator: " · ").prefix(100))
            state = SleepCycleState(phase: .nrem, episodeIds: batch, startedAt: now(), focus: focus)
            try? store.saveSleepCycle(state)
```
      - Change the order array to `let order: [SleepPhase] = [.nrem, .detect, .rem, .reflect, .curate, .shy]` and add a `case .detect:` to the `switch phase` that calls `await detectFollowUps(episodeTexts: state.episodeIds.compactMap { (try? store.node(id: $0))?.body })`.

- [ ] **Step 4: Run → pass** (`-only-testing:GemmaTests/MemoryConsolidationEngineTests`) — the prior 9 + 3 new. Verify the resume tests still pass with the 6-phase order (the existing `test_runCycle_resumes_from_persisted_phase` started at `.shy` — still valid; `test_runCycle_cancel_persists_phase_for_resume` cancels immediately — still valid).

- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(m2b-3): detect phase mines follow_up nodes + sleep cycle sets reflection focus"`

---

## Task 3: `pendingFollowUps` store helper

**Files:** Modify `Memory/MemoryStore.swift`. Test: add to `GemmaTests/MemoryStoreSleepTests.swift`.

- [ ] **Step 1: Add a failing test:**
```swift
func test_pending_followups_returns_pending_tasks_and_followups() throws {
    let store = try MemoryStore(inMemory: true, embeddingDim: 4)
    let now = Date().timeIntervalSince1970
    func n(_ id: String, _ kind: String, _ status: String?) -> Node {
        var attrs = NodeAttributes(); attrs.status = status
        return Node(id: id, kind: kind, label: id, body: id, layer: .daily, createdAt: now, updatedAt: now,
                    lastSeenAt: now, salience: 3, decayRate: 0.001, confidence: .sure, mentionCount: 1,
                    ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: attrs.toJSON())
    }
    try store.upsert(n("t1", NodeKind.task.rawValue, "pending"))
    try store.upsert(n("t2", NodeKind.task.rawValue, "done"))
    try store.upsert(n("f1", NodeKind.followUp.rawValue, "pending"))
    try store.upsert(n("p1", NodeKind.preference.rawValue, nil))   // not a follow-up kind
    let ids = Set(try store.pendingFollowUps().map { $0.id })
    XCTAssertEqual(ids, ["t1", "f1"])   // pending task + pending follow_up; done task & preference excluded
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement** in `Memory/MemoryStore.swift`:
```swift
    /// Pending actionable + conversational follow-ups (task/plan/follow_up nodes whose
    /// NodeAttributes.status is "pending" or unset), most recent first, capped.
    func pendingFollowUps(limit: Int = 5) throws -> [Node] {
        let kinds: Set<String> = [NodeKind.task.rawValue, NodeKind.plan.rawValue, NodeKind.followUp.rawValue]
        return try allNodes()
            .filter { kinds.contains($0.kind) && (NodeAttributes.from($0.extra).status ?? "pending") == "pending" }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .prefix(limit).map { $0 }
    }
```

- [ ] **Step 4: Run → pass; Commit** `git add -A && git commit -m "feat(m2b-3): MemoryStore.pendingFollowUps (pending tasks/plans/follow_ups)"`

---

## Task 4: Scheduler resumes an interrupted cycle on the short pause

**Files:** Modify `Memory/ConsolidationScheduler.swift`. Test: add to `GemmaTests/ConsolidationSchedulerTests.swift`.

- [ ] **Step 1: Add a failing test:**
```swift
    func test_pause_resumes_pending_cycle_instead_of_light() async throws {
        let spy = SpyRunner()
        let s = ConsolidationScheduler(runner: spy, isReady: { true }, hasPendingCycle: { true },
                                       pauseInterval: .milliseconds(20), idleInterval: .seconds(60))
        s.noteUserActivity()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThanOrEqual(spy.cycle, 1, "a pending cycle resumes on the pause timer")
        XCTAssertEqual(spy.light, 0, "light reflection is NOT run while a cycle is pending")
    }
```
(Update the existing scheduler tests' `ConsolidationScheduler(...)` constructions to pass the new `hasPendingCycle:` arg — default it to `{ false }` in those call sites so their behavior is unchanged.)

- [ ] **Step 2: Run → fail** (no `hasPendingCycle:` param).

- [ ] **Step 3: Implement** in `Memory/ConsolidationScheduler.swift`:
  - Add an injected `hasPendingCycle: () -> Bool` to `init` (store as `@ObservationIgnored private let hasPendingCycle`). Add the param after `isReady` with no default in the initializer (callers pass it).
  - In the PAUSE timer handler, decide light vs resume: where it currently does `self.launch(light: true)`, change to:
```swift
            if self.hasPendingCycle() { self.launch(light: false) }  // resume the interrupted cycle promptly
            else { self.launch(light: true) }                        // otherwise a light awake reflection
```
  (The idle timer keeps `launch(light: false)`.)

- [ ] **Step 4: Run → pass** (`-only-testing:GemmaTests/ConsolidationSchedulerTests`, all incl. the new one + the updated existing ones).

- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(m2b-3): scheduler resumes an interrupted sleep cycle on the short pause timer"`

---

## Task 5: `wakeContext` injection — Agent + HarnessModel

**Files:** Modify `Agent/Agent.swift`, `Harness/HarnessModel.swift`. Test: `GemmaTests/WakeContextTests.swift` + add an Agent test to `GemmaTests/AgentMemoryTests.swift`.

- [ ] **Step 1: Agent test** — add to `GemmaTests/AgentMemoryTests.swift` (it already has a stub runtime that captures the system prompt; mirror it):
```swift
    func test_wakeContext_is_injected_into_system_prompt() async throws {
        final class CapturingRuntime: ToolCallingRuntime {
            var systemPrompt: String = ""
            func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
                systemPrompt = options.systemPrompt ?? ""
                return AsyncThrowingStream { c in
                    c.yield(.completed(GenerationResult(text: "ok", metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil)))); c.finish()
                }
            }
        }
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry(), memory: nil, wakeContext: "You were reflecting on: sushi.")
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.systemPrompt.contains("You were reflecting on: sushi."))
    }
```
(Read `AgentMemoryTests` for its existing stub-runtime pattern; reuse it rather than the above if it already defines a capturing runtime.)

- [ ] **Step 2: Run → fail** (`Agent` has no `wakeContext` param).

- [ ] **Step 3: Implement Agent.** In `Agent/Agent.swift`:
  - Add a stored `private let wakeContext: String` and an `init(runtime:registry:memory:wakeContext: String = "")` param (default "" keeps existing callers working).
  - In `systemPrompt(memoryBlock:)`, append the wake context when non-empty:
```swift
    private func systemPrompt(memoryBlock: String) -> String {
        let base = """
        ... (existing base, unchanged) ...
        """
        var out = memoryBlock.isEmpty ? base : base + "\n\n" + memoryBlock
        if !wakeContext.isEmpty { out += "\n\n" + wakeContext }
        return out
    }
```

- [ ] **Step 4: WakeContext builder test** `GemmaTests/WakeContextTests.swift` — test a pure helper on `HarnessModel` (make it `static` + pure so it's testable without driving a turn):
```swift
import XCTest
@testable import Gemma

final class WakeContextTests: XCTestCase {
    func test_focus_only_when_cycle_pending() {
        let ctx = HarnessModel.buildWakeContext(focus: "sushi, fútbol", followUps: [], isWake: false)
        XCTAssertTrue(ctx.contains("reflecting on"))
        XCTAssertTrue(ctx.contains("sushi, fútbol"))
    }
    func test_followups_only_on_wake() {
        let none = HarnessModel.buildWakeContext(focus: "", followUps: ["call the dentist"], isWake: false)
        XCTAssertTrue(none.isEmpty, "follow-ups only surface on wake (first turn / after a gap)")
        let onWake = HarnessModel.buildWakeContext(focus: "", followUps: ["call the dentist"], isWake: true)
        XCTAssertTrue(onWake.contains("call the dentist"))
    }
    func test_empty_when_nothing() {
        XCTAssertTrue(HarnessModel.buildWakeContext(focus: "", followUps: [], isWake: true).isEmpty)
    }
}
```

- [ ] **Step 5: Run → fail** (no `buildWakeContext`).

- [ ] **Step 6: Implement HarnessModel.** In `Harness/HarnessModel.swift`:
  - Add the pure builder (static so it's unit-testable):
```swift
    /// Build the per-turn "wake context" appended to the system prompt: what the agent was
    /// reflecting on (if a cycle is pending) + pending follow-ups (only on a wake turn).
    static func buildWakeContext(focus: String, followUps: [String], isWake: Bool) -> String {
        var parts: [String] = []
        if !focus.isEmpty {
            parts.append("(You were just reflecting on: \(focus). Mention it naturally only if it fits.)")
        }
        if isWake, !followUps.isEmpty {
            let list = followUps.map { "- \($0)" }.joined(separator: "\n")
            parts.append("Things the user left pending you can gently follow up on if it fits (don't force them):\n\(list)")
        }
        return parts.joined(separator: "\n\n")
    }
```
  - Add `@ObservationIgnored private var lastTurnEndedAt: Double = 0` and a wake gap constant (e.g. `180`).
  - In `runAgentTurn`, BEFORE building the `Agent`, compute the wake context:
```swift
        let now = Date().timeIntervalSince1970
        let isWake = (lastTurnEndedAt == 0) || (now - lastTurnEndedAt > 180)   // first turn or long gap
        let focus = (try? memoryStore?.loadSleepCycle())??.focus ?? ""
        let followUps = isWake ? ((try? memoryStore?.pendingFollowUps())?? .map { $0.body } ?? []) : []
        let wakeContext = Self.buildWakeContext(focus: focus, followUps: followUps, isWake: isWake)
```
    Then construct the Agent with it: `let agent = Agent(runtime: runtime, registry: registry, memory: memory, wakeContext: wakeContext)`.
    At the END of `runAgentTurn` (after the loop), set `lastTurnEndedAt = Date().timeIntervalSince1970`.
  > Note the double-optional flatten: `memoryStore?.loadSleepCycle()` is `(SleepCycleState?)?`; `(try? ...)` adds another → use `((try? memoryStore?.loadSleepCycle()) ?? nil)?.focus ?? ""`. Likewise for `pendingFollowUps`. Make it compile cleanly (adjust the flattening as the compiler requires).

- [ ] **Step 7: Run → pass** (`WakeContextTests`, the Agent test, and `AgentMemoryTests` regression). Full build green.

- [ ] **Step 8: `graphify update .`; Commit** `git add -A && git commit -m "feat(m2b-3): inject wake context (reflection focus + pending follow-ups) into the turn"`

---

## Task 6: Manual E2E on macOS + record

- [ ] **Step 1: Conscious resume.** Run the app (⌘R). Have a short conversation, then sit idle so a cycle starts ("🌙"). Mid-cycle, send a message → the cycle cancels; the agent's reply may reference what it was reflecting on. Within ~15s of finishing your message, the "🌙" banner should reappear (the cycle RESUMED promptly from its persisted phase).
- [ ] **Step 2: Follow-up.** In a conversation, mention a task ("recuérdame llamar al dentista") and start-but-drop a topic. Let a full cycle run (or "Consolidar"). Open the memory graph → confirm `task` + `follow_up` nodes (pending). Quit + relaunch the app → on your FIRST message, the agent should gently bring up the pending task / dropped topic.
- [ ] **Step 3: No-nag check.** After resolving/acknowledging, on a normal mid-session turn the agent should NOT keep re-raising them (follow-ups only surface on wake = first-turn/after-gap).
- [ ] **Step 4: Record** in `[[macos-mlx-pivot]]` (M2b-3 done → M2b complete) + a §note in the M2b-3 spec. Commit docs.

**M2b-3 DONE:** the agent resumes its interrupted reflection promptly and consciously, and proactively follows up on pending tasks + dropped threads on wake. **M2b (the Sleep Consolidation memory) is complete.**

---

## Testing Strategy
- **Unit (macOS, no server):** focus round-trip + migration; `detectFollowUps` + dedup (CannedRuntime); `pendingFollowUps`; scheduler pause-resume (spy + `hasPendingCycle`); `buildWakeContext` (pure) + Agent wakeContext injection; all M2b-1/M2b-2 suites stay green.
- **Manual (macOS, real 26B):** Task 6 — prompt+conscious resume; follow-up surfacing on wake; no-nag.

## Self-Review (spec coverage)
- Persist focus → Task 1. detect phase + follow_up kind → Task 2. pendingFollowUps → Task 3. prompt-resume on pause → Task 4. wakeContext (focus + follow-ups, wake-gated) injection → Task 5. Manual resume+follow-up → Task 6. Anti-fabrication + dedup in detect → Task 2. ✅
- **Type consistency:** `SleepCycleState.focus`; `SleepPhase.detect`; order `[.nrem,.detect,.rem,.reflect,.curate,.shy]`; `NodeKind.followUp`; `detectFollowUps(episodeTexts:)`; `MemoryStore.pendingFollowUps(limit:)`; `ConsolidationScheduler(runner:isReady:hasPendingCycle:pauseInterval:idleInterval:)`; `Agent(... wakeContext:)`; `HarnessModel.buildWakeContext(focus:followUps:isWake:)`. Consistent across tasks.
- **Note:** "wake" = first turn or gap > 180s; the focus phrase is a 100-char episode snippet; follow-up auto-resolution is best-effort (spec §7). Tunable in Task 5.

## References
- Spec `…m2b-3-resume-followup-design.md`; vision `…sleep-consolidation-vision.md`. Builds on M2b-2.
