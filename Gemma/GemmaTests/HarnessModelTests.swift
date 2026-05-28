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

    func test_presentBenchmark_dummyKind_doesNotOpenSheet() async {
        let m = HarnessModel()  // .dummy
        await m.presentBenchmark()
        XCTAssertFalse(m.showBenchmark)
        XCTAssertTrue(m.statusMessage.contains("Benchmark needs a model"))
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

    func test_partialDownloads_surfacesOrphanPartial() async throws {
        // A leftover .partial with no final file should be surfaced so the UI can
        // offer to reclaim the (potentially multi-GB) space.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gemma-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let desc = ModelCatalog.find("gemma-4-e2b-it")!
        try Data(repeating: 0, count: 8192).write(to: dir.appendingPathComponent(desc.modelFile + ".partial"))

        let store = InstalledModels(rootDir: dir)
        let m = HarnessModel(installedStore: store)
        XCTAssertEqual(m.partialDownloads[desc.id], 8192)
        XCTAssertFalse(m.installedModels.contains(desc))
        await Task.yield()
    }

    func test_toggleLoad_litertlmKind_withoutInstall_setsStatusMessage() async {
        // Hermetic: inject an isolated empty store so a sideloaded model in the
        // app's real Documents/Models/ can't satisfy the "without install" premise.
        let emptyStore = InstalledModels(
            rootDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gemma-test-empty-\(UUID().uuidString)", isDirectory: true)
        )
        let m = HarnessModel(initialKind: .litertlmE4B, installedStore: emptyStore)
        await m.toggleLoad()
        await Task.yield()
        XCTAssertFalse(m.modelLoaded)
        XCTAssertTrue(
            m.statusMessage.contains("not installed") || m.statusMessage.contains("Open Models"),
            "statusMessage was: \(m.statusMessage)"
        )
    }
}
