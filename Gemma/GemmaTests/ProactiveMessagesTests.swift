import XCTest
@testable import Gemma

final class ProactiveMessagesTests: XCTestCase {
    func test_builds_messages_from_clarifications_and_due_reminders() {
        let clar = "¿La reunión con Carlos del miércoles es la misma que la de mañana?"
        let due = "Reunión con Carlos (fecha: 2026-06-02)"
        let msgs = HarnessModel.proactiveMessages(clarifications: [clar], dueReminders: [due])
        XCTAssertTrue(msgs.contains { $0.contains(clar) })
        XCTAssertTrue(msgs.contains { $0.contains("Carlos") })
        XCTAssertTrue(HarnessModel.proactiveMessages(clarifications: [], dueReminders: []).isEmpty)
    }
}
