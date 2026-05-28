import XCTest
@testable import Gemma

final class ModelCatalogTests: XCTestCase {
    func test_builtIn_containsE4BAndE2B() {
        let ids = Set(ModelCatalog.builtIn.map(\.id))
        XCTAssertTrue(ids.contains("gemma-4-e4b-it"))
        XCTAssertTrue(ids.contains("gemma-4-e2b-it"))
    }

    func test_builtIn_e4b_metadataMatchesGoogleCatalog() {
        guard let e4b = ModelCatalog.find("gemma-4-e4b-it") else {
            return XCTFail("E4B descriptor missing")
        }
        XCTAssertEqual(e4b.modelFile, "gemma-4-E4B-it.litertlm")
        XCTAssertEqual(e4b.sizeInBytes, 3_659_530_240)
        XCTAssertEqual(e4b.minDeviceMemoryGB, 8)
        XCTAssertEqual(e4b.maxContextLength, 32_000)
        XCTAssertTrue(e4b.supportsImage)
        XCTAssertTrue(e4b.supportsAudio)
        XCTAssertTrue(e4b.supportsSpeculativeDecoding)
    }

    func test_builtIn_e2b_metadataMatchesGoogleCatalog() {
        guard let e2b = ModelCatalog.find("gemma-4-e2b-it") else {
            return XCTFail("E2B descriptor missing")
        }
        XCTAssertEqual(e2b.modelFile, "gemma-4-E2B-it.litertlm")
        XCTAssertEqual(e2b.sizeInBytes, 2_588_147_712)
        XCTAssertEqual(e2b.minDeviceMemoryGB, 6)
        XCTAssertEqual(e2b.maxContextLength, 32_000)
    }

    func test_find_unknownId_returnsNil() {
        XCTAssertNil(ModelCatalog.find("does-not-exist"))
    }

    func test_builtIn_idsAreUnique() {
        let ids = ModelCatalog.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
