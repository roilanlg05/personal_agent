# S4 Agent Core + Tool-Calling Implementation Plan (first slice)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An agent core that runs a turn with LiteRT-LM native tool-calling, exposes an extensible tool registry, streams activity (tokens + "calling X / done"), and is validated by a toy `CurrentTimeTool` proving the Gemma 4 E4B reliably calls tools.

**Architecture:** Use LiteRT-LM's native tools (`Tool`/`@ToolParam`/`ConversationConfig(tools:)` + the `Conversation` tool-call loop). A `ToolCallingRuntime` protocol (separate from the base `ModelRuntime` to contain the LiteRT coupling) adds a `generate(prompt:tools:options:)` streaming tool events; `LiteRTLMRuntime` conforms. Tools can't receive injected context (`ToolManager` instantiates them via `init()`), so activity is emitted through a shared `@MainActor ToolActivityRelay` the runtime wires to its stream per generation (safe: the engine allows one session at a time). A thin `Agent` orchestrates a turn and relays an `AgentEvent` stream to the harness.

**Tech Stack:** Swift, Xcode 26.2, LiteRT-LM (vendored, `Tool`/`ToolManager`/`Conversation`), XCTest. Scheme `Gemma`, tests `GemmaTests`. Spec: `docs/superpowers/specs/2026-05-29-s4-agent-core-design.md`.

**Test execution notes:**
- Mac simulator (`iPhone 17`): all pure/unit tests. `xcodebuild test -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GemmaTests/<Class> -quiet`. (No `-skipMacroValidation` needed — MLX is gone; only LiteRTLM remains.)
- Device-only: real tool-calling needs the model on the iPhone 16 (id `00008140-000A6216110A801C`, `-allowProvisioningUpdates`); those tests `XCTSkip` without an installed model.
- LiteRT-LM tool API (confirmed in `vendor/LiteRT-LM/swift/`): `protocol Tool: Decodable { static var name: String; static var description: String; init(); func run() async throws -> Any }`; `@ToolParam(description:)` for params; `ConversationConfig(systemMessage:initialMessages:tools:samplerConfig:)`; `conv.sendMessageStream(_:)` runs the tool loop internally (up to 25 calls), executing each tool's `run()`.

---

## File Structure

- `Gemma/Gemma/Runtime/ModelRuntime.swift` — add `GenerationEvent.toolCallStarted/.toolCallFinished`.
- `Gemma/Gemma/Runtime/ToolCallingRuntime.swift` (new) — `ToolCallingRuntime` protocol + `ToolActivityRelay`.
- `Gemma/Gemma/Runtime/LiteRTLMRuntime.swift` — conform `ToolCallingRuntime` (tool-aware generate via `Conversation(tools:)` + relay wiring).
- `Gemma/Gemma/Agent/CurrentTimeTool.swift` (new) — toy `Tool` emitting activity.
- `Gemma/Gemma/Agent/ToolRegistry.swift` (new) — extensible registry → `[Tool]`.
- `Gemma/Gemma/Agent/Agent.swift` (new) — turn orchestrator + `AgentEvent` stream.
- `Gemma/Gemma/Harness/AgentView.swift` (new) + a button in the harness to present it.
- `Gemma/GemmaTests/` — `ToolRegistryTests`, `CurrentTimeToolTests`, `AgentTests`, `AgentRuntimeTests` (device-gated).

---

## Task 1: GenerationEvent tool cases + ToolCallingRuntime protocol + ToolActivityRelay

**Files:**
- Modify: `Gemma/Gemma/Runtime/ModelRuntime.swift` (GenerationEvent)
- Create: `Gemma/Gemma/Runtime/ToolCallingRuntime.swift`
- Test: `Gemma/GemmaTests/ToolCallingRuntimeTests.swift`

- [ ] **Step 1: Add the two tool events to GenerationEvent**

