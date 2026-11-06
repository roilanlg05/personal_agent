import XCTest
@testable import Gemma

#if os(macOS)

@MainActor
final class BrowserNavigationToolsTests: XCTestCase {

    private func svc(_ stdout: String) -> AgentBrowserService {
        AgentBrowserService(invoker: MockAgentBrowserInvoker.succeeding(stdout: stdout), sessionName: "gemma")
    }
    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], "got: \(out)")
    }

    // MARK: browser_open

    func test_open_returns_the_title_and_url() async throws {
        let out = await BrowserOpenTool(service: svc(#"{"success":true,"data":{"title":"Ejemplo","url":"https://a.test/"},"error":null}"#))
            .run(argsJSON: #"{"url":"https://a.test"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "success")
        XCTAssertEqual(json["title"] as? String, "Ejemplo")
        XCTAssertEqual(json["url"] as? String, "https://a.test/")
    }

    func test_open_uses_the_gemma_session() async {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"title":"T","url":"u"},"error":null}"#)
        _ = await BrowserOpenTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"url":"https://a.test"}"#)
        XCTAssertEqual(mock.receivedArguments.first,
                       ["--session", "gemma", "open", "https://a.test", "--json"])
    }

    func test_open_refuses_non_http_schemes_without_invoking_the_cli() async throws {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,<b>x</b>"] {
            let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{},"error":null}"#)
            let out = await BrowserOpenTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
                .run(argsJSON: ToolJSONOutput.object(["url": url]))
            let json = try parse(out)
            XCTAssertEqual(json["status"] as? String, "error", url)
            XCTAssertTrue(mock.receivedArguments.isEmpty, "CLI invoked for \(url)")
        }
    }

    func test_open_without_url_is_an_argument_error() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{},"error":null}"#)
        let out = await BrowserOpenTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue((json["message"] as? String ?? "").contains("url"))
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }

    // MARK: browser_snapshot

    func test_snapshot_returns_the_tree_and_the_refs_marked_untrusted() async throws {
        let out = await BrowserSnapshotTool(service: svc(#"{"success":true,"data":{"snapshot":"- link \"Más\" [ref=e1]","refs":{"e1":{"name":"Más","role":"link"}},"origin":"https://a.test/"},"error":null}"#))
            .run(argsJSON: #"{}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "success")
        XCTAssertTrue((json["snapshot"] as? String ?? "").contains("ref=e1"))
        XCTAssertEqual(json["element_count"] as? Int, 1)
        XCTAssertEqual(json["content_is_untrusted"] as? Bool, true)
    }

    func test_snapshot_defaults_to_interactive_only() async {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"snapshot":"x","refs":{}},"error":null}"#)
        _ = await BrowserSnapshotTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma")).run(argsJSON: #"{}"#)
        XCTAssertTrue((mock.receivedArguments.first ?? []).contains("-i"))
    }

    func test_snapshot_full_tree_when_asked_and_scopes_to_a_selector() async {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"snapshot":"x","refs":{}},"error":null}"#)
        _ = await BrowserSnapshotTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: ##"{"interactive_only":false,"selector":"#main"}"##)
        let args = mock.receivedArguments.first ?? []
        XCTAssertFalse(args.contains("-i"))
        XCTAssertEqual(args.firstIndex(of: "-s").map { args[$0 + 1] }, "#main")
    }

    func test_snapshot_rejects_a_selector_the_cli_would_eat_as_a_flag() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"snapshot":"x","refs":{}},"error":null}"#)
        let out = await BrowserSnapshotTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            .run(argsJSON: #"{"selector":"--json"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "error")
        XCTAssertTrue(mock.receivedArguments.isEmpty)
    }

    func test_empty_snapshot_is_no_content() async throws {
        let out = await BrowserSnapshotTool(service: svc(#"{"success":true,"data":{"snapshot":"","refs":{}},"error":null}"#))
            .run(argsJSON: #"{}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "no_content")
    }

    func test_missing_snapshot_key_is_no_content() async throws {
        let out = await BrowserSnapshotTool(service: svc(#"{"success":true,"data":null,"error":null}"#))
            .run(argsJSON: #"{}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "no_content")
    }

    func test_long_snapshot_is_truncated_at_8000_with_a_hint() async throws {
        let long = String(repeating: "a", count: 9_000)
        let envelope = ToolJSONOutput.object(["success": true, "data": ["snapshot": long, "refs": [String: Any]()], "error": nil])
        let out = await BrowserSnapshotTool(service: svc(envelope))
            .run(argsJSON: #"{}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "success")
        XCTAssertEqual((json["snapshot"] as? String)?.count, 8_000)
        XCTAssertEqual(json["truncated"] as? Bool, true)
        XCTAssertTrue((json["message"] as? String ?? "").contains("selector"))
    }

    func test_short_snapshot_is_not_truncated() async throws {
        let out = await BrowserSnapshotTool(service: svc(#"{"success":true,"data":{"snapshot":"x","refs":{}},"error":null}"#))
            .run(argsJSON: #"{}"#)
        let json = try parse(out)
        XCTAssertEqual(json["truncated"] as? Bool, false)
        XCTAssertNil(json["message"])
    }

    func test_snapshot_without_an_open_page_is_refused() async throws {
        let out = await BrowserSnapshotTool(service: svc(#"{"success":false,"data":null,"error":"No active page"}"#))
            .run(argsJSON: #"{}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "refused")
        XCTAssertEqual(json["message"] as? String, "No active page")
    }

    // MARK: browser_close

    func test_close_reports_success_and_takes_no_parameters() async throws {
        let out = await BrowserCloseTool(service: svc(#"{"success":true,"data":{},"error":null}"#)).run(argsJSON: #"{}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "success")
        XCTAssertTrue(BrowserCloseTool.parameters.isEmpty)
    }

    func test_close_uses_the_session() async {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{},"error":null}"#)
        _ = await BrowserCloseTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma")).run(argsJSON: #"{}"#)
        XCTAssertEqual(mock.receivedArguments.first, ["--session", "gemma", "close", "--json"])
    }

    // MARK: descriptions

    func test_all_three_descriptions_declare_the_states() {
        let descriptions = [BrowserOpenTool.description, BrowserSnapshotTool.description, BrowserCloseTool.description]
        for d in descriptions {
            for state in ["success", "refused", "not_available", "error"] {
                XCTAssertTrue(d.contains("'\(state)'"), "missing \(state) in: \(d.prefix(60))")
            }
            XCTAssertTrue(d.contains(AgentBrowserToolOutput.honestyNotice))
        }
        XCTAssertTrue(BrowserSnapshotTool.description.contains("'no_content'"))
        XCTAssertTrue(BrowserSnapshotTool.description.contains(AgentBrowserToolOutput.untrustedContentNotice))
        XCTAssertTrue(BrowserSnapshotTool.description.contains("@e"))
        XCTAssertTrue(BrowserSnapshotTool.description.contains("navegación"))
    }
}

#endif
