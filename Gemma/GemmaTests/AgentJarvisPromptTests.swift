import XCTest
@testable import Gemma

@MainActor
final class AgentJarvisPromptTests: XCTestCase {
    func test_nowContext_format() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 4; comps.hour = 14; comps.minute = 32
        let date = Calendar.current.date(from: comps)!
        XCTAssertEqual(Agent.nowContext(date),
                       "Current date and time: 2026-06-04 (Thursday) 14:32 (local).")
    }
}
