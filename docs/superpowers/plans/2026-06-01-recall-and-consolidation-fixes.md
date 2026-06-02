# Recall & consolidation fixes (P1/P2/P3) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix three diagnosed runtime defects in the agent's memory/turn loop: (P2) consolidation blocks/never-returns the user turn; (P1) the agent can't recall a previous conversation (consolidation hadn't run yet); (P3) fragmented/duplicate identity from sentence-shaped labels.

**Diagnosis (from the live `memory.sqlite`, evidenced):**
- **P2 — "se pone a reflexionar y nunca responde":** `ConsolidationScheduler` arms its pause timer (15s) at turn START and `launch()` only checks `running == nil` — it does NOT check whether a user turn is in progress. With streaming + the 2048-token cap, turns exceed 15s, so the timer fires **mid-turn**, launching consolidation that competes with the turn on the shared server; `ServerRuntime` has no generation timeout, so a starved turn can hang.
- **P1 — no cross-session recall:** timestamps show the astigmatismo knowledge nodes were created (00:22) **after** the session that asked about them (00:18–00:21). Consolidation runs in the background, so a prior session isn't in the graph yet when referenced; the short-term window is per-`threadId` (new each launch) so a new session starts blind. **User's direction:** each conversation should have its structured summary/embedding available promptly so recall searches the **summary** (not the full chat).
- **P3 — fragmented identity:** "Roilan" is stored 3×: `person:"User's name is Roilan"` (label = a sentence), `person:"Roilan"`, `fact:"name"`. Sentence-shaped labels defeat semantic dedup.

**Architecture of the fixes:** (P2) the scheduler never consolidates while a user turn runs and arms its timers at turn END; `ServerRuntime` gets an inactivity timeout. (P1) a light "summarize the current session now" runs at the post-turn pause (creating the session's `summary` node immediately, in the conversation's language, with concepts folded into the FTS-searchable body) so the next session's recall finds it. (P3) entity labels are canonicalized (sentence prefixes stripped) before storage + a stronger prompt.

**Tech Stack:** Swift 6 / SwiftUI / GRDB / XCTest. mlx_vlm server (consolidation thinking-OFF, JSON-only).

**Build/test:** `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS'`. Live tests gated by `TEST_RUNNER_GEMMA_LIVE_SERVER=1`.

---

### Task 1: Scheduler never consolidates during a user turn; arm timers at turn END (P2a)

**Files:**
- Modify: `Gemma/Gemma/Memory/ConsolidationScheduler.swift`
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift`
- Test: `Gemma/GemmaTests/ConsolidationSchedulerTests.swift`

- [ ] **Step 1: Write failing tests** — append to `ConsolidationSchedulerTests` (it has a spy runner `SpyRunner`/similar + builds a scheduler; reuse the file's existing helpers and `isReady: { true }`). Add an `isUserBusy` flag the test controls:

```swift
    func test_does_not_launch_while_user_busy() async {
        let runner = SpyRunner()
        var busy = true
        let s = ConsolidationScheduler(runner: runner, isReady: { true }, hasPendingCycle: { false },
                                       isUserBusy: { busy }, pauseInterval: .milliseconds(5), idleInterval: .seconds(3600))
        s.noteTurnEnded()                       // arm the pause timer
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(runner.lightCount, 0, "must NOT consolidate while the user turn is in progress")
        busy = false
        s.noteTurnEnded()                       // re-arm now that the user is free
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertGreaterThan(runner.lightCount, 0, "should consolidate once the user is idle")
    }

    func test_noteUserActivity_cancels_without_arming() async {
        let runner = SpyRunner()
        let s = ConsolidationScheduler(runner: runner, isReady: { true }, hasPendingCycle: { false },
                                       isUserBusy: { false }, pauseInterval: .milliseconds(5), idleInterval: .seconds(3600))
        s.noteUserActivity()                    // turn START: cancel, do NOT arm
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(runner.lightCount, 0, "turn start must not schedule consolidation; only noteTurnEnded() arms it")
    }
```
> If the file's spy runner is named differently or lacks `lightCount`/`cycleCount`, adapt (it must already count `runLight`/`runCycle` calls for the existing tests). Match the existing `ConsolidationScheduler(...)` call sites in this file: they will need the new `isUserBusy:` argument added (defaulted in the initializer so existing call sites still compile — see Step 3).

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ConsolidationSchedulerTests 2>&1 | tail -20`
Expected: COMPILE FAIL (`isUserBusy:` / `noteTurnEnded` undefined).

