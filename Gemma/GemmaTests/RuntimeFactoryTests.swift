import XCTest
@testable import Gemma

final class RuntimeFactoryTests: XCTestCase {
    func test_make_dummy_returnsDummyRuntime() async {
        let r = RuntimeFactory.make(.dummy)
        let id = r.identifier
        XCTAssertEqual(id, "dummy")
        let loaded = await r.isLoaded()
        XCTAssertFalse(loaded)
    }

    func test_runtimeKind_allCasesContainsDummy() {
        XCTAssertTrue(RuntimeKind.allCases.contains(.dummy))
    }

    func test_runtimeKind_displayName_nonEmpty() {
        for kind in RuntimeKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty, "\(kind) needs a display name")
        }
    }

    func test_runtimeKind_litertlmE4B_displayNameAndModelId() {
        let kind = RuntimeKind.litertlmE4B
        XCTAssertEqual(kind.displayName, "Gemma 4 E4B (LiteRT-LM)")
        XCTAssertEqual(kind.requiredModelId, "gemma-4-e4b-it")
    }

    func test_runtimeKind_litertlmE2B_displayNameAndModelId() {
        let kind = RuntimeKind.litertlmE2B
        XCTAssertEqual(kind.displayName, "Gemma 4 E2B (LiteRT-LM)")
        XCTAssertEqual(kind.requiredModelId, "gemma-4-e2b-it")
    }

    func test_runtimeKind_dummy_requiresNoModel() {
        XCTAssertNil(RuntimeKind.dummy.requiredModelId)
    }

    func test_runtimeKind_allCases_includesNewKinds() {
        XCTAssertTrue(RuntimeKind.allCases.contains(.litertlmE4B))
        XCTAssertTrue(RuntimeKind.allCases.contains(.litertlmE2B))
    }
}
