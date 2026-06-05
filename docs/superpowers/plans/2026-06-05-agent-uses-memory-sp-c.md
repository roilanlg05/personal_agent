# Agent Uses Memory (SP-C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent three read-tools — `recall_by_topic`, `why`, `list_topics` — that expose the rich SP-A/SP-B memory (thematic tags + `derivesFrom` provenance) so it answers precisely instead of guessing.

**Architecture:** Three GET endpoints on the server expose existing store data (`distinctTags`, `nodesWithTag`, `edges(from:)`+`derivesFrom`, `searchFTS`/`nearest`), with natural-language targeting resolved server-side (topic→nearest tag, claim→best insight). The app gets three thin `MemoryClient` methods and three `AgentTool`s (modeled on `LoadMessagesTool`), plus a prompt line telling the agent when to use them.

**Tech Stack:** Swift 6 — server (Hummingbird, GRDB) + app (SwiftUI). Spec: `docs/superpowers/specs/2026-06-05-agent-uses-memory-design.md`. No DB migration (reuses existing tables/edges).

**Server tests:** `swift test --filter <Name>` in `gemma-memory/memory-service` (branch from `main`).
**App tests:** `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/<Class> 2>&1 | tail -30`. **Known app failure to IGNORE:** `HarnessModelTests.test_defaultBaseURL_isLocalhost8081`.

**Verified current shapes:**
- `MemoryHandlers.register` (`MemoryHandlers.swift`): `group.post("/memory/save"…)`, `group.get("/memory/expand", use: expand)` — add GET routes here.
- Store: `distinctTags() -> [String]`, `nodesWithTag(_:) -> [String]`, `node(id:) -> Node?`, `edges(from:) -> [Edge]`, `searchFTS(query:limit:) -> [Node]`, `nearest(to:k:) -> [(id,distance)]`, `MemoryStore.cosineDistance(_:_:) -> Double` (public static). `services.embedder.embed(_) throws -> [Float]`, `services.store`.
- `Relation.derivesFrom`, `NodeKind.insight`. `Node` has `kind/label/body`.
- App `MemoryClient`: private `get<R: Decodable>(_ path) async throws -> R`, `escape(_:)`; `byHub`/`byEntity` GET methods are the template; `Node` is a `Decodable` struct.
- Tools registered in `HarnessModel.runAgentTurn` (`registry.register(...)` block, only when `client != nil`).

---

## File Structure

**Server:** `Sources/MemoryService/Handlers/MemoryHandlers.swift` — 3 GET handlers + routes.
**App:** `Gemma/Gemma/Memory/MemoryClient.swift` — 3 methods + 3 decode structs; `Gemma/Gemma/Memory/MemoryTopicTools.swift` (create) — the 3 tools; `Gemma/Gemma/Harness/HarnessModel.swift` — registration; `Gemma/Gemma/Agent/Agent.swift` — prompt line.

---

## Task 1: Server — `GET /v1/memory/tags` + `GET /v1/memory/by_topic`

**Files:** `Sources/MemoryService/Handlers/MemoryHandlers.swift`; Test: `Tests/MemoryServiceTests/MemoryEndpointsTests.swift` (append).

### Step 0: Read `MemoryHandlers.register` + an existing GET handler (`expand`) for the query-param + JSON-encode + `jsonError` pattern. Read how `MemoryEndpointsTests` builds the app (`makeAppWithServices()` → `(app, services)`, `app.test(.live) { client in client.execute(...) }`, `Data(buffer: res.body)`, seeding via `services.store.upsert` + `services.store.setTags` + `services.embedder.embed`). Confirm `MemoryStore.cosineDistance` is `public static`.

