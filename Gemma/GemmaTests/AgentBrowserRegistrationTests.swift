import XCTest
@testable import Gemma

#if os(macOS)

/// Comprueba que las nueve herramientas de navegador quedan registradas y que el prompt
/// del sistema enseña al modelo a usarlas. `browserToolRegistry()` usa el mismo método
/// (`registerBrowserTools(into:)`) que `runAgentTurn`, así que no puede divergir de un turno real.
@MainActor
final class AgentBrowserRegistrationTests: XCTestCase {

    private let names = ["read_webpage", "browser_open", "browser_snapshot", "browser_click",
                         "browser_fill", "browser_press", "browser_wait", "browser_get", "browser_close"]

    func test_the_nine_browser_tools_are_registered() {
        let registry = HarnessModel.browserToolRegistry()
        for name in names {
            XCTAssertNotNil(registry.tool(named: name), "falta \(name)")
        }
        XCTAssertEqual(registry.tools.count, names.count)
    }

    func test_every_browser_tool_has_a_valid_function_spec() {
        for tool in HarnessModel.browserToolRegistry().tools {
            let t = type(of: tool)
            XCTAssertFalse(t.name.isEmpty)
            XCTAssertFalse(t.description.isEmpty, "\(t.name) sin descripción")
            XCTAssertEqual(t.jsonSchema["type"] as? String, "object", "\(t.name) con esquema inválido")
        }
    }

    func test_registering_into_an_existing_registry_adds_the_nine_tools() {
        let registry = ToolRegistry()
        registry.register(WebSearchTool())
        HarnessModel.registerBrowserTools(into: registry)
        XCTAssertEqual(registry.tools.count, names.count + 1)
        XCTAssertNotNil(registry.tool(named: "web_search"))
    }

    func test_system_prompt_points_web_search_at_read_webpage() {
        let prompt = Agent.systemPromptText
        XCTAssertTrue(prompt.contains("read_webpage"))
        XCTAssertTrue(prompt.contains("browser_snapshot"))
        XCTAssertTrue(prompt.contains("browser_open"))
    }
}

#endif
