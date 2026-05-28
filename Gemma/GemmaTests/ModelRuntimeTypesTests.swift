import XCTest
@testable import Gemma

final class ModelRuntimeTypesTests: XCTestCase {
    func test_runtimeMetrics_tokensPerSecond_computesCorrectly() {
        let m = RuntimeMetrics(
            tokensGenerated: 100,
            elapsedSeconds: 5.0,
            timeToFirstTokenSeconds: 0.3,
            peakResidentMemoryBytes: 0,
            draftAcceptanceRate: nil
        )
        XCTAssertEqual(m.tokensPerSecond, 20.0, accuracy: 0.001)
    }

    func test_runtimeMetrics_tokensPerSecond_returnsZeroOnZeroElapsed() {
        let m = RuntimeMetrics(
            tokensGenerated: 100,
            elapsedSeconds: 0,
            timeToFirstTokenSeconds: 0,
            peakResidentMemoryBytes: 0,
            draftAcceptanceRate: nil
        )
        XCTAssertEqual(m.tokensPerSecond, 0)
    }

    func test_generationOptions_defaultsAreSane() {
        let opts = GenerationOptions()
        XCTAssertEqual(opts.maxTokens, 4000)
        XCTAssertEqual(opts.temperature, 1.0, accuracy: 0.001)
        XCTAssertEqual(opts.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(opts.topK, 64)
        XCTAssertFalse(opts.useSpeculativeDecoding)  // legacy field; load-time MTP supersedes
    }

    func test_modelLoadOptions_defaultsAreSane() {
        let url = URL(fileURLWithPath: "/tmp/model.bin")
        let opts = ModelLoadOptions(modelPath: url)
        XCTAssertEqual(opts.modelPath, url)
        XCTAssertTrue(opts.useMmap)
        // KV-cache size (maxNumTokens). Matches the Edge Gallery recipe for Gemma 4;
        // 32K blows the GPU Metal texture budget on-device (failedToCreateEngine).
        XCTAssertEqual(opts.contextLength, 4096)
        XCTAssertFalse(opts.useSpeculativeDecoding)
        XCTAssertFalse(opts.enableThinking)
        XCTAssertNil(opts.systemPrompt)
    }
}