In `ModelRuntime.swift`, extend the enum:
```swift
public enum GenerationEvent: Sendable {
    case token(String)
    /// A tool the model decided to call is about to run. `args` is a JSON string (may be "{}").
    case toolCallStarted(name: String, args: String)
    /// A tool finished; `result` is its stringified return (or an "error: …" message).
    case toolCallFinished(name: String, result: String)
    case completed(GenerationResult)
}
```

- [ ] **Step 2: Write the failing test**

Create `Gemma/GemmaTests/ToolCallingRuntimeTests.swift`:
```swift
import XCTest
@testable import Gemma

@MainActor
final class ToolCallingRuntimeTests: XCTestCase {
    func test_activityRelay_forwardsToSink() {
        var seen: [String] = []
        let relay = ToolActivityRelay()
        relay.sink = { event in
            switch event {
            case .started(let name, _): seen.append("start:\(name)")
            case .finished(let name, _): seen.append("done:\(name)")
            }
        }
        relay.started(name: "Clock", args: "{}")
        relay.finished(name: "Clock", result: "12:00")
        XCTAssertEqual(seen, ["start:Clock", "done:Clock"])
    }
    func test_activityRelay_noSink_doesNotCrash() {
        let relay = ToolActivityRelay()
        relay.started(name: "X", args: "{}")   // sink nil → no-op
        relay.finished(name: "X", result: "")
    }
}
```

- [ ] **Step 3: Run, verify FAIL**

Run: `xcodebuild test -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GemmaTests/ToolCallingRuntimeTests -quiet`
Expected: FAIL (no `ToolActivityRelay`).

- [ ] **Step 4: Create `Gemma/Gemma/Runtime/ToolCallingRuntime.swift`**

```swift
import Foundation
import LiteRTLM

/// Activity emitted by a tool's `run()` while the Conversation tool-loop executes it.
public enum ToolActivity: Sendable {
    case started(name: String, args: String)
    case finished(name: String, result: String)
}

/// Tools (instantiated by LiteRT-LM's ToolManager via `init()`) can't receive injected
/// context, so they emit activity through this shared @MainActor relay. The runtime sets
/// `sink` for the duration of one generation. Safe because LiteRTLMRuntime is @MainActor
/// and the engine runs one session at a time.
@MainActor
public final class ToolActivityRelay {
    public static let shared = ToolActivityRelay()
    public var sink: ((ToolActivity) -> Void)?
    public init() {}
    public func started(name: String, args: String) { sink?(.started(name: name, args: args)) }
    public func finished(name: String, result: String) { sink?(.finished(name: name, result: result)) }
}

/// A runtime that can run a generation with LiteRT-LM tools and stream tool-call events.
/// Separate from `ModelRuntime` so the LiteRT `Tool` coupling stays out of the base protocol.
public protocol ToolCallingRuntime: AnyObject {
    func generate(
        prompt: String,
        tools: [Tool],
        options: GenerationOptions
    ) async -> AsyncThrowingStream<GenerationEvent, Error>
}
```

- [ ] **Step 5: Run tests, verify PASS (2)**

Run: `xcodebuild test -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GemmaTests/ToolCallingRuntimeTests -quiet`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Gemma/Gemma/Runtime/ModelRuntime.swift Gemma/Gemma/Runtime/ToolCallingRuntime.swift Gemma/GemmaTests/ToolCallingRuntimeTests.swift
git commit -m "feat(agent): GenerationEvent tool cases + ToolCallingRuntime protocol + ToolActivityRelay"
```
Append trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## Task 2: CurrentTimeTool

**Files:**
- Create: `Gemma/Gemma/Agent/CurrentTimeTool.swift`
- Test: `Gemma/GemmaTests/CurrentTimeToolTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Gemma/GemmaTests/CurrentTimeToolTests.swift`:
```swift
import XCTest
@testable import Gemma

