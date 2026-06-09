import XCTest
@testable import Gemma

@MainActor
final class UpdateEventToolTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    func test_update_event_tool_reports_not_found() async {
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            XCTAssertEqual(req.url?.path, "/v1/schedule/update")
            return (200, #"{"updated":false,"notFound":true}"#.data(using: .utf8)!)
        }
        let out = await UpdateEventTool().run(argsJSON: #"{"start":"2099-06-09T15:00","title":"ghost"}"#)
        XCTAssertTrue(out.lowercased().contains("couldn't find"), "Expected not-found copy, got: \(out)")
    }

    func test_update_event_tool_echoes_updated_event() async {
        MemoryToolbox.shared.memory = makeStubMemoryClient { _ in
            (200, #"{"updated":true,"event":{"id":"x","title":"meeting","start":9000,"end":9600,"allDay":false,"location":"Miami","status":"scheduled"}}"#.data(using: .utf8)!)
        }
        let out = await UpdateEventTool().run(argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","location":"Miami"}"#)
        XCTAssertTrue(out.contains("Updated"), "got: \(out)")
        XCTAssertTrue(out.contains("Miami"), "got: \(out)")
    }

    func test_update_event_tool_conflict_asks() async {
        MemoryToolbox.shared.memory = makeStubMemoryClient { _ in
            (200, #"{"updated":false,"conflicts":[{"id":"d","title":"dentist","start":3000,"end":3600,"allDay":false,"status":"scheduled"}]}"#.data(using: .utf8)!)
        }
        let out = await UpdateEventTool().run(argsJSON: #"{"start":"2099-06-09T15:00","title":"meeting","newStart":"2099-06-09T11:00","newEnd":"2099-06-09T12:00"}"#)
        XCTAssertTrue(out.contains("NOT changed"), "got: \(out)")
        XCTAssertTrue(out.contains("dentist"), "got: \(out)")
    }

    func test_update_event_tool_no_client_is_safe() async {
        let out = await UpdateEventTool().run(argsJSON: #"{"start":"2099-06-09T15:00"}"#)
        XCTAssertEqual(out, "memory unavailable")
    }
}
