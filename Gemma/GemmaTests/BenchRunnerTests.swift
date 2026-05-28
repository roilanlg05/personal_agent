import XCTest
@testable import Gemma

final class BenchRunnerTests: XCTestCase {
    func test_run_executesAllNonImagePromptsAgainstRuntime() async throws {
        let runtime = DummyRuntime(
            cannedResponse: "ok ok ok",
            tokensPerSecondTarget: 200.0
        )
        try await runtime.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))

        let runner = BenchRunner()
        let report = try await runner.run(
            runtime: runtime,
            modelDescription: "dummy",
            useSpeculativeDecoding: false,
            useMmap: true,
            prompts: PromptSet.all.filter { $0.category != .image }
        )
        // 8 + 6 + 4 = 18 non-image prompts
        XCTAssertEqual(report.results.count, 18)
        XCTAssertEqual(report.runtimeIdentifier, "dummy")
        XCTAssertFalse(report.useSpeculativeDecoding)
        XCTAssertTrue(report.useMmap)
        for r in report.results {
            XCTAssertEqual(r.metrics.tokensGenerated, 3)
            XCTAssertFalse(r.outputText.isEmpty)
        }
    }

    func test_run_propagatesRuntimeError() async {
        let runtime = DummyRuntime()  // never loaded
        let runner = BenchRunner()
        do {
            _ = try await runner.run(
                runtime: runtime,
                modelDescription: "dummy",
                useSpeculativeDecoding: false,
                useMmap: true,
                prompts: [PromptSet.all[0]]
            )
            XCTFail("Expected error")
        } catch RuntimeError.notLoaded {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_run_completedAtIsAfterStartedAt() async throws {
        let runtime = DummyRuntime(cannedResponse: "a", tokensPerSecondTarget: 200)
        try await runtime.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))
        let runner = BenchRunner()
        let report = try await runner.run(
            runtime: runtime,
            modelDescription: "dummy",
            useSpeculativeDecoding: false,
            useMmap: true,
            prompts: [PromptSet.all[0]]
        )
        XCTAssertGreaterThanOrEqual(report.completedAt, report.startedAt)
    }

    func test_run_invokesImageProviderForImagePrompts() async throws {
        let runtime = DummyRuntime(cannedResponse: "a b", tokensPerSecondTarget: 200)
        try await runtime.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))

        let observedIds = Mutex<[String]>([])
        let runner = BenchRunner()
        _ = try await runner.run(
            runtime: runtime,
            modelDescription: "dummy",
            useSpeculativeDecoding: false,
            useMmap: true,
            prompts: PromptSet.all.filter { $0.category == .image },
            imageProvider: { prompt in
                observedIds.write { $0.append(prompt.id) }
                return nil  // DummyRuntime ignores the image anyway
            }
        )

        let ids = observedIds.read { $0 }
        XCTAssertEqual(Set(ids), Set(PromptSet.all.filter { $0.category == .image }.map(\.id)))
    }
}
