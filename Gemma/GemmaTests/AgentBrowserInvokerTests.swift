import XCTest
@testable import Gemma

#if os(macOS)
final class AgentBrowserInvokerTests: XCTestCase {

    func test_candidatePaths_prefers_homebrew_arm_before_usr_local() {
        let paths = AgentBrowserBinary.candidatePaths
        let brew = paths.firstIndex(of: "/opt/homebrew/bin/agent-browser")
        let local = paths.firstIndex(of: "/usr/local/bin/agent-browser")
        XCTAssertNotNil(brew); XCTAssertNotNil(local)
        XCTAssertLessThan(brew!, local!)
    }

    func test_resolve_prefers_the_environment_override() {
        let found = AgentBrowserBinary.resolve(
            environment: ["AGENT_BROWSER_PATH": "/custom/ab"],
            isExecutable: { $0 == "/custom/ab" || $0 == "/opt/homebrew/bin/agent-browser" })
        XCTAssertEqual(found, "/custom/ab")
    }

    func test_resolve_ignores_an_override_that_is_not_executable() {
        let found = AgentBrowserBinary.resolve(
            environment: ["AGENT_BROWSER_PATH": "/custom/ab"],
            isExecutable: { $0 == "/opt/homebrew/bin/agent-browser" })
        XCTAssertEqual(found, "/opt/homebrew/bin/agent-browser")
    }

    func test_resolve_returns_nil_when_nothing_is_executable() {
        XCTAssertNil(AgentBrowserBinary.resolve(environment: [:], isExecutable: { _ in false }))
    }

    /// El descubrimiento se controla por inyección (nada es ejecutable, el respaldo por
    /// shell no encuentra nada): la prueba no depende de que el binario real falte.
    func test_invoker_without_a_binary_reports_binaryNotFound_with_the_paths_it_tried() async {
        let invoker = ProcessAgentBrowserInvoker(
            binaryPath: "/nonexistent/agent-browser",
            environment: [:],
            isExecutable: { _ in false },
            shellLookup: { nil })
        let result = await invoker.invoke(arguments: ["--version"], timeout: 5)
        guard case .failure(.binaryNotFound(let paths)) = result else {
            return XCTFail("got: \(result)")
        }
        XCTAssertFalse(paths.isEmpty)
        XCTAssertEqual(paths.first, "/nonexistent/agent-browser")
    }

    /// Una ruta explícita rota no mata la herramienta si el binario está instalado.
    func test_invoker_falls_back_to_discovery_when_explicit_path_is_not_executable() async throws {
        let invoker = ProcessAgentBrowserInvoker(
            binaryPath: "/nonexistent/agent-browser",
            environment: [:],
            isExecutable: { $0 == "/bin/echo" },
            shellLookup: { "/bin/echo" })
        let result = await invoker.invoke(arguments: ["x"], timeout: 5)
        let run = try XCTUnwrap(try? result.get())
        XCTAssertEqual(run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "x")
    }

    func test_invoker_uses_shell_lookup_when_no_fixed_path_works() async throws {
        let invoker = ProcessAgentBrowserInvoker(
            binaryPath: nil,
            environment: [:],
            isExecutable: { $0 == "/bin/echo" },
            shellLookup: { "/bin/echo" })
        let result = await invoker.invoke(arguments: ["via", "shell"], timeout: 10)
        let run = try XCTUnwrap(try? result.get())
        XCTAssertEqual(run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "via shell")
    }

    /// Usa `/bin/echo` como binario para probar la fontanería sin depender de agent-browser.
    func test_invoker_returns_stdout_and_exit_code() async throws {
        let invoker = ProcessAgentBrowserInvoker(binaryPath: "/bin/echo")
        let result = await invoker.invoke(arguments: ["hola", "mundo"], timeout: 10)
        let run = try XCTUnwrap(try? result.get())
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "hola mundo")
    }

    /// Más de 64 KiB: si las tuberías no se vacían mientras el hijo vive, esto no termina.
    func test_invoker_reads_output_larger_than_the_pipe_buffer() async throws {
        let invoker = ProcessAgentBrowserInvoker(binaryPath: "/bin/sh")
        let result = await invoker.invoke(
            arguments: ["-c", "yes abcdefghij | head -c 300000"], timeout: 30)
        let run = try XCTUnwrap(try? result.get())
        XCTAssertGreaterThan(run.standardOutput.count, 200_000)
    }

    func test_invoker_times_out_and_reports_it() async {
        let invoker = ProcessAgentBrowserInvoker(binaryPath: "/bin/sleep")
        let result = await invoker.invoke(arguments: ["5"], timeout: 0.3)
        guard case .failure(.timedOut) = result else { return XCTFail("got: \(result)") }
    }

    func test_mock_records_arguments_and_returns_programmed_result() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: "{}")
        let result = await mock.invoke(arguments: ["open", "https://x"], timeout: 1)
        XCTAssertEqual(try result.get().standardOutput, "{}")
        XCTAssertEqual(mock.receivedArguments, [["open", "https://x"]])
    }
}
#endif