final class CurrentTimeToolTests: XCTestCase {
    func test_metadata() {
        XCTAssertEqual(CurrentTimeTool.name, "get_current_time")
        XCTAssertFalse(CurrentTimeTool.description.isEmpty)
    }
    func test_run_returnsNonEmptyTimeString() async throws {
        let result = try await CurrentTimeTool().run()
        let s = result as? String
        XCTAssertNotNil(s)
        XCTAssertFalse(s!.isEmpty)
    }
}
```

- [ ] **Step 2: Run, verify FAIL**

Run: `xcodebuild test -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GemmaTests/CurrentTimeToolTests -quiet`
Expected: FAIL (no `CurrentTimeTool`).

- [ ] **Step 3: Create `Gemma/Gemma/Agent/CurrentTimeTool.swift`**

```swift
import Foundation
import LiteRTLM

/// Toy tool whose only purpose is to validate that the E4B reliably calls tools.
/// Emits activity through the shared relay (it can't receive injected context — ToolManager
/// builds the instance via init()).
struct CurrentTimeTool: Tool {
    static let name = "get_current_time"
    static let description = "Returns the user's current local date and time. Call this whenever the user asks what time or date it is."

    init() {}

    func run() async throws -> Any {
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        let text = fmt.string(from: now)
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "{}") }
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: text) }
        return text
    }
}
```

- [ ] **Step 4: Run tests, verify PASS (2)**

Run: `xcodebuild test -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GemmaTests/CurrentTimeToolTests -quiet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Agent/CurrentTimeTool.swift Gemma/GemmaTests/CurrentTimeToolTests.swift
git commit -m "feat(agent): CurrentTimeTool (toy tool) emitting activity via the relay"
```
Append trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## Task 3: ToolRegistry

**Files:**
- Create: `Gemma/Gemma/Agent/ToolRegistry.swift`
- Test: `Gemma/GemmaTests/ToolRegistryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Gemma/GemmaTests/ToolRegistryTests.swift`:
```swift
import XCTest
@testable import Gemma
import LiteRTLM

final class ToolRegistryTests: XCTestCase {
    func test_empty_byDefault() {
        XCTAssertTrue(ToolRegistry().tools.isEmpty)
    }
    func test_register_addsTool() {
        let r = ToolRegistry()
        r.register(CurrentTimeTool())
        XCTAssertEqual(r.tools.count, 1)
        XCTAssertEqual(type(of: r.tools[0]).name, "get_current_time")
    }
    func test_registerDefaults_includesCurrentTime() {
        let r = ToolRegistry.withDefaults()
        XCTAssertTrue(r.tools.contains { type(of: $0).name == "get_current_time" })
    }
}
```

- [ ] **Step 2: Run, verify FAIL**

Run: `xcodebuild test -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GemmaTests/ToolRegistryTests -quiet`
Expected: FAIL (no `ToolRegistry`).

- [ ] **Step 3: Create `Gemma/Gemma/Agent/ToolRegistry.swift`**

```swift
import Foundation
import LiteRTLM

/// Extensible registry of LiteRT-LM tools (CC2: "we'll keep adding capabilities").
/// S6 registers the real iOS tools here. The held instances are used for schema generation;
/// LiteRT-LM's ToolManager instantiates fresh copies per call.
@MainActor
final class ToolRegistry {
    private(set) var tools: [Tool] = []

    init() {}

    func register(_ tool: Tool) { tools.append(tool) }

