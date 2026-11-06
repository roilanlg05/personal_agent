import XCTest
@testable import Gemma

/// Las herramientas con las que el modelo ve, mueve y borra recordatorios.
///
/// La resolución es por texto porque el usuario dice "el del dentista", y con más de una
/// candidata se pregunta: borrar el recordatorio equivocado se descubre cuando no suena
/// el que hacía falta.
final class ReminderCRUDToolTests: XCTestCase {

    private var now: Date { ISO8601Dates.parse("2026-11-06T06:00:00Z")! }
    private var due: Date { ISO8601Dates.parse("2026-11-06T12:00:00Z")! }

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func makeService(
        reminders: StubAppleReminders = StubAppleReminders(),
        alerter: StubReminderAlerter = StubReminderAlerter(),
        memory: StubReminderMemory = StubReminderMemory()
    ) -> HybridReminderService {
        HybridReminderService(
            reminders: reminders,
            alerter: alerter,
            memory: memory,
            calculator: ReminderLeadTimeCalculator(estimator: StubTravelEstimator(seconds: nil)),
            planner: ReminderCheckpointPlanner(),
            monitor: ReminderMonitor(
                estimator: StubTravelEstimator(seconds: nil),
                alerter: StubReminderAlerter()
            ),
            persistence: ReminderPersistence(
                defaults: UserDefaults(suiteName: "test.remtools.\(UUID().uuidString)")!
            )
        )
    }

    // MARK: - list_reminders

