import XCTest
@testable import Gemma

final class ScheduleStatusTests: XCTestCase {
    func test_statusSuffix_maps() {
        XCTAssertEqual(scheduleStatusSuffix("cancelled"), " (cancelado)")
        XCTAssertEqual(scheduleStatusSuffix("done"), " (hecho)")
        XCTAssertEqual(scheduleStatusSuffix("scheduled"), "")
        XCTAssertEqual(scheduleStatusSuffix(nil), "")
    }
}
