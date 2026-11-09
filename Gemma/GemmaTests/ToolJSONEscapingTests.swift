import XCTest
@testable import Gemma

/// Contactos de prueba: no toca la libreta real del usuario.
final class StubContactsManager: ContactsManaging, @unchecked Sendable {
    private let lock = NSLock()
    var contacts: [GemmaContact]
    var errorToThrow: Error?
    var lastQuery: String?

    init(contacts: [GemmaContact] = [], errorToThrow: Error? = nil) {
        self.contacts = contacts
        self.errorToThrow = errorToThrow
    }

    func requestAccess() async throws -> Bool { true }

    func searchContacts(query: String) async throws -> [GemmaContact] {
        lock.lock()
        lastQuery = query
        let err = errorToThrow
        let result = contacts
        lock.unlock()
        if let err { throw err }
        return result
    }
}

/// Defecto 3: ningún tool construye su JSON interpolando strings. Cada prueba mete
/// comillas, barra invertida, salto de línea y tabulador en el contenido y exige que
/// la salida siga siendo JSON válido y que el valor se lea de vuelta intacto.
final class ToolJSONEscapingTests: XCTestCase {

    /// Contiene comilla doble, barra invertida, salto de línea real y tabulador real.
    private let nasty = "Ana \"la jefa\" \\ruta\nsalto\ttab"

