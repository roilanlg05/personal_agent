import XCTest
@testable import Gemma

final class BenchmarkTypesTests: XCTestCase {
    func test_config_defaults() {
        let c = BenchmarkConfig()
        XCTAssertEqual(c.backend, .gpu)
        XCTAssertEqual(c.prefillTokens, 256)
        XCTAssertEqual(c.decodeTokens, 256)
        XCTAssertEqual(c.runCount, 5)
    }

    func test_aggregate_emptyRunsIsZero() {
        let r = BenchmarkResult.aggregate([])
        XCTAssertEqual(r.runs.count, 0)
        XCTAssertEqual(r.firstInitSeconds, 0)
        XCTAssertEqual(r.avgWarmInitSeconds, 0)
        XCTAssertEqual(r.avgTTFTSeconds, 0)
        XCTAssertEqual(r.avgPrefillTokPerSec, 0)
        XCTAssertEqual(r.avgDecodeTokPerSec, 0)
    }

    func test_aggregate_separatesFirstInitFromWarm() {
        let runs = [
            BenchmarkRun(initSeconds: 10, ttftSeconds: 1.0, prefillTokPerSec: 100, decodeTokPerSec: 10),
            BenchmarkRun(initSeconds: 2,  ttftSeconds: 0.5, prefillTokPerSec: 200, decodeTokPerSec: 20),
            BenchmarkRun(initSeconds: 4,  ttftSeconds: 0.5, prefillTokPerSec: 300, decodeTokPerSec: 30),
        ]
        let r = BenchmarkResult.aggregate(runs)
        XCTAssertEqual(r.firstInitSeconds, 10, accuracy: 0.0001)
        XCTAssertEqual(r.avgWarmInitSeconds, 3, accuracy: 0.0001)
        XCTAssertEqual(r.avgTTFTSeconds, 2.0/3.0, accuracy: 0.0001)
        XCTAssertEqual(r.avgPrefillTokPerSec, 200, accuracy: 0.0001)
        XCTAssertEqual(r.avgDecodeTokPerSec, 20, accuracy: 0.0001)
    }

    func test_aggregate_singleRunWarmFallsBackToFirst() {
        let r = BenchmarkResult.aggregate([
            BenchmarkRun(initSeconds: 7, ttftSeconds: 1, prefillTokPerSec: 50, decodeTokPerSec: 5)
        ])
        XCTAssertEqual(r.firstInitSeconds, 7, accuracy: 0.0001)
        XCTAssertEqual(r.avgWarmInitSeconds, 7, accuracy: 0.0001)
    }
}
