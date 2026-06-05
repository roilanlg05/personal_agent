# Agent Gateway — Phase 1a (text) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `POST /v1/agent/turn { text, threadId } → { reply }` to the i3 memory service — the full agentic loop (tool-calling, memory + 11 tools, JARVIS prompt) running as a network service, so any device can get Gemma's reply by posting text.

**Architecture:** All in `gemma-memory/memory-service`, co-located with the store (tools hit it directly). A `ToolCallingClient` (ports the app's `ServerRuntime` tool-calling, non-streamed, reusing the existing `ModelConfigStore`) + a server-side `AgentTool` protocol + 11 tools + a ported JARVIS prompt + a server agent loop + the endpoint. The macOS app is unchanged.

**Tech Stack:** Swift 6 — server (SwiftPM, GRDB, Hummingbird). Spec: `docs/superpowers/specs/2026-06-05-agent-gateway-phase1a-design.md`. No DB migration.

**Refinement vs spec (to honor "app unchanged"):** the gateway reuses the EXISTING `ModelConfigStore` config (the one the app already pushes for consolidation) rather than a new "agent" config — a separate agent-vs-consolidation config would require app changes, deferred. Point that config at a chat-quality model for the E2E.

**Server tests:** `swift test --filter <Name>` in `gemma-memory/memory-service` (branch from `main`).

**Verified current shapes:**
- `RemoteModelClient` (`Sources/MemoryService/RemoteModelClient.swift`): `ModelTextClient`, plain `generate` only. `resolve()` reads `configStore?.load()` → `(baseURL, model, apiKey, isLocal)` where `isLocal = provider=="local"`; falls back to `(defaultBaseURL, defaultModel, nil, true)`. Posts to `baseURL/chat/completions`, bearer if `apiKey`, `chat_template_kwargs.enable_thinking=false` when local. `ModelConfigStore.load() -> ModelConfig?` with `provider`/`baseURL`/`model`/`apiKey`.
- App `Agent.run` (`Gemma/Gemma/Agent/Agent.swift`): max-5 tool loop — build prompt (recall+now tail + user), call runtime with tools, collect `pendingToolCalls`, if none → final; else run each tool, append `[You called the tool \`NAME\` with arguments ARGS; it returned: RESULT. Now reply…]`, re-iterate. `systemPromptText` + `scheduleConventions` (line 21) + `nowContext(_:)` (line 35) are the prompt parts.
- App `ServerRuntime.generate(prompt:tools:options:)`: OpenAI request `{model, messages:[system,…history,user], tools:[functionSpec], …}`, parses `tool_calls` (function.name/arguments). `AgentTool.functionSpec` = `{type:"function", function:{name, description, parameters: jsonSchema}}`; `jsonSchema` from `[AgentToolParam{name,type,description,required}]`.
- Store (`Sources/MemoryCore/`): `upsert`, `node`, `forgetById`/`forgetByLabel`, `distinctTags`/`nodesWithTag`/`tagsFor`, `scheduleConflicts`/`createEventChecked`/`scheduleWindow`/`cancelEvents`, `transcript.range`/`transcript.append`, `searchFTS`/`nearest`, `MemoryStore.cosineDistance`. `services`: `store`, `transcript`, `embedder`, `retriever`, `scheduler`, `modelConfig`, `bearerToken`. Handler registration in `App.swift` (`MemoryHandlers(services:).register(on: v1)` etc.).
- The `by_topic`/`why`/`save` logic lives inline in `MemoryHandlers.swift` (Tasks 1/2/3 of SP-C + the save handler).

---

## File Structure (all new files in `Sources/MemoryService/`)
- `Agent/ToolCallingClient.swift` — model client with tools (non-streamed) + the `AgentModelClient` protocol + result type.
- `Agent/GatewayTool.swift` — server-side `AgentTool` protocol + `functionSpec`/`jsonSchema`.
- `Agent/GatewayTools.swift` — the 11 tool structs.
- `Agent/AgentPrompt.swift` — ported `systemPromptText`/`scheduleConventions`/`nowContext` + the recall `injectionBlock` builder.
- `Agent/AgentLoop.swift` — the ported agentic loop.
- `Handlers/AgentHandlers.swift` — `POST /v1/agent/turn`.
- `MemoryService/MemoryQueries.swift` — shared `byTopic`/`why`/`save` logic extracted from `MemoryHandlers`.

---

## Task 1: `ToolCallingClient` — model client with tools (non-streamed)

**Files:** Create `Sources/MemoryService/Agent/ToolCallingClient.swift`; Test: `Tests/MemoryServiceTests/ToolCallingClientTests.swift` (create).

### Step 0: Read `RemoteModelClient.swift` (the `resolve()` + request build + auth + the OpenAI decode). Read `ModelConfigStore` (`load()` shape). Confirm a `URLSession` can be injected for tests (RemoteModelClient takes `session`).

### Step 1: Failing test — `Tests/MemoryServiceTests/ToolCallingClientTests.swift`:
```swift
import XCTest
@testable import MemoryService
@testable import MemoryCore

final class ToolCallingClientTests: XCTestCase {
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var json = "{}"
        override class func canInit(with r: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let res = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.json.data(using: .utf8)!)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private func makeClient() -> ToolCallingClient {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [Stub.self]
        return ToolCallingClient(configStore: nil, defaultBaseURL: URL(string: "http://localhost:8080/v1")!,
                                 defaultModel: "m", session: URLSession(configuration: cfg))
    }
    func test_parses_text_reply() async throws {
        Stub.json = #"{"choices":[{"message":{"content":"hi there"}}]}"#
        let r = try await makeClient().complete(systemPrompt: "s", userPrompt: "hi", tools: [])
        XCTAssertEqual(r.text, "hi there"); XCTAssertTrue(r.toolCalls.isEmpty)
    }
    func test_parses_tool_call() async throws {
        Stub.json = #"{"choices":[{"message":{"content":null,"tool_calls":[{"function":{"name":"current_time","arguments":"{}"}}]}}]}"#
        let r = try await makeClient().complete(systemPrompt: "s", userPrompt: "what time", tools: [])
        XCTAssertEqual(r.toolCalls.map { $0.name }, ["current_time"])
        XCTAssertEqual(r.toolCalls.first?.args, "{}")
    }
}
```

### Step 2: Run → FAIL.

### Step 3: Create `Sources/MemoryService/Agent/ToolCallingClient.swift`:
```swift
import Foundation
import MemoryCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AgentToolCall: Sendable, Equatable { public let name: String; public let args: String }
public struct AgentModelResult: Sendable { public let text: String; public let toolCalls: [AgentToolCall] }

/// Model client that can request tools (non-streamed OpenAI chat/completions). Mirrors the app's
/// ServerRuntime tool-calling, server-side. Reuses ModelConfigStore (same config the consolidation
/// client uses). The tool specs are passed as already-built OpenAI function specs.
public protocol AgentModelClient: Sendable {
    func complete(systemPrompt: String, userPrompt: String, tools: [[String: Any]]) async throws -> AgentModelResult
}

public struct ToolCallingClient: AgentModelClient {
    let configStore: ModelConfigStore?
    let defaultBaseURL: URL
    let defaultModel: String
    let session: URLSession
    let timeout: TimeInterval

    public init(configStore: ModelConfigStore?, defaultBaseURL: URL,
                defaultModel: String = "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
                session: URLSession = .shared, timeout: TimeInterval = 120) {
        self.configStore = configStore; self.defaultBaseURL = defaultBaseURL
        self.defaultModel = defaultModel; self.session = session; self.timeout = timeout
    }

    private func resolve() -> (baseURL: URL, model: String, apiKey: String?, isLocal: Bool) {
        if let c = try? configStore?.load() ?? nil, let url = URL(string: c.baseURL) {
            return (url, c.model, c.apiKey, c.provider == "local")
        }
        return (defaultBaseURL, defaultModel, nil, true)
    }

    public func complete(systemPrompt: String, userPrompt: String, tools: [[String: Any]]) async throws -> AgentModelResult {
        let r = resolve()
        var messages: [[String: Any]] = []
        if !systemPrompt.isEmpty { messages.append(["role": "system", "content": systemPrompt]) }
        messages.append(["role": "user", "content": userPrompt])
        var body: [String: Any] = ["model": r.model, "messages": messages, "max_tokens": 1024, "temperature": 0.3, "stream": false]
        if r.isLocal { body["chat_template_kwargs"] = ["enable_thinking": false] }
        if !tools.isEmpty { body["tools"] = tools }

        var req = URLRequest(url: r.baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = r.apiKey, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelGatewayError.remoteFailed(status: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
            return AgentModelResult(text: "", toolCalls: [])
        }
        let text = (msg["content"] as? String) ?? ""
        var calls: [AgentToolCall] = []
        if let tcs = msg["tool_calls"] as? [[String: Any]] {
            for tc in tcs {
                if let fn = tc["function"] as? [String: Any], let name = fn["name"] as? String, !name.isEmpty {
                    calls.append(AgentToolCall(name: name, args: (fn["arguments"] as? String) ?? "{}"))
                }
            }
        }
        return AgentModelResult(text: text, toolCalls: calls)
    }
    public enum ModelGatewayError: Error, Equatable { case remoteFailed(status: Int) }
}
```
(ADAPT `ModelConfigStore.load()`'s real return shape — if `ModelConfig` field names differ from `provider`/`baseURL`/`model`/`apiKey`, match `RemoteModelClient.resolve()` exactly, which is the source of truth.)

### Step 4: Run → PASS, then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryService/Agent/ToolCallingClient.swift Tests/MemoryServiceTests/ToolCallingClientTests.swift
git commit -m "feat(gateway): ToolCallingClient — non-streamed OpenAI tool-calling, reuses ModelConfigStore"
```

---

## Task 2: Extract shared `byTopic`/`why`/`save` query logic

**Files:** Create `Sources/MemoryService/MemoryQueries.swift`; Modify `Sources/MemoryService/Handlers/MemoryHandlers.swift` (call the shared funcs); Test: `Tests/MemoryServiceTests/MemoryQueriesTests.swift` (create).

### Step 0: Read the `byTopic`, `why`, and `save`-routing logic in `MemoryHandlers.swift` (the topic→tag resolution, the insight-locate + derivesFrom traversal, and the kind=="self"→upsertSelf else upsertMergingSemantic routing).

### Step 1: Failing test — `Tests/MemoryServiceTests/MemoryQueriesTests.swift`:
```swift
import XCTest
@testable import MemoryService
@testable import MemoryCore

final class MemoryQueriesTests: XCTestCase {
    func test_resolveTopic_and_nodesForTag() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 1024)
        let n = Node(id: "n1", kind: NodeKind.preference.rawValue, label: "calls", body: "calls", layer: .daily,
                     createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0, confidence: .probable,
                     mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                     dirty: true, deleted: false, extra: nil)
        try store.upsert(n); try store.setTags(nodeId: "n1", ["trading"])
        // exact-match resolution
        let nodes = try MemoryQueries.nodesForTopic("trading", store: store, embedder: nil, limit: 100)
        XCTAssertEqual(nodes.map { $0.label }, ["calls"])
    }
    func test_whySources_traverses_derivesFrom() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 1024)
        func mk(_ id: String, _ kind: String, _ b: String) throws {
            try store.upsert(Node(id: id, kind: kind, label: b, body: b, layer: .daily, createdAt: 1, updatedAt: 1,
                lastSeenAt: 1, salience: 3, decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil))
        }
        try mk("ins", NodeKind.insight.rawValue, "trades options"); try mk("s1", NodeKind.preference.rawValue, "calls")
        try store.upsert(Edge(id: "e", srcId: "ins", dstId: "s1", relation: .derivesFrom, weight: 1, confidence: .probable,
                              createdAt: 1, updatedAt: 1, dirty: true, deleted: false, extra: nil))
        let r = try MemoryQueries.why("trades options", store: store, embedder: nil)
        XCTAssertEqual(r.insight?.body, "trades options")
        XCTAssertEqual(r.sources.map { $0.label }, ["calls"])
    }
}
```

### Step 2: Run → FAIL.

### Step 3a: Create `Sources/MemoryService/MemoryQueries.swift` — move the logic from the handlers into pure functions over the store. (Copy the topic-resolution + nodesWithTag from `byTopic`, and the FTS/nearest-insight + derivesFrom traversal from `why`, and the save-routing from `save`.):
```swift
import Foundation
import MemoryCore

