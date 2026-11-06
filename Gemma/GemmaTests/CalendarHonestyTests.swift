import XCTest
@testable import Gemma

/// Calendario simulado. `accessGranted == false` reproduce el caso real en el que el
/// usuario todavía no ha concedido el permiso de EventKit.
final class StubCalendarManager: CalendarManaging, @unchecked Sendable {
    private let lock = NSLock()
    var accessGranted: Bool
    var events: [CalendarEventDTO]
    var updateCalls: [(id: String, title: String?, startDate: Date?, endDate: Date?)] = []
    var accessRequests = 0

    init(accessGranted: Bool = true, events: [CalendarEventDTO] = []) {
        self.accessGranted = accessGranted
        self.events = events
    }

    func requestAccess() async throws -> Bool {
        lock.lock(); accessRequests += 1; let granted = accessGranted; lock.unlock()
        return granted
    }

    func getEvents(from startDate: Date, to endDate: Date) async throws -> [CalendarEventDTO] {
        guard try await requestAccess() else { throw CalendarServiceError.permissionDenied }
        lock.lock(); defer { lock.unlock() }
        return events
    }

    func createEvent(title: String, startDate: Date, endDate: Date,
                     location: String?, notes: String?) async throws -> CalendarEventDTO {
        guard try await requestAccess() else { throw CalendarServiceError.permissionDenied }
        lock.lock(); createCalls.append((title, startDate, endDate)); lock.unlock()
        return CalendarEventDTO(id: "new", title: title, startDate: startDate,
                                endDate: endDate, location: location, notes: notes)
    }

    func updateEvent(id: String, title: String?, startDate: Date?, endDate: Date?,
                     location: String?, notes: String?) async throws -> CalendarEventDTO {
        guard try await requestAccess() else { throw CalendarServiceError.permissionDenied }
        lock.lock()
        updateCalls.append((id, title, startDate, endDate))
        lock.unlock()
        return CalendarEventDTO(
            id: id,
            title: title ?? "Sin título",
            startDate: startDate ?? Date(timeIntervalSince1970: 0),
            endDate: endDate ?? Date(timeIntervalSince1970: 3600),
            location: location,
            notes: notes
        )
    }

    func deleteEvent(id: String) async throws -> Bool {
        guard try await requestAccess() else { throw CalendarServiceError.permissionDenied }
        lock.lock(); defer { lock.unlock() }
        if let missingEventIDs, missingEventIDs.contains(id) {
            throw CalendarServiceError.eventNotFound(id)
        }
        deleteCalls.append(id)
        return deleteSucceeds
    }

    // MARK: - Añadido para probar create/delete

    /// Lo que el tool mandó crear. Sirve para comprobar que cuando el tool se niega a
    /// adivinar una hora que falta, de verdad NO llega a crear nada.
    var createCalls: [(title: String, startDate: Date, endDate: Date)] = []
    var deleteCalls: [String] = []
    /// IDs que el calendario no tiene: borrarlos lanza `eventNotFound`.
    var missingEventIDs: Set<String>?
    /// `false` reproduce el caso en que EventKit dice que no borró nada.
    var deleteSucceeds = true
}

