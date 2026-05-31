import XCTest
@testable import Gemma

/// M2b-2 end-to-end verification of `MemoryConsolidationEngine` against the REAL local
/// mlx-lm server (Gemma 4 26B MoE). Drives the full brain-like sleep cycle —
/// NREM consolidate → REM associate → Reflect → Curate → SHY forget — over a short seeded
/// conversation, then OBSERVES whether the 26B actually produced structured memory:
/// entities (person/preference/task/plan…), associative edges, grounded insights, and any
/// non-standard kinds that Curate folded.
///
/// GATED on `GEMMA_LIVE_SERVER=1` (or its `TEST_RUNNER_`-prefixed form) AND server
/// reachability, so the suite stays green offline. Assertions are FIRM only on the
/// deterministic pipeline (cycle completes: episodes consolidated + sleep_cycle cleared, and
/// at least SOME non-episode nodes were minted). Everything model-dependent (specific kinds,
/// specific edges, insights) is OBSERVED as "E2E-OBSERVE" log lines, never build-failing.
///
/// Run live with:
///   GEMMA_LIVE_SERVER=1 xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj \
///     -destination 'platform=macOS' -only-testing:GemmaTests/SleepConsolidationE2ETests
///
/// NOTE: the test method is `async` on purpose — synchronous @MainActor XCTest methods
/// crash on deinit in this project.
@MainActor
final class SleepConsolidationE2ETests: XCTestCase {
    private let baseURL = URL(string: "http://localhost:8080")!

    /// Print + NSLog + mirror to a sandbox-safe temp file so live model outputs survive
    /// xcodebuild's stdout buffering. The file path is logged once at startup; grep it for
    /// "E2E-OBSERVE".
    private static let observeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sleep_e2e_observe.log")
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

