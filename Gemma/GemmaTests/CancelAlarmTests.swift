import XCTest
@testable import Gemma

/// Gemma podía poner alarmas y temporizadores, y no podía quitarlos.
///
/// `ClockService` solo tenía `createAlarm`, `createTimer` y las listas. No existía
/// ninguna cancelación, ni en el servicio ni como herramienta, aunque
/// `SystemAlarmScheduling.cancel(id:)` ya estaba ahí sin usar. El resultado práctico:
/// "pon una alarma a las 6" funcionaba y "quita la alarma de las 6" no tenía respuesta
/// posible. El usuario solo podía pararla cuando ya estaba sonando.
///
/// La cancelación se verifica contra el sistema antes de limpiar la lista de Gemma, por
/// la misma razón que `list_alarms`: decir "cancelada" cuando el sistema sigue
/// teniéndola puesta es la clase de mentira que hizo desconfiar de las alarmas.
final class ClockServiceCancelTests: XCTestCase {

    private func service(
        _ system: MockSystemAlarmScheduler = MockSystemAlarmScheduler(),
        scheduler: MockClockScheduler = MockClockScheduler()
    ) -> ClockService {
        ClockService(
            systemScheduler: system,
            scheduler: scheduler,
            defaults: UserDefaults(suiteName: "test.cancel.\(UUID().uuidString)")!
        )
    }

    func test_cancelar_una_alarma_la_quita_del_sistema_y_de_la_lista() async throws {
        let system = MockSystemAlarmScheduler()
        let clock = service(system)
        let created = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)

        let outcome = try await clock.cancelAlarm(id: created.alarm.id)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(system.cancelled.contains(created.alarm.id), "Hay que cancelarla en el sistema, no solo olvidarla.")
        XCTAssertTrue(clock.listAlarms().isEmpty, "Y quitarla de la lista de Gemma.")
    }

    func test_cancelar_un_temporizador() async throws {
        let system = MockSystemAlarmScheduler()
        let clock = service(system)
        let created = try await clock.createTimer(durationSeconds: 600, label: "Pasta")

        let outcome = try await clock.cancelTimer(id: created.timer.id)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(clock.listTimers().isEmpty)
    }

    func test_una_alarma_que_el_sistema_ya_no_tiene_se_limpia_y_se_dice() async throws {
        // El usuario la paró desde la pantalla de aviso: el sistema la soltó y Gemma
        // seguía teniéndola apuntada. Cancelarla es limpiar la lista, y hay que contarlo
        // como lo que es, no como una cancelación que nadie hizo.
        let system = MockSystemAlarmScheduler()
        let clock = service(system)
        let created = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)
        system.forgetAll()

        let outcome = try await clock.cancelAlarm(id: created.alarm.id)

        XCTAssertEqual(outcome, .wasNotScheduled)
        XCTAssertTrue(clock.listAlarms().isEmpty)
    }

    func test_si_el_sistema_no_puede_cancelar_no_se_miente_ni_se_limpia() async throws {
        let system = MockSystemAlarmScheduler()
        let clock = service(system)
        let created = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)
        system.errorToThrow = SystemAlarmError.unsupported

        do {
            _ = try await clock.cancelAlarm(id: created.alarm.id)
            XCTFail("Debe propagar el fallo: la alarma sigue puesta.")
        } catch {
            XCTAssertEqual(
                clock.listAlarms().count, 1,
                "Si no se pudo cancelar, Gemma tiene que seguir sabiendo que está puesta."
            )
        }
    }

    func test_cancelar_algo_que_nunca_existio() async throws {
        let clock = service()
        let outcome = try await clock.cancelAlarm(id: UUID())
        XCTAssertEqual(outcome, .notFound)
    }

    func test_sin_alarmas_del_sistema_se_cancela_la_notificacion() async throws {
        // macOS, o iOS anterior a 26: la alarma es una notificación local y hay que
        // retirarla del centro de notificaciones, o seguirá sonando.
        let scheduler = MockClockScheduler()
        let clock = service(MockSystemAlarmScheduler(isSupported: false), scheduler: scheduler)
        let created = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)

        let outcome = try await clock.cancelAlarm(id: created.alarm.id)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(
            scheduler.cancelledNotifications.contains(created.alarm.id),
            "Sin esto la notificación sigue programada y suena una alarma ya cancelada."
        )
        XCTAssertTrue(clock.listAlarms().isEmpty)
    }

    func test_cancelar_una_alarma_no_toca_las_demas() async throws {
        let clock = service()
        let uno = try await clock.createAlarm(title: "Seis", hour: 6, minute: 0)
        _ = try await clock.createAlarm(title: "Siete", hour: 7, minute: 0)

        _ = try await clock.cancelAlarm(id: uno.alarm.id)

        XCTAssertEqual(clock.listAlarms().map(\.hour), [7])
    }
}