### Step 1: Failing test — append to `MemoryEndpointsTests.swift`:
```swift
func test_memory_tags_and_by_topic() async throws {
    let (app, services) = try await makeAppWithServices()
    func seed(_ id: String, _ label: String, tags: [String]) throws {
        let n = Node(id: id, kind: NodeKind.preference.rawValue, label: label, body: "body-\(label)", layer: .daily,
                     createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0, confidence: .probable,
                     mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                     dirty: true, deleted: false, extra: nil)
        try services.store.upsert(n); try services.store.setTags(nodeId: id, tags)
    }
    try seed("n1", "calls", tags: ["trading"])
    try seed("n2", "puts", tags: ["trading"])
    try seed("n3", "yoga", tags: ["salud"])
    struct Tags: Decodable { let tags: [String] }
    struct Topic: Decodable { struct N: Decodable { let kind: String; let label: String; let body: String }
        let tag: String; let nodes: [N] }
    try await app.test(.live) { client in
        try await client.execute(uri: "/v1/memory/tags", method: .get,
            headers: [.authorization: "Bearer test-token"]) { res in
            let out = try JSONDecoder().decode(Tags.self, from: Data(buffer: res.body))
            XCTAssertEqual(out.tags, ["salud", "trading"])     // distinct, sorted
        }
        // exact-match topic → ALL nodes with that tag (complete enumeration)
        try await client.execute(uri: "/v1/memory/by_topic?topic=trading", method: .get,
            headers: [.authorization: "Bearer test-token"]) { res in
            let out = try JSONDecoder().decode(Topic.self, from: Data(buffer: res.body))
            XCTAssertEqual(out.tag, "trading")
            XCTAssertEqual(Set(out.nodes.map { $0.label }), ["calls", "puts"])
        }
        // unknown topic → empty
        try await client.execute(uri: "/v1/memory/by_topic?topic=astrofisica", method: .get,
            headers: [.authorization: "Bearer test-token"]) { res in
            let out = try JSONDecoder().decode(Topic.self, from: Data(buffer: res.body))
            XCTAssertEqual(out.tag, "")
            XCTAssertTrue(out.nodes.isEmpty)
        }
    }
}
```
ADAPT `Node(...)`/`makeAppWithServices`/body-decode to the file's real forms. (The unknown-topic case relies on the embedder not finding a tag within the 0.2 threshold for "astrofisica" vs "trading"/"salud" — true for any real embedder; if the test app's embedder is a degenerate stub that returns equal vectors, switch the unknown-topic assertion to a topic the stub maps far, or seed with a stub that distinguishes them. Verify it's empty for the RIGHT reason.)

### Step 2: Run → FAIL: `swift test --filter test_memory_tags_and_by_topic` (routes 404).

### Step 3a: Register the routes. In `MemoryHandlers.register`, add:
```swift
group.get("/memory/tags",     use: tags)
group.get("/memory/by_topic", use: byTopic)
```

### Step 3b: Add the handlers (mirror `expand`'s style):
```swift
@Sendable func tags(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
    struct Payload: Encodable { let tags: [String] }
    let payload = Payload(tags: (try? services.store.distinctTags()) ?? [])
    let data = try JSONEncoder().encode(payload)
    return Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
}

@Sendable func byTopic(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
    let q = req.uri.queryParameters
    guard let topic = q["topic"].map(String.init), !topic.trimmingCharacters(in: .whitespaces).isEmpty else {
        return jsonError(.badRequest, "bad_request", "topic required")
    }
    let limit = q["limit"].flatMap { Int(String($0)) } ?? 100
    let vocab = (try? services.store.distinctTags()) ?? []
    // resolve topic → canonical tag: exact (case-insensitive) first, else nearest by embedding ≤ 0.2.
    var resolved = vocab.first { $0.caseInsensitiveCompare(topic) == .orderedSame }
    if resolved == nil, let tv = try? services.embedder.embed(topic) {
        var best: (tag: String, dist: Double)?
        for t in vocab {
            guard let v = try? services.embedder.embed(t) else { continue }
            let d = MemoryStore.cosineDistance(tv, v)
            if best == nil || d < best!.dist { best = (t, d) }
        }
        if let b = best, b.dist <= 0.2 { resolved = b.tag }
    }
    struct OutNode: Encodable { let kind: String; let label: String; let body: String }
    struct Payload: Encodable { let tag: String; let nodes: [OutNode] }
    guard let tag = resolved else {
        let data = try JSONEncoder().encode(Payload(tag: "", nodes: []))
        return Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
    let ids = (try? services.store.nodesWithTag(tag)) ?? []
    let nodes = ids.prefix(limit).compactMap { try? services.store.node(id: $0) }
        .map { OutNode(kind: $0.kind, label: $0.label, body: $0.body) }
    let data = try JSONEncoder().encode(Payload(tag: tag, nodes: nodes))
    return Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
}
```

