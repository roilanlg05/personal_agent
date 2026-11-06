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

    // MARK: plazos (el mock no registra el timeout; se fijan las constantes)

    func test_all_interaction_tools_use_a_30_second_timeout() {
        XCTAssertEqual(BrowserClickTool.timeout, 30)
        XCTAssertEqual(BrowserFillTool.timeout, 30)
        XCTAssertEqual(BrowserPressTool.timeout, 30)
    }
}

#endif
