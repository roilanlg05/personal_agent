import XCTest
@testable import Gemma

final class NodeAttributesTests: XCTestCase {
    func test_round_trip_status_and_horizon() {
        var a = NodeAttributes()
        a.status = "pending"; a.horizon = "long"
        let json = a.toJSON()
        let back = NodeAttributes.from(json)
        XCTAssertEqual(back.status, "pending")
        XCTAssertEqual(back.horizon, "long")
    }
    func test_from_nil_or_garbage_is_empty() {
        XCTAssertNil(NodeAttributes.from(nil).status)
        XCTAssertNil(NodeAttributes.from("not json").horizon)
    }
}
