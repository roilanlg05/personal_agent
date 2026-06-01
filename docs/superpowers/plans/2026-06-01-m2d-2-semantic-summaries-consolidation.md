# M2d-2 — Semantic summaries + consolidation from transcript — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wake the (M2d-1-dormant) consolidation by sourcing it from the `TranscriptStore` instead of graph `conversation` nodes, and add a **summarize** phase that distills each consolidated chat segment into a structured `summary` node ("the ruta": topic/concepts/intent/decisions/importance) embedded on its **condensed concepts** for precise recall.

**Architecture:** `MemoryConsolidationEngine` gains a `TranscriptStore` dependency; `runCycle` builds its batch + episode texts from unconsolidated transcript turns and marks them consolidated there. A new `summarize` phase (after NREM) writes one `summary` node per cycle (kind added to `NodeKind`) via `upsertMergingSemantic` with a concept-level embedding, recording `threadId`/`turnRange` in `extra` for later N4 drill-down (M2d-3). Cross-session abstraction comes for free: the existing `associate`/`reflect` phases already run over all non-conversation nodes, so they connect/abstract `summary` nodes too. The retriever gets a light "summaries first" ordering in its injection block.

**Tech Stack:** Swift 6 / GRDB / XCTest, mlx_vlm server (consolidation runs thinking-OFF, JSON-only, `maxTokens:512`).

**Spec:** `docs/superpowers/specs/2026-06-01-m2d-live-context-clean-capture-design.md` (sub-plan **M2d-2** of §9). **Builds on M2d-1 (merged `e7739d8`):** `TranscriptStore` (with `unconsolidated`/`markConsolidated`/`recent`/`range`), the `transcript` table, and `HarnessModel` already builds a `transcriptStore` in `ensureMemory()`.

**Key current facts (verified):**
- `MemoryConsolidationEngine` (`Memory/MemoryConsolidationEngine.swift`): `init(store:embedder:runtime:now:)`; phases `consolidate(episodeTexts:)`, `detectFollowUps(episodeTexts:)`, `associate()`, `reflect()`, `curateKinds()`, `forget()`; `runCycle(isCancelled:)` builds `batch` from `store.unconsolidatedEpisodes()` (graph nodes), reads texts via `store.node(id:)?.body`, and ends with `store.markEpisodesConsolidated(ids:)`. After M2d-1 those node-based episodes no longer exist → cycle is dormant.
- `SleepPhase` enum (`Memory/MemoryStore.swift`): `case nrem, detect, rem, reflect, curate, shy`. `SleepCycleState.episodeIds: [String]`.
- `NodeKind` (`Memory/MemoryModels.swift`): `person, place, fact, preference, topic, trait, task, plan, insight, day, episode, conversation, followUp="follow_up"` — **no `summary`**.
- Node + embedding write pattern (from `consolidate`): build `Node(...)`, `let emb = (try? embedder?.embed(text)) ?? nil`, `store.upsertMergingSemantic(node, embedding: emb, embedder: embedder)` (kind-aware dedup; different kinds never merge).
- `HarnessModel.ensureMemory()` builds `MemoryConsolidationEngine(store: store, embedder: memoryEmbedder, runtime: runtime)` and already has `transcriptStore` set.

**Build/test command (success = "Test Suite … passed"):**
```bash
xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS'
```
Live/E2E tests gated by `TEST_RUNNER_GEMMA_LIVE_SERVER=1` (env-var PREFIX to xcodebuild).

---

### Task 1: `NodeKind.summary` + `TranscriptStore.rows(ids:)`

**Files:**
- Modify: `Gemma/Gemma/Memory/MemoryModels.swift` (add `summary` to `NodeKind`)
- Modify: `Gemma/Gemma/Memory/TranscriptStore.swift` (add `rows(ids:)`)
- Test: `Gemma/GemmaTests/TranscriptStoreTests.swift` (add a `rows(ids:)` test)

- [ ] **Step 1: Write the failing test** — append to `TranscriptStoreTests`:

```swift
    func test_rows_byIds_returnsMatching_orderedOldestFirst() throws {
        let s = try makeStore()
        try s.append(threadId: "t", turnIndex: 0, role: "user", text: "a", now: 1)
        try s.append(threadId: "t", turnIndex: 0, role: "assistant", text: "b", now: 2)
        let all = try s.unconsolidated(limit: 100)
        let ids = all.map { $0.id }
        let rows = try s.rows(ids: ids)
        XCTAssertEqual(rows.map { $0.text }, ["a", "b"], "rows(ids:) returns the rows oldest-first")
        XCTAssertEqual(try s.rows(ids: []).count, 0)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/TranscriptStoreTests 2>&1 | tail -20`
