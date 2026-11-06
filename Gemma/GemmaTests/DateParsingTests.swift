import XCTest
@testable import Gemma

/// Un modelo pequeño escribe la fecha de muchas formas, y casi todas son razonables.
/// Rechazarlas obliga al usuario a repetir la petición, que es lo que pasó con
/// `create_reminder`: "Formato de fecha inválido" ante una fecha perfectamente clara.
///
/// Lo que NO se hace es adivinar: una fecha sin hora se reporta como fecha sin hora,
/// para que Gemma pregunte a qué hora en vez de inventarse la medianoche.
final class DateParsingTests: XCTestCase {

    private let madrid = TimeZone(identifier: "Europe/Madrid")!

    private func components(_ date: Date, _ zone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    // MARK: - Lo que ya funcionaba, y sigue

    func test_iso_completo_en_utc() {
        XCTAssertEqual(
            ISO8601Dates.parse("2026-11-06T08:30:00Z"),
            Date(timeIntervalSince1970: 1_793_953_800)
        )
    }

    func test_iso_con_desplazamiento_horario() throws {
        let date = try XCTUnwrap(ISO8601Dates.parse("2026-11-06T08:30:00-05:00"))
        XCTAssertEqual(components(date, TimeZone(identifier: "America/New_York")!).hour, 8)
    }

    func test_iso_con_fraccion_de_segundo() {
        XCTAssertNotNil(ISO8601Dates.parse("2026-11-06T08:30:00.250Z"))
    }

    // MARK: - Lo que fallaba

    func test_sin_zona_se_interpreta_en_la_hora_del_usuario() throws {
        // "2026-11-06T08:30:00" significa las 8:30 de donde está el usuario. Antes esto
        // se rechazaba, y es justo lo que escribe un modelo al que se le da la hora
        // local en el prompt.
        let date = try XCTUnwrap(ISO8601Dates.parse("2026-11-06T08:30:00", timeZone: madrid))
        let parts = components(date, madrid)
        XCTAssertEqual(parts.hour, 8)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertEqual(parts.day, 6)
    }

    func test_sin_segundos() throws {
        let date = try XCTUnwrap(ISO8601Dates.parse("2026-11-06T08:30", timeZone: madrid))
        XCTAssertEqual(components(date, madrid).hour, 8)
        XCTAssertEqual(components(date, madrid).minute, 30)
    }

    func test_con_espacio_en_vez_de_T() throws {
        let date = try XCTUnwrap(ISO8601Dates.parse("2026-11-06 08:30:00", timeZone: madrid))
        XCTAssertEqual(components(date, madrid).hour, 8)
    }

    func test_sin_zona_y_sin_segundos_con_espacio() throws {
        XCTAssertNotNil(ISO8601Dates.parse("2026-11-06 08:30", timeZone: madrid))
    }

    func test_espacios_alrededor_no_molestan() {
        XCTAssertNotNil(ISO8601Dates.parse("  2026-11-06T08:30:00Z  "))
    }

    // MARK: - Fecha sin hora: se reconoce, pero se marca

    func test_solo_fecha_se_parsea_al_principio_del_dia() throws {
        let parsed = try XCTUnwrap(ISO8601Dates.parseDetailed("2026-11-06", timeZone: madrid))
        XCTAssertFalse(parsed.hasTime, "Hay que poder distinguir que no venía la hora.")
        XCTAssertEqual(components(parsed.date, madrid).hour, 0)
        XCTAssertEqual(components(parsed.date, madrid).day, 6)
    }

    func test_una_fecha_con_hora_se_marca_como_tal() throws {
        let parsed = try XCTUnwrap(ISO8601Dates.parseDetailed("2026-11-06T08:30:00Z"))
        XCTAssertTrue(parsed.hasTime)
    }

    // MARK: - Lo que sigue siendo inválido

    func test_basura_sigue_siendo_invalida() {
        XCTAssertNil(ISO8601Dates.parse("mañana por la mañana"))
        XCTAssertNil(ISO8601Dates.parse(""))
        XCTAssertNil(ISO8601Dates.parse("06/11/2026"))
    }
}

/// El recordatorio necesita una hora. Si no la hay, Gemma tiene que preguntarla, no
/// poner el recordatorio a medianoche ni rechazar la fecha como si fuera ilegible.
final class CreateReminderDateHandlingTests: XCTestCase {

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func tool() -> CreateReminderTool {
        CreateReminderTool(service: HybridReminderService(
            reminders: StubAppleReminders(),
            alerter: StubReminderAlerter(),
            memory: StubReminderMemory(),
            calculator: ReminderLeadTimeCalculator(estimator: StubTravelEstimator(seconds: nil)),
            planner: ReminderCheckpointPlanner(),
            monitor: ReminderMonitor(
                estimator: StubTravelEstimator(seconds: nil),
                alerter: StubReminderAlerter()
            )
        ))
    }

    func test_una_fecha_sin_zona_se_acepta() async throws {
        let future = ISO8601DateFormatter()
        let iso = future.string(from: Date().addingTimeInterval(3 * 3600))
        // Se le quita la Z para simular lo que escribe el modelo con la hora local.
        let local = String(iso.dropLast())
        let result = try json(await tool().run(argsJSON: #"{"title": "la cita", "due_date": "\#(local)"}"#))

        XCTAssertEqual(result["status"] as? String, "created", "Salida: \(result)")
    }

    func test_una_fecha_sin_hora_pide_la_hora() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let result = try json(await tool().run(
            argsJSON: #"{"title": "la cita", "due_date": "\#(formatter.string(from: tomorrow))"}"#
        ))

        XCTAssertEqual(result["status"] as? String, "needs_time")
        let message = try XCTUnwrap(result["message"] as? String)
        XCTAssertTrue(message.lowercased().contains("hora"), "Debe pedir la hora: \(message)")
    }

    func test_basura_sigue_dando_invalid_date() async throws {
        let result = try json(await tool().run(argsJSON: #"{"title": "x", "due_date": "mañana"}"#))
        XCTAssertEqual(result["status"] as? String, "invalid_date")
    }

    func test_el_mensaje_de_fecha_invalida_dice_que_llego() async throws {
        // Sin esto, un fallo de formato es imposible de diagnosticar: el tool no decía
        // qué había recibido.
        let result = try json(await tool().run(argsJSON: #"{"title": "x", "due_date": "06/11/2026"}"#))
        XCTAssertEqual(result["received"] as? String, "06/11/2026")
    }
}
