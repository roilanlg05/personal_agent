import XCTest
@testable import Gemma

#if os(macOS)

/// Comprueba que las nueve herramientas de navegador quedan registradas y que el prompt
/// del sistema enseña al modelo a usarlas. `browserToolRegistry()` y `runAgentTurn` comparten
/// la lista de herramientas (`registerBrowserTools(into:)`), pero que `runAgentTurn` llame a ese
/// método no lo prueba un registro: lo fija `test_run_agent_turn_calls_registerBrowserTools`
/// leyendo el código fuente.
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

    func test_run_agent_turn_calls_registerBrowserTools() throws {
        // Fija la llamada en runAgentTurn leyendo el fuente: construir un turno real exige
        // un runtime y un servicio de memoria. Frágil a propósito ante renombrados.
        let testFile = URL(fileURLWithPath: #filePath)
        let source = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Gemma/Harness/HarnessModel.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(text.contains("Self.registerBrowserTools(into: registry,"),
                      "runAgentTurn ya no llama a registerBrowserTools: un turno real no registraría ninguna herramienta de navegador")
        // La propiedad que de verdad hay que clavar: el permiso para cerrar sale del MENSAJE
        // DEL USUARIO de este turno, y de ningún otro sitio. Si alguien lo cablea a un `true`
        // constante, o lo lee de una preferencia, vuelve el defecto que costó tres rondas (el
        // agente cerrándole la página que el usuario había pedido para leer) y este test es lo
        // único que lo vería.
        XCTAssertTrue(text.contains("userAskedToClose: BrowserCloseIntent.userAskedToClose(prompt)"),
                      "el permiso para cerrar el navegador debe salir del mensaje del usuario de este turno")
    }

    func test_system_prompt_teaches_reading_pages_and_the_interactive_loop() throws {
        let prompt = Agent.systemPromptText
        for phrase in ["`read_webpage(url)` reads the WHOLE page",
                       "call `read_webpage` on the best result BEFORE answering",
                       "`@eN` reference",
                       "`browser_snapshot` again to see the new state",
                       "NEVER reuse an old one"] {
            XCTAssertTrue(prompt.contains(phrase), "al prompt le falta: \(phrase)")
        }
        let open = try XCTUnwrap(prompt.range(of: "`browser_open(url)`"), "falta browser_open(url)")
        let snap = try XCTUnwrap(prompt.range(of: "`browser_snapshot`", range: open.upperBound..<prompt.endIndex),
                                 "browser_snapshot no aparece después de browser_open")
        XCTAssertLessThan(open.lowerBound, snap.lowerBound)
    }
}

#endif
