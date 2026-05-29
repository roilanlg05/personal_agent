import XCTest
@testable import Gemma
import LiteRTLM

@MainActor
final class ToolRegistryTests: XCTestCase {
    func test_empty_byDefault() {
        XCTAssertTrue(ToolRegistry().tools.isEmpty)
    }
    func test_register_addsTool() {
        let r = ToolRegistry()
        r.register(CurrentTimeTool())
        XCTAssertEqual(r.tools.count, 1)
        XCTAssertEqual(type(of: r.tools[0]).name, "get_current_time")
    }
    func test_registerDefaults_includesCurrentTime() {
        let r = ToolRegistry.withDefaults()
        XCTAssertTrue(r.tools.contains { type(of: $0).name == "get_current_time" })
    }
}