    func test_e2e_full_sleep_cycle() async throws {
        let env = ProcessInfo.processInfo.environment
        let enabled = (env["GEMMA_LIVE_SERVER"] == "1") || (env["TEST_RUNNER_GEMMA_LIVE_SERVER"] == "1")
        try XCTSkipUnless(enabled, "set GEMMA_LIVE_SERVER=1 to run the live sleep-cycle E2E")
        let reachable = await isServerUp()
        try XCTSkipUnless(reachable, "mlx-lm server not running on :8080")

        observe("⚠️ E2E-OBSERVE: observe log at \(Self.observeURL.path)")

        // --- Real stack: store + embedder + ServerRuntime + engine ---
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

        // Match production: all consolidation phases run thinking-OFF (the runtime's default).
        let runtime = ServerRuntime()
        let engine = MemoryConsolidationEngine(store: memStore, embedder: embedder, runtime: runtime)
        engine.onProgress = { [weak self] msg in self?.observe("🔧 E2E-OBSERVE: progress: \(msg)") }

        // --- Seed a short conversation as unconsolidated episodes (thread "T") ---
        // EpisodeRecorder.record writes proper episodic `conversation` nodes (status "closed").
        let turns: [(user: String, assistant: String)] = [
            ("Me llamo Roilan y me gusta el sushi y el fútbol.",
             "¡Encantado, Roilan! Buena combinación."),
            ("Mi amigo Juan trabaja conmigo en una panadería.",
             "Qué bien tener a un amigo de compañero de trabajo."),
            ("Tengo que llamar al dentista mañana.",
             "Anotado, no lo olvides."),
            ("Este año quiero aprender alemán.",
             "Excelente meta para este año."),
        ]
        let t0 = Date().timeIntervalSince1970
        for (i, turn) in turns.enumerated() {
            EpisodeRecorder.record(store: memStore, threadId: "T", turnIndex: i,
                                   userText: turn.user, assistantText: turn.assistant,
                                   now: t0 + Double(i))
        }
        let seeded = try memStore.unconsolidatedEpisodes()
        observe("⚠️ E2E-OBSERVE: seeded unconsolidated episodes count=\(seeded.count)")
        XCTAssertGreaterThan(seeded.count, 0, "fixture should seed unconsolidated episode nodes")

        // --- Run a full resumable cycle against the real 26B ---
        observe("⚠️ E2E-OBSERVE: running full sleep cycle (NREM→REM→Reflect→Curate→SHY)...")
        await engine.runCycle(isCancelled: { false })

        // ====================== INSPECT + OBSERVE ======================
        let allNodes = try memStore.allNodes()
        let nonEpisode = allNodes.filter { $0.kind != NodeKind.conversation.rawValue }
        observe("⚠️ E2E-OBSERVE: total nodes=\(allNodes.count) nonEpisode=\(nonEpisode.count)")

        // (1) Non-episode nodes by kind + label (did 26B mint person/preference/task/plan…?)
        for n in nonEpisode {
            observe("⚠️ E2E-OBSERVE: node kind=\(n.kind) layer=\(n.layer.rawValue) label=\"\(n.label)\" body=\"\(n.body)\" attrs=\(n.extra ?? "nil")")
        }

        // (2) Edges (did REM create associative edges, e.g. Roilan→likes→sushi?)
        let edges = try memStore.allEdges()
        observe("⚠️ E2E-OBSERVE: edges count=\(edges.count)")
        func label(of id: String) -> String { (try? memStore.node(id: id))?.label ?? id }
        for e in edges {
            observe("⚠️ E2E-OBSERVE: edge \(label(of: e.srcId)) --\(e.relation.rawValue)--> \(label(of: e.dstId))")
        }

        // (3) Insight nodes (did Reflect synthesize grounded insights linked to ≥2 sources?)
        let insights = nonEpisode.filter { $0.kind == NodeKind.insight.rawValue }
        observe("⚠️ E2E-OBSERVE: insight nodes count=\(insights.count)")
        for ins in insights {
            let outDeg = edges.filter { $0.srcId == ins.id }.count
            observe("⚠️ E2E-OBSERVE: insight \"\(ins.body)\" sources=\(outDeg)")
        }

        // (4) Distinct kinds present (did the model mint a non-standard kind? did Curate fold it?)
        let standard = Set(NodeKind.allCases.map { $0.rawValue })
        let kinds = try memStore.distinctKinds()
        let nonStandard = kinds.filter { !standard.contains($0) }
        observe("⚠️ E2E-OBSERVE: distinct kinds=\(kinds)")
        observe("⚠️ E2E-OBSERVE: non-standard kinds remaining after Curate=\(nonStandard)")

        // (5) Cycle completion: episodes consolidated, sleep_cycle cleared.
        let remainingEpisodes = try memStore.unconsolidatedEpisodes()
        let cycle = try memStore.loadSleepCycle()
        observe("⚠️ E2E-OBSERVE: remaining unconsolidated episodes=\(remainingEpisodes.count) sleepCycle=\(cycle == nil ? "nil" : "present")")

        // ====================== ASSERTIONS ======================
        // FIRM — deterministic pipeline only:
        XCTAssertTrue(remainingEpisodes.isEmpty,
                      "after a full cycle all seeded episodes should be marked consolidated")
        XCTAssertNil(cycle, "after a full cycle the persisted sleep_cycle should be cleared")
        XCTAssertGreaterThan(nonEpisode.count, 0,
                             "the 26B should have produced at least some structured (non-episode) memory")

        // OBSERVE-only — model-dependent. Confirm when present; never fail the build when absent.
        let lowered = nonEpisode.map { "\($0.label) \($0.body)".lowercased() }
        func mentions(_ s: String) -> Bool { lowered.contains { $0.contains(s) } }
        observe("⚠️ E2E-OBSERVE: mentions sushi=\(mentions("sushi")) futbol=\(mentions("fútbol") || mentions("futbol")) juan=\(mentions("juan")) dentist=\(mentions("dentist")) aleman=\(mentions("alemán") || mentions("aleman") || mentions("german"))")
        if !edges.isEmpty { XCTAssertGreaterThan(edges.count, 0, "REM associated entities (great)") }
        if !insights.isEmpty { XCTAssertGreaterThan(insights.count, 0, "Reflect synthesized insights (great)") }
    }
}
