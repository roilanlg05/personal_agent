import XCTest
@testable import Gemma

/// `create_calendar_event` y `delete_calendar_event` ya declaraban estados en su
/// descripción, pero no tenían ni una prueba. Al escribirlas salieron tres cosas
/// (el doble `StubCalendarManager` vive en `CalendarHonestyTests.swift`):
///
/// 1. **`create_calendar_event` se inventaba la hora.** Usaba `ISO8601Dates.parse`, que
///    descarta el `hasTime` de `parseDetailed`. Con una fecha sin hora («el dentista el
///    10 de noviembre») se quedaba con la medianoche, y como el fin también era
///    medianoche creaba un evento de **cero minutos a las 00:00** y contestaba
///    `status: "created"`. El usuario acababa con un evento que no se parecía a lo que
///    pidió, y Gemma le había dicho que estaba hecho. El propio comentario de
///    `ISO8601Dates` dice que una fecha sin hora se devuelve marcada «para que quien la
///    use pregunte la hora»; este tool era el que no lo hacía.
/// 2. **No validaba que el fin fuera posterior al inicio**, así que aceptaba eventos
///    invertidos o de duración cero y los informaba como creados.
/// 3. **Los errores de argumentos salían sin `status`.** Usaban
///    `ToolJSONOutput.error(...)`, que emite `{"error": "..."}`. La descripción le dice al
///    modelo que lea `status`, y en ese camino no había ninguno: el modelo recibía una
///    forma que no esperaba justo cuando algo había ido mal.
final class CalendarCreateDeleteHonestyTests: XCTestCase {

    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      "La salida debe ser JSON válido. got: \(out)")
    }

    private func createTool(_ manager: StubCalendarManager) -> CreateCalendarEventTool {
        CreateCalendarEventTool(service: AppleCalendarService(manager: manager))
    }

    private func deleteTool(_ manager: StubCalendarManager) -> DeleteCalendarEventTool {
        DeleteCalendarEventTool(service: AppleCalendarService(manager: manager))
    }

    // MARK: - Defecto 1: inventarse la hora que falta

    func test_create_calendar_event_pide_la_hora_cuando_solo_llego_la_fecha() async throws {
        let manager = StubCalendarManager()
        let out = await createTool(manager).run(
            argsJSON: #"{"title": "dentista", "start_date": "2026-11-10", "end_date": "2026-11-10"}"#
        )
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "needs_time", "got: \(out)")
        XCTAssertNotNil(json["received"], "Un fallo de formato tiene que ser diagnosticable.")
    }

    func test_create_calendar_event_no_crea_nada_cuando_falta_la_hora() async throws {
        let manager = StubCalendarManager()
        _ = await createTool(manager).run(
            argsJSON: #"{"title": "dentista", "start_date": "2026-11-10", "end_date": "2026-11-10"}"#
        )
        // Lo importante no es el texto de la respuesta: es que no quede un evento de cero
        // minutos a medianoche en el calendario del usuario.
        XCTAssertTrue(manager.createCalls.isEmpty,
                      "Se creó un evento con una hora inventada: \(manager.createCalls)")
    }

    func test_create_calendar_event_pide_la_hora_aunque_solo_falte_en_el_fin() async throws {
        let manager = StubCalendarManager()
        let out = await createTool(manager).run(
            argsJSON: #"{"title": "dentista", "start_date": "2026-11-10T09:00", "end_date": "2026-11-10"}"#
        )
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "needs_time", "got: \(out)")
        XCTAssertTrue(manager.createCalls.isEmpty)
    }

    // MARK: - Defecto 2: eventos invertidos o de duración cero

    func test_create_calendar_event_rechaza_un_fin_anterior_al_inicio() async throws {
        let manager = StubCalendarManager()
        let out = await createTool(manager).run(
            argsJSON: #"{"title": "dentista", "start_date": "2026-11-10T10:00", "end_date": "2026-11-10T09:00"}"#
        )
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "invalid_range", "got: \(out)")
        XCTAssertTrue(manager.createCalls.isEmpty)
    }

    func test_create_calendar_event_rechaza_un_evento_de_duracion_cero() async throws {
        let manager = StubCalendarManager()
        let out = await createTool(manager).run(
            argsJSON: #"{"title": "dentista", "start_date": "2026-11-10T09:00", "end_date": "2026-11-10T09:00"}"#
        )
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "invalid_range", "got: \(out)")
    }

    // MARK: - Defecto 3: errores de argumentos sin `status`

    func test_create_calendar_event_sin_argumentos_trae_status() async throws {
        let json = try parse(await createTool(StubCalendarManager()).run(argsJSON: #"{"title": "dentista"}"#))
        XCTAssertEqual(json["status"] as? String, "missing_fields")
        XCTAssertNotNil(json["required"], "Dile al modelo qué le falta.")
    }

    func test_create_calendar_event_con_fecha_ilegible_trae_status_y_lo_que_llego() async throws {
        let out = await createTool(StubCalendarManager()).run(
            argsJSON: #"{"title": "dentista", "start_date": "mañana por la tarde", "end_date": "luego"}"#
        )
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "invalid_datetime", "got: \(out)")
        XCTAssertNotNil(json["received"])
    }

    func test_delete_calendar_event_sin_id_trae_status() async throws {
        let json = try parse(await deleteTool(StubCalendarManager()).run(argsJSON: "{}"))
        XCTAssertEqual(json["status"] as? String, "missing_fields")
        XCTAssertNotNil(json["required"])
    }

    // MARK: - Los caminos que sí funcionaban, ahora cubiertos

    func test_create_calendar_event_confirma_lo_que_de_verdad_creo() async throws {
        let manager = StubCalendarManager()
        let out = await createTool(manager).run(
            argsJSON: #"{"title": "dentista", "start_date": "2026-11-10T09:00", "end_date": "2026-11-10T10:00", "location": "Clínica"}"#
        )
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "created", "got: \(out)")
        XCTAssertEqual(manager.createCalls.count, 1)
        XCTAssertEqual(manager.createCalls.first?.title, "dentista")
        let event = try XCTUnwrap(json["event"] as? [String: Any])
        XCTAssertEqual(event["title"] as? String, "dentista")
    }

    func test_create_calendar_event_acepta_una_hora_local_sin_zona() async throws {
        // Es la forma que más escribe el modelo; rechazarla hacía repetir la petición.
        let manager = StubCalendarManager()
        let out = await createTool(manager).run(
            argsJSON: #"{"title": "x", "start_date": "2026-11-10 09:00", "end_date": "2026-11-10 10:00"}"#
        )
        XCTAssertEqual(try parse(out)["status"] as? String, "created", "got: \(out)")
    }

    func test_create_calendar_event_reporta_permission_required() async throws {
        let manager = StubCalendarManager(accessGranted: false)
        let out = await createTool(manager).run(
            argsJSON: #"{"title": "x", "start_date": "2026-11-10T09:00", "end_date": "2026-11-10T10:00"}"#
        )
        XCTAssertEqual(try parse(out)["status"] as? String, "permission_required", "got: \(out)")
    }

    func test_create_calendar_event_salida_json_valida_con_titulo_hostil() async throws {
        let manager = StubCalendarManager()
        let nasty = "Reunión \"urgente\"\ncon \\todos"
        let args = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: [
                "title": nasty, "start_date": "2026-11-10T09:00", "end_date": "2026-11-10T10:00"
            ]),
            encoding: .utf8
        ))
        let json = try parse(await createTool(manager).run(argsJSON: args))
        let event = try XCTUnwrap(json["event"] as? [String: Any])
        XCTAssertEqual(event["title"] as? String, nasty)
    }

    func test_delete_calendar_event_confirma_lo_que_borro() async throws {
        let manager = StubCalendarManager()
        let json = try parse(await deleteTool(manager).run(argsJSON: #"{"id": "abc"}"#))
        XCTAssertEqual(json["status"] as? String, "deleted")
        XCTAssertEqual(json["id"] as? String, "abc")
        XCTAssertEqual(manager.deleteCalls, ["abc"])
    }

    func test_delete_calendar_event_dice_not_found_cuando_el_evento_no_existe() async throws {
        // La descripción promete el estado 'not_found'; hasta hoy nadie había comprobado
        // que de verdad llegue a salir.
        let manager = StubCalendarManager()
        manager.missingEventIDs = ["abc"]
        let out = await deleteTool(manager).run(argsJSON: #"{"id": "abc"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "not_found", "got: \(out)")
    }

    func test_delete_calendar_event_reporta_permission_required() async throws {
        let manager = StubCalendarManager(accessGranted: false)
        let out = await deleteTool(manager).run(argsJSON: #"{"id": "abc"}"#)
        XCTAssertEqual(try parse(out)["status"] as? String, "permission_required", "got: \(out)")
    }

    func test_delete_calendar_event_no_dice_borrado_si_el_sistema_dijo_que_no() async throws {
        let manager = StubCalendarManager()
        manager.deleteSucceeds = false
        let out = await deleteTool(manager).run(argsJSON: #"{"id": "abc"}"#)
        let json = try parse(out)
        XCTAssertNotEqual(json["status"] as? String, "deleted",
                          "EventKit dijo que no borró nada; no se puede afirmar que sí.")
        XCTAssertEqual(json["status"] as? String, "error")
    }

    // MARK: - Lo que el modelo lee en las descripciones

    func test_create_calendar_event_declara_que_pide_la_hora() {
        let description = CreateCalendarEventTool.description
        XCTAssertTrue(description.contains("needs_time"),
                      "El modelo tiene que saber que si falta la hora se le pide, no se inventa.")
        XCTAssertTrue(description.contains("invalid_range"))
    }

    func test_delete_calendar_event_declara_sus_estados() {
        let description = DeleteCalendarEventTool.description
        for status in ["deleted", "permission_required", "not_found", "missing_fields"] {
            XCTAssertTrue(description.contains(status), "Falta '\(status)' en la descripción.")
        }
    }
}
