import XCTest
@testable import Gemma

final class InstalledModelsTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InstalledModelsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func test_status_returnsNotInstalledWhenFileAbsent() {
        let store = InstalledModels(rootDir: dir)
        let desc = ModelCatalog.find("gemma-4-e4b-it")!
        XCTAssertEqual(store.status(of: desc), .notInstalled)
    }

    func test_status_returnsCorruptedWhenFileSizeMismatches() throws {
        let desc = ModelCatalog.find("gemma-4-e4b-it")!
        try Data(repeating: 0, count: 32).write(to: dir.appendingPathComponent(desc.modelFile))
        let store = InstalledModels(rootDir: dir)
        XCTAssertEqual(store.status(of: desc), .corrupted(actualSize: 32, expectedSize: desc.sizeInBytes))
    }

    func test_status_returnsInstalledWhenSizeMatches() throws {
        let desc = ModelCatalog.find("gemma-4-e2b-it")!
        let fileURL = dir.appendingPathComponent(desc.modelFile)
        // Make a file of exactly the expected size (sparse via truncate)
        let fh = try FileHandle(forWritingTo: createEmptyFile(at: fileURL))
        try fh.truncate(atOffset: UInt64(desc.sizeInBytes))
        try fh.close()
        let store = InstalledModels(rootDir: dir)
        XCTAssertEqual(store.status(of: desc), .installed(at: fileURL))
    }

    func test_remove_deletesFile() throws {
        let desc = ModelCatalog.find("gemma-4-e2b-it")!
        let fileURL = dir.appendingPathComponent(desc.modelFile)
        try Data().write(to: createEmptyFile(at: fileURL))
        let store = InstalledModels(rootDir: dir)
        try store.remove(desc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func test_allInstalled_listsOnlyExistingMatches() throws {
        let e4b = ModelCatalog.find("gemma-4-e4b-it")!
        let e2bURL = dir.appendingPathComponent(ModelCatalog.find("gemma-4-e2b-it")!.modelFile)
        let fh = try FileHandle(forWritingTo: createEmptyFile(at: e2bURL))
        try fh.truncate(atOffset: UInt64(ModelCatalog.find("gemma-4-e2b-it")!.sizeInBytes))
        try fh.close()
        let store = InstalledModels(rootDir: dir)
        let installed = store.allInstalled(from: ModelCatalog.builtIn)
        XCTAssertEqual(installed.map(\.id), ["gemma-4-e2b-it"])
        XCTAssertFalse(installed.contains(e4b))
    }

    private func createEmptyFile(at url: URL) -> URL {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }
}