/// Shared memory query logic, reused by the HTTP handlers AND the agent-gateway tools (DRY).
public enum MemoryQueries {
    /// Resolve a natural-language topic to a canonical tag (exact, else embedding ≤ 0.2), then
    /// return ALL nodes carrying it, capped. Empty if no tag resolves.
    public static func nodesForTopic(_ topic: String, store: MemoryStore, embedder: Embedder?, limit: Int) throws -> [Node] {
        let vocab = (try? store.distinctTags()) ?? []
        var resolved = vocab.first { $0.caseInsensitiveCompare(topic) == .orderedSame }
        if resolved == nil, let tv = try? embedder?.embed(topic) ?? nil {
            var best: (tag: String, dist: Double)?
            for t in vocab { if let v = try? embedder?.embed(t) ?? nil {
                let d = MemoryStore.cosineDistance(tv, v); if best == nil || d < best!.dist { best = (t, d) } } }
            if let b = best, b.dist <= 0.2 { resolved = b.tag }
        }
        guard let tag = resolved else { return [] }
        let ids = (try? store.nodesWithTag(tag)) ?? []
        return ids.prefix(limit).compactMap { try? store.node(id: $0) }
    }

    public struct WhyResult { public let insight: Node?; public let sources: [Node] }
    /// Locate the best insight matching a claim (FTS, then semantic), return its derivesFrom sources.
    public static func why(_ claim: String, store: MemoryStore, embedder: Embedder?) throws -> WhyResult {
        let insightKind = NodeKind.insight.rawValue
        var insight = ((try? store.searchFTS(query: claim, limit: 10)) ?? []).first { $0.kind == insightKind }
        if insight == nil, let cv = try? embedder?.embed(claim) ?? nil {
            for h in ((try? store.nearest(to: cv, k: 20)) ?? []) where h.distance <= 0.35 {
                if let n = try? store.node(id: h.id), n.kind == insightKind, !n.deleted { insight = n; break }
            }
        }
        guard let ins = insight else { return WhyResult(insight: nil, sources: []) }
        let ids = ((try? store.edges(from: ins.id)) ?? []).filter { $0.relation == .derivesFrom }.map { $0.dstId }
        return WhyResult(insight: ins, sources: ids.compactMap { try? store.node(id: $0) })
    }
}
```
(If `embedder?.embed(...)` is `throws -> [Float]` non-optional, the `try? embedder?.embed(t) ?? nil` double-optional collapses correctly — match how the engine/handlers call `embedder`.)

### Step 3b: In `MemoryHandlers.byTopic`/`why`, REPLACE the inline logic with calls to `MemoryQueries.nodesForTopic`/`MemoryQueries.why` (keep the handlers' Response shaping; they now delegate). This proves the extraction is behavior-preserving — the existing SP-C tests (`test_memory_tags_and_by_topic`, `test_memory_why_*`) must STILL pass.

### Step 4: Run → PASS (new test + the existing SP-C endpoint tests unchanged). Full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryService/MemoryQueries.swift Sources/MemoryService/Handlers/MemoryHandlers.swift Tests/MemoryServiceTests/MemoryQueriesTests.swift
git commit -m "refactor(memory): extract byTopic/why query logic to shared MemoryQueries (reused by gateway)"
```

