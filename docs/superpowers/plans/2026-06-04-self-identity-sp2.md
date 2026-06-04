# Self Identity (SP2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent a first-class "self" record for the user — a singleton `self:user` node always injected as "you" — so it knows who it's talking to, distinct from third parties (who carry their relationship role).

**Architecture:** Server (`gemma-memory`) adds a `self` NodeKind + a singleton `self:user` node (upsert + always-first in `coreMemories`), routes the user's own name/identity to it from consolidation and `save_memory`, and links the self to mentioned people in `associate`. The app (`personal_agent`) renders the self distinctly ("You are speaking with X (the user)") and tells the prompt the self is "you".

**Tech Stack:** Swift 6 — server (SwiftPM, GRDB, Hummingbird), app (SwiftUI). Spec: `docs/superpowers/specs/2026-06-04-self-identity-sp2-design.md`.

**Server tests:** `swift test --filter <Name>` in `personal_agent/gemma-memory/memory-service` (dev clone, `main`).
**App tests:** `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -40` in `personal_agent`.
**Known pre-existing app failure to IGNORE:** `HarnessModelTests.test_defaultBaseURL_isLocalhost8081`.

---

## File Structure

**Server (`gemma-memory/memory-service/Sources/`):**
- `MemoryCore/MemoryModels.swift` — `NodeKind.selfUser` + `hubLabel`.
- `MemoryCore/MemoryStore+List.swift` (or wherever `coreMemories` lives) — `coreMemories` self-first.
- `MemoryCore/MemoryStore+Dedup.swift` (or a fitting store file) — `upsertSelf`/`selfNode`.
- `MemoryCore/MemoryConsolidationEngine.swift` — route `kind:"self"`; relationship role in `detail`; associate self↔people.
- `MemoryService/Handlers/MemoryHandlers.swift` — `save` routes `kind:"self"`.

**App (`personal_agent/Gemma/Gemma/`):**
- `Memory/SaveMemoryTool.swift` — `kind:"self"` documented.
- `Memory/MemoryClient.swift` — `injectionBlock` self render.
- `Agent/Agent.swift` — self line in `systemPromptText`.

---

# PART A — SERVER

## Task 1: `self` NodeKind + `upsertSelf`/`selfNode` + `coreMemories` self-first

**Files:** `MemoryModels.swift`, `MemoryStore+Dedup.swift`, `MemoryStore+List.swift`; Test: `Tests/MemoryCoreTests/SelfIdentityTests.swift` (create).

### Step 0: Read `Sources/MemoryCore/MemoryModels.swift` (`NodeKind` enum + the `hubLabel` extension), the file holding `func coreMemories` (`grep -rn "func coreMemories" Sources/` → likely `MemoryStore+List.swift`), and `Sources/MemoryCore/MemoryStore+Dedup.swift` (for `node(id:)`, `upsert(_:)`, `setEmbedding`, `MemoryText.canonicalEntityLabel`).

### Step 1: Add the kind. In `MemoryModels.swift`:
- In `NodeKind`: append `, selfUser = "self"` to the case list.
- In the `hubLabel` switch, add: `case .selfUser: return "Self"`.

### Step 2: Failing test — `Tests/MemoryCoreTests/SelfIdentityTests.swift`:
```swift
import XCTest
import GRDB
@testable import MemoryCore

final class SelfIdentityTests: XCTestCase {
    func test_upsertSelf_singleton_and_coreFirst() throws {
        let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
        let id1 = try store.upsertSelf(name: "Roilan", detail: nil, embedder: nil)
        let id2 = try store.upsertSelf(name: "Roilan", detail: "ingeniero", embedder: nil)
        XCTAssertEqual(id1, "self:user")
        XCTAssertEqual(id2, "self:user")                  // same singleton, not a new node
        let n = try store.selfNode()
        XCTAssertEqual(n?.kind, "self")
        XCTAssertEqual(n?.label, "Roilan")
        XCTAssertEqual(n?.body, "ingeniero")
        XCTAssertEqual(n?.layer, .identity)
        // seed another identity fact; self must come FIRST in coreMemories
        let pref = Node(id: UUID().uuidString, kind: NodeKind.preference.rawValue, label: "sushi",
                        body: "le gusta", layer: .identity, createdAt: 1, updatedAt: 1, lastSeenAt: 1,
                        salience: 9, decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                        sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        try store.upsert(pref)
        XCTAssertEqual(try store.coreMemories().first?.kind, "self")
    }
}
```

