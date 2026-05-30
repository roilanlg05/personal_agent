import XCTest
@testable import Gemma

final class DummyRuntimeTests: XCTestCase {
    func test_isLoaded_trueByDefault() async {
        let r = DummyRuntime()
        let loaded = await r.isLoaded()
        XCTAssertTrue(loaded)
    }

    func test_load_doesNotThrow() async throws {
        let r = DummyRuntime()
        try await r.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))
        let loaded = await r.isLoaded()
        XCTAssertTrue(loaded)
    }

    func test_generate_echoesPromptAsToken() async throws {
        let r = DummyRuntime()
        let stream = await r.generate(prompt: "hola", options: GenerationOptions())
        var tokens: [String] = []
        var finalResult: GenerationResult?
        for try await event in stream {
            switch event {
            case .token(let t): tokens.append(t)
            case .completed(let result): finalResult = result
            case .toolCallStarted, .toolCallFinished: break
            }
        }
        XCTAssertEqual(tokens, ["hola"])
        let result = try XCTUnwrap(finalResult)
        XCTAssertEqual(result.text, "hola")
    }

    func test_currentMetrics_isNil() async {
        let r = DummyRuntime()
        let m = await r.currentMetrics()
        XCTAssertNil(m)
    }
}
