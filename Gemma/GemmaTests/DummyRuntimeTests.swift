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
        do {
            _ = try await r.generate(
                prompt: "hola",
                image: nil,
                options: GenerationOptions(),
                onToken: { _ in }
            )
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

        let received = Mutex<[String]>([])
        let result = try await r.generate(
            prompt: "hola",
            image: nil,
            options: GenerationOptions(maxTokens: 10),
            onToken: { token in received.write { $0.append(token) } }
        )

        let tokens = received.read { $0 }
        XCTAssertEqual(tokens.count, 3)
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

        let received = Mutex<[String]>([])
        let result = try await r.generate(
            prompt: "p",
            image: nil,
            options: GenerationOptions(maxTokens: 3),
            onToken: { token in received.write { $0.append(token) } }
        )
        XCTAssertEqual(received.read { $0.count }, 3)
        XCTAssertEqual(result.metrics.tokensGenerated, 3)
    }

    func test_currentMetrics_isNilBeforeGenerate() async {
        let r = DummyRuntime()
        let m = await r.currentMetrics()
        XCTAssertNil(m)
    }
}

/// Minimal thread-safe box for collecting from a Sendable closure in tests.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ initial: Value) { self.value = initial }
    func write(_ f: (inout Value) -> Void) { lock.lock(); f(&value); lock.unlock() }
    func read<T>(_ f: (Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(value) }
}
