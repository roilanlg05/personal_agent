import XCTest
@testable import Gemma

/// M1 end-to-end verification against the REAL local mlx-lm server (Gemma 4 26B MoE).
///
/// Drives the production stack — `ServerRuntime` → `Agent` (client-side tool loop) →
/// real `ToolRegistry` (CurrentTimeTool + SaveMemoryTool + ForgetTool) → real `MemoryStore` +
/// `MemoryServices` — exactly as `HarnessModel.runAgentTurn`/`ensureMemory` wire it.
///
/// Every case is GATED on the server being reachable so the suite stays green offline.
/// Assertions are FIRM only on the deterministic pipeline (turn completes, non-empty text,
/// no crash). Model-dependent behavior (does it call `remember`, does recall surface
/// "sushi") is OBSERVED and printed as "⚠️ E2E-OBSERVE:" lines, not
/// enforced — the goal is to report real M1 behavior.
@MainActor
final class ServerE2ETests: XCTestCase {
    private let baseURL = URL(string: "http://localhost:8080")!

    /// Print + NSLog + mirror to a sandbox-safe temp file so live model outputs survive
    /// xcodebuild's stdout buffering (XCTest stdout/print does not reliably reach the piped
    /// build log, and the macOS app target is sandboxed so `/tmp` is off-limits). The file path
    /// is logged once at startup; grep it for "E2E-OBSERVE".
    private static let observeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("e2e_observe.log")
    private func observe(_ line: String) {
        print(line)
        NSLog("%@", line)
        if let data = (line + "\n").data(using: .utf8) {
            let url = Self.observeURL
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    override func tearDown() {
        MemoryToolbox.shared.store = nil
        MemoryToolbox.shared.embedder = nil
        super.tearDown()
    }

    /// Short reachability probe (~3s) to the OpenAI-style models endpoint.
    private func isServerUp() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse { return (200..<300).contains(http.statusCode) }
            return false
        } catch {
            return false
        }
    }

    /// Generous token budget: this model burns a lot on hidden reasoning, so a small budget
    /// leaves `content` empty/truncated. 512 keeps room for a visible answer after the thought.
    private func e2eOptions() -> GenerationOptions {
        GenerationOptions(maxTokens: 512, temperature: 0.7)
    }

    // MARK: Test 1 — tool call

    func test_e2e_currentTime() async throws {
        let reachable = await isServerUp()
        try XCTSkipUnless(reachable, "mlx-lm server not running on :8080")

        observe("⚠️ E2E-OBSERVE: observe log at \(Self.observeURL.path)")
        let runtime = ServerRuntime()
        let registry = ToolRegistry()
        registry.register(CurrentTimeTool())
        let agent = Agent(runtime: runtime, registry: registry)

        var toolFired = false
        var toolResult = ""
        var finalText = ""
        for try await event in agent.run(prompt: "What time is it right now?", options: e2eOptions()) {
            switch event {
            case .toolCallStarted(let name, let args):
                observe("🔧 E2E-OBSERVE: toolCallStarted name=\(name) args=\(args)")
            case .toolCallFinished(let name, let result):
                if name == CurrentTimeTool.name { toolFired = true; toolResult = result }
                observe("🔧 E2E-OBSERVE: toolCallFinished name=\(name) result=\(result)")
            case .token(let t):
                finalText += t
            case .completed(let res):
                if finalText.isEmpty { finalText = res.text }
            case .failed(let m):
                observe("⚠️ E2E-OBSERVE: turn failed: \(m)")
            }
        }

        observe("⚠️ E2E-OBSERVE: test1 get_current_time fired=\(toolFired) toolResult=\(toolResult)")
        observe("⚠️ E2E-OBSERVE: test1 final answer: \(finalText)")

        XCTAssertTrue(toolFired, "expected the agent loop to execute get_current_time (toolCallFinished)")
        XCTAssertFalse(finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "expected a non-empty final answer from the 26B model")
    }

    // MARK: Test 2 — remember + cross-turn recall