    /// The default tool set for the first slice.
    static func withDefaults() -> ToolRegistry {
        let r = ToolRegistry()
        r.register(CurrentTimeTool())
        return r
    }
}
```

- [ ] **Step 4: Run tests, verify PASS (3)**

Run: `xcodebuild test -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GemmaTests/ToolRegistryTests -quiet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Agent/ToolRegistry.swift Gemma/GemmaTests/ToolRegistryTests.swift
git commit -m "feat(agent): extensible ToolRegistry"
```
Append trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## Task 4: LiteRTLMRuntime tool-aware generate

**Files:**
- Modify: `Gemma/Gemma/Runtime/LiteRTLMRuntime.swift`

- [ ] **Step 1: Add a tool-aware conversation builder + ToolCallingRuntime conformance**

Read `LiteRTLMRuntime.swift` first. It has `makeConversation(engine:options:)` building `ConversationConfig(systemMessage:samplerConfig:)`, and `streamGeneration` driving `conv.sendMessageStream`. Add a `ToolCallingRuntime` conformance via an extension that mirrors the existing streaming pattern but (a) builds the conversation WITH tools and (b) wires the relay. Add to the file:

```swift
extension LiteRTLMRuntime: ToolCallingRuntime {
    public func generate(
        prompt: String,
        tools: [Tool],
        options: GenerationOptions
    ) async -> AsyncThrowingStream<GenerationEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task { await self.streamWithTools(prompt: prompt, tools: tools, options: options, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamWithTools(
        prompt: String,
        tools: [Tool],
        options: GenerationOptions,
        into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async {
        guard loaded, let engine else {
            continuation.finish(throwing: RuntimeError.notLoaded)
            return
        }
        // Wire tool activity → stream events for this generation (single session at a time).
        ToolActivityRelay.shared.sink = { activity in
            switch activity {
            case .started(let name, let args): continuation.yield(.toolCallStarted(name: name, args: args))
            case .finished(let name, let result): continuation.yield(.toolCallFinished(name: name, result: result))
            }
        }
        defer { ToolActivityRelay.shared.sink = nil }

        let sampler = try? SamplerConfig(topK: max(1, options.topK), topP: Float(options.topP), temperature: Float(options.temperature))
        let trimmed = options.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemMessage = (trimmed?.isEmpty == false) ? Message(trimmed!, role: .system) : nil
        let convCfg = ConversationConfig(systemMessage: systemMessage, tools: tools, samplerConfig: sampler)

        let conv: Conversation
        do { conv = try await engine.createConversation(with: convCfg) }
        catch { continuation.finish(throwing: RuntimeError.generationFailed("conversation init: \(error)")); return }

        let start = Date()
        var firstTokenAt: Date?
        var accumulated = ""
        var tokenCount = 0
        do {
            for try await chunk in conv.sendMessageStream(Message(prompt)) {
                if Task.isCancelled { try? conv.cancel(); continuation.finish(throwing: CancellationError()); return }
                let piece = chunk.toString
                if piece.isEmpty { continue }
                if firstTokenAt == nil { firstTokenAt = Date() }
                accumulated += piece
                tokenCount += 1
                continuation.yield(.token(piece))
            }
        } catch {
            continuation.finish(throwing: RuntimeError.generationFailed("\(error)")); return
        }
        let elapsed = Date().timeIntervalSince(start)
        let ttft = firstTokenAt?.timeIntervalSince(start) ?? 0
        let metrics = RuntimeMetrics(
            tokensGenerated: tokenCount, elapsedSeconds: elapsed, timeToFirstTokenSeconds: ttft,
            peakResidentMemoryBytes: MemoryReporter.currentResidentBytes(), draftAcceptanceRate: nil)
        continuation.yield(.completed(GenerationResult(text: accumulated, metrics: metrics)))
        continuation.finish()
    }
}
```
Adjust to the file's exact `RuntimeMetrics`/`SamplerConfig`/`Message` usages (match `makeConversation`/`streamGeneration`). Confirm `ConversationConfig(systemMessage:tools:samplerConfig:)` accepts these labels (per `vendor/LiteRT-LM/swift/Config.swift`).

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Gemma/Gemma/Runtime/LiteRTLMRuntime.swift
git commit -m "feat(agent): LiteRTLMRuntime conforms ToolCallingRuntime (Conversation tools + activity relay)"
```
Append trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## Task 5: Agent orchestrator + AgentEvent

**Files:**
- Create: `Gemma/Gemma/Agent/Agent.swift`
- Test: `Gemma/GemmaTests/AgentTests.swift`

- [ ] **Step 1: Write the failing test (Agent relays a stub runtime's events)**

Create `Gemma/GemmaTests/AgentTests.swift`:
```swift
import XCTest
@testable import Gemma
import LiteRTLM

@MainActor
final class AgentTests: XCTestCase {
    /// Stub tool-calling runtime that emits a fixed event sequence.
    final class StubRuntime: ToolCallingRuntime {
        func generate(prompt: String, tools: [Tool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            AsyncThrowingStream { c in
                c.yield(.token("It is "))
                c.yield(.toolCallStarted(name: "get_current_time", args: "{}"))
                c.yield(.toolCallFinished(name: "get_current_time", result: "12:00"))
                c.yield(.token("12:00."))
                c.yield(.completed(GenerationResult(text: "It is 12:00.", metrics: RuntimeMetrics(tokensGenerated: 2, elapsedSeconds: 0.1, timeToFirstTokenSeconds: 0.05, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }

    func test_run_relaysEventsAsAgentEvents() async throws {
        let agent = Agent(runtime: StubRuntime(), registry: ToolRegistry.withDefaults())
        var kinds: [String] = []
        var finalText: String?
        for try await event in await agent.run(prompt: "what time is it?", options: GenerationOptions(maxTokens: 64)) {
            switch event {
            case .token: kinds.append("token")
            case .toolCallStarted(let n, _): kinds.append("start:\(n)")
            case .toolCallFinished(let n, _): kinds.append("done:\(n)")
            case .completed(let r): finalText = r.text; kinds.append("completed")
            case .failed(let m): XCTFail("unexpected failure: \(m)")
            }
        }
        XCTAssertEqual(kinds, ["token", "start:get_current_time", "done:get_current_time", "token", "completed"])
        XCTAssertEqual(finalText, "It is 12:00.")
    }
}
```

- [ ] **Step 2: Run, verify FAIL**

Run: `xcodebuild test -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GemmaTests/AgentTests -quiet`
Expected: FAIL (no `Agent`/`AgentEvent`).

- [ ] **Step 3: Create `Gemma/Gemma/Agent/Agent.swift`**

```swift
import Foundation
import LiteRTLM

public enum AgentEvent: Sendable {
    case token(String)
    case toolCallStarted(name: String, args: String)
    case toolCallFinished(name: String, result: String)
    case completed(GenerationResult)
    case failed(String)
}

/// Orchestrates one agent turn over a tool-calling runtime. Thin for now: it owns the tool
/// registry + system prompt and relays the runtime's event stream. Future home of
/// scratchpad (#20), memory injection (#18), and latency tricks (#23).
@MainActor
final class Agent {
    private let runtime: ToolCallingRuntime
    private let registry: ToolRegistry

    init(runtime: ToolCallingRuntime, registry: ToolRegistry) {
        self.runtime = runtime
        self.registry = registry
    }

    /// System prompt that tells the small model it may call the registered tools.
    private var systemPrompt: String {
        "You are Gemma, a helpful on-device assistant. You can call tools to get real information. When a tool is relevant (e.g. the user asks the time), call it instead of guessing."
    }

    func run(prompt: String, options: GenerationOptions) -> AsyncThrowingStream<AgentEvent, Error> {
        let tools = registry.tools
        var opts = options
        opts.systemPrompt = systemPrompt
        return AsyncThrowingStream { continuation in
            let task = Task {
                let stream = await runtime.generate(prompt: prompt, tools: tools, options: opts)
                do {
                    for try await event in stream {
                        switch event {
                        case .token(let t): continuation.yield(.token(t))
                        case .toolCallStarted(let n, let a): continuation.yield(.toolCallStarted(name: n, args: a))
                        case .toolCallFinished(let n, let r): continuation.yield(.toolCallFinished(name: n, result: r))
                        case .completed(let res): continuation.yield(.completed(res))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.failed("\(error)"))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 4: Run tests, verify PASS**

Run: `xcodebuild test -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GemmaTests/AgentTests -quiet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Agent/Agent.swift Gemma/GemmaTests/AgentTests.swift
git commit -m "feat(agent): Agent turn orchestrator + AgentEvent stream"
```
Append trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## Task 6: Harness AgentView (activity UI)

**Files:**
- Create: `Gemma/Gemma/Harness/AgentView.swift`
- Modify: `Gemma/Gemma/Harness/HarnessView.swift` (a button to present it), `Gemma/Gemma/Harness/HarnessModel.swift` (presentation flag + an `Agent` driver)

- [ ] **Step 1: Add an Agent driver + presentation flag to HarnessModel**

In `HarnessModel`, add observable state and a runner (read the file to match its `@Observable`/`runtime` access; the litert runtime instance is the one already loaded):
```swift
    public var showAgent = false
    public var agentLog: [String] = []   // human-readable activity + answer lines
    public var agentRunning = false

    public func runAgentTurn(_ prompt: String) async {
        guard let lr = runtime as? ToolCallingRuntime else {
            agentLog.append("[agent needs the LiteRT-LM runtime loaded]"); return
        }
        agentRunning = true; defer { agentRunning = false }
        agentLog.append("you: \(prompt)")
        let agent = Agent(runtime: lr, registry: ToolRegistry.withDefaults())
        var answer = ""
        do {
            for try await event in agent.run(prompt: prompt, options: makeGenerationOptions()) {
                switch event {
                case .token(let t): answer += t
                case .toolCallStarted(let n, _): agentLog.append("🔧 \(n)…")
                case .toolCallFinished(let n, let r): agentLog.append("🔧 \(n) ✓ \(r)")
                case .completed: agentLog.append("gemma: \(answer)")
                case .failed(let m): agentLog.append("[error: \(m)]")
                }
            }
        } catch { agentLog.append("[error: \(error)]") }
    }
```
(`makeGenerationOptions()` already exists in HarnessModel; reuse it.)

- [ ] **Step 2: Create `Gemma/Gemma/Harness/AgentView.swift`**

```swift
import SwiftUI

struct AgentView: View {
    @Bindable var model: HarnessModel
    @State private var prompt = "What time is it?"

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.agentLog.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding()
                }
                HStack {
                    TextField("Ask the agent…", text: $prompt)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") { let p = prompt; Task { await model.runAgentTurn(p) } }
                        .disabled(model.agentRunning || prompt.isEmpty)
                }.padding(.horizontal)
            }
            .navigationTitle("Agent")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { model.showAgent = false } } }
        }
    }
}
```

- [ ] **Step 3: Present it from HarnessView**

In `HarnessView.swift`, add a button (near the existing "Models"/"Benchmark" buttons) `Button("Agent") { model.showAgent = true }` and a sheet alongside the others: `.sheet(isPresented: $model.showAgent) { AgentView(model: model) }`.

- [ ] **Step 4: Build to verify**

Run: `xcodebuild build -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Harness/AgentView.swift Gemma/Gemma/Harness/HarnessView.swift Gemma/Gemma/Harness/HarnessModel.swift
git commit -m "feat(agent): harness AgentView showing tool-call activity + answer"
```
Append trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## Task 7: Device-gated E2E test + on-device verification + record

**Files:**
- Test: `Gemma/GemmaTests/AgentRuntimeTests.swift` (new)
- Docs: `docs/superpowers/specs/01-s1-runtime-report.md`

- [ ] **Step 1: Add the device-gated E2E test**

Create `Gemma/GemmaTests/AgentRuntimeTests.swift`:
```swift
import XCTest
@testable import Gemma