Expected: COMPILE FAIL — `rows(ids:)` undefined.

- [ ] **Step 3: Add `summary` to `NodeKind`** in `MemoryModels.swift`. Change the enum line to include `summary` (place it before `insight`):

```swift
enum NodeKind: String, Codable, CaseIterable { case person, place, fact, preference, topic, trait, task, plan, summary, insight, day, episode, conversation, followUp = "follow_up" }
```

- [ ] **Step 4: Add `rows(ids:)` to `TranscriptStore`** (after `range(...)`):

```swift
    /// Fetch specific rows by id, oldest-first. Used by consolidation to rebuild episode texts.
    func rows(ids: [String]) throws -> [TranscriptRow] {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { db in
            try TranscriptRow.filter(ids.contains(Column("id")))
                .order(Column("createdAt").asc, Column("role").asc)
                .fetchAll(db)
        }
    }
```

- [ ] **Step 5: Run to verify it passes**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/TranscriptStoreTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Gemma/Gemma/Memory/MemoryModels.swift Gemma/Gemma/Memory/TranscriptStore.swift Gemma/GemmaTests/TranscriptStoreTests.swift
git commit -m "feat(m2d-2): NodeKind.summary + TranscriptStore.rows(ids:)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Source consolidation from the transcript

**Files:**
- Modify: `Gemma/Gemma/Memory/MemoryConsolidationEngine.swift` (inject `transcriptStore`; rewire `runCycle`)
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift` (pass `transcriptStore` to the engine)
- Test: `Gemma/GemmaTests/MemoryConsolidationEngineTests.swift` (the runCycle test must seed the transcript)

- [ ] **Step 1: Update the runCycle test to seed the transcript.** In `MemoryConsolidationEngineTests.swift`, find the test that drives `runCycle` (it currently seeds `conversation` nodes via `store.upsert(...)` / the old `ep()` helper and asserts entities are extracted). Replace its episode seeding so it appends turns to a `TranscriptStore` and builds the engine with it. The test body should look like:

```swift
    func test_runCycle_consumes_transcript_and_marks_consolidated() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        try ts.append(threadId: "t", turnIndex: 0, role: "user", text: "me llamo Roilan y me gusta el sushi", now: 1)
        try ts.append(threadId: "t", turnIndex: 0, role: "assistant", text: "¡Genial!", now: 2)
        // Fake runtime: NREM returns one entity; all other phases return empty JSON.
        let runtime = ScriptedRuntime(responses: [
            #"{"entities":[{"entity":"sushi","kind":"preference","detail":"likes it"}]}"#,  // nrem
            #"{"topic":"presentación","concepts":["nombre Roilan","gusto sushi"],"intent":"","decisions":[],"importance":0.5,"summary":"El usuario se presenta."}"#, // summarize
            #"{"followUps":[]}"#, #"{"edges":[]}"#, #"{"insights":[]}"#, #"{"map":{}}"#     // detect, rem, reflect, curate
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.runCycle(isCancelled: { false })

        // transcript turns are now consolidated
        XCTAssertEqual(try ts.unconsolidated(limit: 100).count, 0, "consumed transcript turns must be marked consolidated")
        // NREM minted the entity
        let nodes = try store.allNodes()
        XCTAssertNotNil(nodes.first { $0.kind == "preference" && $0.label == "sushi" })
    }
```

> NOTE: `ScriptedRuntime` is a fake `ModelRuntime` returning the next canned `content` per `generate(prompt:options:)` call. If the test file already has such a fake (e.g. `StubModelRuntime`/`ScriptedRuntime`), reuse it and adapt the canned-response list to the new phase order (nrem, summarize, detect, rem, reflect, curate). If not, add this minimal one to the test file:
```swift
    final class ScriptedRuntime: ModelRuntime, @unchecked Sendable {
        nonisolated let identifier = "scripted"
        private var responses: [String]; private var i = 0
        init(responses: [String]) { self.responses = responses }
        func isLoaded() async -> Bool { true }
        func load(options: ModelLoadOptions) async throws {}
        func unload() async {}
        func currentMetrics() async -> RuntimeMetrics? { nil }
        func generate(prompt: String, options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            let text = i < responses.count ? responses[i] : "{}"; i += 1
            return AsyncThrowingStream { c in
                c.yield(.completed(GenerationResult(text: text, metrics: .init(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }
```
Also: if OTHER tests in this file (or `MemoryStoreSleepTests`) seed `conversation` nodes purely to exercise the OLD node-based `unconsolidatedEpisodes`/`markEpisodesConsolidated`, leave those store-level tests as-is (those MemoryStore methods still exist and are still tested) — only the **engine runCycle** test changes to the transcript source.

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryConsolidationEngineTests 2>&1 | tail -25`
Expected: COMPILE FAIL — `MemoryConsolidationEngine` has no `transcriptStore:` init param (and `summarize` phase not yet present; that JSON is just queued for Task 3 — at this step expect the compile failure on the init signature).

- [ ] **Step 3: Inject `transcriptStore` and rewire `runCycle`** in `MemoryConsolidationEngine.swift`.

(a) Add the stored dep + init param:
```swift
    private let transcriptStore: TranscriptStore
```
and in `init`, add `transcriptStore: TranscriptStore` (after `runtime`) and `self.transcriptStore = transcriptStore`.

(b) Add a private helper to rebuild episode texts from transcript ids:
```swift
    /// Formatted "Role: text" lines for the given transcript ids (oldest-first).
    private func episodeTexts(ids: [String]) -> [String] {
        let rows = (try? transcriptStore.rows(ids: ids)) ?? []
        return rows.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
    }
```

(c) In `runCycle`, replace the batch source + the per-phase text rebuilds + the final mark. Specifically:
- Replace the cycle-start batch build:
```swift
            let pending = ((try? transcriptStore.unconsolidated(limit: 200)) ?? [])
            let batch = pending.map { $0.id }
            guard !batch.isEmpty else { return }
            let texts0 = episodeTexts(ids: batch)
            let focus = String(texts0.joined(separator: " · ").prefix(100))
            state = SleepCycleState(phase: .nrem, episodeIds: batch, startedAt: now(), focus: focus)
            try? store.saveSleepCycle(state)
```
(replaces the old `store.unconsolidatedEpisodes()` / `store.node(id:)?.body` block).
- In the `.nrem` case, replace `let texts = state.episodeIds.compactMap { (try? store.node(id: $0))?.body }` with `let texts = episodeTexts(ids: state.episodeIds)`.
- In the `.detect` case, replace `episodeTexts: state.episodeIds.compactMap { (try? store.node(id: $0))?.body }` with `episodeTexts: episodeTexts(ids: state.episodeIds)`.
- Replace the final `try? store.markEpisodesConsolidated(ids: state.episodeIds)` with `try? transcriptStore.markConsolidated(ids: state.episodeIds)`.

(Leave the `salient` focus refinement that reads `store.allNodes()` unchanged.)

(d) In `HarnessModel.ensureMemory()`, pass the transcript store to the engine. The `transcriptStore` is set earlier in `ensureMemory` (M2d-1). Change:
```swift
            let engine = MemoryConsolidationEngine(store: store, embedder: memoryEmbedder, runtime: runtime)
```
to:
```swift
            let engine = MemoryConsolidationEngine(store: store, embedder: memoryEmbedder, runtime: runtime,
                                                   transcriptStore: transcriptStore ?? TranscriptStore(dbQueue: store.dbQueue))
```

- [ ] **Step 4: Run** (the runCycle test will still fail until Task 3 adds `summarize`, because the scripted responses include the summarize slot and the phase order will mismatch — that is expected). For THIS task, verify the engine COMPILES and the FULL suite builds, then move on:

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:" | tail -12`
Expected: BUILDS (no compile errors). The new `test_runCycle_consumes_transcript_and_marks_consolidated` may FAIL on the entity/consolidated assertions ONLY because `summarize` isn't wired yet (the scripted response indices shift) — that's fixed in Task 3. If ANY OTHER test fails for a real reason, fix it. Do NOT commit a red suite; if the only red is the new runCycle test pending Task 3, proceed to Task 3 WITHOUT committing, then commit Tasks 2+3 together at the end of Task 3.

> Rationale: Tasks 2 and 3 are interdependent (phase order). Implement both, then commit once green.

---

### Task 3: `summarize` phase → structured `summary` node

**Files:**
- Modify: `Gemma/Gemma/Memory/MemoryStore.swift` (`SleepPhase` enum: add `summarize`)
- Modify: `Gemma/Gemma/Memory/MemoryConsolidationEngine.swift` (`summarize(...)` + phase order + switch)
- Test: `Gemma/GemmaTests/MemoryConsolidationEngineTests.swift` (a focused summarize test + the runCycle test from Task 2)

- [ ] **Step 1: Add a focused summarize test** to `MemoryConsolidationEngineTests.swift`:

```swift
    func test_summarize_writes_structured_summary_node() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let ts = TranscriptStore(dbQueue: store.dbQueue)
        let runtime = ScriptedRuntime(responses: [
            #"{"topic":"viaje a Japón","concepts":["Tokio","sushi","abril"],"intent":"planear un viaje","decisions":["ir en abril"],"importance":0.8,"summary":"El usuario planea un viaje a Japón en abril."}"#
        ])
        let engine = MemoryConsolidationEngine(store: store, embedder: nil, runtime: runtime, transcriptStore: ts)
        await engine.summarize(episodeTexts: ["User: quiero ir a Japón en abril"], threadId: "t", turnRange: 0...3)

        let summary = try XCTUnwrap(try store.allNodes().first { $0.kind == NodeKind.summary.rawValue })
        XCTAssertEqual(summary.label, "viaje a Japón")
        let extra = try XCTUnwrap(summary.extra?.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: extra) as? [String: Any])
        XCTAssertEqual(obj["concepts"] as? [String], ["Tokio", "sushi", "abril"])
        XCTAssertEqual(obj["threadId"] as? String, "t")
        XCTAssertEqual((obj["turnRange"] as? [Int]), [0, 3])
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryConsolidationEngineTests/test_summarize_writes_structured_summary_node 2>&1 | tail -20`
Expected: COMPILE FAIL — `summarize(...)` undefined.

- [ ] **Step 3: Add `summarize` to `SleepPhase`** in `MemoryStore.swift`:
```swift
enum SleepPhase: String, Codable, CaseIterable { case nrem, summarize, detect, rem, reflect, curate, shy }
```

- [ ] **Step 4: Implement `summarize` + wire it into the cycle** in `MemoryConsolidationEngine.swift`.

(a) Add the decode type + method (place after `consolidate(...)`):
```swift
    private struct SummaryOut: Decodable {
        let topic: String; let concepts: [String]
        let intent: String?; let decisions: [String]?; let importance: Double?; let summary: String?
    }

    /// Distill one chat segment into a structured `summary` node ("the ruta"): topic + condensed
    /// concepts, embedded on the concepts (not the raw turns) for precise recall. Records
    /// threadId + turnRange in `extra` for later drill-down (M2d-3).
    func summarize(episodeTexts: [String], threadId: String, turnRange: ClosedRange<Int>) async {
        guard !episodeTexts.isEmpty else { return }
        let convo = episodeTexts.joined(separator: "\n")
        let prompt = """
        Summarize this conversation segment as STRUCTURED knowledge about ONE user. Output JSON only.
        Give a short `topic` (2-5 words), the key `concepts` (short noun phrases), the user's `intent`, \
        any `decisions` made, an `importance` 0..1, and a one-sentence `summary`. Don't invent.
        Schema: {"topic":"...","concepts":["..."],"intent":"...","decisions":["..."],"importance":0.5,"summary":"..."}
        Conversation:
        \(convo)
        JSON:
        """
        guard let out = parse(await generate(prompt, maxTokens: 512), SummaryOut.self) else { return }
        let topic = MemoryText.cleanLabel(out.topic)
        guard !topic.isEmpty, !MemoryText.isJunkLabel(topic) else { return }
        let t = now()
        var extra: [String: Any] = [
            "concepts": out.concepts,
            "intent": out.intent ?? "",
            "decisions": out.decisions ?? [],
            "importance": out.importance ?? 0.5,
            "threadId": threadId,
            "turnRange": [turnRange.lowerBound, turnRange.upperBound],
        ]
        let extraJSON = (try? JSONSerialization.data(withJSONObject: extra)).flatMap { String(data: $0, encoding: .utf8) }
        let body = (out.summary?.isEmpty == false) ? out.summary! : topic
        let node = Node(id: UUID().uuidString, kind: NodeKind.summary.rawValue, label: topic, body: body,
                        layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 4,
                        decayRate: Decay.defaultDecayRate(for: .daily), confidence: .probable, mentionCount: 1,
                        ttlExpiresAt: nil, sourceRef: threadId, origin: .extracted, serverId: nil,
                        dirty: true, deleted: false, extra: extraJSON)
        // Embed the CONDENSED concepts (not the raw turns) — better recall precision.
        let conceptText = ([topic] + out.concepts).joined(separator: " ")
        let emb = (try? embedder?.embed(conceptText)) ?? nil
        _ = try? store.upsertMergingSemantic(node, embedding: emb, embedder: embedder)
        onProgress?("+1 summary")
    }
```

(b) Wire it into `runCycle`. Update the phase order to include `.summarize` after `.nrem`:
```swift
        let order: [SleepPhase] = [.nrem, .summarize, .detect, .rem, .reflect, .curate, .shy]
```
Add a `.summarize` case to the `switch phase` (after `.nrem`):
```swift
            case .summarize:
                let rows = (try? transcriptStore.rows(ids: state.episodeIds)) ?? []
                let turns = rows.map { $0.turnIndex }
                let range = (turns.min() ?? 0)...(turns.max() ?? 0)
                let threadId = rows.first?.threadId ?? ""
                await summarize(episodeTexts: episodeTexts(ids: state.episodeIds), threadId: threadId, turnRange: range)
```

- [ ] **Step 5: Run the summarize test + the runCycle test + full suite**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryConsolidationEngineTests 2>&1 | tail -20`
Expected: PASS (both the new summarize test and the Task-2 runCycle test now pass with the corrected phase order). Then full suite:
`xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:" | tail -10` → expect ** TEST SUCCEEDED **.

- [ ] **Step 6: Commit (Tasks 2 + 3 together)**

```bash
git add Gemma/Gemma/Memory/MemoryConsolidationEngine.swift Gemma/Gemma/Memory/MemoryStore.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(m2d-2): consolidation reads transcript + summarize phase (structured summary nodes)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Retriever — surface summaries first in the injection block

**Files:**
- Modify: `Gemma/Gemma/Memory/MemoryRetriever.swift` (`injectionBlock(for:)`)
- Test: `Gemma/GemmaTests/MemoryRetrieverTests.swift` (new, or add to an existing retriever test file if present)

> The retriever already does vector + FTS + 1-hop proximity + salience ranking, so `summary` nodes are retrieved naturally. This task only makes the injected block put summaries first (the "ruta" gives the model the gist before individual facts) and labels them.

- [ ] **Step 1: Write the failing test** `Gemma/GemmaTests/MemoryRetrieverTests.swift`:

```swift
import XCTest
@testable import Gemma

final class MemoryRetrieverInjectionTests: XCTestCase {
    private func node(_ kind: String, _ label: String, _ body: String) -> Node {
        Node(id: UUID().uuidString, kind: kind, label: label, body: body, layer: .daily,
             createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0.1, confidence: .sure,
             mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
             dirty: true, deleted: false, extra: nil)
    }

    func test_injectionBlock_lists_summaries_before_facts() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let r = MemoryRetriever(store: store, embedder: nil)
        let nodes = [node("preference", "sushi", "likes sushi"),
                     node(NodeKind.summary.rawValue, "viaje a Japón", "Plan a trip to Japan")]
        let block = r.injectionBlock(for: nodes)
        let iSummary = try XCTUnwrap(block.range(of: "viaje a Japón"))
        let iFact = try XCTUnwrap(block.range(of: "sushi"))
        XCTAssertTrue(iSummary.lowerBound < iFact.lowerBound, "summary must appear before the plain fact")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryRetrieverInjectionTests 2>&1 | tail -20`
Expected: FAIL — current `injectionBlock` keeps input order (fact first).

- [ ] **Step 3: Update `injectionBlock(for:)`** in `MemoryRetriever.swift` to put summaries first (stable within each group):

```swift
    /// Render retrieved nodes as a compact injection block (empty string if none).
    /// Summaries (the "ruta") come first so the model gets the gist before individual facts.
    func injectionBlock(for nodes: [Node]) -> String {
        guard !nodes.isEmpty else { return "" }
        let summaries = nodes.filter { $0.kind == NodeKind.summary.rawValue }
        let rest = nodes.filter { $0.kind != NodeKind.summary.rawValue }
        let lines = (summaries + rest).map { "- [\($0.kind)] \($0.label): \($0.body.isEmpty ? $0.label : $0.body)" }
        return "What you remember about the user (use if relevant):\n" + lines.joined(separator: "\n")
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/MemoryRetrieverInjectionTests 2>&1 | tail -20`
Expected: PASS. Then full suite green.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Memory/MemoryRetriever.swift Gemma/GemmaTests/MemoryRetrieverTests.swift
git commit -m "feat(m2d-2): retriever surfaces summary nodes first in the injection block

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Final verification + real-26B E2E + graphify

**Files:**
- (Optional) Modify: `Gemma/GemmaTests/SleepConsolidationE2ETests.swift` (seed transcript instead of conversation nodes, if it drives `runCycle`)

- [ ] **Step 1: Align the gated E2E with the transcript source.** Open `SleepConsolidationE2ETests.swift`. If its full-cycle test seeds the conversation by upserting `conversation` nodes (M2d-1 changed it to inline `Node` upserts), change it to append turns to a `TranscriptStore(dbQueue: store.dbQueue)` and construct the engine with `transcriptStore:`. The assertions (entities/edges/insights produced; now also a `summary` node) stay. Keep it gated (`XCTSkipUnless GEMMA_LIVE_SERVER`). If it does NOT drive runCycle, leave it.

- [ ] **Step 2: Run the complete unit suite**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED" | tail -2`
Expected: ** TEST SUCCEEDED **.

- [ ] **Step 3: (Gated, real 26B) run the sleep E2E** to confirm a real cycle over a seeded transcript produces a structured `summary` + entities. Kill anything on 8080 first.

Run:
```bash
lsof -ti tcp:8080 | xargs -r kill
TEST_RUNNER_GEMMA_LIVE_SERVER=1 xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' \
  -only-testing:GemmaTests/SleepConsolidationE2ETests 2>&1 | grep -E "passed|failed|skipped|summary|TEST" | tail -15
```
Expected: PASS (a `summary` node with topic/concepts is created; entities extracted). If the model returns 0 for a phase, that is the known thinking-off JSON behavior — re-run once; if persistent, note it (do not loosen asserts silently).

- [ ] **Step 4: Update the knowledge graph**

Run: `graphify update .`

- [ ] **Step 5: Commit graph + any E2E test change**

```bash
git add Gemma/GemmaTests/SleepConsolidationE2ETests.swift graphify-out ':!graphify-out/cache/ast'
git commit -m "test(m2d-2): sleep E2E over transcript source; graphify update

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (M2d-2, spec §9):**
- Consolidation reads transcript (not conversation nodes) → Task 2. ✓
- Summarize phase → structured `summary` nodes (concept embedding, turnRange) → Tasks 1 (kind) + 3. ✓
- Cross-session abstraction → existing `associate`/`reflect` already run over all non-conversation nodes, so they connect/abstract `summary` nodes (no new code; noted). ✓ (deeper merge-of-recurring-summaries deferred — acceptable)
- Retriever summary-first / proximity → Task 4 (summary-first); proximity already in `MemoryRetriever` (vector+FTS+1-hop+salience, unchanged). ✓

**Placeholder scan:** none — each step has concrete code/commands. Task 2 Step 4 intentionally defers its commit to Task 3 (interdependent phase order) — explicitly stated, not a placeholder.

**Type consistency:** `TranscriptStore.rows(ids:)`, `NodeKind.summary`, `SleepPhase.summarize`, `MemoryConsolidationEngine.init(store:embedder:runtime:transcriptStore:now:)`, `episodeTexts(ids:)`, `summarize(episodeTexts:threadId:turnRange:)`, `SummaryOut{topic,concepts,intent,decisions,importance,summary}`, `extra` JSON keys (`concepts,intent,decisions,importance,threadId,turnRange`) — consistent across tasks. `upsertMergingSemantic(_, embedding:, embedder:)` matches the existing call shape in `consolidate`.

**Notes for the implementer:**
- The old node-based `store.unconsolidatedEpisodes()`/`markEpisodesConsolidated()` remain (still unit-tested at the store level); `runCycle` simply stops calling them. Do not delete them in M2d-2.
- New files auto-included (filesystem-synchronized groups). If a retriever test file already exists, add the test there instead of creating a duplicate class name.
- Consolidation phases run thinking-OFF, JSON-only, `maxTokens:512` (do not change). The fake `ScriptedRuntime` returns one canned `content` per `generate` call in phase order (nrem, summarize, detect, rem, reflect, curate) — keep response lists aligned with that order.