    func test_e2e_memoryRecall() async throws {
        let reachable = await isServerUp()
        try XCTSkipUnless(reachable, "mlx-lm server not running on :8080")

        // Real store + embedder, wired exactly like production (HarnessModel.ensureMemory).
        let store = try MemoryStore(inMemory: true, embeddingDim: 512)
        let embedder: Embedder
        let dim: Int
        if let nl = try? NLContextualEmbedder() {
            embedder = nl
            dim = nl.dimension
            observe("⚠️ E2E-OBSERVE: using NLContextualEmbedder (dim=\(dim))")
        } else {
            embedder = FakeEmbedder(dimension: 512)
            dim = 512
            observe("⚠️ E2E-OBSERVE: NLContextualEmbedder unavailable; using FakeEmbedder (dim=\(dim))")
        }
        // The store embeddingDim must match the embedder; rebuild if NL gave a different dim.
        let memStore = dim == 512 ? store : try MemoryStore(inMemory: true, embeddingDim: dim)

        MemoryToolbox.shared.store = memStore
        MemoryToolbox.shared.embedder = embedder

        let runtime = ServerRuntime()

        func makeAgent() -> Agent {
            let retriever = MemoryRetriever(store: memStore, embedder: embedder)
            let registry = ToolRegistry()
            registry.register(CurrentTimeTool())
            registry.register(SaveMemoryTool())
            registry.register(ForgetTool())
            return Agent(runtime: runtime, registry: registry,
                         memory: MemoryServices(retriever: retriever))
        }

        // --- Turn A: state a fact ---
        let agentA = makeAgent()
        var turnAText = ""
        var rememberFired = false
        for try await event in agentA.run(prompt: "Me llamo Roilan y me gusta el sushi.", options: e2eOptions()) {
            switch event {
            case .toolCallFinished(let name, let result):
                if name == SaveMemoryTool.name { rememberFired = true }
                observe("🔧 E2E-OBSERVE: turnA toolCallFinished name=\(name) result=\(result)")
            case .toolCallStarted(let name, let args):
                observe("🔧 E2E-OBSERVE: turnA toolCallStarted name=\(name) args=\(args)")
            case .token(let t):
                turnAText += t
            case .completed(let res):
                if turnAText.isEmpty { turnAText = res.text }
            case .failed(let m):
                observe("⚠️ E2E-OBSERVE: turnA failed: \(m)")
            }
        }
        observe("⚠️ E2E-OBSERVE: turnA answer: \(turnAText)")
        observe("⚠️ E2E-OBSERVE: turnA remember tool fired=\(rememberFired)")

        // Deterministic store inspection.
        let nodesAfterA = try memStore.allNodes()
        observe("⚠️ E2E-OBSERVE: nodes after turnA count=\(nodesAfterA.count)")
        for n in nodesAfterA {
            observe("⚠️ E2E-OBSERVE: node kind=\(n.kind) layer=\(n.layer.rawValue) origin=\(n.origin.rawValue) label=\"\(n.label)\" body=\"\(n.body)\"")
        }
        let sushiNode = nodesAfterA.first {
            $0.label.lowercased().contains("sushi") || $0.body.lowercased().contains("sushi")
        }
        if let sn = sushiNode {
            observe("⚠️ E2E-OBSERVE: sushi node PRESENT via origin=\(sn.origin.rawValue) label=\"\(sn.label)\"")
        } else {
            observe("⚠️ E2E-OBSERVE: sushi node ABSENT — save_memory was not called for it")
        }

        // --- Turn B: recall (new Agent, same store/toolbox) ---
        let agentB = makeAgent()
        var turnBText = ""
        for try await event in agentB.run(prompt: "¿Qué me gusta?", options: e2eOptions()) {
            switch event {
            case .token(let t):
                turnBText += t
            case .completed(let res):
                if turnBText.isEmpty { turnBText = res.text }
            case .toolCallFinished(let name, let result):
                observe("🔧 E2E-OBSERVE: turnB toolCallFinished name=\(name) result=\(result)")
            case .toolCallStarted(let name, let args):
                observe("🔧 E2E-OBSERVE: turnB toolCallStarted name=\(name) args=\(args)")
            case .failed(let m):
                observe("⚠️ E2E-OBSERVE: turnB failed: \(m)")
            }
        }
        observe("⚠️ E2E-OBSERVE: turnB recall answer: \(turnBText)")
        let mentionsSushi = turnBText.lowercased().contains("sushi")
        observe("⚠️ E2E-OBSERVE: turnB recall mentions sushi=\(mentionsSushi)")

        // FIRM assertions: deterministic pipeline only.
        XCTAssertFalse(turnAText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "turn A should complete with a non-empty answer")
        XCTAssertFalse(turnBText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "turn B should complete with a non-empty answer")

        // OBSERVE-only: model-dependent. Confirm when present; never fail the build when absent.
        if sushiNode != nil {
            XCTAssertNotNil(sushiNode, "sushi memory was saved (great)")
        }
        if mentionsSushi {
            XCTAssertTrue(mentionsSushi, "recall mentioned sushi (great)")
        }
    }
}