/// La herramienta que el modelo usa para cancelar. Resuelve por hora o por título,
/// porque el usuario dice "quita la alarma de las 6", no un UUID.
final class CancelAlarmToolTests: XCTestCase {

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func service() -> ClockService {
        ClockService(
            systemScheduler: MockSystemAlarmScheduler(),
            scheduler: MockClockScheduler(),
            defaults: UserDefaults(suiteName: "test.cancetool.\(UUID().uuidString)")!
        )
    }

    func test_cancela_por_hora() async throws {
        let clock = service()
        _ = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)

        let result = try json(await CancelAlarmTool(clockService: clock).run(argsJSON: #"{"time": "06:00"}"#))

        XCTAssertEqual(result["status"] as? String, "cancelled", "Salida: \(result)")
        XCTAssertTrue(clock.listAlarms().isEmpty)
    }

    func test_cancela_por_titulo() async throws {
        let clock = service()
        _ = try await clock.createAlarm(title: "Despertar temprano", hour: 6, minute: 0)

        let result = try json(await CancelAlarmTool(clockService: clock).run(argsJSON: #"{"title": "despertar"}"#))

        XCTAssertEqual(result["status"] as? String, "cancelled")
    }

    func test_cancela_por_id() async throws {
        let clock = service()
        let created = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)

        let result = try json(await CancelAlarmTool(clockService: clock)
            .run(argsJSON: #"{"id": "\#(created.alarm.id.uuidString)"}"#))

        XCTAssertEqual(result["status"] as? String, "cancelled")
    }

    func test_cancela_un_temporizador_por_etiqueta() async throws {
        let clock = service()
        _ = try await clock.createTimer(durationSeconds: 600, label: "Pasta")

        let result = try json(await CancelAlarmTool(clockService: clock).run(argsJSON: #"{"title": "pasta"}"#))

        XCTAssertEqual(result["status"] as? String, "cancelled")
        XCTAssertEqual(result["kind"] as? String, "timer")
        XCTAssertTrue(clock.listTimers().isEmpty)
    }

    func test_dos_alarmas_a_la_misma_hora_se_preguntan() async throws {
        let clock = service()
        _ = try await clock.createAlarm(title: "Trabajo", hour: 6, minute: 0)
        _ = try await clock.createAlarm(title: "Gimnasio", hour: 6, minute: 0)

        let result = try json(await CancelAlarmTool(clockService: clock).run(argsJSON: #"{"time": "06:00"}"#))

        XCTAssertEqual(result["status"] as? String, "ambiguous")
        XCTAssertEqual((result["candidates"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(clock.listAlarms().count, 2, "Mientras haya duda no se cancela nada.")
    }

    func test_cancelar_todas_cuando_se_pide_explicitamente() async throws {
        let clock = service()
        _ = try await clock.createAlarm(title: "Seis", hour: 6, minute: 0)
        _ = try await clock.createAlarm(title: "Siete", hour: 7, minute: 0)
        _ = try await clock.createTimer(durationSeconds: 60, label: "Huevo")

        let result = try json(await CancelAlarmTool(clockService: clock).run(argsJSON: #"{"all": true}"#))

        XCTAssertEqual(result["status"] as? String, "cancelled")
        XCTAssertEqual(result["cancelled_count"] as? Int, 3)
        XCTAssertTrue(clock.listAlarms().isEmpty)
        XCTAssertTrue(clock.listTimers().isEmpty)
    }

    func test_lo_que_no_existe_se_dice_sin_inventar() async throws {
        let result = try json(await CancelAlarmTool(clockService: service()).run(argsJSON: #"{"time": "09:00"}"#))

        XCTAssertEqual(result["status"] as? String, "not_found")
    }

    func test_sin_criterio_pide_uno() async throws {
        let clock = service()
        _ = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)

        let result = try json(await CancelAlarmTool(clockService: clock).run(argsJSON: #"{}"#))

        XCTAssertEqual(result["status"] as? String, "needs_criteria")
        XCTAssertEqual(clock.listAlarms().count, 1, "Sin criterio no se borra nada por si acaso.")
    }

    func test_una_alarma_que_el_sistema_ya_solto_se_cuenta_aparte() async throws {
        let system = MockSystemAlarmScheduler()
        let clock = ClockService(
            systemScheduler: system,
            scheduler: MockClockScheduler(),
            defaults: UserDefaults(suiteName: "test.cancetool.\(UUID().uuidString)")!
        )
        _ = try await clock.createAlarm(title: "Despertar", hour: 6, minute: 0)
        system.forgetAll()

        let result = try json(await CancelAlarmTool(clockService: clock).run(argsJSON: #"{"time": "06:00"}"#))

        XCTAssertEqual(result["status"] as? String, "was_not_scheduled")
        let message = try XCTUnwrap(result["message"] as? String)
        XCTAssertTrue(message.lowercased().contains("ya no"), "Hay que explicar que no estaba puesta: \(message)")
    }

    func test_la_descripcion_cubre_alarmas_y_temporizadores() {
        let description = CancelAlarmTool.description.lowercased()
        XCTAssertTrue(description.contains("temporizador"))
        XCTAssertTrue(description.contains("cancelled"))
    }
}
