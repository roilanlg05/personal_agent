import XCTest
@testable import Gemma

@MainActor
final class HarnessModelTests: XCTestCase {
    func test_init_defaultsAreDummyAndNotLoaded() async {
        let m = HarnessModel()
        XCTAssertEqual(m.runtimeKind, .dummy)
        XCTAssertFalse(m.modelLoaded)
        XCTAssertFalse(m.isGenerating)
        XCTAssertFalse(m.isLoadingModel)
        XCTAssertTrue(m.statusMessage.contains("not loaded"))
        // Yield once so the model is released on an executor hop, avoiding
        // a libmalloc deinit-time crash seen with @Observable + @MainActor in
        // purely-synchronous XCTest cases on iOS 26.2 simulator.
        await Task.yield()
    }

    func test_toggleLoad_setsModelLoaded() async {
        let m = HarnessModel()
        await m.toggleLoad()
        XCTAssertTrue(m.modelLoaded)
        XCTAssertTrue(m.statusMessage.contains("loaded"))
    }

    func test_toggleLoad_secondCallUnloads() async {
        let m = HarnessModel()
        await m.toggleLoad()
        await m.toggleLoad()
        XCTAssertFalse(m.modelLoaded)
        XCTAssertTrue(m.statusMessage.contains("unloaded"))
    }

    func test_runSingle_streamsTokensIntoOutput() async {
        let m = HarnessModel()
        m.prompt = "ignored by dummy"
        await m.toggleLoad()
        await m.runSingle()
        XCTAssertFalse(m.streamedOutput.isEmpty)
        XCTAssertNotNil(m.lastMetrics)
    }

    func test_runBench_writesReportAndSetsPath() async {
        let m = HarnessModel()
        await m.toggleLoad()
        await m.runBench()
        XCTAssertNotNil(m.benchReportPath)
        XCTAssertTrue(m.streamedOutput.starts(with: "Bench done"))
    }
}
