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
    /// Lo que contesta `cierra()`: `false` simula un Chrome que sigue vivo tras el SIGTERM.
    var cierraBien = true
    func cierra() async -> Bool { anota("cierra"); return cierraBien }
}

/// El "sistema" de mentira para `ChromeRealDeLaMac`: una lista de procesos, las señales que se
/// mandan (apuntadas, nunca enviadas de verdad) y un puerto que contesta o no.
private final class SistemaDeMentira: @unchecked Sendable {
    private let lock = NSLock()
    private var _procesos: [ProcesoDelSistema]
    private var _senales: [(pid_t, Int32)] = []
    private var _puertoAbierto: Bool
    /// Si es `true`, la señal NO cierra nada: el Chrome que no se deja cerrar.
    let sordo: Bool

    init(procesos: [ProcesoDelSistema] = [], puertoAbierto: Bool, sordo: Bool = false) {
        _procesos = procesos; _puertoAbierto = puertoAbierto; self.sordo = sordo
    }
    var senales: [(pid_t, Int32)] { lock.lock(); defer { lock.unlock() }; return _senales }
    func procesos() -> [ProcesoDelSistema] { lock.lock(); defer { lock.unlock() }; return _procesos }
    func senal(_ pid: pid_t, _ sig: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _senales.append((pid, sig))
        if !sordo { _puertoAbierto = false; _procesos.removeAll { $0.pid == pid } }
        return true
    }
    func contesta() -> Bool { lock.lock(); defer { lock.unlock() }; return _puertoAbierto }
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

    // MARK: - Cerrar el Chrome del perfil, lo haya lanzado quien lo haya lanzado

    private let perfil = URL(fileURLWithPath: "/Users/x/Library/Application Support/Gemma/chrome-real", isDirectory: true)
    private let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    private func chromeReal(_ sis: SistemaDeMentira, rutaDeChrome: String? = nil,
                            perfil: URL? = nil, esperaCierre: TimeInterval = 0.5) -> ChromeRealDeLaMac {
        ChromeRealDeLaMac(puerto: 9222, rutaDeChrome: rutaDeChrome ?? chrome, perfil: perfil ?? self.perfil,
                          espera: 5, esperaCierre: esperaCierre,
                          listaProcesos: { sis.procesos() },
                          senal: { sis.senal($0, $1) },
                          contestaPuerto: { _ in sis.contesta() })
    }

    /// (b) El síntoma medido: el Chrome del perfil lo abrió OTRA instancia de la app (o una que
    /// murió), así que esta no tiene `lanzado`. Se cierra igual, mandando SIGTERM SOLO al proceso
    /// raíz (no a los ayudantes `--type=`).
    func test_cierra_el_chrome_del_perfil_aunque_no_lo_lanzara_esta_instancia() async {
        let sis = SistemaDeMentira(procesos: [
            ProcesoDelSistema(pid: 4242, argumentos: [chrome, "--remote-debugging-port=9222",
                                                      "--user-data-dir=\(perfil.path)", "--no-first-run"]),
            ProcesoDelSistema(pid: 4243, argumentos: [chrome + " Helper (Renderer)", "--type=renderer",
                                                      "--user-data-dir=\(perfil.path)"]),
        ], puertoAbierto: true)
        let cerrado = await chromeReal(sis).cierra()
        XCTAssertTrue(cerrado)
        XCTAssertEqual(sis.senales.map(\.0), [4242], "solo el proceso raíz del perfil")
        XCTAssertEqual(sis.senales.map(\.1), [SIGTERM], "SIGTERM: cierre limpio que guarda el perfil")
    }

    /// (c) El Chrome normal del usuario y cualquier otro perfil NO se tocan, ni siquiera uno cuya
    /// ruta empieza igual que la nuestra.
    func test_no_toca_un_chrome_de_otro_perfil_ni_el_normal() async {
        let sis = SistemaDeMentira(procesos: [
            ProcesoDelSistema(pid: 100, argumentos: [chrome]),
            ProcesoDelSistema(pid: 101, argumentos: [chrome, "--user-data-dir=/Users/x/otro"]),
            ProcesoDelSistema(pid: 102, argumentos: [chrome, "--user-data-dir=\(perfil.path)-2"]),
            ProcesoDelSistema(pid: 103, argumentos: [chrome, "--user-data-dir=\(perfil.path)/sub"]),
            ProcesoDelSistema(pid: 104, argumentos: [chrome, "--profile-directory=chrome-real"]),
        ], puertoAbierto: false)
        let cerrado = await chromeReal(sis).cierra()
        XCTAssertTrue(cerrado, "no hay nada nuestro abierto y el puerto no contesta")
        XCTAssertTrue(sis.senales.isEmpty, "se mandó señal a un Chrome ajeno: \(sis.senales)")
    }