### Step 4: Run → PASS, then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryService/Handlers/MemoryHandlers.swift Tests/MemoryServiceTests/MemoryEndpointsTests.swift
git commit -m "feat(memory): GET /v1/memory/tags + /v1/memory/by_topic (topic→tag resolution + complete enumeration)"
```

---

## Task 2: Server — `GET /v1/memory/why` (provenance traversal)

**Files:** `Sources/MemoryService/Handlers/MemoryHandlers.swift`; Test: `Tests/MemoryServiceTests/MemoryEndpointsTests.swift` (append).

### Step 1: Failing test — append:
```swift
func test_memory_why_traces_insight_to_sources() async throws {
    let (app, services) = try await makeAppWithServices()
    func mk(_ id: String, _ kind: String, _ label: String, _ body: String) throws {
        let n = Node(id: id, kind: kind, label: label, body: body, layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1,
                     salience: 3, decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                     origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
        try services.store.upsert(n)
    }
    try mk("ins", NodeKind.insight.rawValue, "trades options actively", "trades options actively")
    try mk("s1", NodeKind.preference.rawValue, "calls", "calls")
    try mk("s2", NodeKind.preference.rawValue, "puts", "puts")
    for s in ["s1", "s2"] {
        try services.store.upsert(Edge(id: UUID().uuidString, srcId: "ins", dstId: s, relation: .derivesFrom,
                                       weight: 1, confidence: .probable, createdAt: 1, updatedAt: 1, dirty: true, deleted: false, extra: nil))
    }
    struct Why: Decodable { struct N: Decodable { let label: String }; let insight: String; let sources: [N] }
    try await app.test(.live) { client in
        try await client.execute(uri: "/v1/memory/why?claim=\("trades options".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)",
            method: .get, headers: [.authorization: "Bearer test-token"]) { res in
            let out = try JSONDecoder().decode(Why.self, from: Data(buffer: res.body))
            XCTAssertEqual(out.insight, "trades options actively")
            XCTAssertEqual(Set(out.sources.map { $0.label }), ["calls", "puts"])
        }
        // unmatchable claim → empty
        try await client.execute(uri: "/v1/memory/why?claim=quantum%20chromodynamics", method: .get,
            headers: [.authorization: "Bearer test-token"]) { res in
            let out = try JSONDecoder().decode(Why.self, from: Data(buffer: res.body))
            XCTAssertTrue(out.insight.isEmpty && out.sources.isEmpty)
        }
    }
}
```
(The FTS match: `searchFTS("trades options")` should match the insight body "trades options actively". The unmatchable claim relies on FTS + semantic both missing — confirm the test app's embedder/FTS don't spuriously match; if the embedder is degenerate, the semantic fallback could match the insight — in that case assert the non-empty path only and note the empty-path is covered by inspection. Verify the empty case is empty for the RIGHT reason.)

### Step 2: Run → FAIL (route 404).

### Step 3a: Register the route. In `MemoryHandlers.register`, add:
```swift
group.get("/memory/why", use: why)
```

### Step 3b: Add the handler:
```swift
@Sendable func why(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
    let q = req.uri.queryParameters
    guard let claim = q["claim"].map(String.init), !claim.trimmingCharacters(in: .whitespaces).isEmpty else {
        return jsonError(.badRequest, "bad_request", "claim required")
    }
    let insightKind = NodeKind.insight.rawValue
    // Locate the best-matching insight: FTS first, then semantic fallback.
    var insight = ((try? services.store.searchFTS(query: claim, limit: 10)) ?? []).first { $0.kind == insightKind }
    if insight == nil, let cv = try? services.embedder.embed(claim) {
        let hits = (try? services.store.nearest(to: cv, k: 20)) ?? []
        for h in hits {
            if h.distance <= 0.35, let n = try? services.store.node(id: h.id), n.kind == insightKind { insight = n; break }
        }
    }
    struct OutNode: Encodable { let kind: String; let label: String; let body: String }
    struct Payload: Encodable { let insight: String; let sources: [OutNode] }
    guard let ins = insight else {
        let data = try JSONEncoder().encode(Payload(insight: "", sources: []))
        return Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
    let sourceIds = ((try? services.store.edges(from: ins.id)) ?? []).filter { $0.relation == .derivesFrom }.map { $0.dstId }
    let sources = sourceIds.compactMap { try? services.store.node(id: $0) }.map { OutNode(kind: $0.kind, label: $0.label, body: $0.body) }
    let data = try JSONEncoder().encode(Payload(insight: ins.body, sources: sources))
    return Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
}
```

### Step 4: Run → PASS, then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryService/Handlers/MemoryHandlers.swift Tests/MemoryServiceTests/MemoryEndpointsTests.swift
git commit -m "feat(memory): GET /v1/memory/why — locate insight + traverse derivesFrom to source memories"
```

---

## Task 3: App — `MemoryClient` methods

**Files:** `Gemma/Gemma/Memory/MemoryClient.swift`; Test: `Gemma/GemmaTests/MemoryClientTests.swift` (append).

### Step 0: Read `MemoryClient.byHub`/`byEntity` (the GET-via-`get<R>` pattern), `escape`, and the `MemoryClientTests` `StubProtocol`/`makeClient()` helpers.

### Step 1: Failing test — append to `MemoryClientTests.swift`:
```swift
func test_memoryTags_recallByTopic_why_decode() async throws {
    StubProtocol.stub = { req in
        let path = req.url?.path ?? ""
        let json: String
        switch path {
        case "/v1/memory/tags":     json = #"{"tags":["salud","trading"]}"#
        case "/v1/memory/by_topic": json = #"{"tag":"trading","nodes":[{"kind":"preference","label":"calls","body":"x"}]}"#
        case "/v1/memory/why":      json = #"{"insight":"trades options","sources":[{"kind":"preference","label":"calls","body":"x"}]}"#
        default: json = "{}"
        }
        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, json.data(using: .utf8)!)
    }
    let c = makeClient()
    XCTAssertEqual(try await c.memoryTags(), ["salud", "trading"])
    let topic = try await c.recallByTopic(topic: "trading")
    XCTAssertEqual(topic.tag, "trading"); XCTAssertEqual(topic.nodes.first?.label, "calls")
    let why = try await c.why(claim: "trades options")
    XCTAssertEqual(why.insight, "trades options"); XCTAssertEqual(why.sources.first?.label, "calls")
}
```

### Step 2: Run → FAIL.

### Step 3: In `MemoryClient.swift`, add the structs (near `ByHubResult`) + methods (near `byHub`):
```swift
struct TopicNode: Decodable, Sendable { let kind: String; let label: String; let body: String }
struct TopicResult: Decodable, Sendable { let tag: String; let nodes: [TopicNode] }
struct WhyResult: Decodable, Sendable { let insight: String; let sources: [TopicNode] }

func memoryTags() async throws -> [String] {
    struct R: Decodable { let tags: [String] }
    let r: R = try await get("/v1/memory/tags")
    return r.tags
}
func recallByTopic(topic: String, limit: Int = 100) async throws -> TopicResult {
    try await get("/v1/memory/by_topic?topic=\(escape(topic))&limit=\(limit)")
}
func why(claim: String) async throws -> WhyResult {
    try await get("/v1/memory/why?claim=\(escape(claim))")
}
```

### Step 4: Run → PASS (`-only-testing:GemmaTests/MemoryClientTests`). Only the known unrelated failure may remain elsewhere.

### Step 5: Commit
```bash
git add Gemma/Gemma/Memory/MemoryClient.swift Gemma/GemmaTests/MemoryClientTests.swift
git commit -m "feat(app): MemoryClient memoryTags/recallByTopic/why"
```

---

## Task 4: App — three tools + registration + prompt

**Files:** Create `Gemma/Gemma/Memory/MemoryTopicTools.swift`; Modify `Gemma/Gemma/Harness/HarnessModel.swift` (registration), `Gemma/Gemma/Agent/Agent.swift` (prompt); Test: `Gemma/GemmaTests/AgentJarvisPromptTests.swift` (append).

### Step 0: Read `Memory/LoadMessagesTool.swift` (the AgentTool template — `MemoryToolbox.shared.memory`, `ToolActivityRelay.started/finished`, the `await { ... }()` pattern, output cap), the registration block in `HarnessModel.runAgentTurn`, and `Agent.systemPromptText`. Confirm `AgentToolParam.ParamType` cases (`string`/`integer`/`number`/`boolean`).

### Step 1: Failing test — append to `AgentJarvisPromptTests.swift`:
```swift
func test_prompt_mentions_topic_and_why_tools() {
    let p = Agent.systemPromptText
    XCTAssertTrue(p.localizedCaseInsensitiveContains("recall_by_topic"), p)
    XCTAssertTrue(p.localizedCaseInsensitiveContains("why"), p)
    XCTAssertTrue(p.localizedCaseInsensitiveContains("list_topics"), p)
}
```

### Step 2: Run → FAIL.

### Step 3a: Create `Gemma/Gemma/Memory/MemoryTopicTools.swift`:
```swift
import Foundation

/// List the thematic topics (tags) the assistant has memories about.
struct ListTopicsTool: AgentTool {
    static let name = "list_topics"
    static let description = "List the topics/themes you have memories about (e.g. when the user asks what you know about them). No arguments."
    static let parameters: [AgentToolParam] = []
    func run(argsJSON: String) async -> String {
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "") }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
            do {
                let tags = try await mem.memoryTags()
                return tags.isEmpty ? "no topics yet" : "Topics: " + tags.joined(separator: ", ")
            } catch { return "memory unavailable" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// Complete enumeration of what the assistant remembers about ONE topic (tag-filtered).
struct RecallByTopicTool: AgentTool {
    static let name = "recall_by_topic"
    static let description = """
    Return EVERYTHING you remember about one topic/theme (e.g. "finanzas", "trabajo", "salud"), \
    not just what you already see. Use it when the user asks for all you know about a subject.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "topic", type: .string, description: "The topic/theme to enumerate, e.g. \"finanzas\".", required: true),
    ]
    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let topic = ((obj["topic"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return "need a topic" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: topic) }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
            do {
                let r = try await mem.recallByTopic(topic: topic)
                guard !r.nodes.isEmpty else { return "nothing remembered about \"\(topic)\"" }
                let lines = r.nodes.map { "- [\($0.kind)] \($0.label): \($0.body.isEmpty ? $0.label : $0.body)" }
                return String(("About \(r.tag):\n" + lines.joined(separator: "\n")).prefix(4000))
            } catch { return "memory unavailable" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// Justify a belief: trace an insight back to the source memories it derives from.
struct WhyTool: AgentTool {
    static let name = "why"
    static let description = """
    Explain WHY you believe something about the user, by tracing it to the source memories. \
    Use it when the user asks why you think that or what you're basing it on. Pass the belief/claim. \
    Cite the sources it returns; don't invent a justification.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "claim", type: .string, description: "The belief/claim to justify, e.g. \"the user trades options\".", required: true),
    ]
    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let claim = ((obj["claim"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claim.isEmpty else { return "need a claim" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: claim) }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
            do {
                let r = try await mem.why(claim: claim)
                guard !r.insight.isEmpty else { return "I can't trace that to a specific memory" }
                guard !r.sources.isEmpty else { return "I believe \"\(r.insight)\" but have no recorded sources" }
                let src = r.sources.map { "\($0.label)" }.joined(separator: ", ")
                return String("I believe \"\(r.insight)\" because of: \(src)".prefix(2000))
            } catch { return "memory unavailable" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
```
(If `AgentTool.parameters` cannot be an empty array literal for `ListTopicsTool` due to type inference, write `static let parameters: [AgentToolParam] = []` exactly as shown — it is a typed empty array, which compiles.)

### Step 3b: Register the tools. In `HarnessModel.runAgentTurn`, in the `if client != nil { ... }` block alongside the other memory tools, add:
```swift
registry.register(ListTopicsTool()); registry.register(RecallByTopicTool()); registry.register(WhyTool())
```

### Step 3c: Add the prompt line. In `Agent.systemPromptText`, after the `load_messages` sentence (the "...never load raw messages you don't need." part), insert:
```
Your memory is rich — identity, episodic summaries, thematic topics, and derived insights. When the user asks for everything about a topic, call recall_by_topic(topic) for the complete list (not just what you see). When they ask why you believe something or what you're basing it on, call why(claim) and cite the source memories it returns. When they ask what topics you know about them, call list_topics. Don't invent what a tool can answer. \
```
(Keep the `\` line-continuation so the literal stays valid.)

### Step 4: Run → PASS: `AgentJarvisPromptTests`. Build the app + a fuller test run; only the known `HarnessModelTests.test_defaultBaseURL_isLocalhost8081` may fail.

### Step 5: Commit
```bash
git add Gemma/Gemma/Memory/MemoryTopicTools.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/Gemma/Agent/Agent.swift Gemma/GemmaTests/AgentJarvisPromptTests.swift
git commit -m "feat(app): list_topics / recall_by_topic / why tools + prompt guidance"
```

---

## Task 5: Deploy server + manual E2E

- [ ] **Deploy:** `ssh HomeLab 'cd ~/Projects/gemma-memory && git pull --ff-only origin main && docker compose build memory && docker compose up -d memory'`. Verify `healthz` 200. Smoke: `GET /v1/memory/tags` returns the current tags (curl with the bearer token).
- [ ] **App build (⌘R) on real memory** (with clusters/tags/identity from prior consolidation): ask "¿de qué temas sabes de mí?" → `list_topics`; "¿qué sé de <un tema real>?" → `recall_by_topic` enumerates; "¿por qué crees <un rasgo de identidad>?" → `why` cites the source memories. Confirm the agent calls the tools and grounds its answer in what they return (no invention).
- [ ] **Record** the result.

---

## Self-Review

**Spec coverage:** §4.1 `/v1/memory/tags`+`/by_topic` → Task 1; `/why` → Task 2. §4.2 client methods → Task 3. §4.3 three tools + registration → Task 4. §4.4 prompt → Task 4. §6 error handling (empty topic/claim, unavailable) → handled in Tasks 1/2 (empty payloads) + Task 4 (tool messages). §7 testing → Tasks 1–4 unit + Task 5 E2E. §8 order → Tasks 1–5. ✓ No migration (matches spec). ✓

**Placeholder scan:** No TBD/TODO. Step-0 "match the file's helpers" notes point to concrete existing patterns (`expand` handler, `byHub` client method, `LoadMessagesTool`, test app construction). The two embedder-determinism caveats (Tasks 1/2 unknown-topic/unmatchable-claim) give explicit fallback instructions and a "verify it's empty for the right reason" check.

**Type consistency:** Server `Payload{tag, nodes:[{kind,label,body}]}` (Task 1) ↔ app `TopicResult{tag, nodes:[TopicNode{kind,label,body}]}` (Task 3) ↔ rendered by `RecallByTopicTool` (Task 4). Server `Payload{insight, sources:[{kind,label,body}]}` (Task 2) ↔ app `WhyResult{insight, sources:[TopicNode]}` (Task 3) ↔ `WhyTool` (Task 4). `memoryTags() -> [String]` (Task 3) ↔ `ListTopicsTool` (Task 4). Tool names `list_topics`/`recall_by_topic`/`why` consistent across Task 4 registration, prompt, and the prompt test. Routes `/v1/memory/tags`/`/by_topic`/`/why` consistent between Task 1/2 handlers and Task 3 client paths.
