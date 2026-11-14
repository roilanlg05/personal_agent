import XCTest
@testable import Gemma

/// El usuario puso una alarma, Gemma dijo que estaba puesta, y él no la encontró en
/// ninguna parte. La alarma existía (el sistema la tenía como `scheduled`), pero no hay
/// forma de verla: las alarmas de AlarmKit no salen en la app Reloj de Apple y Gemma no
/// tenía manera de enumerarlas.
///
/// Esta herramienta cierra ese hueco, y su fuente de verdad es el sistema, no la lista
/// que Gemma se apunta: si las dos discrepan, lo que vale es lo que el sistema tiene.
final class ListAlarmsToolTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "test.listalarms.\(UUID().uuidString)")!
        return suite
    }

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func service(
        _ system: MockSystemAlarmScheduler
    ) -> ClockService {
        ClockService(
            systemScheduler: system,
            scheduler: MockClockScheduler(),
            defaults: defaults()
        )
    }

    func test_lista_las_alarmas_puestas_con_su_hora() async throws {
        let system = MockSystemAlarmScheduler()
        let clock = service(system)
        _ = try await clock.createAlarm(title: "Despertar", hour: 7, minute: 5)

        let result = try json(await ListAlarmsTool(clockService: clock).run(argsJSON: "{}"))

        XCTAssertEqual(result["status"] as? String, "ok")
        let alarms = try XCTUnwrap(result["alarms"] as? [[String: Any]])
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(alarms[0]["title"] as? String, "Despertar")
        XCTAssertEqual(alarms[0]["time"] as? String, "07:05")
        XCTAssertEqual(alarms[0]["in_system"] as? Bool, true)
    }

    func test_una_alarma_que_el_sistema_ya_no_tiene_se_marca() async throws {
        // Pasa si el usuario la paró desde la pantalla de la alarma: Gemma la tiene
        // apuntada y el sistema no. Decir que sigue puesta sería mentir.
        let system = MockSystemAlarmScheduler()
        let clock = service(system)
        _ = try await clock.createAlarm(title: "Despertar", hour: 7, minute: 5)
        system.forgetAll()

        let result = try json(await ListAlarmsTool(clockService: clock).run(argsJSON: "{}"))

        let alarms = try XCTUnwrap(result["alarms"] as? [[String: Any]])
        XCTAssertEqual(alarms[0]["in_system"] as? Bool, false)
    }

    func test_lista_los_temporizadores() async throws {
        let system = MockSystemAlarmScheduler()
        let clock = service(system)
        _ = try await clock.createTimer(durationSeconds: 600, label: "Pasta")

        let result = try json(await ListAlarmsTool(clockService: clock).run(argsJSON: "{}"))

        let timers = try XCTUnwrap(result["timers"] as? [[String: Any]])
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers[0]["label"] as? String, "Pasta")
        XCTAssertEqual(timers[0]["duration_minutes"] as? Int, 10)
    }

    func test_sin_nada_puesto_lo_dice_claro() async throws {
        let result = try json(await ListAlarmsTool(clockService: service(MockSystemAlarmScheduler()))
            .run(argsJSON: "{}"))

        XCTAssertEqual(result["status"] as? String, "empty")
        XCTAssertEqual((result["alarms"] as? [[String: Any]])?.count, 0)
    }

    func test_avisa_de_que_no_salen_en_la_app_reloj() async throws {
        // Es la pregunta que el usuario va a hacer, y la respuesta honesta no está en
        // ninguna otra parte: Apple no da API para escribir en la app Reloj.
        let system = MockSystemAlarmScheduler()
        let clock = service(system)
        _ = try await clock.createAlarm(title: "Despertar", hour: 7, minute: 5)

        let result = try json(await ListAlarmsTool(clockService: clock).run(argsJSON: "{}"))

        let note = try XCTUnwrap(result["note"] as? String)
        XCTAssertTrue(note.lowercased().contains("reloj"), "Debe explicar dónde viven: \(note)")
    }

    func test_en_plataformas_sin_alarmas_del_sistema_no_finge_saber() async throws {
        let system = MockSystemAlarmScheduler(isSupported: false)
        let clock = service(system)
        _ = try await clock.createAlarm(title: "Despertar", hour: 7, minute: 5)

        let result = try json(await ListAlarmsTool(clockService: clock).run(argsJSON: "{}"))

        let alarms = try XCTUnwrap(result["alarms"] as? [[String: Any]])
        XCTAssertNil(alarms[0]["in_system"], "Sin alarmas del sistema no hay nada que confirmar.")
        XCTAssertEqual(alarms[0]["method"] as? String, "gemma_notification")
    }

    func test_la_descripcion_dice_que_no_estan_en_la_app_reloj() {
        let description = ListAlarmsTool.description.lowercased()
        XCTAssertTrue(description.contains("reloj"))
    }
}
