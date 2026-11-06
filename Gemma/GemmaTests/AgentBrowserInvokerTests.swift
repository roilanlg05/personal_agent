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

    /// Mide también el plazo: devolver `.timedOut` tarde (esperando a que el hijo acabe
    /// solo) era el fallo original, y el resultado por sí solo no lo delata.
    func test_invoker_times_out_and_reports_it() async {
        let invoker = ProcessAgentBrowserInvoker(binaryPath: "/bin/sleep")
        let start = ContinuousClock.now
        let result = await invoker.invoke(arguments: ["5"], timeout: 0.3)
        let elapsed = ContinuousClock.now - start
        guard case .failure(.timedOut) = result else { return XCTFail("got: \(result)") }
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    /// Un hijo que ignora SIGTERM (un CLI de Node con su propio manejador) no debe
    /// dejar la llamada colgada: `invoke` vuelve en torno al plazo, y el hijo acaba
    /// muriendo por SIGKILL tras el periodo de gracia.
    func test_invoker_returns_at_the_deadline_and_kills_a_child_that_ignores_sigterm() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ab-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let invoker = ProcessAgentBrowserInvoker(binaryPath: "/bin/sh")
        let start = ContinuousClock.now
        let result = await invoker.invoke(
            arguments: ["-c", "echo $$ > '\(pidFile.path)'; trap '' TERM; while :; do sleep 1; done"],
            timeout: 0.5)
        let elapsed = ContinuousClock.now - start
        guard case .failure(.timedOut) = result else { return XCTFail("got: \(result)") }
        XCTAssertLessThan(elapsed, .seconds(2))

        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        // Gracia de SIGKILL (2 s) más margen.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertNotEqual(kill(pid, 0), 0, "el hijo sigue vivo tras el SIGKILL")
    }

    /// El padre sale y deja un nieto con las tuberías abiertas (un demonio del navegador):
    /// no llega EOF, pero la llamada no debe esperarlo y debe conservar la salida.
    func test_invoker_returns_when_a_daemon_keeps_the_pipes_open() async throws {
        let invoker = ProcessAgentBrowserInvoker(binaryPath: "/bin/sh")
        let start = ContinuousClock.now
        let result = await invoker.invoke(
            arguments: ["-c", "echo listo; sleep 5 & exit 0"], timeout: 10)
        let elapsed = ContinuousClock.now - start
        let run = try XCTUnwrap(try? result.get())
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "listo")
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func test_mock_records_arguments_and_returns_programmed_result() async throws {
        let mock = MockAgentBrowserInvoker.succeeding(stdout: "{}")
        let result = await mock.invoke(arguments: ["open", "https://x"], timeout: 1)
        XCTAssertEqual(try result.get().standardOutput, "{}")
        XCTAssertEqual(mock.receivedArguments, [["open", "https://x"]])
    }

    /// La spec §6.1 dice de la búsqueda que «se resuelve una vez y se recuerda». No lo hacía:
    /// `locateBinary()` corría en cada `invoke`.
    func test_invoker_resolves_the_binary_only_once_across_calls() async {
        let probed = Mutex<[String]>([])
        let invoker = ProcessAgentBrowserInvoker(
            binaryPath: "/bin/echo",
            environment: [:],
            isExecutable: { path in probed.write { $0.append(path) }; return path == "/bin/echo" },
            shellLookup: { nil })
        _ = await invoker.invoke(arguments: ["uno"], timeout: 10)
        let afterFirst = probed.read { $0.count }
        _ = await invoker.invoke(arguments: ["dos"], timeout: 10)
        XCTAssertEqual(afterFirst, 1, "la primera llamada acierta con la ruta explícita")
        XCTAssertEqual(probed.read { $0.count }, afterFirst,
                       "la segunda llamada volvió a resolver: \(probed.read { $0 })")
    }

    /// El negativo es el caso que de verdad importa: sin memoria, cada llamada caía hasta
    /// `/bin/sh -lc "command -v agent-browser"`, que carga el perfil de login completo del
    /// usuario y tiene sus propios 5 s FUERA del plazo del llamante.
    func test_invoker_does_not_reprobe_the_shell_after_a_missing_binary() async {
        let shellLookups = Mutex(0)
        let invoker = ProcessAgentBrowserInvoker(
            binaryPath: nil,
            environment: [:],
            isExecutable: { _ in false },
            shellLookup: { shellLookups.write { $0 += 1 }; return nil })
        let first = await invoker.invoke(arguments: ["--version"], timeout: 5)
        let second = await invoker.invoke(arguments: ["--version"], timeout: 5)
        guard case .failure(.binaryNotFound) = first, case .failure(.binaryNotFound) = second else {
            return XCTFail("ambas llamadas deben seguir reportando binaryNotFound: \(first), \(second)")
        }
        XCTAssertEqual(shellLookups.read { $0 }, 1, "el respaldo por shell se repitió")
    }
}
#endif