@MainActor
final class AgentRuntimeTests: XCTestCase {
    private func installedModelURL() throws -> URL {
        let store = InstalledModels.defaultInDocuments()
        for id in ["gemma-4-e2b-it", "gemma-4-e4b-it"] {
            if let d = ModelCatalog.find(id), case .installed(let url) = store.status(of: d) { return url }
        }
        throw XCTSkip("No Gemma 4 .litertlm installed — sideload to run the agent E2E test.")
    }

    func test_agent_callsCurrentTimeTool() async throws {
        let url = try installedModelURL()
        let runtime = LiteRTLMRuntime()
        try await runtime.load(options: ModelLoadOptions(modelPath: url))
        let agent = Agent(runtime: runtime, registry: ToolRegistry.withDefaults())
        var calledTool = false
        var text = ""
        for try await event in agent.run(prompt: "What time is it right now?", options: GenerationOptions(maxTokens: 128)) {
            switch event {
            case .toolCallStarted(let n, _) where n == "get_current_time": calledTool = true
            case .token(let t): text += t
            case .completed(let r): text = r.text
            default: break
            }
        }
        await runtime.unload()
        XCTAssertTrue(calledTool, "E4B should have called get_current_time")
        XCTAssertFalse(text.isEmpty)
    }
}
```

- [ ] **Step 2: Build the test target (compiles; self-skips without a model)**

Run: `xcodebuild build-for-testing -scheme Gemma -destination 'platform=iOS Simulator,name=iPhone 17' -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Verify on device (manual)**

