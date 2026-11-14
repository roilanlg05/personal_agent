import XCTest
@testable import Gemma

#if os(macOS)

/// Invoca el binario `agent-browser` de verdad, sin mocks. Desactivada por omisión
/// para que la suite normal nunca lance Chrome ni toque la red:
/// (xcodebuild solo reenvía al proceso de pruebas las variables con prefijo TEST_RUNNER_.)
///   TEST_RUNNER_GEMMA_LIVE_BROWSER=1 xcodebuild test … -only-testing:GemmaTests/AgentBrowserLiveTests
@MainActor
final class AgentBrowserLiveTests: XCTestCase {

    /// Sesión propia de las pruebas: no choca con `gemma` (producción) ni con otras sesiones.
    private static let liveSession = "gemma-live-test"

    private func requireLive() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GEMMA_LIVE_BROWSER"] == "1",
                          "Prueba en vivo: pon GEMMA_LIVE_BROWSER=1 para ejecutarla contra agent-browser")
    }

    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], "got: \(out)")
    }

    func test_read_webpage_reads_example_dot_com() async throws {
        try requireLive()
        let service = AgentBrowserService(sessionName: Self.liveSession)
        let out = await ReadWebpageTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "success", "got: \(out)")
        XCTAssertTrue((json["content"] as? String ?? "").contains("documentation"), "got: \(out)")
    }

    func test_open_snapshot_and_close_round_trip() async throws {
        try requireLive()
        let service = AgentBrowserService(sessionName: Self.liveSession)
        // Cierra la sesión pase lo que pase, para no dejar un Chrome vivo.
        addTeardownBlock { _ = await BrowserCloseTool(service: service).run(argsJSON: "{}") }

        let opened = try parse(await BrowserOpenTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#))
        XCTAssertEqual(opened["status"] as? String, "success", "got: \(opened)")

        let snap = try parse(await BrowserSnapshotTool(service: service).run(argsJSON: "{}"))
        XCTAssertEqual(snap["status"] as? String, "success", "got: \(snap)")
        XCTAssertTrue((snap["snapshot"] as? String ?? "").contains("ref=e"), "got: \(snap)")

        let closed = try parse(await BrowserCloseTool(service: service).run(argsJSON: "{}"))
        XCTAssertEqual(closed["status"] as? String, "success", "got: \(closed)")
    }

    // MARK: contra el navegador del i3 (visor + herramientas por red)
    //
    // Guardián propio, distinto de `requireLive()` (que prueba el agent-browser LOCAL de la Mac):
    //   TEST_RUNNER_GEMMA_LIVE_I3=1 TEST_RUNNER_GEMMA_I3_BROWSER_URL=http://host:8083 \
    //   TEST_RUNNER_GEMMA_I3_BROWSER_TOKEN=<token> xcodebuild test … -only-testing:GemmaTests/AgentBrowserLiveTests
    // Opcional para la prueba de reconexión: GEMMA_I3_SSH=usuario@host (reinicia el servicio `browser`).

    /// DEBE ser la sesión que el relé del i3 transmite (`BROWSER_STREAM_SESSION`, por omisión
    /// `gemma`, el nombre que usa la app): una sesión con otro nombre navega pero el panel no la
    /// ve, y las pruebas de frames recibirían solo el último frame en caché del demonio.
    private static let i3Session = AgentBrowserService.defaultSessionName

    private func requireLiveI3() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["GEMMA_LIVE_I3"] == "1",
                          "Prueba en vivo contra el i3: pon GEMMA_LIVE_I3=1, GEMMA_I3_BROWSER_URL y GEMMA_I3_BROWSER_TOKEN")
        try XCTSkipUnless(!(env["GEMMA_I3_BROWSER_URL"] ?? "").isEmpty && !(env["GEMMA_I3_BROWSER_TOKEN"] ?? "").isEmpty,
                          "Faltan GEMMA_I3_BROWSER_URL o GEMMA_I3_BROWSER_TOKEN")
    }

    private static func i3URL() -> URL { URL(string: ProcessInfo.processInfo.environment["GEMMA_I3_BROWSER_URL"] ?? "")! }
    private static func i3Token() -> String { ProcessInfo.processInfo.environment["GEMMA_I3_BROWSER_TOKEN"] ?? "" }

    private static func i3Invoker() -> HTTPAgentBrowserInvoker {
        HTTPAgentBrowserInvoker(baseURL: i3URL(), bearerToken: i3Token())
    }

    /// Servicio contra el i3 con cierre de sesión garantizado al terminar la prueba.
    private func i3Service() -> AgentBrowserService {
        let service = AgentBrowserService(invoker: Self.i3Invoker(), sessionName: Self.i3Session)
        addTeardownBlock { _ = await BrowserCloseTool(service: service).run(argsJSON: "{}") }
        return service
    }

    /// Contador de frames compartido entre la tarea que consume y la prueba.
    private actor FrameCounter {
        private(set) var count = 0
        /// Frames recibidos DESPUÉS de un `closed`: solo llegan si el visor reconectó solo.
        /// (Tras reconectar, el `seq` vuelve a empezar y una página quieta manda un único frame.)
        private(set) var framesAfterClose = 0
        private var sawClose = false
        /// Cronología de todo lo que llegó, para que un fallo diga qué pasó y cuándo.
        private(set) var timeline: [String] = []
        /// Todo texto que viajó por el cable, de los tipos de mensaje que traen texto, con su tipo.
        private(set) var wireTexts: [String] = []
        private(set) var narrations: [String] = []
        private let start = Date()
        func record(_ event: BrowserRelayEvent) {
            let t = String(format: "%.1fs", Date().timeIntervalSince(start))
            switch event {
            case .narration(let t): wireTexts.append("narration: \(t)"); narrations.append(t)
            case .host(let t): wireTexts.append("host: \(t)")
            case .summary(let t): wireTexts.append("summary: \(t)")
            case .closed(let t): wireTexts.append("closed: \(t)")
            default: break
            }
            switch event {
            case .frame(let seq, _, _): count += 1; if sawClose { framesAfterClose += 1 }; timeline.append("\(t) frame#\(seq)")
            case .narration(let text): timeline.append("\(t) narration(\(text))")
            case .host(let host): timeline.append("\(t) host(\(host))")
            case .state(let live, let collapsed): timeline.append("\(t) state(live=\(live),collapsed=\(collapsed))")
            case .summary(let text): timeline.append("\(t) summary(\(text))")
            case .closed(let reason): sawClose = true; timeline.append("\(t) closed(\(reason))")
            }
        }
        func note(_ text: String) { timeline.append(String(format: "%.1fs ", Date().timeIntervalSince(start)) + "-- " + text) }
    }

    /// Arranca el visor volcando todo en `counter`. El teardown cancela la tarea y cierra el
    /// socket aunque una aserción lance antes de llegar al final de la prueba.
    private func watch(_ client: BrowserRelayClient, into counter: FrameCounter) async -> Task<Void, Never> {
        let stream = await client.events()
        let pump = Task { for await e in stream { await counter.record(e) } }
        addTeardownBlock { pump.cancel(); await client.stop() }
        return pump
    }

    func test_en_vivo_una_herramienta_conduce_el_navegador_del_i3() async throws {
        try requireLiveI3()
        let service = i3Service()
        let out = await BrowserOpenTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "success", "got: \(out)")
    }

    /// La prueba del acuse POR EL EFECTO, de punta a punta: si el encadenado
    /// visor→relé→demonio estuviera mal, el flujo se pararía en el primer frame.
    func test_en_vivo_llegan_dos_o_mas_frames_del_rele() async throws {
        try requireLiveI3()
        let service = i3Service()
        _ = await BrowserOpenTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#)
        let client = BrowserRelayClient(baseURL: Self.i3URL(), bearerToken: Self.i3Token())
        let counter = FrameCounter()
        let pump = await watch(client, into: counter)
        // Una página quieta solo manda el frame inicial (1 o 2 según el momento), así que se
        // provoca actividad real navegando mientras el visor mira. Que lleguen más frames que
        // los del arranque exige que el acuse visor→relé→demonio funcione. El plazo se vigila
        // aparte del flujo: un `for await` con la comprobación dentro se cuelga si no llegan eventos.
        let end = Date(timeIntervalSinceNow: 45)
        let pages = ["https://example.org", "https://example.com"]
        var i = 0
        while Date() < end, await counter.count < 4 {
            _ = await BrowserOpenTool(service: service).run(argsJSON: "{\"url\":\"\(pages[i % 2])\"}")
            i += 1
            try await Task.sleep(for: .seconds(2))
        }
        pump.cancel(); await client.stop()
        let frames = await counter.count
        let timeline = await counter.timeline.joined(separator: "\n")
        XCTAssertGreaterThanOrEqual(frames, 4, "esperaba >=4 frames con navegación activa.\nCronología:\n\(timeline)")
    }

    /// EL ANTI OBJETIVO PRINCIPAL, de punta a punta.
    func test_en_vivo_pagina_quieta_treinta_segundos_sigue_diciendo_en_vivo() async throws {
        try requireLiveI3()
        let service = i3Service()
        _ = await BrowserOpenTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#)
        let state = BrowserPanelState()
        let client = BrowserRelayClient(baseURL: Self.i3URL(), bearerToken: Self.i3Token())
        let stream = await client.events()
        let pump = Task { @MainActor in for await e in stream { state.apply(e) } }
        addTeardownBlock { pump.cancel(); await client.stop() }
        try await Task.sleep(for: .seconds(30))
        XCTAssertTrue(state.isLive, "página quieta: no llega ni un frame en 30 s y sigue viva")
        pump.cancel(); await client.stop()
    }

    /// LA PRUEBA DE SEGURIDAD, sobre el cable real. Mide tres cosas, las tres necesarias para
    /// que no pueda pasar con el sistema roto: (1) el `fill` TUVO ÉXITO (si falla, no se mandó
    /// nada y «nada contiene el secreto» sería vacío); (2) llegó la narración DEL fill, es decir,
    /// una nueva, posterior al lanzamiento, con la frase que el filtro del servidor genera para
    /// esa acción («rellenando un campo»); (3) el secreto y el selector no aparecen en NINGÚN
    /// texto del cable: narración, resumen, host ni motivo de cierre (los frames son JPEG sin
    /// texto). Si el filtro del servidor dejara pasar el `command` crudo, la narración llevaría
    /// el valor o el selector y (3) se pondría roja; si no hubiera narración del fill, (2).
    /// Usa una página con un campo real (la de example.com no tiene ninguno).
    func test_en_vivo_un_fill_no_manda_su_valor_por_el_cable() async throws {
        try requireLiveI3()
        let secret = "SECRETO123"
        let selector = "input[name=custname]"
        let service = i3Service()
        let opened = try parse(await BrowserOpenTool(service: service).run(argsJSON: #"{"url":"https://httpbin.org/forms/post"}"#))
        XCTAssertEqual(opened["status"] as? String, "success", "no se pudo abrir la página con formulario: \(opened)")
        let client = BrowserRelayClient(baseURL: Self.i3URL(), bearerToken: Self.i3Token())
        let counter = FrameCounter()
        _ = await watch(client, into: counter)
        try await Task.sleep(for: .seconds(1))

        let before = await counter.narrations.count
        let args = try String(data: JSONSerialization.data(withJSONObject: ["selector": selector, "text": secret]), encoding: .utf8) ?? "{}"
        let filled = try parse(await BrowserFillTool(service: service).run(argsJSON: args))
        XCTAssertEqual(filled["status"] as? String, "success", "el fill debe tener éxito para que la prueba mida algo: \(filled)")

        var fillNarration = false
        let end = Date(timeIntervalSinceNow: 10)
        while Date() < end && !fillNarration {
            let all = await counter.narrations
            fillNarration = all.dropFirst(before).contains { $0.contains("rellenando un campo") }
            if !fillNarration { try await Task.sleep(for: .milliseconds(250)) }
        }
        try await Task.sleep(for: .seconds(2))   // margen para que un mensaje filtrado mal llegue
        await client.stop()
        let texts = await counter.wireTexts
        XCTAssertTrue(fillNarration, "no llegó la narración del fill (\"rellenando un campo\"). Cable: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains(secret) }, "el valor del fill viajó por el cable: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains("custname") }, "el selector viajó por el cable: \(texts)")
    }

    /// `docker compose restart browser` en el i3 por ssh, FUERA del hilo principal y con plazo:
    /// pasado `timeout` se termina el proceso (estado 15). nil si ssh no pudo ni lanzarse.
    private nonisolated static func restartBrowserService(ssh: String, timeout: TimeInterval) async -> Int32? {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", ssh,
                                 "cd ~/Projects/gemma-browser && docker compose restart browser"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { process.terminationHandler = nil; cont.resume(returning: nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Con el i3 inalcanzable el estado es `error` (no `not_available`: ese estado dice
    /// «instala agent-browser», consejo falso si el binario vive en otra máquina) y el
    /// motivo NOMBRA al i3, que es lo que permite arreglar el problema.
    func test_en_vivo_un_i3_inalcanzable_da_error_con_motivo_accionable() async throws {
        try requireLiveI3()
        let invoker = HTTPAgentBrowserInvoker(baseURL: URL(string: "http://127.0.0.1:1")!, bearerToken: "x")
        let out = await BrowserOpenTool(service: AgentBrowserService(invoker: invoker, sessionName: "x"))
            .run(argsJSON: #"{"url":"https://example.com"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "error", "got: \(out)")
        XCTAssertTrue((json["message"] as? String ?? "").contains("127.0.0.1"), "el motivo debe nombrar el host; got: \(out)")
    }

    /// POLÍTICA DE RECONEXIÓN, la única sin cobertura automática (URLProtocol no intercepta
    /// WebSocket). Con el visor recibiendo frames se reinicia el servicio `browser` del i3 y
    /// se comprueba que el MISMO visor vuelve a recibir frames sin que nadie lo reinicie.
    /// Requiere GEMMA_I3_SSH (p. ej. usuario@100.91.174.81) y que el binario ssh funcione sin pedir clave.
    func test_en_vivo_el_visor_reconecta_tras_reiniciar_el_servicio_del_navegador() async throws {
        try requireLiveI3()
        let sshOrNil = ProcessInfo.processInfo.environment["GEMMA_I3_SSH"].flatMap { $0.isEmpty ? nil : $0 }
        try XCTSkipUnless(sshOrNil != nil, "Pon GEMMA_I3_SSH=usuario@host para ejecutarla (reinicia el servicio del navegador del i3)")
        let ssh = sshOrNil!
        let service = i3Service()
        _ = await BrowserOpenTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#)

        let client = BrowserRelayClient(baseURL: Self.i3URL(), bearerToken: Self.i3Token())
        let counter = FrameCounter()
        _ = await watch(client, into: counter)

        func waitFor(frames target: Int, seconds: Double) async -> Bool {
            let end = Date(timeIntervalSinceNow: seconds)
            while Date() < end {
                if await counter.count >= target { return true }
                try? await Task.sleep(for: .milliseconds(500))
            }
            return false
        }
        let before = await waitFor(frames: 1, seconds: 30)  // página quieta: un solo frame inicial
        let early = await counter.timeline.joined(separator: "\n")
        XCTAssertTrue(before, "sin frames antes del reinicio; la prueba no puede continuar.\nCronología:\n\(early)")
        guard before else { return }

        await counter.note("reiniciando el servicio")
        let status = await Self.restartBrowserService(ssh: ssh, timeout: 120)
        guard status == 0 else {
            XCTFail("No se pudo reiniciar el servicio del navegador por ssh (estado \(status.map(String.init) ?? "no lanzó")); el resto de la prueba no tiene sentido.")
            return
        }

        // El contenedor y el demonio arrancan en frío: se reabre la página (reintentando hasta
        // que el servicio responda) para que haya algo que transmitir, y se espera con holgura.
        var reopened = false
        let reopenEnd = Date(timeIntervalSinceNow: 90)
        while Date() < reopenEnd && !reopened {
            let out = await BrowserOpenTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#)
            reopened = (try? parse(out))?["status"] as? String == "success"
            if !reopened { try await Task.sleep(for: .seconds(3)) }
        }
        await counter.note("reabierto=\(reopened)")
        XCTAssertTrue(reopened, "el servicio no volvió a aceptar órdenes tras el reinicio")
        // Plazo generoso: el contenedor y el demonio arrancan en frío, y el visor espera
        // 1, 2, 4… s entre intentos.
        var after = false
        let afterEnd = Date(timeIntervalSinceNow: 150)
        while Date() < afterEnd && !after {
            after = await counter.framesAfterClose >= 1
            if !after { try await Task.sleep(for: .milliseconds(500)) }
        }
        await client.stop()
        let timeline = await counter.timeline.joined(separator: "\n")
        XCTAssertTrue(after, "el visor no recibió ningún frame tras el cierre provocado por el reinicio: la reconexión no funciona.\nCronología:\n\(timeline)")
    }

    /// Garantiza que no queda un Chromium vivo en el i3. Abre antes una página para que haya
    /// sesión que cerrar (cerrar una inexistente no es éxito) y exige el estado `success`.
    func test_en_vivo_cierra_la_sesion_de_prueba() async throws {
        try requireLiveI3()
        let service = AgentBrowserService(invoker: Self.i3Invoker(), sessionName: Self.i3Session)
        let opened = try parse(await BrowserOpenTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#))
        XCTAssertEqual(opened["status"] as? String, "success", "got: \(opened)")
        let closed = try parse(await BrowserCloseTool(service: service).run(argsJSON: "{}"))
        XCTAssertEqual(closed["status"] as? String, "success", "got: \(closed)")
    }
}

#endif
