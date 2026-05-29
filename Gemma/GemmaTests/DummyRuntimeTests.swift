import XCTest
@testable import Gemma

final class DummyRuntimeTests: XCTestCase {
    func test_isLoaded_falseInitially() async {
        let r = DummyRuntime()
        let loaded = await r.isLoaded()
        XCTAssertFalse(loaded)
    }

    func test_load_setsLoadedToTrue() async throws {
        let r = DummyRuntime()
        try await r.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))
        let loaded = await r.isLoaded()
        XCTAssertTrue(loaded)
    }

    func test_generate_throwsWhenNotLoaded() async {
        let r = DummyRuntime()
        let stream = await r.generate(prompt: "hola", image: nil, audioURL: nil, options: GenerationOptions())
        do {
            for try await _ in stream { }
            XCTFail("Expected RuntimeError.notLoaded")
        } catch RuntimeError.notLoaded {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_generate_streamsAllTokens() async throws {
        let r = DummyRuntime(
            cannedResponse: "uno dos tres",
            tokensPerSecondTarget: 200.0
        )
        try await r.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))

        let stream = await r.generate(
            prompt: "hola",
            image: nil,
            audioURL: nil,
            options: GenerationOptions(maxTokens: 10)
        )
        let received = Mutex<[String]>([])
        var finalResult: GenerationResult?
        for try await event in stream {
            switch event {
            case .token(let t): received.write { $0.append(t) }
            case .completed(let result): finalResult = result
            case .toolCallStarted, .toolCallFinished: break
            }
        }

        let tokens = received.read { $0 }
        XCTAssertEqual(tokens.count, 3)
        let result = try XCTUnwrap(finalResult)
        XCTAssertEqual(result.metrics.tokensGenerated, 3)
        XCTAssertGreaterThan(result.metrics.elapsedSeconds, 0)
        XCTAssertGreaterThan(result.metrics.timeToFirstTokenSeconds, 0)
        XCTAssertEqual(result.text, "uno dos tres")
    }

    func test_generate_respectsMaxTokens() async throws {
        let r = DummyRuntime(
            cannedResponse: "a b c d e f",
            tokensPerSecondTarget: 200.0
        )
        try await r.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))

        let stream = await r.generate(
            prompt: "p",
            image: nil,
            audioURL: nil,
            options: GenerationOptions(maxTokens: 3)
        )
        let received = Mutex<[String]>([])
        var finalResult: GenerationResult?
        for try await event in stream {
            switch event {
            case .token(let t): received.write { $0.append(t) }
            case .completed(let result): finalResult = result
            case .toolCallStarted, .toolCallFinished: break
            }
        }
        XCTAssertEqual(received.read { $0.count }, 3)
        let result = try XCTUnwrap(finalResult)
        XCTAssertEqual(result.metrics.tokensGenerated, 3)
    }

    func test_currentMetrics_isNilBeforeGenerate() async {
        let r = DummyRuntime()
        let m = await r.currentMetrics()
        XCTAssertNil(m)
    }

    func test_generate_withAudioURL_isIgnoredByDummy() async throws {
        let r = DummyRuntime()
        try await r.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))
        let stream = await r.generate(
            prompt: "hola",
            image: nil,
            audioURL: URL(fileURLWithPath: "/tmp/nope.wav"),
            options: GenerationOptions()
        )
        var text = ""
        for try await event in stream { if case .token(let t) = event { text += t } }
        XCTAssertFalse(text.isEmpty)
    }
}
