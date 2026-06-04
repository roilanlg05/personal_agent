import XCTest
@testable import Gemma

final class RecallInjectionTests: XCTestCase {
    private func node(_ kind: String, _ label: String, _ body: String, _ extra: String?) -> MemoryClient.RecallNode {
        MemoryClient.RecallNode(kind: kind, label: label, body: body, extra: extra)
    }

    func test_cancelledEvent_isMarked() {
        let bundle = MemoryClient.RecallBundle(core: [], recall: [
            node("event", "Reunión Miami", "9-jun 8am", #"{"status":"cancelled","startAt":1}"#)
        ], recentTurns: [])
        let block = bundle.injectionBlock()
        XCTAssertTrue(block.contains("Reunión Miami"))
        XCTAssertTrue(block.contains("(cancelado)"), block)
    }

    func test_scheduledEvent_notMarked() {
        let bundle = MemoryClient.RecallBundle(core: [], recall: [
            node("event", "Dentista", "11-jun 9am", #"{"status":"scheduled"}"#)
        ], recentTurns: [])
        XCTAssertFalse(bundle.injectionBlock().contains("(cancelado)"))
    }

    func test_nonEventNode_unchanged() {
        let bundle = MemoryClient.RecallBundle(core: [], recall: [
            node("preference", "sushi", "le gusta el sushi", nil)
        ], recentTurns: [])
        let block = bundle.injectionBlock()
        XCTAssertTrue(block.contains("sushi"))
        XCTAssertFalse(block.contains("(cancelado)"))
    }

    func test_recentTurns_render_in_block() {
        let bundle = MemoryClient.RecallBundle(core: [], recall: [],
            recentTurns: [MemoryClient.RecentTurn(role: "user", text: "voy a Varadero")])
        let block = bundle.injectionBlock()
        XCTAssertTrue(block.contains("Recent conversation (other chats):"), block)
        XCTAssertTrue(block.contains("voy a Varadero"))
    }

    func test_empty_bundle_is_empty() {
        XCTAssertEqual(MemoryClient.RecallBundle(core: [], recall: [], recentTurns: []).injectionBlock(), "")
    }
}