Build/run on the iPhone 16. Open **Agent**, ensure the Gemma 4 model is loaded, ask "What time is it?". Confirm the activity log shows `🔧 get_current_time…` then `✓`, and the answer includes the actual time. Try 3–4 phrasings to gauge how reliably the E4B calls the tool (the core S4 risk). Note the hit rate.

- [ ] **Step 4: Record + graph**

Append an "§8 Agent / tool-calling" subsection to `docs/superpowers/specs/01-s1-runtime-report.md`: whether the E4B reliably calls `get_current_time`, observed hit rate across phrasings, and any system-prompt tweaks that helped. Then `graphify update .`.
```bash
git add docs/superpowers/specs/01-s1-runtime-report.md Gemma/GemmaTests/AgentRuntimeTests.swift
git commit -m "test(agent): device-gated E2E tool-call test + on-device reliability record"
```
Append trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## Follow-ups (out of scope)

- **Real iOS tools (S6):** calendar, reminders, maps, weather, web search, etc. — each a `Tool` registered in `ToolRegistry`.
- **Scratchpad (#20), latency/instant phrases (#23/#3 → S12), memory injection (#18 → S5)** — built on the `Agent` seam.
- If function-calling proves unreliable on E4B, iterate the tool system prompt (few-shot examples) before S6.

---

## Self-Review

- **Spec §2 architecture:** ToolCallingRuntime + relay (T1), CurrentTimeTool (T2), ToolRegistry (T3), LiteRTLMRuntime tool-aware (T4), Agent+AgentEvent (T5), harness AgentView (T6). ✓
- **Spec §3 data flow / events:** GenerationEvent tool cases (T1) → LiteRT Conversation(tools) + relay (T4) → Agent relays AgentEvent (T5) → UI (T6). ✓
- **Spec §3 errors:** generationFailed → AgentEvent.failed (T5); tool error surfaces as finished(result) + fed back by LiteRT (T4). ✓
- **Spec §4 tests:** relay (T1), tool (T2), registry (T3), Agent-with-stub (T5), device E2E (T7). ✓
- **Spec §6 deliverables 1-6:** 1→T1/T4, 2→T3, 3→T2, 4→T5, 5→T6, 6→T7. ✓
- **Type consistency:** `GenerationEvent.toolCallStarted(name:args:)/.toolCallFinished(name:result:)`, `ToolActivity.started/finished`, `ToolActivityRelay.shared.sink`, `ToolCallingRuntime.generate(prompt:tools:options:)`, `ToolRegistry.tools/register/withDefaults`, `CurrentTimeTool.name=="get_current_time"`, `Agent.run(prompt:options:)→AgentEvent`, `AgentEvent.{token,toolCallStarted,toolCallFinished,completed,failed}` — consistent across T1–T7. ✓
- **Placeholders:** none; LiteRT `Tool`/`ConversationConfig(tools:)` confirmed in the vendored sources; runtime tool-loop behavior validated on device in T7.
- **Coupling note:** LiteRT `Tool` appears in `ToolCallingRuntime`/`ToolRegistry`/`CurrentTimeTool` only (the accepted native-tools coupling); base `ModelRuntime`/`DummyRuntime` untouched.