    func test_list_enumera_con_hora_y_aviso() async throws {
        let service = makeService()
        _ = try await service.create(title: "Dentista", due: due, now: now)

        let result = try json(await ListRemindersTool(service: service).run(argsJSON: "{}"))

        XCTAssertEqual(result["status"] as? String, "ok", "Salida: \(result)")
        let rows = try XCTUnwrap(result["reminders"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["title"] as? String, "Dentista")
        XCTAssertNotNil(rows[0]["due"])
        XCTAssertNotNil(rows[0]["alert_at"])
        XCTAssertNotNil(rows[0]["id"], "Sin el id el modelo no puede moverlo ni borrarlo.")
    }

    func test_list_sin_nada_lo_dice_claro() async throws {
        let result = try json(await ListRemindersTool(service: makeService()).run(argsJSON: "{}"))
        XCTAssertEqual(result["status"] as? String, "empty")
    }

    func test_list_marca_lo_que_el_usuario_ya_tacho_en_apple() async throws {
        let reminders = StubAppleReminders()
        let service = makeService(reminders: reminders)
        let created = try await service.create(title: "Dentista", due: due, now: now)
        reminders.completed.insert(created.reminder.id.uuidString)

        let result = try json(await ListRemindersTool(service: service).run(argsJSON: "{}"))

        let rows = try XCTUnwrap(result["reminders"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["completed_in_apple"] as? Bool, true)
        XCTAssertEqual(result["pending_count"] as? Int, 0, "No hay que insistir con uno ya hecho.")
    }

    // MARK: - update_reminder

    func test_update_mueve_la_hora() async throws {
        let service = makeService()
        _ = try await service.create(title: "Dentista", due: due, now: now)

        let result = try json(await UpdateReminderTool(service: service)
            .run(argsJSON: #"{"title": "dentista", "due_date": "2026-11-06T16:00:00Z"}"#))

        XCTAssertEqual(result["status"] as? String, "updated", "Salida: \(result)")
        XCTAssertEqual(service.list().first?.due, ISO8601Dates.parse("2026-11-06T16:00:00Z"))
        XCTAssertNotNil(result["alert_at"], "El usuario necesita saber la hora nueva del aviso.")
    }

    func test_update_no_duplica_el_recordatorio() async throws {
        let service = makeService()
        _ = try await service.create(title: "Dentista", due: due, now: now)

        _ = await UpdateReminderTool(service: service)
            .run(argsJSON: #"{"title": "dentista", "due_date": "2026-11-06T16:00:00Z"}"#)

        XCTAssertEqual(service.list().count, 1, "Mover no es crear otro.")
    }

    func test_update_cambia_solo_el_titulo() async throws {
        let service = makeService()
        _ = try await service.create(title: "Dentista", due: due, now: now)

        let result = try json(await UpdateReminderTool(service: service)
            .run(argsJSON: #"{"title": "dentista", "new_title": "Dentista Dr. Ruiz"}"#))

        XCTAssertEqual(result["status"] as? String, "updated")
        XCTAssertEqual(service.list().first?.title, "Dentista Dr. Ruiz")
        XCTAssertEqual(service.list().first?.due, due, "La hora no se tocó.")
    }

    func test_update_sin_nada_que_cambiar() async throws {
        let service = makeService()
        _ = try await service.create(title: "Dentista", due: due, now: now)

        let result = try json(await UpdateReminderTool(service: service)
            .run(argsJSON: #"{"title": "dentista"}"#))

        XCTAssertEqual(result["status"] as? String, "nothing_to_change")
    }

    func test_update_con_fecha_ilegible_no_toca_nada() async throws {
        let service = makeService()
        _ = try await service.create(title: "Dentista", due: due, now: now)

        let result = try json(await UpdateReminderTool(service: service)
            .run(argsJSON: #"{"title": "dentista", "due_date": "mañana por la tarde", "new_title": "Otro"}"#))

        XCTAssertEqual(result["status"] as? String, "invalid_date")
        XCTAssertEqual(result["received"] as? String, "mañana por la tarde")
        XCTAssertEqual(
            service.list().first?.title, "Dentista",
            "Si la fecha es ilegible no se aplica el resto a medias."
        )
    }

    func test_update_con_fecha_sin_hora_pide_la_hora() async throws {
        let service = makeService()
        _ = try await service.create(title: "Dentista", due: due, now: now)

        let result = try json(await UpdateReminderTool(service: service)
            .run(argsJSON: #"{"title": "dentista", "due_date": "2026-11-07"}"#))

        XCTAssertEqual(result["status"] as? String, "needs_time")
    }

    func test_update_de_algo_que_no_existe() async throws {
        let result = try json(await UpdateReminderTool(service: makeService())
            .run(argsJSON: #"{"title": "nada", "due_date": "2026-11-06T16:00:00Z"}"#))

        XCTAssertEqual(result["status"] as? String, "not_found")
    }

    func test_update_ambiguo_no_cambia_ninguno() async throws {
        let service = makeService()
        _ = try await service.create(title: "Cita médica", due: due, now: now)
        _ = try await service.create(title: "Cita dentista", due: due.addingTimeInterval(7200), now: now)

        let result = try json(await UpdateReminderTool(service: service)
            .run(argsJSON: #"{"title": "cita", "due_date": "2026-11-06T18:00:00Z"}"#))

        XCTAssertEqual(result["status"] as? String, "ambiguous")
        XCTAssertEqual((result["candidates"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(service.list().map(\.due).sorted(), [due, due.addingTimeInterval(7200)])
    }

    // MARK: - delete_reminder

    func test_delete_lo_quita_de_todos_los_sitios() async throws {
        let reminders = StubAppleReminders()
        let alerter = StubReminderAlerter()
        let memory = StubReminderMemory()
        let service = makeService(reminders: reminders, alerter: alerter, memory: memory)
        let created = try await service.create(title: "Dentista", due: due, now: now)

        let result = try json(await DeleteReminderTool(service: service)
            .run(argsJSON: #"{"title": "dentista"}"#))

        XCTAssertEqual(result["status"] as? String, "deleted", "Salida: \(result)")
        let removed = try XCTUnwrap(result["removed_from"] as? [String])
        XCTAssertTrue(removed.contains("apple_reminders"))
        XCTAssertTrue(removed.contains("gemma_alert"))
        XCTAssertTrue(service.list().isEmpty)
        XCTAssertTrue(alerter.cancelled.contains(created.reminder.id))
    }

    func test_delete_por_id() async throws {
        let service = makeService()
        let created = try await service.create(title: "Dentista", due: due, now: now)

        let result = try json(await DeleteReminderTool(service: service)
            .run(argsJSON: #"{"id": "\#(created.reminder.id.uuidString)"}"#))

        XCTAssertEqual(result["status"] as? String, "deleted")
    }

    func test_delete_avisa_de_lo_que_quedo_sin_limpiar() async throws {
        let reminders = StubAppleReminders()
        let service = makeService(reminders: reminders)
        _ = try await service.create(title: "Dentista", due: due, now: now)
        reminders.deleteError = ReminderServiceError.noRemindersCalendar

        let result = try json(await DeleteReminderTool(service: service)
            .run(argsJSON: #"{"title": "dentista"}"#))

        XCTAssertEqual(result["status"] as? String, "deleted")
        XCTAssertNotNil(result["warnings"], "El usuario tiene que saber que le queda uno en la app de Apple.")
        let removed = try XCTUnwrap(result["removed_from"] as? [String])
        XCTAssertFalse(removed.contains("apple_reminders"))
        XCTAssertTrue(removed.contains("gemma_alert"), "El aviso se retira igual: es lo que suena.")
    }

    func test_delete_de_algo_que_no_existe() async throws {
        let result = try json(await DeleteReminderTool(service: makeService())
            .run(argsJSON: #"{"title": "nada"}"#))

        XCTAssertEqual(result["status"] as? String, "not_found")
    }

    func test_delete_ambiguo_no_borra_ninguno() async throws {
        let service = makeService()
        _ = try await service.create(title: "Cita médica", due: due, now: now)
        _ = try await service.create(title: "Cita dentista", due: due.addingTimeInterval(7200), now: now)

        let result = try json(await DeleteReminderTool(service: service)
            .run(argsJSON: #"{"title": "cita"}"#))

        XCTAssertEqual(result["status"] as? String, "ambiguous")
        XCTAssertEqual(service.list().count, 2)
    }

    func test_delete_sin_criterio_no_borra() async throws {
        let service = makeService()
        _ = try await service.create(title: "Dentista", due: due, now: now)

        let result = try json(await DeleteReminderTool(service: service).run(argsJSON: "{}"))

        XCTAssertEqual(result["status"] as? String, "not_found")
        XCTAssertEqual(service.list().count, 1)
    }

    // MARK: - Lo que el modelo lee

    func test_la_descripcion_de_update_desaconseja_crear_otro() {
        let description = UpdateReminderTool.description.lowercased()
        XCTAssertTrue(
            description.contains("create_reminder"),
            "Sin esto el modelo mueve la hora creando un segundo recordatorio."
        )
    }

    func test_el_titulo_exacto_gana_al_parcial() async throws {
        // "Cita" existe y "Cita dentista" también: pedir "cita" tiene que resolver a la
        // exacta en vez de quedarse en duda.
        let service = makeService()
        _ = try await service.create(title: "Cita", due: due, now: now)
        _ = try await service.create(title: "Cita dentista", due: due.addingTimeInterval(7200), now: now)

        let result = try json(await DeleteReminderTool(service: service)
            .run(argsJSON: #"{"title": "Cita"}"#))

        XCTAssertEqual(result["status"] as? String, "deleted")
        XCTAssertEqual(service.list().map(\.title), ["Cita dentista"])
    }
}
