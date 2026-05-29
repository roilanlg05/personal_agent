import XCTest
@testable import Gemma

@MainActor
final class ToolCallingRuntimeTests: XCTestCase {
    func test_activityRelay_forwardsToSink() {
        var seen: [String] = []
        let relay = ToolActivityRelay()
        relay.sink = { event in
            switch event {
            case .started(let name, _): seen.append("start:\(name)")
            case .finished(let name, _): seen.append("done:\(name)")
            }
        }
        relay.started(name: "Clock", args: "{}")
        relay.finished(name: "Clock", result: "12:00")
        XCTAssertEqual(seen, ["start:Clock", "done:Clock"])
    }
    func test_activityRelay_noSink_doesNotCrash() {
        let relay = ToolActivityRelay()
        relay.started(name: "X", args: "{}")
        relay.finished(name: "X", result: "")
    }
}
