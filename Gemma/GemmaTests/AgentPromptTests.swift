import XCTest
@testable import Gemma

final class AgentPromptTests: XCTestCase {
    func test_conventions_present() {
        let c = Agent.scheduleConventions
        XCTAssertTrue(c.contains("Monday") && c.contains("Sunday"), c)
        XCTAssertTrue(c.localizedCaseInsensitiveContains("working week"), c)
        XCTAssertTrue(c.localizedCaseInsensitiveContains("absolute date"), c)
        XCTAssertTrue(c.localizedCaseInsensitiveContains("query_schedule"), c)
    }
}
