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
}
