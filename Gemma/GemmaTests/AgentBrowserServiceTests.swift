import XCTest
@testable import Gemma

#if os(macOS)

final class AgentBrowserServiceTests: XCTestCase {

    private func service(_ stdout: String) -> (AgentBrowserService, MockAgentBrowserInvoker) {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: stdout)
        return (AgentBrowserService(invoker: mock, sessionName: "gemma"), mock)
    }

    func test_sessioned_command_carries_the_session_and_json_flags() async {
        let (svc, mock) = service(#"{"success":true,"data":{},"error":null}"#)
        _ = await svc.run(command: ["open", "https://a.test"], sessioned: true, timeout: 5)
        XCTAssertEqual(mock.receivedArguments.first,
                       ["--session", "gemma", "open", "https://a.test", "--json"])
    }

    func test_unsessioned_command_omits_the_session_flag() async {
        let (svc, mock) = service(#"{"success":true,"data":{},"error":null}"#)
        _ = await svc.run(command: ["read", "https://a.test"], sessioned: false, timeout: 5)
        XCTAssertEqual(mock.receivedArguments.first, ["read", "https://a.test", "--json"])
    }

    func test_success_strips_lifecycle_from_data() async throws {
        let (svc, _) = service(#"{"success":true,"data":{"title":"T","lifecycle":{"reused":true}},"error":null}"#)
        guard case .ok(let data) = await svc.run(command: ["get", "title"], sessioned: true, timeout: 5)
        else { return XCTFail("esperaba .ok") }
        let fields = AgentBrowserService.fields(data)
        XCTAssertEqual(fields["title"] as? String, "T")
        XCTAssertNil(fields["lifecycle"], "lifecycle es ruido para el modelo")
    }

    /// La trampa: el CLI devuelve 0 también cuando falla.
    func test_failure_with_exit_code_zero_is_refused_not_ok() async {
        let mock = MockAgentBrowserInvoker(nextResult: .success(
            AgentBrowserInvocation(exitCode: 0,
                standardOutput: #"{"success":false,"data":null,"error":"Unknown ref: e999"}"#,
                standardError: "")))
        let svc = AgentBrowserService(invoker: mock, sessionName: "gemma")
        guard case .refused(let message) = await svc.run(command: ["click", "@e999"], sessioned: true, timeout: 5)
        else { return XCTFail("un success:false nunca es .ok") }
        XCTAssertEqual(message, "Unknown ref: e999")
    }

    func test_failure_without_an_error_message_still_refuses() async {
        let (svc, _) = service(#"{"success":false,"data":null,"error":null}"#)
        guard case .refused(let message) = await svc.run(command: ["click", "@e1"], sessioned: true, timeout: 5)
        else { return XCTFail("esperaba .refused") }
        XCTAssertFalse(message.isEmpty)
    }

    func test_empty_stdout_is_malformed() async {
        let (svc, _) = service("")
        guard case .malformed = await svc.run(command: ["snapshot"], sessioned: true, timeout: 5)
        else { return XCTFail("esperaba .malformed") }
    }

    func test_json_without_the_success_key_is_malformed() async {
        let (svc, _) = service(#"{"data":{"title":"T"}}"#)
        guard case .malformed = await svc.run(command: ["snapshot"], sessioned: true, timeout: 5)
        else { return XCTFail("esperaba .malformed") }
    }

    func test_non_json_stdout_is_malformed_and_keeps_the_raw_output() async {
        let (svc, _) = service("agent-browser: command not found")
        guard case .malformed(let raw) = await svc.run(command: ["snapshot"], sessioned: true, timeout: 5)
        else { return XCTFail("esperaba .malformed") }
        XCTAssertTrue(raw.contains("not found"))
    }

    func test_missing_binary_is_unavailable_and_flagged_as_missing() async {
        let mock = MockAgentBrowserInvoker(nextResult: .failure(.binaryNotFound(searchedPaths: ["/a"])))
        let svc = AgentBrowserService(invoker: mock, sessionName: "gemma")
        guard case .unavailable(_, let isMissing) = await svc.run(command: ["open", "x"], sessioned: true, timeout: 5)
        else { return XCTFail("esperaba .unavailable") }
        XCTAssertTrue(isMissing)
    }

    func test_timeout_is_unavailable_but_not_a_missing_binary() async {
        let mock = MockAgentBrowserInvoker(nextResult: .failure(.timedOut(seconds: 30)))
        let svc = AgentBrowserService(invoker: mock, sessionName: "gemma")
        guard case .unavailable(_, let isMissing) = await svc.run(command: ["open", "x"], sessioned: true, timeout: 5)
        else { return XCTFail("esperaba .unavailable") }
        XCTAssertFalse(isMissing)
    }

    func test_default_session_name_is_gemma() {
        XCTAssertEqual(AgentBrowserService.defaultSessionName, "gemma")
    }
}

#endif
