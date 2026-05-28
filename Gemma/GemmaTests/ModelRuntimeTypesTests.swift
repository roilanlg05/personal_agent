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

    func test_modelLoadOptions_defaultsAreSane() {
        let url = URL(fileURLWithPath: "/tmp/model.bin")
        let opts = ModelLoadOptions(modelPath: url)
        XCTAssertEqual(opts.modelPath, url)
        XCTAssertNil(opts.drafterPath)
        XCTAssertTrue(opts.useMmap)
        XCTAssertEqual(opts.contextLength, 4096)
    }

    func test_generationOptions_defaultsAreSane() {
        let opts = GenerationOptions()
        XCTAssertEqual(opts.maxTokens, 256)
        XCTAssertEqual(opts.temperature, 0.7, accuracy: 0.001)
        XCTAssertEqual(opts.topP, 0.9, accuracy: 0.001)
        XCTAssertFalse(opts.useSpeculativeDecoding)
    }
}
