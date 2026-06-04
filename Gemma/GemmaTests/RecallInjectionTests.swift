import XCTest
@testable import Gemma

final class RecallInjectionTests: XCTestCase {
    private func node(_ kind: String, _ label: String, _ body: String, _ extra: String?) -> MemoryClient.RecallNode {
        MemoryClient.RecallNode(kind: kind, label: label, body: body, extra: extra)
    }

    func test_cancelledEvent_isMarked() {
        let bundle = MemoryClient.RecallBundle(core: [], recall: [
            node("event", "Reunión Miami", "9-jun 8am", #"{"status":"cancelled","startAt":1}"#)
        ], summaries: [], recentTurns: [])
        let block = bundle.injectionBlock()
        XCTAssertTrue(block.contains("Reunión Miami"))
        XCTAssertTrue(block.contains("(cancelado)"), block)
    }

    func test_scheduledEvent_notMarked() {
        let bundle = MemoryClient.RecallBundle(core: [], recall: [
            node("event", "Dentista", "11-jun 9am", #"{"status":"scheduled"}"#)
        ], summaries: [], recentTurns: [])
        XCTAssertFalse(bundle.injectionBlock().contains("(cancelado)"))
    }

    func test_nonEventNode_unchanged() {
        let bundle = MemoryClient.RecallBundle(core: [], recall: [
            node("preference", "sushi", "le gusta el sushi", nil)
        ], summaries: [], recentTurns: [])
        let block = bundle.injectionBlock()
        XCTAssertTrue(block.contains("sushi"))
        XCTAssertFalse(block.contains("(cancelado)"))
    }

    func test_recentTurns_render_in_block() {
        let bundle = MemoryClient.RecallBundle(core: [], recall: [],
            summaries: [],
            recentTurns: [MemoryClient.RecentTurn(role: "user", text: "voy a Varadero")])
        let block = bundle.injectionBlock()
        XCTAssertTrue(block.contains("Recent conversation (other chats):"), block)
        XCTAssertTrue(block.contains("voy a Varadero"))
    }

    func test_empty_bundle_is_empty() {
        XCTAssertEqual(MemoryClient.RecallBundle(core: [], recall: [], summaries: [], recentTurns: []).injectionBlock(), "")
    }

    func test_self_node_renders_as_you_first() {
        let bundle = MemoryClient.RecallBundle(
            core: [MemoryClient.RecallNode(kind: "self", label: "Roilan", body: "", extra: nil),
                   MemoryClient.RecallNode(kind: "preference", label: "sushi", body: "le gusta", extra: nil)],
            recall: [], summaries: [], recentTurns: [])
        let block = bundle.injectionBlock()
        XCTAssertTrue(block.contains("You are speaking with Roilan (the user)."), block)
        XCTAssertFalse(block.contains("- [self]"), "self must not render as a generic fact line")
        // self sentence comes before the remembered-facts section
        let selfRange = block.range(of: "You are speaking with Roilan")
        let factsRange = block.range(of: "What you remember about the user")
        XCTAssertNotNil(selfRange); XCTAssertNotNil(factsRange)
        if let s = selfRange, let f = factsRange { XCTAssertTrue(s.lowerBound < f.lowerBound) }
    }

    func test_summaries_tier_renders_with_drilldown_refs() {
        let bundle = MemoryClient.RecallBundle(
            core: [], recall: [],
            summaries: [MemoryClient.RecallSummary(summaryId: "s1", chatId: "g7y", messageRange: [21, 56],
                                                   text: "trading de opciones semanales")],
            recentTurns: [])
        let block = bundle.injectionBlock()
        XCTAssertTrue(block.contains("Episodic summaries"), block)
        XCTAssertTrue(block.contains("[chat g7y · msgs 21-56]"), block)
        XCTAssertTrue(block.contains("trading de opciones semanales"), block)
    }
}
