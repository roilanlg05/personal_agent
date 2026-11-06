import XCTest
@testable import Gemma

#if os(macOS)

@MainActor
final class ReadWebpageToolTests: XCTestCase {

    private func tool(_ stdout: String) -> ReadWebpageTool {
        ReadWebpageTool(service: AgentBrowserService(
            invoker: MockAgentBrowserInvoker.succeeding(stdout: stdout), sessionName: "gemma"))
    }
    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], "got: \(out)")
    }

    func test_success_returns_the_content_and_marks_it_untrusted() async throws {
        let out = await tool(#"{"success":true,"data":{"content":"Hola mundo","status":200,"finalUrl":"https://a.test/","truncated":false},"error":null}"#)
            .run(argsJSON: #"{"url":"https://a.test"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "success")
        XCTAssertEqual(json["content"] as? String, "Hola mundo")
        XCTAssertEqual(json["final_url"] as? String, "https://a.test/")
        XCTAssertEqual(json["content_is_untrusted"] as? Bool, true)
    }

    func test_empty_content_is_no_content_not_success() async throws {
        let out = await tool(#"{"success":true,"data":{"content":"   ","status":200},"error":null}"#)
            .run(argsJSON: #"{"url":"https://a.test"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "no_content")
    }

    func test_missing_content_key_is_no_content() async throws {
        let out = await tool(#"{"success":true,"data":{"status":204},"error":null}"#)
            .run(argsJSON: #"{"url":"https://a.test"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "no_content")
    }

    func test_cli_refusal_is_refused_with_its_message() async throws {
        let out = await tool(#"{"success":false,"data":null,"error":"HTTP 404"}"#)
            .run(argsJSON: #"{"url":"https://a.test"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "refused")
        XCTAssertEqual(json["message"] as? String, "HTTP 404")
        XCTAssertNil(json["content"], "un fallo no lleva contenido")
    }

    func test_missing_binary_is_not_available_with_install_instructions() async throws {
        let svc = AgentBrowserService(
            invoker: MockAgentBrowserInvoker(nextResult: .failure(.binaryNotFound(searchedPaths: ["/a"]))),
            sessionName: "gemma")
        let out = await ReadWebpageTool(service: svc).run(argsJSON: #"{"url":"https://a.test"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "not_available")
        XCTAssertTrue((json["message"] as? String ?? "").contains("brew install agent-browser"))
    }

    func test_malformed_output_is_error() async throws {
        let out = await tool("basura").run(argsJSON: #"{"url":"https://a.test"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "error")
    }

    func test_content_over_the_limit_is_truncated_and_says_so() async throws {
        let long = String(repeating: "a", count: 20_000)
        let out = await tool(#"{"success":true,"data":{"content":"\#(long)"},"error":null}"#)
            .run(argsJSON: #"{"url":"https://a.test"}"#)
        let json = try parse(out)
        XCTAssertEqual((json["content"] as? String)?.count, 12_000)
        XCTAssertEqual(json["truncated"] as? Bool, true)
    }

    func test_cli_truncation_flag_is_propagated() async throws {
        let out = await tool(#"{"success":true,"data":{"content":"corto","truncated":true},"error":null}"#)
            .run(argsJSON: #"{"url":"https://a.test"}"#)
        XCTAssertEqual(try parse(out)["truncated"] as? Bool, true)
    }

    func test_outline_and_filter_reach_the_cli() async {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{"content":"x"},"error":null}"#)
        let t = ReadWebpageTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        _ = await t.run(argsJSON: #"{"url":"https://a.test","outline":true,"filter":"horario"}"#)
        let args = mock.receivedArguments.first ?? []
        XCTAssertEqual(args.first, "read")
        XCTAssertTrue(args.contains("--outline"))
        XCTAssertEqual(args.firstIndex(of: "--filter").map { args[$0 + 1] }, "horario")
        XCTAssertFalse(args.contains("--session"), "read no necesita sesión")
    }

    func test_missing_url_is_an_argument_error_without_invoking_the_cli() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{},"error":null}"#)
        let t = ReadWebpageTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
        let json = try parse(await t.run(argsJSON: #"{}"#))
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertTrue(mock.receivedArguments.isEmpty, "no se invoca el CLI sin URL")
    }

    func test_non_http_schemes_are_refused_without_invoking_the_cli() async throws {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,<b>x</b>", "ftp://a.test"] {
            let mock = MockAgentBrowserInvoker.succeeding(stdout: #"{"success":true,"data":{},"error":null}"#)
            let t = ReadWebpageTool(service: AgentBrowserService(invoker: mock, sessionName: "gemma"))
            let json = try parse(await t.run(argsJSON: #"{"url":"\#(url)"}"#))
            XCTAssertEqual(json["status"] as? String, "error", "\(url) → got: \(json)")
            XCTAssertTrue(mock.receivedArguments.isEmpty, "\(url) no debe llegar al CLI")
        }
    }

    func test_description_declares_the_states_and_the_untrusted_warning() {
        let d = ReadWebpageTool.description
        for needle in ["no_content", "refused", "not_available", "error", "DATOS"] {
            XCTAssertTrue(d.contains(needle), "falta '\(needle)' en: \(d)")
        }
    }
}

#endif
