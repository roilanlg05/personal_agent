import XCTest
@testable import Gemma

final class WakeContextTests: XCTestCase {
    func test_focus_only_when_cycle_pending() {
        let ctx = HarnessModel.buildWakeContext(focus: "sushi, fútbol", followUps: [], isWake: false)
        XCTAssertTrue(ctx.contains("reflecting on"))
        XCTAssertTrue(ctx.contains("sushi, fútbol"))
    }
    func test_followups_only_on_wake() {
        let none = HarnessModel.buildWakeContext(focus: "", followUps: ["call the dentist"], isWake: false)
        XCTAssertTrue(none.isEmpty, "follow-ups only surface on wake (first turn / after a gap)")
        let onWake = HarnessModel.buildWakeContext(focus: "", followUps: ["call the dentist"], isWake: true)
        XCTAssertTrue(onWake.contains("call the dentist"))
    }
    func test_empty_when_nothing() {
        XCTAssertTrue(HarnessModel.buildWakeContext(focus: "", followUps: [], isWake: true).isEmpty)
    }
}