### Step 3: Run → FAIL: `swift test --filter SelfIdentityTests`.

### Step 4a: Add `upsertSelf`/`selfNode` to a `MemoryStore` extension (in `MemoryStore+Dedup.swift`):
```swift
/// Upsert the singleton self/user identity node (fixed id "self:user"). Always exactly one.
@discardableResult
public func upsertSelf(name: String, detail: String? = nil, embedder: Embedder? = nil,
                       now: Double = Date().timeIntervalSince1970) throws -> String {
    let id = "self:user"
    let label = MemoryText.canonicalEntityLabel(name)
    if var node = try node(id: id) {
        if !label.isEmpty { node.label = label }
        if let detail, !detail.isEmpty { node.body = detail }
        node.updatedAt = now; node.lastSeenAt = now; node.deleted = false; node.dirty = true
        try upsert(node)
    } else {
        let node = Node(id: id, kind: NodeKind.selfUser.rawValue, label: label, body: detail ?? "",
                        layer: .identity, createdAt: now, updatedAt: now, lastSeenAt: now,
                        salience: 10, decayRate: 0, confidence: .sure, mentionCount: 1, ttlExpiresAt: nil,
                        sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: nil)
        try upsert(node)
    }
    if let embedder, let emb = try? embedder.embed(label) { try? setEmbedding(nodeId: id, emb) }
    return id
}

public func selfNode() throws -> Node? { try node(id: "self:user") }
```

### Step 4b: `coreMemories` self-first. Replace the body of `coreMemories` (in `MemoryStore+List.swift`) with:
```swift
public func coreMemories(limit: Int = 6) throws -> [Node] {
    try dbQueue.read { db in
        let selfN = try Node.fetchOne(db, key: "self:user").flatMap { $0.deleted ? nil : $0 }
        let others = try Node
            .filter(Column("layer") == MemoryLayer.identity.rawValue
                    && Column("deleted") == false
                    && Column("kind") != "hub"
                    && Column("id") != "self:user")
            .order(Column("salience").desc).limit(limit).fetchAll(db)
        return selfN.map { [$0] + others } ?? others
    }
}
```
(This also excludes kind="hub" anchors from the identity core — they were never meant as facts.)

### Step 5: Run → PASS: `swift test --filter SelfIdentityTests`, then `swift test` (whole suite green — adding a NodeKind case + a hub for it is additive; `ensureKindHubs` will create a `hub:self`, harmless).

### Step 6: Commit
```bash
git add Sources/MemoryCore/MemoryModels.swift Sources/MemoryCore/MemoryStore+Dedup.swift Sources/MemoryCore/MemoryStore+List.swift Tests/MemoryCoreTests/SelfIdentityTests.swift
git commit -m "feat(self): singleton self:user node (kind=self) + upsertSelf/selfNode + coreMemories self-first"
```

---

## Task 2: Consolidation routes the user's identity to self

**Files:** `MemoryConsolidationEngine.swift`; Test: `Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift` (append).

