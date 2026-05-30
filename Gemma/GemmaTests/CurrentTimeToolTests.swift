import XCTest
@testable import Gemma

final class CurrentTimeToolTests: XCTestCase {
    func test_metadata() {
        XCTAssertEqual(CurrentTimeTool.name, "get_current_time")
        XCTAssertFalse(CurrentTimeTool.description.isEmpty)
    }
    func test_run_returnsNonEmptyTimeString() async throws {
        let s = await CurrentTimeTool().run(argsJSON: "{}")
        XCTAssertFalse(s.isEmpty)
    }
}
