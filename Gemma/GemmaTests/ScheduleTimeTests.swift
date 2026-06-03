import XCTest
@testable import Gemma

final class ScheduleTimeTests: XCTestCase {
    func test_epoch_parsesLocalDateTime() {
        // 2026-06-09 08:00 local → round-trips back to the same local string
        let e = ScheduleTime.epoch(fromISO: "2026-06-09T08:00")
        XCTAssertNotNil(e)
        XCTAssertEqual(ScheduleTime.iso(fromEpoch: e!), "2026-06-09T08:00")
    }
    func test_epoch_parsesDateOnly_asMidnight() {
        let e = ScheduleTime.epoch(fromISO: "2026-06-09")
        XCTAssertNotNil(e)
        XCTAssertEqual(ScheduleTime.iso(fromEpoch: e!), "2026-06-09T00:00")
    }
    func test_epoch_nilOnGarbage() {
        XCTAssertNil(ScheduleTime.epoch(fromISO: "next thursday"))
    }
}