### Step 1: Failing test — append (use the file's canned `ModelTextClient` pattern):
```swift
func test_consolidate_routes_self_kind_to_singleton() async throws {
    let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
    let json = #"{"entities":[{"entity":"Roilan","kind":"self","detail":"el usuario"},{"entity":"María","kind":"person","detail":"esposa"}]}"#
    let engine = MemoryConsolidationEngine(store: store, embedder: nil,
                                           runtime: <CANNED CLIENT returning json>,
                                           transcriptStore: TranscriptStore(dbQueue: store.dbQueue))
    await engine.consolidate(episodeTexts: ["User: me llamo Roilan, mi esposa es María"])
    XCTAssertEqual(try store.selfNode()?.label, "Roilan")
    XCTAssertEqual(try store.selfNode()?.kind, "self")
    // María is a normal person carrying her role in detail.
    let people = try store.allNodes().filter { $0.kind == NodeKind.person.rawValue }
    XCTAssertTrue(people.contains { $0.label == "María" && $0.body.contains("esposa") })
}
```
Reuse the file's existing canned `ModelTextClient` (the same one Task 5 of consolidation-hardening used). If none, add a minimal `CannedClient { let reply; func generate(...) async throws -> String { reply } }`.

### Step 2: Run → FAIL.

### Step 3a: Prompt. In `consolidate`'s extraction prompt, change the kind-choice guidance to introduce `self`. Where it lists the kinds ("person, place, preference, fact, trait, task, plan, …"), prepend:
```
The USER's OWN name/identity (the person you're talking to) → kind "self" (there is exactly ONE user; never a third party). Other people the user mentions → kind "person", and put their relationship role in `detail` (e.g. "esposa", "hija", "amigo", "jefe"). \
```
(Keep the rest of the kind list + schema.)

### Step 3b: Route in the entity loop. In `consolidate`, at the TOP of the `for e in out.entities` loop (before the event branch), add:
```swift
if e.kind == "self" {
    let label = MemoryText.canonicalEntityLabel(e.entity)
    if !MemoryText.isJunkLabel(label) {
        try? store.upsertSelf(name: label, detail: e.detail, embedder: embedder)
        added += 1
    }
    continue
}
```

