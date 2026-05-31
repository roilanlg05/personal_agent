import XCTest
@testable import Gemma

@MainActor
final class ReflectToolTests: XCTestCase {
    override func tearDown() { MemoryToolbox.shared.reflectionRequest = nil; super.tearDown() }
    func test_reflect_tool_requests_light_reflection() async {
        var requested = false
        MemoryToolbox.shared.reflectionRequest = { requested = true }
        let out = await ReflectTool().run(argsJSON: "{}")
        XCTAssertTrue(requested)
        XCTAssertFalse(out.isEmpty)
    }
    func test_reflect_tool_no_handler_is_safe() async {
        let out = await ReflectTool().run(argsJSON: "{}")
        XCTAssertFalse(out.isEmpty)   // returns a benign ack, no crash
    }
}
