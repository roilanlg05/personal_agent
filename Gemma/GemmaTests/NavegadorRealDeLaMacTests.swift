import XCTest
@testable import Gemma

#if os(macOS)
/// Un navegador de mentira que apunta lo que le piden, en orden.
private final class NavegadorDeMentira: NavegadorReal, @unchecked Sendable {
    let puertoCDP = 9333
    private let lock = NSLock()
    private var _llamadas: [String] = []
    var fallo: AgentBrowserInvocationFailure?
    var llamadas: [String] { lock.lock(); defer { lock.unlock() }; return _llamadas }
    private func anota(_ s: String) { lock.lock(); _llamadas.append(s); lock.unlock() }
    func asegura() async -> Result<Void, AgentBrowserInvocationFailure> {
        anota("asegura")
        if let fallo { return .failure(fallo) }
        return .success(())
    }
    func cierra() async { anota("cierra") }
}

final class NavegadorRealDeLaMacTests: XCTestCase {

    /// Un "agent-browser" de mentira: escribe en su salida el puerto CDP que recibió por entorno
    /// y los argumentos, y sale con el código que se le pida por `FALSO_SALIDA`.
    private func binarioFalso(salida: Int32 = 0) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ab-falso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ruta = dir.appendingPathComponent("agent-browser")
        try "#!/bin/sh\necho \"CDP=$AGENT_BROWSER_CDP ARGS=$*\"\nexit \(salida)\n"
            .write(to: ruta, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ruta.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return ruta.path
    }

    func test_el_subcomando_salta_la_sesion() {
        XCTAssertEqual(ChromeRealDeLaMac.subcomando(de: ["--session", "s", "open", "https://x.com", "--json"]), "open")
        XCTAssertEqual(ChromeRealDeLaMac.subcomando(de: ["open", "https://x.com"]), "open")
        XCTAssertEqual(ChromeRealDeLaMac.subcomando(de: ["--session", "s", "close", "--json"]), "close")
        XCTAssertNil(ChromeRealDeLaMac.subcomando(de: ["--session", "s"]))
        XCTAssertNil(ChromeRealDeLaMac.subcomando(de: []))
    }

    /// Ninguna bandera de automatización: es lo que deja a Google dejar entrar. Y el CDP solo
    /// escucha en localhost.
    func test_las_banderas_no_llevan_automatizacion_y_el_cdp_es_local() {
        let args = ChromeRealDeLaMac.argumentos(puerto: 9222, perfil: URL(fileURLWithPath: "/tmp/p"))
        XCTAssertTrue(args.contains("--remote-debugging-port=9222"))
        XCTAssertTrue(args.contains("--remote-debugging-address=127.0.0.1"))
        XCTAssertTrue(args.contains("--user-data-dir=/tmp/p"))
        XCTAssertFalse(args.contains { $0.contains("automation") || $0.contains("headless") },
                       "una bandera de automatización hace que Google bloquee el inicio de sesión")
    }

    func test_open_abre_el_navegador_antes_y_le_pasa_el_puerto() async throws {
        let nav = NavegadorDeMentira()
        let inv = ProcessAgentBrowserInvoker(binaryPath: try binarioFalso(), navegadorReal: nav)
        let res = await inv.invoke(arguments: ["--session", "s", "open", "https://x.com", "--json"], timeout: 10)
        let r = try XCTUnwrap(try? res.get())
        XCTAssertEqual(nav.llamadas, ["asegura"], "el navegador se abre antes del open")
        XCTAssertTrue(r.standardOutput.contains("CDP=9333"), "agent-browser tiene que recibir el puerto: \(r.standardOutput)")
    }

    func test_los_demas_comandos_llevan_el_puerto_pero_no_abren_nada() async throws {
        let nav = NavegadorDeMentira()
        let inv = ProcessAgentBrowserInvoker(binaryPath: try binarioFalso(), navegadorReal: nav)
        let res = await inv.invoke(arguments: ["--session", "s", "snapshot", "--json"], timeout: 10)
        let r = try XCTUnwrap(try? res.get())
        XCTAssertEqual(nav.llamadas, [])
        XCTAssertTrue(r.standardOutput.contains("CDP=9333"))
    }

    func test_si_el_navegador_no_abre_el_open_falla_sin_lanzar_agent_browser() async throws {
        let nav = NavegadorDeMentira()
        nav.fallo = .launchFailed("sin Chrome")
        let inv = ProcessAgentBrowserInvoker(binaryPath: try binarioFalso(), navegadorReal: nav)
        let r = await inv.invoke(arguments: ["--session", "s", "open", "https://x.com"], timeout: 10)
        guard case .failure(.launchFailed("sin Chrome")) = r else { return XCTFail("got: \(r)") }
    }

    func test_close_cierra_el_navegador_solo_si_salio_bien() async throws {
        let bien = NavegadorDeMentira()
        let invBien = ProcessAgentBrowserInvoker(binaryPath: try binarioFalso(salida: 0), navegadorReal: bien)
        _ = await invBien.invoke(arguments: ["--session", "s", "close", "--json"], timeout: 10)
        XCTAssertEqual(bien.llamadas, ["cierra"])

        let mal = NavegadorDeMentira()
        let invMal = ProcessAgentBrowserInvoker(binaryPath: try binarioFalso(salida: 1), navegadorReal: mal)
        _ = await invMal.invoke(arguments: ["--session", "s", "close", "--json"], timeout: 10)
        XCTAssertEqual(mal.llamadas, [], "si agent-browser falló al cerrar no se cierra el Chrome del usuario")
    }

    func test_sin_navegador_real_no_se_toca_el_entorno() async throws {
        let inv = ProcessAgentBrowserInvoker(binaryPath: try binarioFalso())
        let res = await inv.invoke(arguments: ["--session", "s", "open", "https://x.com"], timeout: 10)
        let r = try XCTUnwrap(try? res.get())
        XCTAssertFalse(r.standardOutput.contains("CDP=9333"))
    }
}
#endif