---

## Task 3: Server-side `AgentTool` protocol + the 11 tools

**Files:** Create `Sources/MemoryService/Agent/GatewayTool.swift` + `Sources/MemoryService/Agent/GatewayTools.swift`; Test: `Tests/MemoryServiceTests/GatewayToolsTests.swift` (create).

### Step 0: Read the app's tool files (`Gemma/Gemma/Memory/*.swift`, `Gemma/Gemma/Agent/CurrentTimeTool.swift`, the schedule tools) to COPY each tool's `name`/`description`/`parameters` VERBATIM (so the model behaves identically). Read `AgentTool.swift` for `functionSpec`/`jsonSchema`. Read the store methods + `MemoryQueries` (Task 2).

### Step 1: Failing test — `Tests/MemoryServiceTests/GatewayToolsTests.swift`:
```swift
import XCTest
@testable import MemoryService
@testable import MemoryCore

final class GatewayToolsTests: XCTestCase {
    private func services() throws -> Services { try Services.makeForTests() }   // see Step 3c note
    func test_currentTime_tool_returns_a_time() async throws {
        let out = await CurrentTimeGatewayTool().run(argsJSON: "{}", services: try services())
        XCTAssertTrue(out.contains(":"))   // HH:mm
    }
    func test_recallByTopic_tool_enumerates() async throws {
        let s = try services()
        let n = Node(id: "n1", kind: NodeKind.preference.rawValue, label: "calls", body: "calls", layer: .daily,
                     createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0, confidence: .probable,
                     mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                     dirty: true, deleted: false, extra: nil)
        try s.store.upsert(n); try s.store.setTags(nodeId: "n1", ["trading"])
        let out = await RecallByTopicGatewayTool().run(argsJSON: #"{"topic":"trading"}"#, services: s)
        XCTAssertTrue(out.contains("calls"))
    }
    func test_functionSpec_shape() {
        let spec = RecallByTopicGatewayTool.functionSpec
        XCTAssertEqual((spec["type"] as? String), "function")
        let fn = spec["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "recall_by_topic")
    }
}
```
(If there's no `Services.makeForTests()`, build a `Services` the way `MemoryEndpointsTests` does, or add a tiny test factory. Match the existing test infra.)

### Step 2: Run → FAIL.

### Step 3a: Create `Sources/MemoryService/Agent/GatewayTool.swift`:
```swift
import Foundation

/// Server-side agent tool: same shape as the app's AgentTool but `run` gets `services` to hit the
/// store directly (no HTTP). `functionSpec` builds the OpenAI schema like the app's.
public protocol GatewayTool: Sendable {
    static var name: String { get }
    static var description: String { get }
    static var parameters: [GatewayToolParam] { get }
    func run(argsJSON: String, services: Services) async -> String
}
public struct GatewayToolParam: Sendable {
    public enum ParamType: String { case string, integer, number, boolean }
    public let name: String; public let type: ParamType; public let description: String; public let required: Bool
    public init(name: String, type: ParamType, description: String, required: Bool) {
        self.name = name; self.type = type; self.description = description; self.required = required
    }
}
public extension GatewayTool {
    static var jsonSchema: [String: Any] {
        var props: [String: Any] = [:]; var required: [String] = []
        for p in parameters { props[p.name] = ["type": p.type.rawValue, "description": p.description]; if p.required { required.append(p.name) } }
        return ["type": "object", "properties": props, "required": required]
    }
    static var functionSpec: [String: Any] { ["type": "function", "function": ["name": name, "description": description, "parameters": jsonSchema]] }
    /// Parse a JSON args object once.
    static func args(_ json: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:] }
}
```

### Step 3b: Create `Sources/MemoryService/Agent/GatewayTools.swift` with the 11 tool structs. Each COPIES the app tool's `name`/`description`/`parameters` verbatim (port) and implements `run` over `services` (store direct / `MemoryQueries`). Implement all 11: `CurrentTimeGatewayTool`, `SaveMemoryGatewayTool` (→ `services.store.upsertSelf`/`upsertMergingSemantic` via the save-routing logic — extract it to `MemoryQueries.save(...)` if cleaner), `ForgetGatewayTool` (→ `store.forgetById`/`forgetByLabel`), `LoadMessagesGatewayTool` (→ `transcript.range`), `ListTopicsGatewayTool` (→ `store.distinctTags`), `RecallByTopicGatewayTool` (→ `MemoryQueries.nodesForTopic`), `WhyGatewayTool` (→ `MemoryQueries.why`), `CheckScheduleGatewayTool` (→ `store.scheduleConflicts`), `CreateEventGatewayTool` (→ `store.createEventChecked` + the ScheduleTime epoch parsing the app/handler uses), `QueryScheduleGatewayTool` (→ `store.scheduleWindow`), `CancelEventsGatewayTool` (→ `store.cancelEvents`). Example (the simplest + one store-backed):
```swift
import Foundation
import MemoryCore

public struct CurrentTimeGatewayTool: GatewayTool {
    public static let name = "current_time"
    public static let description = "Get the current local date and time."   // copy the app's verbatim
    public static let parameters: [GatewayToolParam] = []
    public init() {}
    public func run(argsJSON: String, services: Services) async -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd (EEEE) HH:mm"; return f.string(from: Date())
    }
}

public struct RecallByTopicGatewayTool: GatewayTool {
    public static let name = "recall_by_topic"
    public static let description = """
    Return EVERYTHING you remember about one topic/theme … (copy verbatim from the app's RecallByTopicTool)
    """
    public static let parameters: [GatewayToolParam] = [
        .init(name: "topic", type: .string, description: "The topic/theme to enumerate, e.g. \"finanzas\".", required: true)
    ]
    public init() {}
    public func run(argsJSON: String, services: Services) async -> String {
        let topic = ((Self.args(argsJSON)["topic"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return "need a topic" }
        let nodes = (try? MemoryQueries.nodesForTopic(topic, store: services.store, embedder: services.embedder, limit: 100)) ?? []
        guard !nodes.isEmpty else { return "nothing remembered about \"\(topic)\"" }
        return String(nodes.map { "- [\($0.kind)] \($0.label): \($0.body.isEmpty ? $0.label : $0.body)" }.joined(separator: "\n").prefix(4000))
    }
}
```
Implement the remaining 9 the same way — **copy each app tool's exact `name`/`description`/`parameters`, then map `run` to the store/MemoryQueries call** from the spec's table. For `create_event`/`query_schedule`/`check_schedule`/`cancel_events`, mirror how the app's schedule tools parse their args (ISO dates → epoch via `ScheduleTime`) and call the store methods — read both the app tool and the `ScheduleHandlers` to match the arg names + epoch parsing exactly.

### Step 3c: A registry of the 11 tools: `static let gatewayTools: [GatewayTool] = [CurrentTimeGatewayTool(), …]` (add it in `GatewayTools.swift`), and `gatewayToolSpecs = gatewayTools.map { type(of: $0).functionSpec }`.

### Step 4: Run → PASS (the few tool tests), then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryService/Agent/GatewayTool.swift Sources/MemoryService/Agent/GatewayTools.swift Tests/MemoryServiceTests/GatewayToolsTests.swift
git commit -m "feat(gateway): server-side AgentTool protocol + 11 tools (store-direct, app descriptions ported)"
```

---

## Task 4: Prompt assembly (port JARVIS prompt + recall injection)

**Files:** Create `Sources/MemoryService/Agent/AgentPrompt.swift`; Test: `Tests/MemoryServiceTests/AgentPromptTests.swift` (create).

### Step 0: Read the app's `Agent.systemPromptText` + `scheduleConventions` + `nowContext(_:)` (copy verbatim), and the app's `RecallBundle.injectionBlock` (the self/facts/summaries/recentTurns rendering) — port it to build from `services.retriever.retrieve(...)` + `store.coreMemories()`. Read `MemoryRetriever.retrieve` + `injectionBlock(for:)` (the server already has a retriever-side injectionBlock — reuse/extend it).

### Step 1: Failing test — `Tests/MemoryServiceTests/AgentPromptTests.swift`:
```swift
import XCTest
@testable import MemoryService
@testable import MemoryCore

final class AgentPromptTests: XCTestCase {
    func test_systemPrompt_has_jarvis_and_tools_guidance() {
        let p = AgentPrompt.systemPrompt()
        XCTAssertTrue(p.localizedCaseInsensitiveContains("Gemma"))
        XCTAssertTrue(p.localizedCaseInsensitiveContains("recall_by_topic"))   // tool guidance ported
    }
    func test_recall_injection_includes_a_seeded_memory() throws {
        let s = try Services.makeForTests()
        let n = Node(id: "n1", kind: NodeKind.preference.rawValue, label: "sushi", body: "le gusta", layer: .daily,
                     createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 5, decayRate: 0, confidence: .probable,
                     mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                     dirty: true, deleted: false, extra: nil)
        try s.store.upsert(n); try s.store.setEmbedding(nodeId: "n1", s.embedder.embed("sushi"))
        let tail = AgentPrompt.recallTail(query: "comida", threadId: "T", services: s)
        XCTAssertTrue(tail.localizedCaseInsensitiveContains("sushi"), tail)
    }
}
```

### Step 2: Run → FAIL.

### Step 3: Create `Sources/MemoryService/Agent/AgentPrompt.swift`:
```swift
import Foundation
import MemoryCore

public enum AgentPrompt {
    /// The JARVIS system prompt — ported VERBATIM from the app's Agent.systemPromptText + scheduleConventions.
    public static func systemPrompt() -> String { systemPromptText + "\n" + scheduleConventions }
    static let systemPromptText: String = """
    <PASTE Agent.systemPromptText verbatim from Gemma/Gemma/Agent/Agent.swift>
    """
    static let scheduleConventions: String = """
    <PASTE Agent.scheduleConventions verbatim>
    """
    /// Current date/time line (ported from Agent.nowContext).
    public static func nowContext(_ date: Date = Date()) -> String {
        <PASTE Agent.nowContext body verbatim>
    }
    /// Build the per-turn tail: nowContext + recall injection (memory the retriever surfaced).
    public static func recallTail(query: String, threadId: String, services: Services) -> String {
        let qv = try? services.embedder.embed(query)
        let nodes = (try? services.retriever.retrieve(query: query, k: 6, queryVector: qv)) ?? []
        let block = services.retriever.injectionBlock(for: nodes)   // reuse the server-side injection renderer
        let now = nowContext()
        return block.isEmpty ? now : now + "\n\n" + block
    }
}
```
**The three `<PASTE …>` markers are verbatim ports**: open `Gemma/Gemma/Agent/Agent.swift`, copy `systemPromptText` (the JARVIS string), `scheduleConventions`, and the `nowContext(_:)` body exactly. If `services.retriever` lacks an `injectionBlock(for:)`, the server retriever DOES have one (`MemoryRetriever.injectionBlock(for:)` per the codebase) — use it; if its output differs from the app's, that's acceptable for 1a (same memory surfaced).

### Step 4: Run → PASS, then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryService/Agent/AgentPrompt.swift Tests/MemoryServiceTests/AgentPromptTests.swift
git commit -m "feat(gateway): port JARVIS system prompt + nowContext + recall-injection tail"
```

---

## Task 5: The agent loop

**Files:** Create `Sources/MemoryService/Agent/AgentLoop.swift`; Test: `Tests/MemoryServiceTests/AgentLoopTests.swift` (create).

### Step 0: Re-read the app's `Agent.run` loop structure (max 5; pendingToolCalls; the augmentation note `[You called the tool \`NAME\` with arguments ARGS; it returned: RESULT. Now reply…]`). The server version is NON-streamed: one `complete()` call per iteration returning `{text, toolCalls}`.

### Step 1: Failing test — `Tests/MemoryServiceTests/AgentLoopTests.swift`:
```swift
import XCTest
@testable import MemoryService
@testable import MemoryCore

final class AgentLoopTests: XCTestCase {
    // Canned client: returns scripted results per call (text or tool calls).
    final class CannedClient: AgentModelClient, @unchecked Sendable {
        var scripted: [AgentModelResult]; init(_ s: [AgentModelResult]) { scripted = s }
        func complete(systemPrompt: String, userPrompt: String, tools: [[String: Any]]) async throws -> AgentModelResult {
            scripted.isEmpty ? AgentModelResult(text: "", toolCalls: []) : scripted.removeFirst()
        }
    }
    func test_final_text_returned() async throws {
        let s = try Services.makeForTests()
        let loop = AgentLoop(client: CannedClient([AgentModelResult(text: "hola", toolCalls: [])]))
        let reply = await loop.run(text: "hi", threadId: "T", services: s)
        XCTAssertEqual(reply, "hola")
    }
    func test_tool_call_then_final() async throws {
        let s = try Services.makeForTests()
        let loop = AgentLoop(client: CannedClient([
            AgentModelResult(text: "", toolCalls: [AgentToolCall(name: "current_time", args: "{}")]),
            AgentModelResult(text: "son las 3", toolCalls: []),
        ]))
        let reply = await loop.run(text: "what time", threadId: "T", services: s)
        XCTAssertEqual(reply, "son las 3")   // executed the tool, re-fed, returned the final text
    }
}
```

### Step 2: Run → FAIL.

### Step 3: Create `Sources/MemoryService/Agent/AgentLoop.swift`:
```swift
import Foundation
import MemoryCore

public struct AgentLoop {
    let client: AgentModelClient
    let maxIterations: Int
    public init(client: AgentModelClient, maxIterations: Int = 5) { self.client = client; self.maxIterations = maxIterations }

    /// Run the agentic turn (non-streamed): recall → loop(model + tools) → final reply text.
    public func run(text: String, threadId: String, services: Services) async -> String {
        let system = AgentPrompt.systemPrompt()
        let tail = AgentPrompt.recallTail(query: text, threadId: threadId, services: services)
        var prompt = tail.isEmpty ? text : tail + "\n\n" + text
        let specs = GatewayToolRegistry.specs
        var lastText = ""
        for iteration in 0..<maxIterations {
            let result: AgentModelResult
            do { result = try await client.complete(systemPrompt: system, userPrompt: prompt, tools: specs) }
            catch { return "I can't reach my model right now." }
            lastText = result.text
            if result.toolCalls.isEmpty { return result.text }   // final
            // execute each requested tool, augment the prompt, re-iterate
            for tc in result.toolCalls {
                let out: String
                if let tool = GatewayToolRegistry.tool(named: tc.name) { out = await tool.run(argsJSON: tc.args, services: services) }
                else { out = "error: no tool named \(tc.name)" }
                prompt += "\n\n[You called the tool `\(tc.name)` with arguments \(tc.args); it returned: \(out). Now reply to the user in a short natural sentence using this result.]"
            }
            if iteration == maxIterations - 1 { return lastText.isEmpty ? "(no pude completar la respuesta)" : lastText }
        }
        return lastText
    }
}

/// Registry of the gateway tools (defined in GatewayTools.swift as `gatewayTools`).
public enum GatewayToolRegistry {
    public static let all: [GatewayTool] = gatewayTools
    public static let specs: [[String: Any]] = all.map { type(of: $0).functionSpec }
    public static func tool(named n: String) -> GatewayTool? { all.first { type(of: $0).name == n } }
}
```
(`gatewayTools` is the array from Task 3. If naming clashes, expose it via `GatewayToolRegistry.all` and remove the free `gatewayTools` — keep ONE source of the list.)

### Step 4: Run → PASS, then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryService/Agent/AgentLoop.swift Tests/MemoryServiceTests/AgentLoopTests.swift
git commit -m "feat(gateway): agentic loop (non-streamed) — model + tool execution + re-feed, max 5"
```

---

## Task 6: `POST /v1/agent/turn` handler + post-turn writes

**Files:** Create `Sources/MemoryService/Handlers/AgentHandlers.swift`; Modify `Sources/MemoryService/App.swift` (register + build the `ToolCallingClient`); Test: `Tests/MemoryServiceTests/AgentEndpointTests.swift` (create).

### Step 0: Read `App.swift` — the `Services` construction + the handler registration block (`MemoryHandlers(services:).register(on: v1)` …). Read how `MemoryEndpointsTests` builds the app for a live test. Decide where the gateway's `AgentLoop`/`ToolCallingClient` is built — the handler can build a `ToolCallingClient(configStore: services.modelConfig, defaultBaseURL: <the consolidation default>)` per turn (cheap), or hold one on `Services`. Mirror how `RemoteModelClient` is constructed in `App.swift` for the `defaultBaseURL`.

### Step 1: Failing test — `Tests/MemoryServiceTests/AgentEndpointTests.swift` (inject a canned model so it's deterministic — see the note):
```swift
func test_agent_turn_returns_reply_and_appends_transcript() async throws {
    let (app, services) = try await makeAppWithServices(agentClient: CannedClient([AgentModelResult(text: "hola Roilan", toolCalls: [])]))
    try await app.test(.live) { client in
        try await client.execute(uri: "/v1/agent/turn", method: .post,
            headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
            body: ByteBuffer(string: #"{"text":"hola","threadId":"T"}"#)) { res in
            XCTAssertEqual(res.status, .ok)
            struct Out: Decodable { let reply: String }
            XCTAssertEqual(try JSONDecoder().decode(Out.self, from: Data(buffer: res.body)).reply, "hola Roilan")
        }
    }
    // the turn was persisted (user + assistant)
    let rows = try services.transcript.range(threadId: "T", from: 1, to: 99)
    XCTAssertEqual(rows.map { $0.role }, ["user", "assistant"])
}
func test_agent_turn_empty_text_is_400() async throws {
    let (app, _) = try await makeAppWithServices(agentClient: CannedClient([]))
    try await app.test(.live) { client in
        try await client.execute(uri: "/v1/agent/turn", method: .post,
            headers: [.authorization: "Bearer test-token", .contentType: "application/json"],
            body: ByteBuffer(string: #"{"text":""}"#)) { res in XCTAssertEqual(res.status, .badRequest) }
    }
}
```
**Injecting a canned model:** the handler must use an `AgentModelClient` it can get from `Services` (add `services.agentClient: AgentModelClient` — defaulting to the real `ToolCallingClient`, overridable in tests). Extend `makeAppWithServices` (the test helper) to accept an `agentClient` override. Match the file's existing helper; if it doesn't support overrides, add the parameter with a default that builds the real client.

### Step 2: Run → FAIL (route 404).

### Step 3a: Add `services.agentClient` to `Services` (an `AgentModelClient`, default = the real `ToolCallingClient` built from `modelConfig` + the consolidation default base URL). Construct it in `App.swift` where `Services` is built.

### Step 3b: Create `Sources/MemoryService/Handlers/AgentHandlers.swift`:
```swift
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import MemoryCore

struct AgentHandlers {
    let services: Services
    func register(on group: RouterGroup<BasicRequestContext>) {
        group.post("/agent/turn", use: turn)
    }
    struct TurnBody: Decodable, Sendable { let text: String; let threadId: String? }
    @Sendable func turn(_ req: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let buf: ByteBuffer
        do { buf = try await req.body.collect(upTo: 32_000) } catch { return jsonError(.badRequest, "bad_request", "body unreadable") }
        guard let body = try? JSONDecoder().decode(TurnBody.self, from: Data(buf.readableBytesView)),
              !body.text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return jsonError(.badRequest, "bad_request", "text required")
        }
        let threadId = body.threadId ?? "gateway"
        let loop = AgentLoop(client: services.agentClient)
        let reply = await loop.run(text: body.text, threadId: threadId, services: services)
        // persist the turn (seq auto-assigned) + arm consolidation
        _ = try? services.transcript.append(threadId: threadId, turnIndex: 0, role: "user", text: body.text)
        if !reply.isEmpty { _ = try? services.transcript.append(threadId: threadId, turnIndex: 0, role: "assistant", text: reply) }
        services.scheduler.armAfterTurn(threadId: threadId)   // match the real scheduler-arming method name
        struct Out: Encodable { let reply: String }
        let data = try JSONEncoder().encode(Out(reply: reply))
        return Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}
```
(ADAPT the scheduler-arming call to the real method the existing `consolidationTurnEnd` handler uses — read `ConsolidationHandlers` / `ConsolidationScheduler` for the exact "arm after a turn" entry point and call the same one. If embedding the transcript turns is done elsewhere on append, no change needed.)

### Step 3c: Register in `App.swift`: `AgentHandlers(services: services).register(on: v1)`.

### Step 4: Run → PASS, then full `swift test`.

### Step 5: Commit
```bash
git add Sources/MemoryService/Handlers/AgentHandlers.swift Sources/MemoryService/App.swift Tests/MemoryServiceTests/AgentEndpointTests.swift
git commit -m "feat(gateway): POST /v1/agent/turn — agentic turn endpoint + transcript + consolidation arming"
```

---

## Task 7: Deploy server + manual E2E

- [ ] **Deploy:** `ssh HomeLab 'cd ~/Projects/gemma-memory && git pull --ff-only origin main && docker compose build memory && docker compose up -d memory'`. `healthz` 200. Ensure the i3's model config (`/v1/config/model`) points at a chat-quality model reachable from the i3 (the Mac mlx at `192.168.1.x:8080` with bind 0.0.0.0, or a cloud provider with its key).
- [ ] **E2E (curl on the i3 with the bearer token):**
  - `{"text":"¿qué hora es?","threadId":"e2e"}` → reply states the time (the agent called `current_time`).
  - `{"text":"me llamo Roilan, recuérdalo","threadId":"e2e"}` → then `{"text":"¿cómo me llamo?","threadId":"e2e2"}` → recalls "Roilan" (save + cross-chat recall through the gateway).
  - `{"text":"agéndame el dentista mañana a las 3pm","threadId":"e2e"}` → creates the event (conflict-checked) and confirms.
- [ ] **Record** the result. This proves the full agentic brain runs as a service any device can call.

---

## Self-Review

**Spec coverage:** §4.1 endpoint+loop+client+prompt+post-writes → Tasks 1,4,5,6. §4.2 server tools + DRY extraction → Tasks 2,3 (incl. `reflect` omitted). §4.3 contract (400/empty, threadId default), model config (reuses existing — documented refinement), errors (model-unreachable reply, tool-error string, 400) → Tasks 1,5,6. §5 testing → unit Tasks 1–6 + E2E Task 7. §6 order → Tasks 1–7. ✓

**Placeholder scan:** The three `<PASTE … verbatim>` markers in Task 4 are precise port instructions (copy a specific named artifact from `Agent.swift`) — not vague TODOs; the engineer opens the named file and copies. The Task-3 "implement the remaining 9 like the example, copying each app tool's name/description/parameters and mapping run to the spec table" is a precise, bounded instruction with the per-tool mapping given in the spec table + Step 0 telling them which app files to copy from. The Step-0 "match the real X" notes (scheduler-arm method, `Services.makeForTests`, `injectionBlock`) point at concrete existing code.

**Type consistency:** `AgentModelClient.complete(systemPrompt:userPrompt:tools:) -> AgentModelResult{text, toolCalls:[AgentToolCall{name,args}]}` (Task 1) consumed by `AgentLoop` (Task 5) + faked in Tasks 5/6. `GatewayTool{name,description,parameters,run(argsJSON:,services:)}` + `functionSpec` (Task 3) used by `GatewayToolRegistry.specs`/`.tool(named:)` (Task 5). `MemoryQueries.nodesForTopic`/`why` (Task 2) used by the tools (Task 3). `AgentPrompt.systemPrompt()`/`recallTail()` (Task 4) used by `AgentLoop` (Task 5). `services.agentClient` (Task 6) is the `AgentModelClient` from Task 1. `POST /v1/agent/turn {text,threadId} → {reply}` consistent across Task 6 + the E2E.
