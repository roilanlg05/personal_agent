import XCTest
@testable import Gemma

@MainActor
final class RuntimeFactoryTests: XCTestCase {
    func test_make_dummy_returnsDummyRuntime() async {
        let r = RuntimeFactory.make(.dummy)
        XCTAssertEqual(r.identifier, "dummy")
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
