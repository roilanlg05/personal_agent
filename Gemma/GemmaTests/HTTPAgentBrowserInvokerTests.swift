#if os(macOS)
import XCTest
@testable import Gemma

/// Reusa `VoiceClientTests.StubProtocol` (el ayudante de `URLProtocol` que ya hay en el repo)
/// para las respuestas con cuerpo, y añade solo lo que ese no sabe hacer: fallar en el transporte.
@MainActor
final class HTTPAgentBrowserInvokerTests: XCTestCase {
    final class FailingProtocol: URLProtocol {
        nonisolated(unsafe) static var error: Error = URLError(.cannotConnectToHost)
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: Self.error) }
        override func stopLoading() {}
    }

    /// Lo que el stub vio de la última petición.
    final class Capture: @unchecked Sendable {
        var lastRequest: URLRequest?
        var lastBody: Data?
    }

    private static func invoker(status: Int = 200, responding body: String)
        -> (HTTPAgentBrowserInvoker, Capture) {
        let capture = Capture()
        VoiceClientTests.StubProtocol.stub = { req in
            capture.lastRequest = req
            capture.lastBody = Self.body(of: req)
            return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil,
                                    headerFields: nil)!, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [VoiceClientTests.StubProtocol.self]
        return (HTTPAgentBrowserInvoker(baseURL: URL(string: "http://i3.test:8083")!,
                                        bearerToken: "t0k3n",
                                        session: URLSession(configuration: cfg)), capture)
    }

    private static func invoker(failingWith error: Error) -> (HTTPAgentBrowserInvoker, Capture) {
        FailingProtocol.error = error
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FailingProtocol.self]
        return (HTTPAgentBrowserInvoker(baseURL: URL(string: "http://i3.test:8083")!,
                                        bearerToken: "t0k3n",
                                        session: URLSession(configuration: cfg)), Capture())
    }

    /// `URLProtocol` mueve `httpBody` a `httpBodyStream`: se lee de ahí.
    private static func body(of req: URLRequest) -> Data? {
        if let data = req.httpBody { return data }
        guard let stream = req.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    func test_manda_el_argv_y_el_plazo_en_el_cuerpo() async throws {
        let (invoker, stub) = Self.invoker(responding: #"{"exitCode":0,"stdout":"{}","stderr":""}"#)
        _ = await invoker.invoke(arguments: ["--session", "gemma", "open", "https://a.test", "--json"],
                                 timeout: 60)
        let body = try XCTUnwrap(stub.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["arguments"] as? [String],
                       ["--session", "gemma", "open", "https://a.test", "--json"])
        XCTAssertEqual(json["timeout"] as? Double, 60)
    }

    func test_el_argv_con_acentos_comillas_y_emoji_viaja_intacto() async throws {
        let argv = ["--session", "gemma", "fill", "input[name=\"q\"]", "canción “ñandú” \"hola\" 🚀", "--json"]
        let (invoker, stub) = Self.invoker(responding: #"{"exitCode":0,"stdout":"{}","stderr":""}"#)
        _ = await invoker.invoke(arguments: argv, timeout: 30)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(stub.lastBody)) as? [String: Any])
        XCTAssertEqual(json["arguments"] as? [String], argv)
    }

    /// Una conexión colgada vence por el plazo de red: el motivo tiene que nombrar el i3, no al CLI.
    func test_un_timeout_de_red_nombra_el_i3_y_no_dice_que_el_cli_tardo() async {
        let (invoker, _) = Self.invoker(failingWith: URLError(.timedOut))
        guard case .failure(.launchFailed(let detail)) = await invoker.invoke(arguments: ["open", "https://a.test"], timeout: 10)
        else { return XCTFail("esperaba .launchFailed, no .timedOut") }
        XCTAssertTrue(detail.contains("i3"))
    }

    func test_el_token_con_salto_de_linea_o_espacios_se_recorta_en_la_cabecera() async {
        let capture = Capture()
        VoiceClientTests.StubProtocol.stub = { req in
            capture.lastRequest = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"exitCode":0,"stdout":"{}","stderr":""}"#.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [VoiceClientTests.StubProtocol.self]
        // El token ya no vive en `UserDefaults` (Tarea 6): se siembra en el almacén, que es de
        // donde lo lee el invocador. Sigue sin recortar, que es lo que esta prueba mide.
        let d = defaults(url: "http://100.1.2.3:8083")
        let invoker = HarnessModel.browserInvoker(
            defaults: d, session: URLSession(configuration: cfg),
            almacen: AlmacenEnMemoria([TokenDeConducir.cuenta: "  t0k3n\n"]))
        _ = await invoker.invoke(arguments: ["stream", "status"], timeout: 10)
        XCTAssertEqual(capture.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer t0k3n")
    }

    func test_manda_el_bearer_y_pega_la_ruta_al_base() async {
        let (invoker, stub) = Self.invoker(responding: #"{"exitCode":0,"stdout":"{}","stderr":""}"#)
        _ = await invoker.invoke(arguments: ["stream", "status"], timeout: 10)
        XCTAssertEqual(stub.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(stub.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer t0k3n")
        XCTAssertEqual(stub.lastRequest?.url?.path, "/v1/browser/invoke")
        XCTAssertFalse(stub.lastRequest?.url?.absoluteString.contains("t0k3n") ?? true,
                       "el token va en la cabecera, nunca en la URL")
    }

    func test_devuelve_el_stdout_del_cli_sin_interpretarlo() async throws {
        let envelope = #"{\"success\":true,\"data\":{\"title\":\"T\"},\"error\":null}"#
        let (invoker, _) = Self.invoker(responding: #"{"exitCode":0,"stdout":"\#(envelope)","stderr":""}"#)
        guard case .success(let run) = await invoker.invoke(arguments: ["get", "title"], timeout: 10)
        else { return XCTFail("esperaba .success") }
        XCTAssertTrue(run.standardOutput.contains("\"success\":true"),
                      "el invocador no interpreta el envelope: eso es de AgentBrowserService")
        XCTAssertEqual(run.exitCode, 0)
    }

    func test_un_codigo_de_salida_distinto_de_cero_llega_como_exito_de_invocacion() async {
        let (invoker, _) = Self.invoker(responding: #"{"exitCode":1,"stdout":"","stderr":"boom"}"#)
        guard case .success(let run) = await invoker.invoke(arguments: ["get", "title"], timeout: 10)
        else { return XCTFail("esperaba .success") }
        XCTAssertEqual(run.exitCode, 1)
        XCTAssertEqual(run.standardError, "boom")
    }

    /// Review Focus 2: el i3 caído tiene que dar el mismo estado accionable que un binario ausente.
    func test_un_error_de_red_es_launchFailed_con_motivo() async {
        let (invoker, _) = Self.invoker(failingWith: URLError(.cannotConnectToHost))
        guard case .failure(.launchFailed(let detail)) = await invoker.invoke(arguments: ["open", "https://a.test"], timeout: 10)
        else { return XCTFail("esperaba .launchFailed") }
        XCTAssertFalse(detail.isEmpty, "el motivo llega al usuario: 'no pude hablar con el i3'")
        XCTAssertTrue(detail.contains("i3"), "el motivo nombra el i3 para que el usuario sepa dónde mirar")
    }

    func test_un_401_dice_que_el_token_esta_mal_y_no_se_confunde_con_un_rechazo_del_cli() async {
        let (invoker, _) = Self.invoker(status: 401, responding: #"{"detail":"unauthorized"}"#)
        guard case .failure(.launchFailed(let detail)) = await invoker.invoke(arguments: ["open", "https://a.test"], timeout: 10)
        else { return XCTFail("esperaba .launchFailed") }
        XCTAssertTrue(detail.contains("401"))
        XCTAssertTrue(detail.contains("i3"))
    }

    func test_un_400_del_servicio_tambien_es_fallo_de_invocacion_no_un_envelope() async {
        let (invoker, _) = Self.invoker(status: 400, responding: #"{"detail":"subcomando no permitido: eval"}"#)
        guard case .failure(.launchFailed(let detail)) = await invoker.invoke(arguments: ["eval", "1+1"], timeout: 10)
        else { return XCTFail("esperaba .failure(.launchFailed)") }
        XCTAssertTrue(detail.contains("subcomando no permitido"), "el motivo del servicio llega al usuario")
    }

    func test_una_respuesta_2xx_ilegible_es_fallo_de_invocacion() async {
        let (invoker, _) = Self.invoker(responding: "<html>no soy json</html>")
        guard case .failure(.launchFailed) = await invoker.invoke(arguments: ["get", "title"], timeout: 10)
        else { return XCTFail("esperaba .launchFailed") }
    }

    func test_el_plazo_de_la_peticion_deja_margen_sobre_el_del_cli() async throws {
        let (invoker, stub) = Self.invoker(responding: #"{"exitCode":0,"stdout":"{}","stderr":""}"#)
        _ = await invoker.invoke(arguments: ["open", "https://a.test"], timeout: 60)
        let interval = try XCTUnwrap(stub.lastRequest?.timeoutInterval)
        XCTAssertGreaterThan(interval, 60, "el viaje de red se suma al plazo del CLI, no se le resta")
    }

    // MARK: selección del invocador (HarnessModel.browserInvoker)
    // Si elige mal, el agente conduce un navegador y el panel muestra otro, sin ningún error.

    private func defaults(url: String?, token: String? = nil) -> UserDefaults {
        let suite = "HTTPAgentBrowserInvokerTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        if let url { d.set(url, forKey: SettingsKeys.browserBaseURL) }
        if let token { d.set(token, forKey: SettingsKeys.browserBearerToken) }
        return d
    }

    func test_sin_url_configurada_se_usa_el_proceso_local() {
        XCTAssertTrue(HarnessModel.browserInvoker(defaults: defaults(url: nil), almacen: AlmacenEnMemoria()) is ProcessAgentBrowserInvoker)
    }

    func test_url_vacia_o_en_blanco_se_usa_el_proceso_local() {
        XCTAssertTrue(HarnessModel.browserInvoker(defaults: defaults(url: ""), almacen: AlmacenEnMemoria()) is ProcessAgentBrowserInvoker)
        XCTAssertTrue(HarnessModel.browserInvoker(defaults: defaults(url: "  \n"), almacen: AlmacenEnMemoria()) is ProcessAgentBrowserInvoker)
    }

    func test_url_valida_con_token_usa_el_invocador_http() {
        let d = defaults(url: "http://100.1.2.3:8083", token: "t")
        XCTAssertTrue(HarnessModel.browserInvoker(defaults: d, almacen: AlmacenEnMemoria()) is HTTPAgentBrowserInvoker)
    }

    /// Decisión deliberada: URL válida y token vacío sigue siendo el i3 (dará 401 con motivo
    /// accionable), nunca el navegador local a escondidas.
    func test_url_valida_con_token_vacio_sigue_siendo_el_i3() {
        XCTAssertTrue(HarnessModel.browserInvoker(defaults: defaults(url: "http://100.1.2.3:8083"), almacen: AlmacenEnMemoria()) is HTTPAgentBrowserInvoker)
        XCTAssertTrue(HarnessModel.browserInvoker(defaults: defaults(url: "http://100.1.2.3:8083", token: ""), almacen: AlmacenEnMemoria()) is HTTPAgentBrowserInvoker)
    }

    func test_url_no_vacia_pero_invalida_no_cae_al_proceso_local() {
        for bad in ["no es una url", "100.1.2.3:8083", "ftp://x.test", "http://"] {
            let invoker = HarnessModel.browserInvoker(defaults: defaults(url: bad, token: "t"), almacen: AlmacenEnMemoria())
            XCTAssertFalse(invoker is ProcessAgentBrowserInvoker, "'\(bad)' no debe desviar al navegador local")
            XCTAssertTrue(invoker is InvalidBrowserURLInvoker, "'\(bad)'")
        }
    }

    func test_url_invalida_hace_que_la_herramienta_falle_con_motivo_nombrando_la_url_sin_usar_el_local() async throws {
        let invoker = HarnessModel.browserInvoker(defaults: defaults(url: "no es una url"), almacen: AlmacenEnMemoria())
        let out = await BrowserPressTool(service: AgentBrowserService(invoker: invoker, sessionName: "gemma"))
            .run(argsJSON: #"{"key":"Enter"}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], "got: \(out)")
        // AgentBrowserToolOutput reserva "not_available" para el binario ausente (y su mensaje
        // manda a INSTALAR agent-browser, que aquí sería un consejo equivocado). Un launchFailed
        // sale como "error" con el motivo; el turno no se rompe y el motivo nombra la URL del i3.
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertFalse(out.contains("instal"), "no debe mandar a instalar el binario local: \(out)")
        XCTAssertTrue(out.contains("URL del navegador del i3"), "el motivo nombra la URL: \(out)")
    }
}
#endif
