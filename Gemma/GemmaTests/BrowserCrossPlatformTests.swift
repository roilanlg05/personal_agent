import XCTest
@testable import Gemma

/// Sin `#if os(macOS)`: estas pruebas corren en macOS y en iOS. Si alguien repone una puerta de
/// fichero completo sobre el stack del navegador, esto deja de compilar en iOS.
@MainActor
final class BrowserCrossPlatformTests: XCTestCase {
    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], "got: \(out)")
    }

    /// El valor de esta prueba es que COMPILE en las dos plataformas: si alguien repone una puerta
    /// de fichero completo sobre el stack del navegador, iOS deja de compilar el target de pruebas.
    /// No hay nada que afirmar en tiempo de ejecución, y un `XCTAssertNotNil` sobre un inicializador
    /// no fallable no podría fallar nunca, así que se construye y se descarta, sin fingir una aserción.
    func test_el_stack_del_navegador_compila_en_las_dos_plataformas() {
        let invoker = UnconfiguredBrowserInvoker()
        let service = AgentBrowserService(invoker: invoker, sessionName: "x")
        _ = BrowserOpenTool(service: service)
        _ = BrowserFillTool(service: service)
        _ = BrowserGetTool(service: service)
        _ = ReadWebpageTool(service: service)
    }

    /// Sin URL configurada, el motivo tiene que mandar a los Ajustes, no a instalar nada.
    /// La forma real de la salida es `{status, message}` (ver `AgentBrowserToolOutput.resolve`):
    /// un fallo de lanzamiento llega como `status: "error"` con el motivo en `message`.
    func test_sin_url_configurada_el_motivo_manda_a_los_ajustes() async throws {
        let service = AgentBrowserService(invoker: UnconfiguredBrowserInvoker(), sessionName: "x")
        let out = await BrowserOpenTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "error", "got: \(out)")
        let message = (json["message"] as? String ?? "").lowercased()
        XCTAssertTrue(message.contains("ajustes") && message.contains("url"),
                      "el motivo tiene que ser accionable; got: \(out)")
        XCTAssertFalse(message.contains("instala"),
                       "no puede decir que instale un binario: en iOS no hay binario que instalar")
        XCTAssertFalse(message.contains("brew"), "got: \(out)")
        XCTAssertFalse(message.contains("agent-browser"),
                       "en iOS no existe ese binario; el texto no puede nombrarlo; got: \(out)")
    }

    /// La fábrica del panel ya no depende de la plataforma, solo de la configuración.
    func test_la_fabrica_del_panel_depende_de_la_config_no_de_la_plataforma() {
        let vacios = UserDefaults(suiteName: "test.panel.vacio")!
        vacios.removePersistentDomain(forName: "test.panel.vacio")
        defer { vacios.removePersistentDomain(forName: "test.panel.vacio") }
        XCTAssertNil(HarnessModel.makeRelayStream(defaults: vacios))

        let puestos = UserDefaults(suiteName: "test.panel.puesto")!
        puestos.removePersistentDomain(forName: "test.panel.puesto")
        defer { puestos.removePersistentDomain(forName: "test.panel.puesto") }
        puestos.set("http://127.0.0.1:1", forKey: SettingsKeys.browserBaseURL)
        puestos.set("t", forKey: SettingsKeys.browserBearerToken)
        XCTAssertNotNil(HarnessModel.makeRelayStream(defaults: puestos),
                        "con URL válida tiene que haber flujo en CUALQUIER plataforma")
    }

    /// Con URL puesta, el invocador es el de HTTP en las dos plataformas.
    func test_con_url_puesta_el_invocador_es_el_de_http() {
        let d = UserDefaults(suiteName: "test.invoker")!
        d.removePersistentDomain(forName: "test.invoker")
        defer { d.removePersistentDomain(forName: "test.invoker") }
        d.set("http://100.64.0.1:8083", forKey: SettingsKeys.browserBaseURL)
        XCTAssertTrue(HarnessModel.browserInvoker(defaults: d) is HTTPAgentBrowserInvoker)
    }

    /// Una URL escrita pero inválida sigue sin caer al navegador local, en las dos plataformas.
    func test_url_invalida_sigue_siendo_invalida_en_las_dos_plataformas() {
        let d = UserDefaults(suiteName: "test.invoker.invalida")!
        d.removePersistentDomain(forName: "test.invoker.invalida")
        defer { d.removePersistentDomain(forName: "test.invoker.invalida") }
        d.set("no es una url", forKey: SettingsKeys.browserBaseURL)
        XCTAssertTrue(HarnessModel.browserInvoker(defaults: d) is InvalidBrowserURLInvoker)
    }

    /// El texto de una URL inválida lo lee también el usuario del iPhone: no puede mandarle a
    /// "dejarla vacía para usar el navegador local" (en iOS vacío significa ningún navegador).
    func test_el_texto_de_url_invalida_no_miente_en_ninguna_plataforma() async throws {
        let service = AgentBrowserService(invoker: InvalidBrowserURLInvoker(), sessionName: "x")
        let out = await BrowserOpenTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#)
        let message = (try parse(out)["message"] as? String ?? "").lowercased()
        XCTAssertTrue(message.contains("ajustes"), "got: \(out)")
        XCTAssertFalse(message.contains("agent-browser"), "got: \(out)")
        XCTAssertFalse(message.contains("vac"), "no puede sugerir dejar el campo vacío; got: \(out)")
        XCTAssertFalse(message.contains("local"), "got: \(out)")
    }

    /// Lo que se le promete al modelo en las descripciones tampoco puede ser imposible en iOS.
    func test_las_descripciones_no_prometen_instalar_nada() {
        let text = AgentBrowserToolOutput.statesSentence.lowercased()
        XCTAssertFalse(text.contains("instal"), text)
        XCTAssertFalse(text.contains("brew"), text)
    }

    /// Las nueve herramientas se registran en cualquier plataforma.
    func test_las_nueve_herramientas_se_registran_en_cualquier_plataforma() {
        XCTAssertEqual(HarnessModel.browserToolRegistry().tools.count, 9)
    }

    #if os(iOS)
    /// En iOS el campo vacío no puede caer a un navegador local que no existe.
    func test_ios_campo_vacio_es_unconfigured() {
        let d = UserDefaults(suiteName: "test.invoker.vacio")!
        d.removePersistentDomain(forName: "test.invoker.vacio")
        defer { d.removePersistentDomain(forName: "test.invoker.vacio") }
        XCTAssertTrue(HarnessModel.browserInvoker(defaults: d) is UnconfiguredBrowserInvoker)
    }
    #else
    /// En macOS el campo vacío sigue siendo el navegador local de siempre.
    func test_macos_campo_vacio_es_el_navegador_local() {
        let d = UserDefaults(suiteName: "test.invoker.vacio")!
        d.removePersistentDomain(forName: "test.invoker.vacio")
        defer { d.removePersistentDomain(forName: "test.invoker.vacio") }
        XCTAssertTrue(HarnessModel.browserInvoker(defaults: d) is ProcessAgentBrowserInvoker)
    }
    #endif
}
