import XCTest
import UIKit
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
        // PromptSet has 20 prompts total — image prompts included via UIImage(named:) lookup.
        XCTAssertTrue(m.streamedOutput.contains("20 prompts"))
    }

    func test_benchImage1_assetExistsInBundle() {
        let img = UIImage(named: "bench-image-1")
        XCTAssertNotNil(img, "bench-image-1 must be present in Assets.xcassets")
    }

    func test_catalog_isModelCatalogBuiltIn() async {
        let m = HarnessModel()
        XCTAssertEqual(m.catalog.map(\.id), ModelCatalog.builtIn.map(\.id))
        // Same deinit-hop workaround as test_init_defaultsAreDummyAndNotLoaded.
        await Task.yield()
    }

    func test_deviceCapability_isRealisticForTestDevice() async {
        let m = HarnessModel()
        XCTAssertGreaterThan(m.deviceCapability.totalRAMBytes, 0)
        XCTAssertGreaterThan(m.deviceCapability.freeDiskBytes, 0)
        await Task.yield()
    }

    func test_initialInstalledModels_isEmptyOrSubsetOfCatalog() async {
        let m = HarnessModel()
        for installed in m.installedModels {
            XCTAssertTrue(m.catalog.contains(installed))
        }
        await Task.yield()
    }

    func test_toggleLoad_litertlmKind_withoutInstall_setsStatusMessage() async {
        let m = HarnessModel(initialKind: .litertlmE4B)
        await m.toggleLoad()
        await Task.yield()
        XCTAssertFalse(m.modelLoaded)
        XCTAssertTrue(
            m.statusMessage.contains("not installed") || m.statusMessage.contains("Open Models"),
            "statusMessage was: \(m.statusMessage)"
        )
    }
}
