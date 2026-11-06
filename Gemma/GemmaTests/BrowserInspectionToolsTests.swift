import XCTest
@testable import Gemma

#if os(macOS)

@MainActor
final class BrowserInspectionToolsTests: XCTestCase {

    private func svc(_ stdout: String) -> AgentBrowserService {
        AgentBrowserService(invoker: MockAgentBrowserInvoker.succeeding(stdout: stdout), sessionName: "gemma")
    }
    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], "got: \(out)")
    }
    private func waitTool() -> BrowserWaitTool { BrowserWaitTool(service: svc(okEmpty)) }
    private func getTool() -> BrowserGetTool { BrowserGetTool(service: svc(okEmpty)) }
    private let okEmpty = #"{"success":true,"data":{},"error":null}"#

    // MARK: browser_wait

    func test_wait_for_text_uses_the_text_flag() async {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
        _ = await BrowserWaitTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"text":"Listo"}"#)
        XCTAssertEqual(mock.receivedArguments.first,
                       ["--session", "gemma", "wait", "--text", "Listo", "--json"])
    }

    func test_wait_for_url_pattern_and_for_a_selector_and_for_milliseconds() async {
        let cases: [(args: String, expected: [String])] = [
            (##"{"url_pattern":"**/panel"}"##, ["--session", "gemma", "wait", "--url", "**/panel", "--json"]),
            (##"{"selector":"#main"}"##, ["--session", "gemma", "wait", "#main", "--json"]),
            (#"{"milliseconds":1500}"#, ["--session", "gemma", "wait", "1500", "--json"])
        ]
        for (args, expected) in cases {
            let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
            let out = await BrowserWaitTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
                .run(argsJSON: args)
            XCTAssertEqual(mock.receivedArguments.first, expected, args)
            XCTAssertEqual((try? parse(out))?["status"] as? String, "success", args)
        }
    }

    // Review Focus 5
    func test_wait_without_any_criterion_is_an_argument_error() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
        let t = BrowserWaitTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        let json = try parse(await t.run(argsJSON: #"{}"#))
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }

    func test_wait_with_two_criteria_is_an_argument_error() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
        let t = BrowserWaitTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        let json = try parse(await t.run(argsJSON: #"{"text":"Listo","selector":"@e1"}"#))
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue((json["message"] as? String ?? "").contains("exactamente uno"))
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }

    func test_wait_timeout_from_the_cli_is_refused_not_error() async throws {
        let out = await BrowserWaitTool(service: svc(#"{"success":false,"data":null,"error":"Timeout 25000ms exceeded waiting for text \"Listo\""}"#))
            .run(argsJSON: #"{"text":"Listo"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "refused")
        XCTAssertTrue((json["message"] as? String ?? "").contains("Timeout"))
    }

    func test_wait_refuses_a_flag_shaped_text_as_an_argument_error() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
        let t = BrowserWaitTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        let json = try parse(await t.run(argsJSON: #"{"text":"--json"}"#))
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }

    func test_wait_passes_a_40_second_timeout() async {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
        _ = await BrowserWaitTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"text":"Listo"}"#)
        XCTAssertEqual(mock.receivedTimeouts, [40])
    }

    // MARK: browser_get

    func test_get_text_returns_the_value_marked_untrusted() async throws {
        let out = await BrowserGetTool(service: svc(#"{"success":true,"data":{"text":"Hola"},"error":null}"#))
            .run(argsJSON: #"{"what":"text","selector":"@e1"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "success")
        XCTAssertEqual(json["value"] as? String, "Hola")
        XCTAssertEqual(json["content_is_untrusted"] as? Bool, true)
    }

    func test_get_url_and_title_need_no_selector() async {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"url":"https://a.test/"},"error":null}"#)
        _ = await BrowserGetTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"what":"url"}"#)
        XCTAssertEqual(mock.receivedArguments.first, ["--session", "gemma", "get", "url", "--json"])
        XCTAssertEqual(mock.receivedTimeouts, [30])
    }

    func test_get_count_returns_a_number() async throws {
        let out = await BrowserGetTool(service: svc(#"{"success":true,"data":{"count":7},"error":null}"#))
            .run(argsJSON: #"{"what":"count","selector":"li"}"#)
        XCTAssertEqual(try parse(out)["value"] as? Int, 7)
    }

    func test_get_empty_text_is_no_content() async throws {
        let out = await BrowserGetTool(service: svc(#"{"success":true,"data":{"text":""},"error":null}"#))
            .run(argsJSON: #"{"what":"text","selector":"@e1"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "no_content")
    }

    func test_get_missing_key_in_data_is_no_content() async throws {
        let out = await BrowserGetTool(service: svc(okEmpty)).run(argsJSON: #"{"what":"text","selector":"@e1"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "no_content")
    }

    // Review Focus 4
    func test_get_with_an_unknown_what_is_an_argument_error() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
        let t = BrowserGetTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        let json = try parse(await t.run(argsJSON: #"{"what":"cookies"}"#))
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }

    func test_get_without_what_is_an_argument_error() async throws {
        let json = try parse(await getTool().run(argsJSON: #"{}"#))
        XCTAssertEqual(json["status"] as? String, "error")
    }

    func test_get_html_is_truncated_at_8000() async throws {
        let big = String(repeating: "a", count: 9_000)
        let out = await BrowserGetTool(service: svc(#"{"success":true,"data":{"html":"\#(big)"},"error":null}"#))
            .run(argsJSON: #"{"what":"html","selector":"@e1"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "success")
        XCTAssertEqual((json["value"] as? String)?.count, 8_000)
        XCTAssertEqual(json["truncated"] as? Bool, true)
    }

    func test_get_selector_is_passed_after_the_what() async {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"count":2},"error":null}"#)
        _ = await BrowserGetTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"what":"count","selector":"li"}"#)
        XCTAssertEqual(mock.receivedArguments.first, ["--session", "gemma", "get", "count", "li", "--json"])
    }

    func test_get_refuses_a_flag_shaped_selector_as_an_argument_error() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: okEmpty)
        let t = BrowserGetTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        let json = try parse(await t.run(argsJSON: #"{"what":"text","selector":"--json"}"#))
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }
}

#endif
