import XCTest
@testable import Gemma

#if os(macOS)

@MainActor
final class BrowserInteractionToolsTests: XCTestCase {

    private func svc(_ stdout: String) -> AgentBrowserService {
        AgentBrowserService(invoker: MockAgentBrowserInvoker.succeeding(stdout: stdout), sessionName: "gemma")
    }
    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], "got: \(out)")
    }
    private let okEmpty = #"{"success":true,"data":{},"error":null}"#
    private let okFilled = #"{"success":true,"data":{"filled":"@e2"},"error":null}"#

    // MARK: browser_click

    func test_click_passes_the_ref_through() async {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
        _ = await BrowserClickTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e3"}"#)
        XCTAssertEqual(mock.receivedArguments.first, ["--session", "gemma", "click", "@e3", "--json"])
    }

    func test_click_succeeds_with_status_success() async throws {
        let out = await BrowserClickTool(service: svc(okEmpty)).run(argsJSON: #"{"selector":"@e3"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "success")
    }

    func test_click_on_an_unknown_ref_is_refused_with_the_cli_message() async throws {
        let out = await BrowserClickTool(service: svc(#"{"success":false,"data":null,"error":"Unknown ref: e999"}"#))
            .run(argsJSON: #"{"selector":"@e999"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "refused")
        XCTAssertEqual(json["message"] as? String, "Unknown ref: e999")
    }

    func test_click_without_selector_is_an_argument_error() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
        let out = await BrowserClickTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue((json["message"] as? String ?? "").contains("selector"))
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }

    func test_click_refuses_a_selector_the_cli_would_eat_as_a_flag() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
        let out = await BrowserClickTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"--json"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "error")
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }

    // MARK: browser_fill

    func test_fill_sends_selector_then_text() async {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okFilled)
        _ = await BrowserFillTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e2","text":"hola"}"#)
        XCTAssertEqual(mock.receivedArguments.first,
                       ["--session", "gemma", "fill", "@e2", "hola", "--json"])
    }

    func test_fill_accepts_text_that_merely_starts_with_a_dash() async throws {
        // "-abc" llega entero al navegador (verificado en vivo): debe invocarse el CLI.
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okFilled)
        let out = await BrowserFillTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e2","text":"-abc"}"#)
        XCTAssertEqual(mock.receivedArguments.first,
                       ["--session", "gemma", "fill", "@e2", "-abc", "--json"])
        XCTAssertEqual(try parse(out)["status"] as? String, "success")
    }

    // Review Focus 1
    func test_fill_refuses_text_that_the_cli_would_eat_as_a_flag() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okFilled)
        let t = BrowserFillTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        let json = try parse(await t.run(argsJSON: #"{"selector":"@e2","text":"--json"}"#))
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue(mock.receivedArguments.isEmpty,
                      "el CLI se comería --json como flag y rellenaría el campo vacío reportando éxito")
    }

    func test_fill_refuses_a_selector_the_cli_would_eat_as_a_flag() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okFilled)
        let t = BrowserFillTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        let json = try parse(await t.run(argsJSON: #"{"selector":"--session","text":"hola"}"#))
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }

    // Review Focus 4
    func test_fill_without_text_is_an_argument_error() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okFilled)
        let out = await BrowserFillTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e2"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue((json["message"] as? String ?? "").contains("text"))
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }

    func test_fill_without_selector_is_an_argument_error() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okFilled)
        let out = await BrowserFillTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"text":"hola"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue((json["message"] as? String ?? "").contains("selector"))
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }

    func test_fill_with_empty_text_clears_the_field_and_is_allowed() async throws {
        // `fill <sel> ""` es la forma de vaciar un campo: debe llegar al CLI.
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okFilled)
        let out = await BrowserFillTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e2","text":""}"#)
        XCTAssertEqual(mock.receivedArguments.first,
                       ["--session", "gemma", "fill", "@e2", "", "--json"])
        XCTAssertEqual(try parse(out)["status"] as? String, "success")
    }

    func test_fill_description_forbids_passwords() {
        let d = BrowserFillTool.description.lowercased()
        XCTAssertTrue(d.contains("contraseñ"))
        XCTAssertTrue(d.contains("token"))
        XCTAssertTrue(d.contains("pide"))
    }

    // MARK: browser_press

    func test_press_passes_the_key_combo() async {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
        _ = await BrowserPressTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"key":"Control+a"}"#)
        XCTAssertEqual(mock.receivedArguments.first, ["--session", "gemma", "press", "Control+a", "--json"])
    }

    func test_press_without_key_is_an_argument_error() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
        let out = await BrowserPressTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue((json["message"] as? String ?? "").contains("key"))
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }

    func test_press_refuses_a_key_the_cli_would_eat_as_a_flag() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
        let out = await BrowserPressTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"key":"--json"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "error")
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }

    func test_press_reports_binary_missing_as_not_available() async throws {
        let mock = MockAgentBrowserInvoker(nextResult: .failure(.binaryNotFound(searchedPaths: ["/x"])))
        let out = await BrowserPressTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"key":"Enter"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "not_available")
    }

    // MARK: la URL posterior a la accion (lo que alimenta el corte de la cola)

    /// Medido contra el CLI 0.41.2: ni `click --help`, ni `references/commands.md`, ni la guia
    /// oficial documentan una URL en la salida de `click`/`fill`/`press`, y en la tabla de
    /// cadenas del binario las claves vecinas del manejador de `click` son `clicked`, `newTab`
    /// y `dialogOpened`, sin URL. Aun asi, si una version del CLI la trajera, es un dato que ya
    /// viaja: se propaga sin pedir nada mas. Esta prueba fija ese camino gratis.
    private let okClickConURL =
        #"{"success":true,"data":{"clicked":true,"url":"https://b.test/destino"},"error":null}"#
    private let okGetURL = #"{"success":true,"data":{"url":"https://b.test/destino"},"error":null}"#

    func test_click_propagates_the_url_the_cli_already_gives() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdouts: [okClickConURL])
        let out = await BrowserClickTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e3"}"#)
        XCTAssertEqual(try parse(out)["url"] as? String, "https://b.test/destino")
        XCTAssertEqual(mock.receivedArguments.count, 1,
                       "si la accion ya trae la URL no se gasta una segunda orden: \(mock.receivedArguments)")
    }

    func test_click_asks_the_url_itself_when_the_cli_does_not_give_it() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdouts: [okEmpty, okGetURL])
        let out = await BrowserClickTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e3"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "success")
        XCTAssertEqual(json["url"] as? String, "https://b.test/destino")
        XCTAssertEqual(mock.receivedArguments.count, 2, "falta la orden que averigua la URL")
        XCTAssertEqual(mock.receivedArguments.last, ["--session", "gemma", "get", "url", "--json"])
    }

    func test_fill_asks_the_url_itself_when_the_cli_does_not_give_it() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdouts: [okFilled, okGetURL])
        let out = await BrowserFillTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e2","text":"hola"}"#)
        XCTAssertEqual(try parse(out)["url"] as? String, "https://b.test/destino")
        XCTAssertEqual(mock.receivedArguments.last, ["--session", "gemma", "get", "url", "--json"])
    }

    func test_press_asks_the_url_itself_when_the_cli_does_not_give_it() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdouts: [okEmpty, okGetURL])
        let out = await BrowserPressTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"key":"Enter"}"#)
        XCTAssertEqual(try parse(out)["url"] as? String, "https://b.test/destino")
        XCTAssertEqual(mock.receivedArguments.last, ["--session", "gemma", "get", "url", "--json"])
    }

    /// La direccion segura del proyecto, aqui: lo que no se pudo leer NO se inventa. Sin URL en
    /// el resultado, `Agent.cortaLaCola` cae en su rama que no corta, que es el lado barato.
    func test_an_unreadable_url_is_left_out_instead_of_guessed() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(
            stdouts: [okEmpty, #"{"success":false,"data":null,"error":"Browser not launched"}"#])
        let out = await BrowserClickTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e3"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "success", "el clic si ocurrio: su estado no cambia")
        XCTAssertNil(json["url"], "una URL que no se pudo leer no se reporta: \(out)")
    }

    func test_an_absurd_url_is_not_reported_as_the_page() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(
            stdouts: [okEmpty, #"{"success":true,"data":{"url":"ni-idea"},"error":null}"#])
        let out = await BrowserClickTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e3"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "success")
        XCTAssertNil(json["url"], "'ni-idea' no es una pagina: no puede fabricar un corte: \(out)")
    }

    /// Una accion que no ocurrio no movio la pagina: preguntar la URL seria gastar un viaje al
    /// navegador para nada (y en el i3 es un viaje de red).
    func test_a_refused_action_does_not_ask_for_the_url() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":false,"data":null,"error":"Unknown ref: e999"}"#)
        let out = await BrowserClickTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e999"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "refused")
        XCTAssertEqual(mock.receivedArguments.count, 1, "no hay nada que averiguar: \(mock.receivedArguments)")
    }

    /// Por que existe todo lo anterior: la cola solo se corta si el resultado DEMUESTRA que la
    /// pagina es otra, y hasta ahora el clic no lo demostraba nunca. El caso recorre el camino
    /// completo —herramienta real, salida real, decision real— en vez de afirmar un campo suelto.
    func test_a_click_that_navigates_now_cuts_the_queue() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdouts: [okEmpty, okGetURL])
        let out = await BrowserClickTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e3"}"#)
        XCTAssertTrue(Agent.cortaLaCola(trasHerramienta: "browser_click",
                                        resultado: out,
                                        urlConocida: "https://a.test/origen"),
                      "el clic navego a otra pagina y la cola sigue viva: \(out)")
    }

    func test_a_click_that_stays_on_the_same_page_does_not_cut_the_queue() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdouts: [okEmpty, okGetURL])
        let out = await BrowserClickTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e3"}"#)
        XCTAssertFalse(Agent.cortaLaCola(trasHerramienta: "browser_click",
                                         resultado: out,
                                         urlConocida: "https://b.test/destino"),
                       "la pagina no se movio: cortar costaria una ronda por nada: \(out)")
    }

    // MARK: plazos (el mock no registra el timeout; se fijan las constantes)

    func test_all_interaction_tools_use_a_30_second_timeout() {
        XCTAssertEqual(BrowserClickTool.timeout, 30)
        XCTAssertEqual(BrowserFillTool.timeout, 30)
        XCTAssertEqual(BrowserPressTool.timeout, 30)
    }

    /// Averiguar la URL es una lectura inmediata del navegador, no un trabajo de pagina: con el
    /// plazo de la accion un `get url` colgado doblaria la espera del turno.
    func test_the_url_lookup_gets_a_shorter_deadline_than_the_action() async {
        let mock = MockAgentBrowserInvoker.succeeding(stdouts: [okEmpty, okGetURL])
        _ = await BrowserClickTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"@e3"}"#)
        XCTAssertEqual(mock.receivedTimeouts, [30, 10])
    }
}

#endif
