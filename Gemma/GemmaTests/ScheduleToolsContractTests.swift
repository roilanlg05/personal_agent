import XCTest
@testable import Gemma

/// Las cuatro herramientas de agenda de SP1 (`check_schedule`, `create_event`,
/// `query_schedule`, `cancel_events`) existen para que Gemma no agende al usuario en un
/// sitio mientras está de viaje en otro. Su prueba de extremo a extremo se hizo el
/// 2026-06-04 y falló, y hasta hoy no tenían ni una sola prueba propia.
///
/// Lo que se encontró al escribir estas pruebas, y que estas pruebas fijan:
///
/// 1. **`check_schedule` decía «No conflicts» cuando no había podido mirar.** La consulta
///    de rutinas iba con `try?`: si el servicio de memoria fallaba en ese paso, el fallo
///    se tragaba y la herramienta contestaba que el hueco estaba libre. El modelo le
///    decía al usuario «tienes ese rato libre» cuando la verdad era «no pude comprobar tus
///    rutinas». Lo mismo en `create_event`, que además agendaba.
/// 2. **`check_schedule` y `create_event` solo miraban los 50 nodos más nuevos.** Una
///    rutina más antigua que esos 50 nodos era invisible, así que el conflicto no se
///    detectaba y la respuesta seguía siendo «libre».
/// 3. **`query_schedule` se inventaba el rango.** Si el fin era anterior al inicio
///    (`to <= from`) la herramienta lo reemplazaba en silencio por `from + 24h` y
///    enumeraba una ventana que nadie pidió.
/// 4. **`cancel_events` no entendía «hoy».** `to` se interpretaba sin
///    `endOfDayIfDateOnly`, así que `from: "2026-11-10", to: "2026-11-10"` era la ventana
///    vacía 00:00–00:00: el usuario pedía cancelar las citas del día, no se cancelaba
///    ninguna, y la herramienta contestaba «Cancelled 0 event(s)». `query_schedule` sí lo
///    hacía bien, con lo que las dos herramientas no coincidían sobre qué es un día.
/// 5. **`create_event` aceptaba eventos de duración cero.** Con fecha sin hora,
///    `start == end == medianoche`: se creaba un evento de cero minutos a las 00:00 y se
///    informaba como creado.
/// 6. **Ninguna de las cuatro tenía contrato `status`.** Devolvían prosa en inglés
///    (`"memory unavailable"`, `"No conflicts."`) que el modelo tenía que interpretar.
@MainActor
final class ScheduleToolsContractTests: XCTestCase {

    // MARK: - Andamiaje

