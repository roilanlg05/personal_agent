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

    func test_systemPrompt_isJarvis_constrained_dateless() {
        let p = Agent.systemPromptText
        XCTAssertTrue(p.contains("JARVIS"), "persona")
        XCTAssertTrue(p.contains("Report ONLY what your tools actually returned"), "anti-invent")
        XCTAssertTrue(p.contains("NEVER invent"), "anti-invent")
        XCTAssertTrue(p.localizedCaseInsensitiveContains("automatic-rescheduling"), "no fake feature")
        XCTAssertTrue(p.localizedCaseInsensitiveContains("do not use tables"), "concision")
        XCTAssertTrue(p.contains("Monday–Sunday"), "schedule conventions kept")
        XCTAssertTrue(p.localizedCaseInsensitiveContains("query_schedule is the ONLY source of truth"), "authority kept")
        XCTAssertTrue(p.localizedCaseInsensitiveContains("event to PERSIST"), "trips are persisted as events")
        XCTAssertFalse(p.contains("Today is"), "no static date in prefix")
        XCTAssertFalse(p.contains("2026-06-10"), "no hard-coded date example")
    }
}
