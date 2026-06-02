import XCTest
@testable import Gemma

@MainActor
final class ExpandContextToolTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    func test_expand_returns_formatted_turns_for_a_topic() async {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            XCTAssertEqual(req.url?.path, "/v1/memory/expand")
            let payload = #"""
            {"transcript":[
              {"role":"user","text":"quiero ir a Japón en abril"},
              {"role":"assistant","text":"buena idea"}
            ],"summaryLabel":"viaje a Japón"}
            """#.data(using: .utf8)!
            return (200, payload)
        }
        let out = await ExpandContextTool().run(argsJSON: #"{"topic":"viaje a Japón"}"#)
        XCTAssertTrue(out.contains("quiero ir a Japón en abril"), "verbatim user turn; got: \(out)")
        XCTAssertTrue(out.contains("buena idea"), "assistant turn; got: \(out)")
        XCTAssertTrue(out.contains("User:"), "user role label; got: \(out)")
        XCTAssertTrue(out.contains("Gemma:"), "assistant role label; got: \(out)")
    }

    func test_expand_empty_transcript_returns_no_detail_message() async {
        MemoryToolbox.shared.memory = makeStubMemoryClient { _ in
            (200, #"{"transcript":[],"summaryLabel":null}"#.data(using: .utf8)!)
        }
        let out = await ExpandContextTool().run(argsJSON: #"{"topic":"inexistente"}"#)
        XCTAssertTrue(out.contains("no detail found"), "got: \(out)")
    }

    func test_expand_empty_topic_is_noop() async {
        let out = await ExpandContextTool().run(argsJSON: #"{"topic":""}"#)
        XCTAssertEqual(out, "no topic given")
    }

    func test_expand_no_client_is_safe() async {
        let out = await ExpandContextTool().run(argsJSON: #"{"topic":"x"}"#)
        XCTAssertEqual(out, "memory unavailable")
    }
}