- [ ] **Step 3: Implement in `ConsolidationScheduler.swift`.**

Add the dependency + init param (defaulted so existing tests/call sites compile):
```swift
    @ObservationIgnored private let isUserBusy: () -> Bool
```
In `init`, add `isUserBusy: @escaping () -> Bool = { false }` (place it after `hasPendingCycle`) and `self.isUserBusy = isUserBusy`.

Replace `noteUserActivity()` so it only CANCELS (no re-arm), and add `noteTurnEnded()` that arms the timers:
```swift
    /// Turn START: cancel any running/scheduled consolidation so the model is free. Does NOT
    /// arm new timers — consolidation is (re)scheduled only when the turn ends (noteTurnEnded).
    func noteUserActivity() {
        cancelFlag = true
        running?.cancel(); running = nil
        pauseTask?.cancel(); idleTask?.cancel()
        state = .idle
    }

    /// Turn END: start the idle countdown. Consolidation may run only after the user has been
    /// quiet (pauseInterval / idleInterval) — never mid-turn.
    func noteTurnEnded() {
        pauseTask?.cancel(); idleTask?.cancel()
        scheduleTimers()
    }
```
Add the `isUserBusy` check to `launch()`:
```swift
    private func launch(light: Bool) {
        guard isReady(), running == nil, !isUserBusy() else { return }
        ...
    }
```
(Keep the rest of `launch`/`scheduleTimers` as-is. `requestLightReflection()` stays — but it now also no-ops while the user is busy via `launch`'s guard; that's fine.)

- [ ] **Step 4: Wire `HarnessModel`.** In `ensureMemory()`, pass `isUserBusy` to the scheduler:
```swift
            let sched = ConsolidationScheduler(runner: engine, isReady: { [weak self] in self?.serverManager.state == .ready },
                                               hasPendingCycle: { [weak self] in ((try? self?.memoryStore?.loadSleepCycle()) ?? nil) != nil },
                                               isUserBusy: { [weak self] in self?.agentRunning ?? false })
```
In `runAgentTurn`, at the END (replace the stale comment block at lines ~136-143 is optional, but you MUST add the turn-end arming): after `lastTurnEndedAt = Date().timeIntervalSince1970`, add:
```swift
        consolidationScheduler?.noteTurnEnded()
```
(Keep the existing `consolidationScheduler?.noteUserActivity()` call at turn start.)

- [ ] **Step 5: Run to verify pass**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ConsolidationSchedulerTests 2>&1 | tail -20`
Expected: PASS (new + existing scheduler tests). If an existing test relied on `noteUserActivity` arming timers, update it to call `noteTurnEnded()` instead and note it.
Then full suite green.

- [ ] **Step 6: Commit**
```bash
git add Gemma/Gemma/Memory/ConsolidationScheduler.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/ConsolidationSchedulerTests.swift
git commit -m "fix(memory): never consolidate during a user turn; arm timers at turn end

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `ServerRuntime` inactivity timeout (P2b)

**Files:**
- Modify: `Gemma/Gemma/Runtime/ServerRuntime.swift`
- Test: `Gemma/GemmaTests/ServerRuntimeStreamingTests.swift`

- [ ] **Step 1: Write failing test** — append to `ServerRuntimeStreamingTests`. A stub that sends headers then never sends data should make a short-timeout runtime throw:

```swift
    final class StallStub: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            // never deliver data / never finish → exercises the inactivity timeout
        }
        override func stopLoading() {}
    }

    func test_generation_times_out_when_server_stalls() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StallStub.self]
        let rt = ServerRuntime(session: URLSession(configuration: cfg), generationTimeout: .seconds(1))
        var threw = false
        do { for try await _ in await rt.generate(prompt: "hi", tools: [], options: GenerationOptions()) {} }
        catch { threw = true }
        XCTAssertTrue(threw, "a stalled server must surface as a thrown error, not hang forever")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ServerRuntimeStreamingTests 2>&1 | tail -20`
Expected: COMPILE FAIL (`generationTimeout:` param undefined).

- [ ] **Step 3: Implement.** Add an init param + apply it as the request's inactivity timeout (URLSession resets `timeoutInterval` on each received byte, so for SSE it's a "no data for N seconds" timeout — exactly what a stalled generation needs).

