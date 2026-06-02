import XCTest
@testable import Gemma

@MainActor
final class ReflectToolTests: XCTestCase {
    override func tearDown() {
        MemoryToolbox.shared.reflectionRequest = nil
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    func test_reflect_tool_requests_light_reflection_locally() async {
        var requested = false
        MemoryToolbox.shared.reflectionRequest = { requested = true }
        let out = await ReflectTool().run(argsJSON: "{}")
        XCTAssertTrue(requested)
        XCTAssertFalse(out.isEmpty)
    }

    func test_reflect_tool_hits_remote_reflect_endpoint_when_client_present() async {
        var sawPath: String?
        MemoryToolbox.shared.memory = makeStubMemoryClient { req in
            sawPath = req.url?.path
            return (200, #"{"cycleId":"c-1"}"#.data(using: .utf8)!)
        }
        _ = await ReflectTool().run(argsJSON: "{}")
        XCTAssertEqual(sawPath, "/v1/consolidation/reflect")
    }

    func test_reflect_tool_no_handler_is_safe() async {
        let out = await ReflectTool().run(argsJSON: "{}")
        XCTAssertFalse(out.isEmpty)
    }
}