### Step 4: Run → PASS + `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryCore/MemoryConsolidationEngine.swift Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(self): consolidation routes the user's own identity to the self node; person roles in detail"
```

---

## Task 3: `save_memory` routes `kind:"self"`

**Files:** `MemoryService/Handlers/MemoryHandlers.swift`; Test: `Tests/MemoryServiceTests/MemoryEndpointsTests.swift` (append).

### Step 1: Failing test — append (mirror the file's app/auth helpers):
```swift
func test_save_self_kind_routes_to_singleton() async throws {
    let app = try makeTestApp()
    _ = try await app.executeRequest(uri: "/v1/memory/save", method: .post, headers: authHeaders(app),
        body: ByteBuffer(string: #"{"kind":"self","label":"Roilan","body":"el usuario"}"#))
    XCTAssertEqual(try app.services.store.selfNode()?.label, "Roilan")
    // no generic node of kind "self" other than the singleton
    let selves = try app.services.store.allNodes().filter { $0.kind == "self" }
    XCTAssertEqual(selves.count, 1)
}
```

### Step 2: Run → FAIL.

### Step 3: In `MemoryHandlers.save`, before building the generic `candidate`/`upsertMergingSemantic`, add a self route right after decoding `body`:
```swift
if body.kind == "self" {
    let id = (try? services.store.upsertSelf(name: body.label, detail: body.body, embedder: services.embedder)) ?? "self:user"
    struct Out: Encodable { let id: String; let mergedInto: String? }
    let data = try JSONEncoder().encode(Out(id: id, mergedInto: nil))
    return Response(status: .ok, headers: [.contentType: "application/json"],
                    body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
}
```
Leave the existing generic path for all other kinds unchanged.

### Step 4: Run → PASS + `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryService/Handlers/MemoryHandlers.swift Tests/MemoryServiceTests/MemoryEndpointsTests.swift
git commit -m "feat(self): /v1/memory/save routes kind=self to the singleton self node"
```

---

## Task 4: `associate` links the self to mentioned people

**Files:** `MemoryConsolidationEngine.swift` (`associate` prompt); Test: `Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift` (append).

### Step 1: Failing test — append:
```swift
func test_associate_links_self_to_people() async throws {
    let store = try MemoryStore(path: ":memory:", embeddingDim: 1024)
    try store.upsertSelf(name: "Roilan", detail: nil, embedder: nil)
    let maria = Node(id: UUID().uuidString, kind: NodeKind.person.rawValue, label: "María", body: "esposa",
                     layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0,
                     confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                     origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
    try store.upsert(maria)
    let json = #"{"edges":[{"from":"Roilan","relation":"family","to":"María"}]}"#
    let engine = MemoryConsolidationEngine(store: store, embedder: nil,
                                           runtime: <CANNED CLIENT returning json>, transcriptStore: TranscriptStore(dbQueue: store.dbQueue))
    await engine.associate()
    let edges = try store.edges(from: "self:user").filter { $0.relation == .family }
    XCTAssertEqual(edges.first?.dstId, maria.id)
}
```

### Step 2: Run → FAIL (the associate prompt doesn't yet treat `self` as the user; the resolve() should still find "Roilan" → the self node by label — verify, and if the self node's label "Roilan" resolves, the only change needed is the prompt mentioning `self`).

### Step 3: In `associate`'s prompt, update the user-linking guidance. Change the line that says "The `person` node is usually the user; connect the user to …" to:
```
The `self` node is the USER (the person you're talking to); connect the user (self) to their preferences (likes/dislikes), places (locatedAt/worksWith), and the people they know (knows/worksWith/family). Other `person` nodes are third parties — link them to the self with the right relation (family for relatives, knows for friends, worksWith for colleagues). Don't invent entities not listed.
```
(The `resolve(_:)` helper already finds a node by its label's dedup key, so "Roilan" resolves to the self node whose label is "Roilan". No code change beyond the prompt — but confirm `associate` includes the self node in its `nodes`/`labels` list: it iterates `store.allNodes().filter { $0.kind != conversation }`, which includes `self`. Good.)

### Step 4: Run → PASS + `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryCore/MemoryConsolidationEngine.swift Tests/MemoryCoreTests/MemoryConsolidationEngineTests.swift
git commit -m "feat(self): associate links the self node to the user's people (family/knows/worksWith)"
```

---

# PART B — APP

## Task 5: App renders self as "you" + prompt + save tool

**Files:** `personal_agent/Gemma/Gemma/Memory/MemoryClient.swift`, `Gemma/Gemma/Agent/Agent.swift`, `Gemma/Gemma/Memory/SaveMemoryTool.swift`; Test: `Gemma/GemmaTests/RecallInjectionTests.swift` + `AgentJarvisPromptTests.swift` (append).

### Step 1: Render the self node first in `RecallBundle.injectionBlock()`. Read the current `injectionBlock()` (it builds `lines` from `merged`, handles event status, appends `recentTurns`). Add a self section BEFORE the remembered-facts lines, and EXCLUDE the self node from the generic `lines`:
```swift
func injectionBlock() -> String {
    let all = recall + core.filter { c in !recall.contains(where: { $0.label == c.label && $0.kind == c.kind }) }
    let selfNode = all.first { $0.kind == "self" }
    let merged = all.filter { $0.kind != "self" }
    let summaries = merged.filter { $0.kind == "summary" }
    let rest = merged.filter { $0.kind != "summary" }
    let lines = (summaries + rest).map { n -> String in
        let base = "- [\(n.kind)] \(n.label): \(n.body.isEmpty ? n.label : n.body)"
        guard n.kind == "event", let extra = n.extra,
              let data = extra.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? String else { return base }
        return base + scheduleStatusSuffix(status)
    }
    var out = ""
    if let s = selfNode, !s.label.isEmpty {
        out = "You are speaking with \(s.label) (the user)." + (s.body.isEmpty ? "" : " \(s.body).")
    }
    if !merged.isEmpty {
        out += (out.isEmpty ? "" : "\n") + "What you remember about the user (use if relevant):\n" + lines.joined(separator: "\n")
    }
    if !recentTurns.isEmpty {
        let rt = recentTurns.map { "- \($0.role): \($0.text)" }.joined(separator: "\n")
        out += (out.isEmpty ? "" : "\n\n") + "Recent conversation (other chats):\n" + rt
    }
    return out
}
```

### Step 2: `Agent.systemPromptText` — add the self line. Insert (e.g. right after the persona sentence) inside the static string:
```
The "self" record you may be given is the USER you are speaking with — their name and identity; address them by it, treat what they say about themselves as about "you" (never a third party), and never ask for something already in your memory about them. Other named people are separate persons with their own roles.
```

### Step 3: `SaveMemoryTool` — document `kind:"self"`. In its `kind` `AgentToolParam` description, change to: `"One of: self (the user's own name/identity), person, place, preference, fact."`.

### Step 4: Tests — append.
`RecallInjectionTests.swift`:
```swift
func test_self_node_renders_as_you() {
    let bundle = MemoryClient.RecallBundle(
        core: [MemoryClient.RecallNode(kind: "self", label: "Roilan", body: "", extra: nil)],
        recall: [], recentTurns: [])
    let block = bundle.injectionBlock()
    XCTAssertTrue(block.contains("You are speaking with Roilan (the user)."), block)
    XCTAssertFalse(block.contains("- [self]"), "self must not render as a generic fact line")
}
```
`AgentJarvisPromptTests.swift`:
```swift
func test_prompt_has_self_instruction() {
    XCTAssertTrue(Agent.systemPromptText.localizedCaseInsensitiveContains("the user you are speaking with"),
                  Agent.systemPromptText)
}
```
Run the app suite → these pass; only the known-unrelated failure remains.

### Step 5: Commit
```bash
git add Gemma/Gemma/Memory/MemoryClient.swift Gemma/Gemma/Agent/Agent.swift Gemma/Gemma/Memory/SaveMemoryTool.swift Gemma/GemmaTests/
git commit -m "feat(app): render the self node as 'you are speaking with X (the user)' + prompt + save_memory self kind"
```

---

## Task 6: Deploy server + manual E2E

- [ ] **Deploy:** `ssh HomeLab 'cd ~/Projects/gemma-memory && git pull && docker compose build memory && docker compose up -d memory'`. Verify `/healthz` 200.
- [ ] **App build (⌘R)** on the fresh memory: "me llamo Roilan, mi esposa es María, mi hija Ana." Open a new chat → "¿cómo me llamo y quién va conmigo de viaje?" → the agent addresses you as Roilan (the user) and names María (esposa) and Ana (hija) as third parties. Confirm `selfNode` exists (`curl`/inspector shows exactly one `kind=self`).
- [ ] **Record** the result.

---

## Self-Review

**Spec coverage:** §4.1 self singleton + coreMemories-first → Task 1. §4.2 capture routing (consolidation + save + associate role-in-detail + self↔people) → Tasks 2, 3, 4. §4.3 render + prompt → Task 5. §7 testing → unit tests in Tasks 1–5 + manual E2E Task 6. §8 order → Tasks 1–6. ✓ Server + app split. ✓

**Placeholder scan:** No TBD/TODO. The `<CANNED CLIENT returning json>` notes (Tasks 2, 4) point to the file's existing canned `ModelTextClient` test helper (used by prior consolidation tests) — match it, don't invent. The "mirror the app/auth helpers" notes (Task 3) reuse sibling endpoint-test infrastructure.

**Type consistency:** `NodeKind.selfUser` (rawValue "self") in Task 1, used as `kind == "self"` in Tasks 2, 3, 5. `upsertSelf(name:detail:embedder:) -> String` / `selfNode() -> Node?` defined in Task 1, used in Tasks 2, 3, 4, 6. `coreMemories` self-first (Task 1) consumed by the recall handler (unchanged) → app `injectionBlock` self render (Task 5). `Agent.systemPromptText` (existing static) extended in Task 5 and asserted there. The self node id is the literal `"self:user"` everywhere.