In `ServerRuntime`, add a stored property + init param:
```swift
    /// Inactivity timeout: if no SSE bytes arrive for this long, the request fails (so a starved
    /// generation surfaces an error instead of hanging the turn forever).
    let generationTimeout: Duration
```
In `init`, add `generationTimeout: Duration = .seconds(120)` (last param) and `self.generationTimeout = generationTimeout`.
In `generate(prompt:tools:options:)`, after building `req`, set its timeout (convert Duration → seconds):
```swift
                    req.timeoutInterval = Double(generationTimeout.components.seconds)
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ServerRuntimeStreamingTests 2>&1 | tail -20`
Expected: PASS (the stall test throws within ~1s). Then full suite green.

- [ ] **Step 5: Commit**
```bash
git add Gemma/Gemma/Runtime/ServerRuntime.swift Gemma/GemmaTests/ServerRuntimeStreamingTests.swift
git commit -m "fix(runtime): inactivity timeout so a stalled generation never hangs the turn

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Prompt session summary at the post-turn pause (P1)

**Files:**
- Modify: `Gemma/Gemma/Memory/MemoryConsolidationEngine.swift` (add `summarizeRecent()`; call it from `runLight`; summary in user language + concepts in body)
- Test: `Gemma/GemmaTests/MemoryConsolidationEngineTests.swift`

- [ ] **Step 1: Write failing test** — append to `MemoryConsolidationEngineTests`:

```swift
    func test_summarizeRecent_creates_summary_without_marking_consolidated() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "S", turnIndex: 0, role: "user", text: "tengo astigmatismo leve", now: 1)
        try ts.append(threadId: "S", turnIndex: 0, role: "assistant", text: "anotado", now: 2)
        let runtime = CannedRuntime([
            #"{"topic":"astigmatismo","concepts":["ojos","vista","astigmatismo"],"summary":"El usuario tiene astigmatismo leve."}"#
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.summarizeRecent()
        let summary = try XCTUnwrap(try store.allNodes().first { $0.kind == NodeKind.summary.rawValue })
        XCTAssertEqual(summary.label, "astigmatismo")
        XCTAssertTrue(summary.body.localizedCaseInsensitiveContains("ojos"), "concepts folded into body for FTS recall")
        XCTAssertEqual(try ts.unconsolidated(limit: 100).count, 2, "summarizeRecent must NOT mark turns consolidated")
    }

    func test_summarizeRecent_skips_threads_already_summarized() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "S", turnIndex: 0, role: "user", text: "hola", now: 1)
        let runtime = CannedRuntime([#"{"topic":"saludo","concepts":["hola"],"summary":"saludo"}"#])  // ONE response only
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.summarizeRecent()
        await engine.summarizeRecent()   // second call must NOT summarize thread "S" again (no 2nd canned response needed)
        XCTAssertEqual(try store.allNodes().filter { $0.kind == NodeKind.summary.rawValue }.count, 1)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryConsolidationEngineTests 2>&1 | tail -20`
Expected: COMPILE FAIL (`summarizeRecent` undefined).

- [ ] **Step 3: Implement in `MemoryConsolidationEngine.swift`.**

(a) Update the `summarize(...)` method's prompt to answer in the conversation's language, and fold concepts into the FTS-searchable body. Change the prompt's instruction line to add: `Answer in the SAME language as the conversation.` And change the node `body` construction from `let body = (out.summary?.isEmpty == false) ? out.summary! : topic` to also append the concepts so FTS over `body` can match recall queries:
```swift
        let prose = (out.summary?.isEmpty == false) ? out.summary! : topic
        let body = out.concepts.isEmpty ? prose : prose + " · " + out.concepts.joined(separator: ", ")
```
(Use `body` for the Node as before.)

(b) Add `summarizeRecent()` — summarize each unconsolidated thread that has no summary yet, WITHOUT marking consolidated:
```swift
    /// Light, immediate summarization of the current unconsolidated conversation(s) so each session
    /// has its structured `summary` node promptly (cross-session recall before the full sleep cycle).
    /// Does NOT mark turns consolidated — the full cycle still extracts entities/edges later.
    /// Skips a thread that already has a summary (avoids re-summarizing on every pause).
    func summarizeRecent() async {
        let rows = ((try? transcriptStore.unconsolidated(limit: 200)) ?? [])
        guard !rows.isEmpty else { return }
        let alreadySummarized = Set(((try? store.allNodes()) ?? [])
            .filter { $0.kind == NodeKind.summary.rawValue }
            .compactMap { $0.sourceRef })
        let groups = Dictionary(grouping: rows, by: { $0.threadId })
            .sorted { ($0.value.map(\.createdAt).min() ?? 0) < ($1.value.map(\.createdAt).min() ?? 0) }
        for (threadId, tRows) in groups where !alreadySummarized.contains(threadId) {
            let turns = tRows.map { $0.turnIndex }
            let range = (turns.min() ?? 0)...(turns.max() ?? 0)
            let texts = tRows.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
            await summarize(episodeTexts: texts, threadId: threadId, turnRange: range)
        }
    }
```
(`summarize` already sets `sourceRef = threadId`, so the `alreadySummarized` check uses `sourceRef`.)

(c) In `runLight`, summarize the current session FIRST so it's recallable immediately:
```swift
    func runLight(isCancelled: @escaping () -> Bool) async {
        if isCancelled() { return }
        await summarizeRecent()
        if isCancelled() { return }
        await associate()
        if isCancelled() { return }
        await reflect()
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryConsolidationEngineTests 2>&1 | tail -20`
Expected: PASS (incl. existing summarize/runCycle tests). Then full suite green.

- [ ] **Step 5: Commit**
```bash
git add Gemma/Gemma/Memory/MemoryConsolidationEngine.swift Gemma/GemmaTests/MemoryConsolidationEngineTests.swift
git commit -m "fix(memory): summarize each session at the post-turn pause for prompt cross-session recall

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Canonical entity labels (P3)

**Files:**
- Modify: `Gemma/Gemma/Memory/MemoryText.swift` (add `canonicalEntityLabel`)
- Modify: `Gemma/Gemma/Memory/MemoryConsolidationEngine.swift` (apply it in `consolidate`)
- Test: `Gemma/GemmaTests/` (add to an existing MemoryText test file if present, else new `MemoryTextCanonicalTests.swift`)

- [ ] **Step 1: Write failing test** `Gemma/GemmaTests/MemoryTextCanonicalTests.swift` (or append to an existing MemoryText tests file — check `ls Gemma/GemmaTests | grep -i memorytext`):

```swift
import XCTest
@testable import Gemma

final class MemoryTextCanonicalTests: XCTestCase {
    func test_strips_user_name_sentence_prefix() {
        XCTAssertEqual(MemoryText.canonicalEntityLabel("User's name is Roilan"), "Roilan")
        XCTAssertEqual(MemoryText.canonicalEntityLabel("the user's name is Roilan"), "Roilan")
        XCTAssertEqual(MemoryText.canonicalEntityLabel("El usuario se llama Roilan"), "Roilan")
    }
    func test_keeps_already_canonical_labels() {
        XCTAssertEqual(MemoryText.canonicalEntityLabel("Roilan"), "Roilan")
        XCTAssertEqual(MemoryText.canonicalEntityLabel("sushi"), "sushi")
    }
    func test_trims_overlong_to_first_words() {
        // a long sentence collapses to a short head (≤ 4 words), never an empty string
        let out = MemoryText.canonicalEntityLabel("has a medical condition related to vision and eyes")
        XCTAssertFalse(out.isEmpty)
        XCTAssertLessThanOrEqual(out.split(separator: " ").count, 4)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryTextCanonicalTests 2>&1 | tail -20`
Expected: COMPILE FAIL (`canonicalEntityLabel` undefined).

- [ ] **Step 3: Add `canonicalEntityLabel` to `MemoryText`:**
```swift
    /// Reduce an entity label to a canonical short form: strip common "the user's name is …"
    /// sentence prefixes (EN/ES) and cap to a short head so person/place/preference labels stay
    /// dedupable (the model sometimes returns whole sentences as a label).
    static func canonicalEntityLabel(_ raw: String) -> String {
        var s = cleanLabel(raw)
        let prefixes = ["the user's name is ", "user's name is ", "the user is ", "user is ",
                        "el usuario se llama ", "el usuario es ", "su nombre es ", "mi nombre es ",
                        "the user's ", "user's "]
        let lower = s.lowercased()
        for p in prefixes where lower.hasPrefix(p) {
            s = String(s.dropFirst(p.count)); break
        }
        // Cap an over-long (sentence-like) label to its first 4 words.
        let words = s.split(separator: " ")
        if words.count > 4 { s = words.prefix(4).joined(separator: " ") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
```
(Confirm `cleanLabel` exists in `MemoryText` — it does, used by `SaveMemoryTool`/`consolidate`.)

- [ ] **Step 4: Apply it in `consolidate(...)`** in `MemoryConsolidationEngine.swift`. The phase already does `let label = MemoryText.cleanLabel(e.entity)`. Change it to canonicalize for entity-like kinds (NOT insight/summary/follow_up/task/plan, which are naturally phrases):
```swift
            let rawKind = (e.kind?.isEmpty == false) ? e.kind! : NodeKind.fact.rawValue
            let entityKinds: Set<String> = [NodeKind.person.rawValue, NodeKind.place.rawValue,
                                            NodeKind.preference.rawValue, NodeKind.fact.rawValue]
            let label = entityKinds.contains(rawKind) ? MemoryText.canonicalEntityLabel(e.entity)
                                                      : MemoryText.cleanLabel(e.entity)
```
and use `rawKind` where `kind` was computed (keep the rest of the loop the same; ensure the existing `let kind = ...` uses `rawKind`). Also append to the NREM prompt's entity instruction: `The "entity" MUST be a short canonical noun/name (1-3 words), NEVER a sentence (e.g. "Roilan", not "the user's name is Roilan").`

- [ ] **Step 5: Run to verify pass**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryTextCanonicalTests 2>&1 | tail -20`
Expected: PASS. Then full suite green (existing MemoryTools/consolidate tests must still pass — `canonicalEntityLabel("sushi") == "sushi"` etc.).

- [ ] **Step 6: Commit**
```bash
git add Gemma/Gemma/Memory/MemoryText.swift Gemma/Gemma/Memory/MemoryConsolidationEngine.swift Gemma/GemmaTests/MemoryTextCanonicalTests.swift
git commit -m "fix(memory): canonical entity labels (strip sentence prefixes) so identity dedups

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Verification + graphify

- [ ] **Step 1: Full suite**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED" | tail -2`
Expected: ** TEST SUCCEEDED ** (re-run once if a transient launch failure).

- [ ] **Step 2: (Optional, gated real-26B) cross-session recall smoke.** Start the server, ⌘R: in session A say "tengo astigmatismo leve", quit/relaunch (new session B), wait ~20s (post-turn pause summarizes A), then ask "¿qué te dije que tenía en la vista?" → the agent should recall astigmatismo from A's summary. Also confirm sending a message during a long reply no longer "reflexiona y nunca responde".

- [ ] **Step 3: graphify** — `graphify update .`

- [ ] **Step 4: Commit graph**
```bash
git add graphify-out ':!graphify-out/cache/ast'
git commit -m "chore: graphify update (recall + consolidation fixes)"
```

---

## Self-Review

**Coverage:** P2a (no consolidate during turn + arm-at-end) → Task 1; P2b (timeout) → Task 2; P1 (prompt cross-session summary, user-language, concepts-in-body) → Task 3; P3 (canonical labels) → Task 4; verify → Task 5.

**Placeholder scan:** none — concrete code/commands.

**Type consistency:** `ConsolidationScheduler.init(..., isUserBusy:)`, `noteTurnEnded()`, `MemoryConsolidationEngine.summarizeRecent()`, `summarize(...)` body-with-concepts, `MemoryText.canonicalEntityLabel(_)`, `ServerRuntime.init(..., generationTimeout:)` — used consistently. `CannedRuntime` is the existing fake in MemoryConsolidationEngineTests.

**Notes for the implementer:**
- Keep the existing `noteUserActivity` call at turn START in `runAgentTurn`; ADD `noteTurnEnded()` at turn END. Update the now-inaccurate comment block (lines ~136-143) to reflect the new "consolidate only when idle after the turn" behavior.
- `summarizeRecent` re-uses `summarize`; the `alreadySummarized` guard (by `sourceRef`/threadId) prevents re-summarizing each pause. The full `runCycle` still summarizes + marks consolidated later; same-topic summaries dedup (kind-aware, latest extra).
- Task 4 must NOT canonicalize insight/summary/follow_up labels (those are naturally phrases). Only person/place/preference/fact.
- Some existing consolidation tests assert canned-response order; adding `summarizeRecent` to `runLight` changes the LIGHT path's generate-call count — if a `runLight` test breaks, align its `CannedRuntime` responses (summarizeRecent calls generate once per unconsolidated thread before associate/reflect).