final class CalendarHonestyTests: XCTestCase {

    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                      "La salida debe ser JSON válido. got: \(out)")
    }

    // MARK: - Defecto 6: sin permiso no se dice "no tienes nada"

    func test_event_kit_manager_requests_access_before_reading_events() async {
        // El manager real debe pedir acceso en getEvents igual que en create/update/delete:
        // sin permiso, `store.events(matching:)` devuelve una lista vacía indistinguible
        // de una agenda realmente vacía.
        let manager = EventKitCalendarManager(accessRequester: { false })
        do {
            _ = try await manager.getEvents(from: Date(), to: Date().addingTimeInterval(3600))
            XCTFail("Sin permiso getEvents debe fallar, no devolver una lista vacía.")
        } catch let error as CalendarServiceError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func test_get_calendar_events_distinguishes_missing_permission_from_empty_agenda() async throws {
        let denied = StubCalendarManager(accessGranted: false)
        let tool = ListCalendarEventsTool(service: AppleCalendarService(manager: denied))
        let out = await tool.run(
            argsJSON: #"{"start_date": "2026-11-05T00:00:00Z", "end_date": "2026-11-05T23:59:59Z"}"#
        )
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "permission_required", "got: \(out)")
        XCTAssertNil(json["events"], "Sin permiso no se puede afirmar que la agenda esté vacía.")
        XCTAssertGreaterThan(denied.accessRequests, 0)
    }

    func test_get_calendar_events_reports_truly_empty_agenda() async throws {
        let granted = StubCalendarManager(accessGranted: true, events: [])
        let tool = ListCalendarEventsTool(service: AppleCalendarService(manager: granted))
        let out = await tool.run(
            argsJSON: #"{"start_date": "2026-11-05T00:00:00Z", "end_date": "2026-11-05T23:59:59Z"}"#
        )
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "ok", "got: \(out)")
        XCTAssertEqual((json["events"] as? [[String: Any]])?.count, 0)
    }

    func test_get_calendar_events_output_is_valid_json_with_hostile_title() async throws {
        let nasty = "Cita con \"el jefe\"\nsalto\ttab"
        let granted = StubCalendarManager(accessGranted: true, events: [
            CalendarEventDTO(id: "1", title: nasty,
                             startDate: Date(timeIntervalSince1970: 0),
                             endDate: Date(timeIntervalSince1970: 3600),
                             location: "Oficina \"central\"", notes: nil)
        ])
        let tool = ListCalendarEventsTool(service: AppleCalendarService(manager: granted))
        let out = await tool.run(
            argsJSON: #"{"start_date": "2026-11-05T00:00:00Z", "end_date": "2026-11-05T23:59:59Z"}"#
        )
        let json = try parse(out)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["title"] as? String, nasty)
    }

    // MARK: - Defecto 8: una fecha mal formada no se ignora

    func test_update_calendar_event_rejects_unparseable_start_date() async throws {
        let manager = StubCalendarManager(accessGranted: true)
        let tool = UpdateCalendarEventTool(service: AppleCalendarService(manager: manager))
        let out = await tool.run(argsJSON: #"{"id": "abc", "start_date": "el jueves por la tarde"}"#)
        let json = try parse(out)
        XCTAssertNotEqual(json["status"] as? String, "updated",
                          "Una fecha ilegible no puede reportarse como actualización. got: \(out)")
        let error = try XCTUnwrap(json["error"] as? String, "got: \(out)")
        XCTAssertTrue(error.contains("ISO8601"), "El error debe explicar el formato esperado. got: \(error)")
        XCTAssertTrue(manager.updateCalls.isEmpty, "No debe tocar el evento si la fecha no se entiende.")
    }

    /// Antes esta misma fecha se rechazaba, y no es ilegible: es la hora local escrita
    /// con un espacio en vez de la "T". Rechazarla obligaba al usuario a repetirse.
    func test_update_calendar_event_accepts_a_local_time_without_zone() async throws {
        let manager = StubCalendarManager(accessGranted: true)
        let tool = UpdateCalendarEventTool(service: AppleCalendarService(manager: manager))
        let out = await tool.run(argsJSON: #"{"id": "abc", "start_date": "2026-11-06 15:00"}"#)
        let json = try parse(out)
        XCTAssertNil(json["error"] as? String, "got: \(out)")
        XCTAssertEqual(manager.updateCalls.count, 1)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = try XCTUnwrap(manager.updateCalls.first?.startDate)
        XCTAssertEqual(calendar.component(.hour, from: start), 15)
        XCTAssertEqual(calendar.component(.day, from: start), 6)
    }

    func test_update_calendar_event_rejects_unparseable_end_date() async throws {
        let manager = StubCalendarManager(accessGranted: true)
        let tool = UpdateCalendarEventTool(service: AppleCalendarService(manager: manager))
        let out = await tool.run(argsJSON: #"{"id": "abc", "end_date": "mañana por la tarde"}"#)
        let json = try parse(out)
        XCTAssertNotNil(json["error"] as? String, "got: \(out)")
        XCTAssertTrue(manager.updateCalls.isEmpty)
    }

    func test_update_calendar_event_accepts_valid_iso8601() async throws {
        let manager = StubCalendarManager(accessGranted: true)
        let tool = UpdateCalendarEventTool(service: AppleCalendarService(manager: manager))
        let out = await tool.run(
            argsJSON: #"{"id": "abc", "start_date": "2026-11-06T15:00:00Z", "end_date": "2026-11-06T16:00:00Z"}"#
        )
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "updated", "got: \(out)")
        XCTAssertEqual(manager.updateCalls.count, 1)
        XCTAssertNotNil(manager.updateCalls.first?.startDate)
    }

    func test_update_calendar_event_accepts_fractional_seconds() async throws {
        let manager = StubCalendarManager(accessGranted: true)
        let tool = UpdateCalendarEventTool(service: AppleCalendarService(manager: manager))
        let out = await tool.run(argsJSON: #"{"id": "abc", "start_date": "2026-11-06T15:00:00.500Z"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "updated", "got: \(out)")
    }

    func test_update_calendar_event_output_is_valid_json_with_hostile_title() async throws {
        let manager = StubCalendarManager(accessGranted: true)
        let tool = UpdateCalendarEventTool(service: AppleCalendarService(manager: manager))
        let nasty = "Reunión \"urgente\"\ncon \\todos"
        let args = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: ["id": "abc", "title": nasty]),
            encoding: .utf8
        ))
        let out = await tool.run(argsJSON: args)
        let json = try parse(out)
        let event = try XCTUnwrap(json["event"] as? [String: Any])
        XCTAssertEqual(event["title"] as? String, nasty)
    }

    func test_update_calendar_event_reports_permission_required() async throws {
        let manager = StubCalendarManager(accessGranted: false)
        let tool = UpdateCalendarEventTool(service: AppleCalendarService(manager: manager))
        let out = await tool.run(argsJSON: #"{"id": "abc", "title": "x"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "permission_required", "got: \(out)")
    }
}
