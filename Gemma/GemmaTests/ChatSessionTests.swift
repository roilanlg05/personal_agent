import XCTest
@testable import Gemma

final class ChatSessionTests: XCTestCase {
    func test_starts_new_chat_after_idle_gap() {
        let gap = 1800.0
        // first ever turn: no previous activity → keep the chat
        XCTAssertFalse(ChatSession.shouldStartNewChat(lastActivity: 0, now: 100, gapSeconds: gap))
        // within the window → same chat
        XCTAssertFalse(ChatSession.shouldStartNewChat(lastActivity: 1000, now: 1000 + 1799, gapSeconds: gap))
        // exactly at the window → still same chat (not strictly greater)
        XCTAssertFalse(ChatSession.shouldStartNewChat(lastActivity: 1000, now: 1000 + 1800, gapSeconds: gap))
        // past the window → new chat
        XCTAssertTrue(ChatSession.shouldStartNewChat(lastActivity: 1000, now: 1000 + 1801, gapSeconds: gap))
    }
    func test_default_gap_is_thirty_minutes() {
        XCTAssertEqual(ChatSession.defaultGapSeconds, 1800)
    }
}