    /// Enruta por prefijo de path → (código HTTP, cuerpo JSON). Mismo patrón que
    /// `MemoryClientScheduleTests`, para no necesitar el servicio de memoria levantado.
    final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            let path = (request.url?.path ?? "") + (request.url?.query.map { "?\($0)" } ?? "")
            let key = Self.routes.keys.first { path.hasPrefix($0) } ?? path
            let (status, body) = Self.routes[key] ?? (404, "{}")
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.routes = [:]
        MemoryToolbox.shared.memory = nil
    }

    override func tearDown() {
        StubURLProtocol.routes = [:]
        MemoryToolbox.shared.memory = nil
        super.tearDown()
    }

    /// Instala un cliente de memoria contra el stub HTTP.
    private func installMemory() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        MemoryToolbox.shared.memory = MemoryClient(
            baseURL: URL(string: "http://test.local:8081")!,
            bearerToken: "t",
            session: URLSession(configuration: cfg)
        )
    }

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      "No es JSON: \(out)")
    }

    /// Una rutina que ocupa `[desde, hasta)` el mismo día que `date`, en el formato que
    /// `RoutineHelper.findRoutineConflicts` sabe leer.
    private func routineNodeJSON(overlapping date: Date, label: String = "Trabajo") -> String {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: date)
        let hour = cal.component(.hour, from: date)
        let start = max(0, hour - 1) * 60
        let end = min(23, hour + 2) * 60
        let extra = """
        {\\"days\\":[\(weekday)],\\"startMinutes\\":\(start),\\"endMinutes\\":\(end),\\"title\\":\\"\(label)\\"}
        """.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        {"id":"n1","kind":"routine","label":"\(label)","body":"turno habitual","extra":"\(extra)"}
        """
    }

    // MARK: - Contrato: salida legible por el modelo

    func test_las_cuatro_herramientas_de_agenda_devuelven_json_con_status() async throws {
        // Sin memoria configurada todas caen al camino de "no disponible", pero tienen que
        // devolver JSON con 'status': antes eran la frase suelta "memory unavailable".
        let outputs = [
            await CheckScheduleTool().run(argsJSON: #"{"start":"2026-11-10T08:00","end":"2026-11-10T09:00"}"#),
            await CreateEventTool().run(argsJSON: #"{"title":"dentista","start":"2026-11-10T08:00","end":"2026-11-10T09:00"}"#),
            await QueryScheduleTool().run(argsJSON: #"{"from":"2026-11-10T00:00","to":"2026-11-10T23:59"}"#),
            await CancelEventsTool().run(argsJSON: #"{"from":"2026-11-10T00:00","to":"2026-11-10T23:59"}"#)
        ]
        for out in outputs {
            let parsed = try json(out)
            XCTAssertNotNil(parsed["status"], "Sin 'status': \(out)")
        }
    }

    func test_sin_memoria_el_estado_es_memory_unavailable_y_no_vacio() async throws {
        // "No se pudo saber" no es "no hay nada": si esto dijera 'empty' el modelo le
        // contestaría al usuario "no tienes nada agendado" cuando la verdad es "no lo sé".
        let check = try json(await CheckScheduleTool().run(
            argsJSON: #"{"start":"2026-11-10T08:00","end":"2026-11-10T09:00"}"#))
        XCTAssertEqual(check["status"] as? String, "memory_unavailable")

        let query = try json(await QueryScheduleTool().run(
            argsJSON: #"{"from":"2026-11-10T00:00","to":"2026-11-10T23:59"}"#))
        XCTAssertEqual(query["status"] as? String, "memory_unavailable")
        XCTAssertNotEqual(query["status"] as? String, "empty")
    }

    // MARK: - Defecto 1: afirmar "libre" sin haber podido mirar

    func test_check_schedule_no_afirma_que_esta_libre_si_no_pudo_leer_las_rutinas() async throws {
        installMemory()
        // El servidor contesta que no hay eventos en conflicto, pero la consulta de nodos
        // (de donde salen las rutinas) falla. Media comprobación no es una comprobación.
        StubURLProtocol.routes = [
            "/v1/schedule/check": (200, #"{"conflicts":[]}"#),
            "/v1/nodes": (500, #"{"error":"boom"}"#)
        ]
        let result = try json(await CheckScheduleTool().run(
            argsJSON: #"{"start":"2026-11-10T08:00","end":"2026-11-10T09:00"}"#))

        XCTAssertNotEqual(result["status"] as? String, "free",
                          "No se puede decir 'libre' si las rutinas no se pudieron comprobar.")
        XCTAssertEqual(result["status"] as? String, "partial")
        XCTAssertNotNil(result["warnings"], "El fallo parcial se declara en 'warnings'.")
    }

    func test_create_event_avisa_si_no_pudo_comprobar_las_rutinas() async throws {
        installMemory()
        StubURLProtocol.routes = [
            "/v1/nodes": (500, #"{"error":"boom"}"#),
            "/v1/schedule/create": (200, #"{"created":true,"id":"e1","conflicts":[]}"#)
        ]
        let result = try json(await CreateEventTool().run(
            argsJSON: #"{"title":"dentista","start":"2026-11-10T08:00","end":"2026-11-10T09:00"}"#))

        // El evento sí se creó (el servidor lo confirmó), pero el modelo no puede decir
        // que no choca con nada: la mitad de la comprobación no se hizo.
        XCTAssertEqual(result["status"] as? String, "created_with_warnings")
        XCTAssertNotNil(result["warnings"])
    }

    // MARK: - Defecto 2: solo se miraban los 50 nodos más nuevos

    func test_check_schedule_avisa_si_no_pudo_revisar_todas_las_rutinas() async throws {
        installMemory()
        // El servicio dice que hay 900 nodos pero solo devuelve los que caben: las rutinas
        // que quedaron fuera no se comprobaron, y eso hay que decirlo.
        StubURLProtocol.routes = [
            "/v1/schedule/check": (200, #"{"conflicts":[]}"#),
            "/v1/nodes": (200, #"{"nodes":[],"total":900}"#)
        ]
        let result = try json(await CheckScheduleTool().run(
            argsJSON: #"{"start":"2026-11-10T08:00","end":"2026-11-10T09:00"}"#))
        XCTAssertEqual(result["status"] as? String, "partial")
        XCTAssertNotNil(result["warnings"])
    }

    func test_check_schedule_dice_libre_cuando_de_verdad_pudo_mirar_todo() async throws {
        installMemory()
        StubURLProtocol.routes = [
            "/v1/schedule/check": (200, #"{"conflicts":[]}"#),
            "/v1/nodes": (200, #"{"nodes":[],"total":0}"#)
        ]
        let result = try json(await CheckScheduleTool().run(
            argsJSON: #"{"start":"2026-11-10T08:00","end":"2026-11-10T09:00"}"#))
        XCTAssertEqual(result["status"] as? String, "free")
        XCTAssertNil(result["warnings"])
    }

    func test_check_schedule_encuentra_el_conflicto_con_una_rutina() async throws {
        installMemory()
        // Un hueco dentro del turno habitual del usuario: el conflicto de rutina es
        // justo lo que SP1 existe para detectar.
        let start = Date().addingTimeInterval(3 * 86400)
        let cal = Calendar.current
        let hour = cal.component(.hour, from: start)
        let startISO = ScheduleTime.iso(fromEpoch: start.timeIntervalSince1970)
        let endISO = ScheduleTime.iso(fromEpoch: start.timeIntervalSince1970 + 1800)
        // La rutina solapa solo si la hora elegida deja hueco dentro del día.
        try XCTSkipIf(hour < 1 || hour > 21, "La hora del reloj no deja construir el solape.")

        StubURLProtocol.routes = [
            "/v1/schedule/check": (200, #"{"conflicts":[]}"#),
            "/v1/nodes": (200, #"{"nodes":[\#(routineNodeJSON(overlapping: start))],"total":1}"#)
        ]
        let result = try json(await CheckScheduleTool().run(
            argsJSON: #"{"start":"\#(startISO)","end":"\#(endISO)"}"#))
        XCTAssertEqual(result["status"] as? String, "conflict")
        let conflicts = result["conflicts"] as? [Any]
        XCTAssertEqual(conflicts?.count, 1, "Salida: \(result)")
    }

    // MARK: - Defecto 3: query_schedule se inventaba el rango

    func test_query_schedule_no_inventa_el_rango_si_el_fin_precede_al_inicio() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/schedule/window": (200, #"{"events":[]}"#)]
        let result = try json(await QueryScheduleTool().run(
            argsJSON: #"{"from":"2026-11-10T12:00","to":"2026-11-10T08:00"}"#))

        XCTAssertEqual(result["status"] as? String, "invalid_range")
        XCTAssertNotNil(result["received"], "Hay que poder diagnosticar qué llegó.")
    }

    func test_query_schedule_acepta_una_fecha_suelta_como_el_dia_entero() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/schedule/window": (200, #"{"events":[]}"#)]
        let result = try json(await QueryScheduleTool().run(
            argsJSON: #"{"from":"2026-11-10","to":"2026-11-10"}"#))
        XCTAssertEqual(result["status"] as? String, "empty")
        XCTAssertEqual(result["to"] as? String, "2026-11-10T23:59")
    }

    func test_query_schedule_distingue_vacio_de_fallo() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/schedule/window": (200, #"{"events":[]}"#)]
        let empty = try json(await QueryScheduleTool().run(
            argsJSON: #"{"from":"2026-11-10T00:00","to":"2026-11-10T23:59"}"#))
        XCTAssertEqual(empty["status"] as? String, "empty")

        StubURLProtocol.routes = ["/v1/schedule/window": (500, #"{"error":"boom"}"#)]
        let failed = try json(await QueryScheduleTool().run(
            argsJSON: #"{"from":"2026-11-10T00:00","to":"2026-11-10T23:59"}"#))
        XCTAssertEqual(failed["status"] as? String, "failed")
        XCTAssertNotEqual(failed["status"] as? String, "empty",
                          "Un fallo del servidor no es una agenda vacía.")
    }

    // MARK: - Defecto 4: cancel_events no entendía "hoy"

    func test_cancel_events_toma_una_fecha_suelta_como_el_dia_entero() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/schedule/cancel": (200, #"{"cancelled":2}"#)]
        let result = try json(await CancelEventsTool().run(
            argsJSON: #"{"from":"2026-11-10","to":"2026-11-10"}"#))

        // Antes `to` se quedaba en las 00:00 del día 10: la ventana era vacía y no se
        // cancelaba nada aunque el usuario hubiera pedido cancelar las citas del día.
        XCTAssertEqual(result["to"] as? String, "2026-11-10T23:59",
                       "Una fecha sin hora como fin es el final del día, igual que en query_schedule.")
        XCTAssertEqual(result["status"] as? String, "cancelled")
        XCTAssertEqual(result["cancelled_count"] as? Int, 2)
    }

    func test_cancel_events_distingue_que_no_habia_nada_que_cancelar() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/schedule/cancel": (200, #"{"cancelled":0}"#)]
        let result = try json(await CancelEventsTool().run(
            argsJSON: #"{"from":"2026-11-10T00:00","to":"2026-11-10T23:59"}"#))
        XCTAssertEqual(result["status"] as? String, "nothing_to_cancel")
        XCTAssertNotEqual(result["status"] as? String, "cancelled",
                          "Cancelar cero eventos no es haber cancelado.")
    }

    func test_cancel_events_no_inventa_el_rango_si_el_fin_precede_al_inicio() async throws {
        installMemory()
        StubURLProtocol.routes = ["/v1/schedule/cancel": (200, #"{"cancelled":9}"#)]
        let result = try json(await CancelEventsTool().run(
            argsJSON: #"{"from":"2026-11-10T12:00","to":"2026-11-10T08:00"}"#))
        XCTAssertEqual(result["status"] as? String, "invalid_range")
        XCTAssertNotNil(result["received"])
    }

    // MARK: - Defecto 5: eventos de duración cero

    func test_create_event_rechaza_un_evento_que_empieza_y_acaba_a_la_vez() async throws {
        installMemory()
        StubURLProtocol.routes = [
            "/v1/nodes": (200, #"{"nodes":[],"total":0}"#),
            "/v1/schedule/create": (200, #"{"created":true,"id":"e1","conflicts":[]}"#)
        ]
        // Las dos horas iguales dejan el evento en cero minutos: no es un evento, es un
        // argumento mal escrito. Antes se creaba y se informaba como creado.
        let result = try json(await CreateEventTool().run(
            argsJSON: #"{"title":"dentista","start":"2026-11-10T09:00","end":"2026-11-10T09:00"}"#))
        XCTAssertEqual(result["status"] as? String, "invalid_range")
        XCTAssertNotNil(result["received"])
    }

    /// Esta prueba empezó al revés: exigía `invalid_range` para dos fechas sin hora,
    /// porque antes del arreglo ambas se leían como medianoche y el evento duraba cero
    /// minutos. La premisa era incorrecta: lo que el usuario quiere decir con
    /// «del 10 al 10» (o «del 15 al 20», un viaje) es el día completo, no las 00:00. El
    /// arreglo correcto no es rechazarlo, es leer una fecha suelta como el final del día
    /// — igual que hacen `query_schedule` y `cancel_events`.
    func test_create_event_toma_dos_fechas_sueltas_como_el_dia_entero() async throws {
        installMemory()
        StubURLProtocol.routes = [
            "/v1/nodes": (200, #"{"nodes":[],"total":0}"#),
            "/v1/schedule/create": (200, #"{"created":true,"id":"e1","conflicts":[]}"#)
        ]
        let result = try json(await CreateEventTool().run(
            argsJSON: #"{"title":"viaje a Cuba","start":"2026-11-10","end":"2026-11-10","allDay":true}"#))
        XCTAssertEqual(result["status"] as? String, "created")
        XCTAssertEqual(result["start"] as? String, "2026-11-10T00:00")
        XCTAssertEqual(result["end"] as? String, "2026-11-10T23:59",
                       "Un evento de día entero acaba al final del día, no a su medianoche inicial.")
    }

    func test_create_event_rechaza_un_fin_anterior_al_inicio() async throws {
        installMemory()
        StubURLProtocol.routes = [
            "/v1/nodes": (200, #"{"nodes":[],"total":0}"#),
            "/v1/schedule/create": (200, #"{"created":true,"id":"e1","conflicts":[]}"#)
        ]
        let result = try json(await CreateEventTool().run(
            argsJSON: #"{"title":"dentista","start":"2026-11-10T10:00","end":"2026-11-10T09:00"}"#))
        XCTAssertEqual(result["status"] as? String, "invalid_range")
    }

    func test_create_event_confirma_lo_que_el_servidor_confirmo() async throws {
        installMemory()
        StubURLProtocol.routes = [
            "/v1/nodes": (200, #"{"nodes":[],"total":0}"#),
            "/v1/schedule/create": (200, #"{"created":true,"id":"e1","conflicts":[]}"#)
        ]
        let result = try json(await CreateEventTool().run(
            argsJSON: #"{"title":"dentista","start":"2026-11-10T08:00","end":"2026-11-10T09:00"}"#))
        XCTAssertEqual(result["status"] as? String, "created")
        XCTAssertNil(result["warnings"])
    }

    func test_create_event_no_dice_agendado_cuando_el_servidor_lo_rechazo() async throws {
        installMemory()
        StubURLProtocol.routes = [
            "/v1/nodes": (200, #"{"nodes":[],"total":0}"#),
            "/v1/schedule/create": (200, """
            {"created":false,"id":null,"conflicts":[{"id":"x","title":"viaje a Cuba",\
            "start":1793000000,"end":1793600000,"allDay":true,"location":"Cuba","status":"scheduled"}]}
            """)
        ]
        let result = try json(await CreateEventTool().run(
            argsJSON: #"{"title":"reunión en Miami","start":"2026-11-10T08:00","end":"2026-11-10T09:00"}"#))
        XCTAssertEqual(result["status"] as? String, "conflict")
        XCTAssertEqual((result["conflicts"] as? [Any])?.count, 1)
    }

    // MARK: - Validación de argumentos, que no depende de la memoria

    func test_check_schedule_exige_inicio_y_fin() async throws {
        let result = try json(await CheckScheduleTool().run(argsJSON: #"{"start":"2026-11-10T08:00"}"#))
        XCTAssertEqual(result["status"] as? String, "missing_fields")
        XCTAssertNotNil(result["required"])
    }

    func test_check_schedule_rechaza_una_fecha_ilegible_con_lo_que_llego() async throws {
        let result = try json(await CheckScheduleTool().run(
            argsJSON: #"{"start":"mañana por la mañana","end":"luego"}"#))
        XCTAssertEqual(result["status"] as? String, "invalid_datetime")
        XCTAssertNotNil(result["received"], "Un fallo de formato tiene que ser diagnosticable.")
    }

    func test_create_event_exige_titulo_inicio_y_fin() async throws {
        let result = try json(await CreateEventTool().run(argsJSON: #"{"start":"2026-11-10T08:00"}"#))
        XCTAssertEqual(result["status"] as? String, "missing_fields")
        XCTAssertNotNil(result["required"])
    }

    func test_query_schedule_exige_el_rango() async throws {
        let result = try json(await QueryScheduleTool().run(argsJSON: "{}"))
        XCTAssertEqual(result["status"] as? String, "missing_fields")
    }

    func test_cancel_events_exige_el_rango() async throws {
        let result = try json(await CancelEventsTool().run(argsJSON: "{}"))
        XCTAssertEqual(result["status"] as? String, "missing_fields")
    }

    // MARK: - Lo que el modelo lee en las descripciones

    func test_todas_las_descripciones_declaran_su_contrato_de_status() {
        for description in [CheckScheduleTool.description, CreateEventTool.description,
                            QueryScheduleTool.description, CancelEventsTool.description] {
            XCTAssertTrue(description.lowercased().contains("status"),
                          "El contrato se declara en la descripción: \(description)")
            XCTAssertTrue(description.contains("memory_unavailable"),
                          "El modelo tiene que saber qué significa 'no se pudo saber'.")
        }
    }

    func test_check_schedule_explica_que_partial_no_es_libre() {
        let description = CheckScheduleTool.description
        XCTAssertTrue(description.contains("partial"))
        XCTAssertTrue(description.contains("free"))
    }

    func test_cancel_events_explica_nothing_to_cancel() {
        XCTAssertTrue(CancelEventsTool.description.contains("nothing_to_cancel"))
    }
}