    /// (c bis) Si el puerto lo ocupa un Chrome que no es de nuestro perfil, no se toca y tampoco
    /// se dice que quedó cerrado.
    func test_un_chrome_ajeno_en_el_puerto_no_se_toca_y_no_se_da_por_cerrado() async {
        let sis = SistemaDeMentira(procesos: [
            ProcesoDelSistema(pid: 101, argumentos: [chrome, "--remote-debugging-port=9222",
                                                     "--user-data-dir=/Users/x/otro"]),
        ], puertoAbierto: true)
        let cerrado = await chromeReal(sis).cierra()
        XCTAssertFalse(cerrado)
        XCTAssertTrue(sis.senales.isEmpty)
    }

    /// (d) Chrome no se cierra tras el SIGTERM: `cierra()` lo dice en vez de dar por hecho.
    func test_si_sigue_abierto_tras_la_senal_cierra_devuelve_false() async {
        let sis = SistemaDeMentira(procesos: [
            ProcesoDelSistema(pid: 4242, argumentos: [chrome, "--user-data-dir=\(perfil.path)"]),
        ], puertoAbierto: true, sordo: true)
        let cerrado = await chromeReal(sis, esperaCierre: 0.3).cierra()
        XCTAssertFalse(cerrado)
        XCTAssertEqual(sis.senales.map(\.0), [4242])
    }

    /// (e) No hay Chrome: éxito sin mandar ninguna señal.
    func test_sin_chrome_es_exito_sin_senales() async {
        let sis = SistemaDeMentira(procesos: [], puertoAbierto: false)
        let cerrado = await chromeReal(sis).cierra()
        XCTAssertTrue(cerrado)
        XCTAssertTrue(sis.senales.isEmpty)
    }