    private func args(_ dict: [String: Any]) throws -> String {
        try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: dict), encoding: .utf8))
    }

    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      "La salida del tool debe ser JSON válido. got: \(out)")
    }

    // MARK: - draft_message

    func test_draft_message_output_is_valid_json() async throws {
        let out = await DraftMessageTool().run(
            argsJSON: try args(["recipient": nasty, "raw_idea": "mañana \"vamos\"\na pescar"])
        )
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "drafted")
        XCTAssertEqual(json["recipient"] as? String, nasty)
        let drafted = try XCTUnwrap(json["drafted_message"] as? String)
        XCTAssertTrue(drafted.contains("pescar"), "got: \(drafted)")
    }

    // MARK: - call_contact

    func test_make_phone_call_output_is_valid_json() async throws {
        let manager = StubContactsManager(contacts: [
            GemmaContact(id: "1", givenName: nasty, familyName: "Pérez",
                         nickname: nil, phoneNumbers: ["+1 (305) 555-0100"], emailAddresses: [])
        ])
        let opener = MockAppURLOpener(supportedSchemes: ["tel"])
        let tool = MakePhoneCallTool(manager: manager, urlOpener: opener)
        let out = await tool.run(argsJSON: try args(["contact_or_number": nasty]))
        let json = try parse(out)
        // Este test exigía `status: "calling"`, que era precisamente la mentira: iOS solo
        // abre el marcador y espera a que el usuario pulse. Ver `MakePhoneCallToolTests`.
        XCTAssertEqual(json["status"] as? String, "confirmation_required", "got: \(out)")
        XCTAssertEqual(json["contact"] as? String, "\(nasty) Pérez")
        // Se reporta el número tal como se marca, ya normalizado, no como estaba escrito
        // en la libreta: si no, el número del informe y el del marcador no coinciden.
        XCTAssertEqual(json["number"] as? String, "+13055550100")
        XCTAssertEqual(opener.openedURLs.first?.scheme, "tel")
    }

    func test_make_phone_call_not_found_output_is_valid_json() async throws {
        let tool = MakePhoneCallTool(manager: StubContactsManager(),
                                     urlOpener: MockAppURLOpener(supportedSchemes: ["tel"]))
        let out = await tool.run(argsJSON: try args(["contact_or_number": nasty]))
        let json = try parse(out)
        // Antes era un `error` genérico; ahora es un estado que el modelo puede leer para
        // saber qué hacer (pedirle el número al usuario).
        XCTAssertEqual(json["status"] as? String, "not_found", "got: \(out)")
        XCTAssertEqual(json["requested"] as? String, nasty)
    }

    // MARK: - Defecto 4: la llamada abre la URL por el actor principal

    func test_make_phone_call_uses_async_url_opener() async throws {
        let opener = MockAppURLOpener(supportedSchemes: ["tel"])
        let tool = MakePhoneCallTool(manager: StubContactsManager(), urlOpener: opener)
        let out = await tool.run(argsJSON: #"{"contact_or_number": "3055550100"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["requires_user_tap"] as? Bool, true, "got: \(out)")
        // `tel:` sin barras: es un esquema sin componente de autoridad, como lo documenta
        // Apple. El viejo `tel://` funcionaba por tolerancia del sistema.
        XCTAssertEqual(opener.openedURLs.first?.absoluteString, "tel:3055550100")
    }

    func test_make_phone_call_reports_failure_honestly() async throws {
        let opener = MockAppURLOpener(supportedSchemes: ["tel"])
        opener.shouldSucceed = false
        let tool = MakePhoneCallTool(manager: StubContactsManager(), urlOpener: opener)
        let out = await tool.run(argsJSON: #"{"contact_or_number": "3055550100"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "failed",
                       "Si el sistema no abrió el marcador, no está llamando. got: \(out)")
    }

    // MARK: - search_contacts

    func test_search_contacts_output_is_valid_json() async throws {
        let manager = StubContactsManager(contacts: [
            GemmaContact(id: "1", givenName: nasty, familyName: "X",
                         nickname: "la \"jefa\"", phoneNumbers: ["+1"], emailAddresses: ["a@b.c"])
        ])
        let out = await SearchContactsTool(manager: manager).run(argsJSON: try args(["query": nasty]))
        let json = try parse(out)
        // `found`, no `ok`: lo que la herramienta documenta en su propia descripción al
        // modelo ("Lee 'status': 'found' = hay resultados en 'contacts'"). El test pedía
        // `ok`, que nunca emitió ningún camino de este tool.
        XCTAssertEqual(json["status"] as? String, "found", "got: \(out)")
        XCTAssertEqual(json["searched_query"] as? String, nasty)
        XCTAssertEqual(json["count"] as? Int, 1, "got: \(out)")
        let contacts = try XCTUnwrap(json["contacts"] as? [[String: Any]])
        // El caso difícil de esta clase: el nombre lleva comilla doble, barra invertida,
        // salto de línea y tabulador, y tiene que volver IDÉNTICO del viaje por el JSON.
        XCTAssertEqual(contacts.first?["given_name"] as? String ?? contacts.first?["givenName"] as? String, nasty)
        // Y el apodo, que lleva sus propias comillas, también.
        XCTAssertEqual(contacts.first?["nickname"] as? String, "la \"jefa\"", "got: \(out)")
    }

    /// Los DOS caminos de error del tool, porque emiten claves distintas a propósito:
    /// con 403 "no pude mirar la libreta" (`permission_required`, sin `error`: el texto del
    /// sistema no aporta nada y el mensaje dice qué hacer) y con cualquier otro fallo
    /// `failed` + `error` con la descripción entera. El test antiguo pedía la clave `error`
    /// sobre el camino de 403, que dejó de emitirla cuando los dos estados se separaron.
    func test_search_contacts_error_output_is_valid_json() async throws {
        let motivo = "Permiso \"denegado\"\npara contactos\tya"

        let sinPermiso = StubContactsManager(errorToThrow: NSError(
            domain: "Contacts", code: 403,
            userInfo: [NSLocalizedDescriptionKey: motivo]
        ))
        // La consulta lleva el texto difícil para que el escapado se ejercite también aquí.
        let outPermiso = await SearchContactsTool(manager: sinPermiso).run(argsJSON: try args(["query": nasty]))
        let jsonPermiso = try parse(outPermiso)
        XCTAssertEqual(jsonPermiso["status"] as? String, "permission_required", "got: \(outPermiso)")
        XCTAssertEqual(jsonPermiso["searched_query"] as? String, nasty)
        XCTAssertNil(jsonPermiso["error"], "el camino de permiso no emite `error`: \(outPermiso)")

        let falla = StubContactsManager(errorToThrow: NSError(
            domain: "Contacts", code: 1,
            userInfo: [NSLocalizedDescriptionKey: motivo]
        ))
        let outFallo = await SearchContactsTool(manager: falla).run(argsJSON: #"{"query": "mamá"}"#)
        let jsonFallo = try parse(outFallo)
        XCTAssertEqual(jsonFallo["status"] as? String, "failed", "got: \(outFallo)")
        // EL CASO DIFÍCIL, que es por lo que esta clase se llama «escaping»: un motivo con
        // comillas, salto de línea y tabulador sobrevive entero el viaje por el JSON.
        XCTAssertEqual(jsonFallo["error"] as? String, motivo, "got: \(outFallo)")
        XCTAssertTrue((jsonFallo["message"] as? String)?.contains(motivo) ?? false,
                      "el mensaje al modelo también lleva el motivo entero: \(outFallo)")
    }

    // MARK: - create_alarm

    func test_create_alarm_output_is_valid_json() async throws {
        let service = ClockService(
            scheduler: MockClockScheduler(),
            defaults: UserDefaults(suiteName: "gemma.tests.clock.\(UUID().uuidString)")!
        )
        let out = await CreateAlarmTool(clockService: service).run(
            argsJSON: try args(["title": nasty, "hour": 7, "minute": 5])
        )
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "created")
        XCTAssertEqual(json["title"] as? String, nasty)
        XCTAssertEqual(json["time"] as? String, "07:05")
    }

    func test_create_alarm_error_output_is_valid_json() async throws {
        final class FailingScheduler: ClockScheduling, @unchecked Sendable {
            func requestAuthorization() async -> Bool { true }
            func scheduleAlarmNotification(alarm: GemmaAlarm) async throws {
                throw NSError(domain: "Clock", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No hay permiso \"de avisos\"\n"])
            }
            func scheduleTimerNotification(timer: GemmaTimer) async throws {
                throw NSError(domain: "Clock", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No hay permiso \"de avisos\"\n"])
            }
        }
        let service = ClockService(
            scheduler: FailingScheduler(),
            defaults: UserDefaults(suiteName: "gemma.tests.clock.\(UUID().uuidString)")!
        )
        let out = await CreateAlarmTool(clockService: service).run(
            argsJSON: #"{"title": "x", "hour": 7, "minute": 5}"#
        )
        let json = try parse(out)
        XCTAssertNotNil(json["error"] as? String, "got: \(out)")
    }

    // MARK: - create_timer

    func test_create_timer_output_is_valid_json() async throws {
        let service = ClockService(
            scheduler: MockClockScheduler(),
            defaults: UserDefaults(suiteName: "gemma.tests.clock.\(UUID().uuidString)")!
        )
        let out = await CreateTimerTool(clockService: service).run(
            argsJSON: try args(["duration_seconds": 125, "label": nasty])
        )
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "started")
        XCTAssertEqual(json["label"] as? String, nasty)
        XCTAssertEqual(json["duration_seconds"] as? Int, 125)
        XCTAssertEqual(json["formatted_duration"] as? String, "2m 5s")
    }

    // MARK: - open_app

    func test_open_app_output_is_valid_json() async throws {
        let opener = MockAppURLOpener(supportedSchemes: [])
        let tool = OpenAppTool(launcherService: AppLauncherService(urlOpener: opener))
        let out = await tool.run(argsJSON: try args(["app_name": "Spotify", "payload": nasty]))
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "opened")
        XCTAssertEqual(json["app_name"] as? String, "Spotify")
        XCTAssertNotNil(json["url"] as? String)
    }

    func test_open_app_failure_output_is_valid_json() async throws {
        let opener = MockAppURLOpener(supportedSchemes: [])
        opener.shouldSucceed = false
        let tool = OpenAppTool(launcherService: AppLauncherService(urlOpener: opener))
        let out = await tool.run(argsJSON: try args(["app_name": "Spotify", "payload": nasty]))
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "failed", "got: \(out)")
        XCTAssertEqual(json["app_name"] as? String, "Spotify")
        XCTAssertNotNil(json["message"] as? String)
    }

    /// Un nombre de app que no forma una URL válida devuelve un error, y ese error
    /// también tiene que ser JSON válido aunque el nombre lleve comillas y saltos.
    func test_open_app_unresolvable_name_output_is_valid_json() async throws {
        let tool = OpenAppTool(launcherService: AppLauncherService(urlOpener: MockAppURLOpener()))
        let out = await tool.run(argsJSON: try args(["app_name": "App \"Rara\"\n"]))
        let json = try parse(out)
        XCTAssertNotEqual(json["status"] as? String, "opened", "got: \(out)")
    }

    // MARK: - web_search

    func test_web_search_output_is_valid_json() async throws {
        let searcher = MockWebSearcher(cannedResults: [
            WebSearchResult(title: nasty, snippet: "frag \"mento\"\n", url: "https://a.test/?q=1&x=\"y\"")
        ])
        let tool = WebSearchTool(searchService: WebSearchService(searcher: searcher))
        let out = await tool.run(argsJSON: try args(["query": nasty]))
        let json = try parse(out)
        XCTAssertEqual(json["query"] as? String, nasty)
        let results = try XCTUnwrap(json["results"] as? [[String: Any]])
        XCTAssertEqual(results.first?["title"] as? String, nasty)
        XCTAssertEqual(results.first?["snippet"] as? String, "frag \"mento\"\n")
    }

    // MARK: - get_device_status

    func test_get_device_status_output_is_valid_json() async throws {
        let provider = MockDeviceStatusProvider(deviceType: "iPhone \"de Roilan\"\n",
                                                batteryPercent: 42, isCharging: false)
        let out = await GetDeviceStatusTool(service: DeviceStatusService(provider: provider)).run(argsJSON: "{}")
        let json = try parse(out)
        XCTAssertEqual(json["device"] as? String, "iPhone \"de Roilan\"\n")
        XCTAssertEqual(json["battery_percent"] as? Int, 42)
        XCTAssertNotNil(json["summary"] as? String)
    }
}