    /// (a) El Chrome lo lanzó ESTA instancia: se termina el proceso propio. El "Chrome" es un
    /// guion que crea una marca (el "puerto abierto") y la borra al recibir SIGTERM; es hijo de
    /// la prueba, no un proceso del usuario. Sale solo a los ~20 s para no quedar huérfano si
    /// una mutación quita el SIGTERM (pasó: un guion de una corrida mutada quedó vivo).
    func test_cierra_el_chrome_que_lanzo_esta_instancia() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-falso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let marca = dir.appendingPathComponent("abierto")
        let guion = dir.appendingPathComponent("chrome")
        try "#!/bin/sh\ntrap 'rm -f \"\(marca.path)\"; exit 0' TERM\ntouch \"\(marca.path)\"\ni=0; while [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done\n"
            .write(to: guion, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: guion.path)
        let senales = SistemaDeMentira(procesos: [], puertoAbierto: false)
        let nav = ChromeRealDeLaMac(puerto: 9222, rutaDeChrome: guion.path,
                                    perfil: dir.appendingPathComponent("perfil", isDirectory: true),
                                    espera: 5, esperaCierre: 3,
                                    listaProcesos: { [] },
                                    senal: { senales.senal($0, $1) },
                                    contestaPuerto: { _ in FileManager.default.fileExists(atPath: marca.path) })
        guard case .success = await nav.asegura() else { return XCTFail("el Chrome falso no arrancó") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marca.path))
        let cerrado = await nav.cierra()
        XCTAssertTrue(cerrado)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marca.path), "el proceso propio recibió SIGTERM")
    }

    /// La búsqueda es pura: coincidencia EXACTA de `--user-data-dir` y sin `--type=`.
    func test_pids_del_perfil_es_exacto() {
        let ps = [
            ProcesoDelSistema(pid: 1, argumentos: ["c", "--user-data-dir=/a/b"]),
            ProcesoDelSistema(pid: 2, argumentos: ["c", "--user-data-dir=/a/b", "--type=gpu-process"]),
            ProcesoDelSistema(pid: 3, argumentos: ["c", "--user-data-dir=/a/bc"]),
            ProcesoDelSistema(pid: 4, argumentos: ["c", "--user-data-dir=/a"]),
            ProcesoDelSistema(pid: 5, argumentos: ["c", "--user-data-dir=/a/b/"]),
            ProcesoDelSistema(pid: 6, argumentos: []),
        ]
        XCTAssertEqual(ChromeRealDeLaMac.pidsRaiz(delPerfil: URL(fileURLWithPath: "/a/b"), en: ps), [1, 5])
    }

    /// El lector de `KERN_PROCARGS2`: argc (Int32) + ruta del ejecutable + relleno de NUL + argv.
    func test_lee_procargs2() {
        var d = Data()
        var argc: Int32 = 3
        d.append(Data(bytes: &argc, count: 4))
        d.append("/bin/exe".data(using: .utf8)!); d.append(contentsOf: [0, 0, 0, 0])
        for a in ["exe", "--user-data-dir=/x y/z", "--no-first-run"] { d.append(a.data(using: .utf8)!); d.append(0) }
        d.append("PATH=/bin".data(using: .utf8)!); d.append(0)
        XCTAssertEqual(ProcesosDelSistema.argumentos(deProcArgs2: d), ["exe", "--user-data-dir=/x y/z", "--no-first-run"])
        XCTAssertNil(ProcesosDelSistema.argumentos(deProcArgs2: Data([1, 0])))
    }

    /// El lector real ve, al menos, este mismo proceso de pruebas con sus argumentos. No manda
    /// ninguna señal a nadie.
    func test_el_lector_real_se_ve_a_si_mismo() {
        let yo = getpid()
        let todos = ProcesosDelSistema.todos()
        let mio = todos.first { $0.pid == yo }
        XCTAssertNotNil(mio, "el lector no encontró su propio pid entre \(todos.count) procesos")
        XCTAssertFalse(mio?.argumentos.isEmpty ?? true)
    }

    /// (d) en el invocador: si Chrome sigue abierto, el `close` NO puede decir que se cerró.
    func test_close_con_chrome_aun_abierto_devuelve_fallo_honesto() async throws {
        let nav = NavegadorDeMentira()
        nav.cierraBien = false
        let inv = ProcessAgentBrowserInvoker(binaryPath: try binarioFalsoJSON(), navegadorReal: nav)
        let r = await inv.invoke(arguments: ["--session", "s", "close", "--json"], timeout: 10)
        guard case .failure(.closeFailed(let msg)) = r else { return XCTFail("got: \(r)") }
        XCTAssertEqual(msg, "No pude cerrar Chrome: sigue abierto en el puerto 9333.")

        let tool = BrowserCloseTool(service: AgentBrowserService(invoker: inv, sessionName: "s"),
                                    userAskedToClose: true)
        let out = await tool.run(argsJSON: "{}")
        XCTAssertTrue(out.contains("\"error\""), out)
        XCTAssertTrue(out.contains("No pude cerrar Chrome: sigue abierto en el puerto 9333."), out)
        XCTAssertFalse(out.contains("Navegador cerrado"), out)
    }

    func test_close_con_chrome_cerrado_dice_cerrado() async throws {
        let nav = NavegadorDeMentira()
        let inv = ProcessAgentBrowserInvoker(binaryPath: try binarioFalsoJSON(), navegadorReal: nav)
        let tool = BrowserCloseTool(service: AgentBrowserService(invoker: inv, sessionName: "s"),
                                    userAskedToClose: true)
        let out = await tool.run(argsJSON: "{}")
        XCTAssertTrue(out.contains("Navegador cerrado"), out)
    }

    /// Un "agent-browser" que contesta el envelope JSON de éxito.
    private func binarioFalsoJSON() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ab-json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ruta = dir.appendingPathComponent("agent-browser")
        try "#!/bin/sh\necho '{\"success\":true,\"data\":{}}'\n".write(to: ruta, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ruta.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return ruta.path
    }

    func test_sin_navegador_real_no_se_toca_el_entorno() async throws {
        let inv = ProcessAgentBrowserInvoker(binaryPath: try binarioFalso())
        let res = await inv.invoke(arguments: ["--session", "s", "open", "https://x.com"], timeout: 10)
        let r = try XCTUnwrap(try? res.get())
        XCTAssertFalse(r.standardOutput.contains("CDP=9333"))
    }
}
#endif
