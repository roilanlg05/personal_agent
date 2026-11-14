import XCTest
@testable import Gemma

/// Los recordatorios solo se podían crear.
///
/// `HybridReminderService` tenía `create` y nada más: no se podían listar, ni mover de
/// hora, ni borrar. Y como un recordatorio se escribe en tres sitios a la vez (la app
/// Recordatorios de Apple, el aviso propio de Gemma y su memoria), borrarlo "a mano"
/// desde la app de Apple dejaba el aviso de Gemma sonando y la memoria creyendo que el
/// compromiso sigue en pie.
///
/// Para poder tocar un recordatorio después hay que saber cuál es, así que ahora queda
/// apuntado en un almacén local junto con su identificador de la app de Apple. Sin ese
/// mapeo, `create` devolvía el identificador de Apple y se tiraba.
final class ReminderPersistenceTests: XCTestCase {

    private func store() -> ReminderPersistence {
        ReminderPersistence(defaults: UserDefaults(suiteName: "test.rem.\(UUID().uuidString)")!)
    }

    private func stored(title: String = "Cita", id: UUID = UUID()) -> StoredReminder {
        StoredReminder(
            id: id,
            title: title,
            due: Date(timeIntervalSince1970: 1_800_000_000),
            destinationName: nil,
            notes: nil,
            alertAt: Date(timeIntervalSince1970: 1_799_996_400),
            leaveBy: nil,
            appleID: "apple-1"
        )
    }

    func test_guarda_y_devuelve() {
        let store = store()
        let one = stored()
        store.add(one)
        XCTAssertEqual(store.all().map(\.id), [one.id])
        XCTAssertEqual(store.all().first?.appleID, "apple-1")
    }

    func test_borra_solo_el_pedido() {
        let store = store()
        let one = stored(title: "Uno")
        let two = stored(title: "Dos")
        store.add(one)
        store.add(two)

        store.remove(id: one.id)

        XCTAssertEqual(store.all().map(\.title), ["Dos"])
    }

    func test_actualizar_reemplaza_sin_duplicar() {
        let store = store()
        let one = stored(title: "Antes")
        store.add(one)

        store.add(StoredReminder(
            id: one.id, title: "Después", due: one.due, destinationName: nil,
            notes: nil, alertAt: one.alertAt, leaveBy: nil, appleID: one.appleID
        ))

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.title, "Después")
    }
}

/// Listar, mover y borrar, con los tres destinos a la vez.
final class HybridReminderCRUDTests: XCTestCase {

    private var now: Date { ISO8601Dates.parse("2026-11-06T06:00:00Z")! }
    private var due: Date { ISO8601Dates.parse("2026-11-06T12:00:00Z")! }

    private func service(
        reminders: StubAppleReminders = StubAppleReminders(),
        alerter: StubReminderAlerter = StubReminderAlerter(),
        memory: StubReminderMemory = StubReminderMemory(),
        persistence: ReminderPersistence
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
            persistence: persistence
        )
    }

    private func store() -> ReminderPersistence {
        ReminderPersistence(defaults: UserDefaults(suiteName: "test.remcrud.\(UUID().uuidString)")!)
    }

    // MARK: - Leer

    func test_crear_deja_el_recordatorio_apuntado_con_su_id_de_apple() async throws {
        let store = store()
        let reminders = StubAppleReminders()
        let service = service(reminders: reminders, persistence: store)

        let created = try await service.create(title: "Dentista", due: due, now: now)

        let listed = try XCTUnwrap(service.list().first)
        XCTAssertEqual(listed.id, created.reminder.id)
        XCTAssertEqual(listed.title, "Dentista")
        XCTAssertEqual(
            listed.appleID, reminders.created.first?.reminder.id.uuidString,
            "Sin guardar el identificador de Apple no se puede tocar el recordatorio después."
        )
    }

    func test_listar_lo_que_no_hay() {
        XCTAssertTrue(service(persistence: store()).list().isEmpty)
    }

    func test_listar_contrasta_con_la_app_de_apple() async throws {
        // El usuario tacha el recordatorio en la app de Apple: Gemma tiene que poder
        // decir que ya está hecho en vez de insistir con el compromiso.
        let store = store()
        let reminders = StubAppleReminders()
        let service = service(reminders: reminders, persistence: store)
        let created = try await service.create(title: "Dentista", due: due, now: now)
        reminders.completed.insert(created.reminder.id.uuidString)

        let rows = await service.listWithAppleState()

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].completedInApple, true)
    }

    // MARK: - Mover de hora

    func test_mover_la_hora_reprograma_los_avisos() async throws {
        let store = store()
        let alerter = StubReminderAlerter()
        let service = service(alerter: alerter, persistence: store)
        let created = try await service.create(title: "Dentista", due: due, now: now)
        let alertsBefore = alerter.scheduled.count

        let later = due.addingTimeInterval(3600)
        let updated = try await service.update(id: created.reminder.id, due: later, now: now)

        XCTAssertEqual(updated.plan.due, later)
        XCTAssertTrue(
            alerter.cancelled.contains(created.reminder.id),
            "Los avisos viejos hay que retirarlos o avisará a las dos horas."
        )
        XCTAssertGreaterThan(alerter.scheduled.count, alertsBefore, "Y programar los nuevos.")
        XCTAssertEqual(service.list().first?.due, later)
    }

    func test_mover_actualiza_el_recordatorio_de_apple_en_vez_de_duplicarlo() async throws {
        let store = store()
        let reminders = StubAppleReminders()
        let service = service(reminders: reminders, persistence: store)
        let created = try await service.create(title: "Dentista", due: due, now: now)

        _ = try await service.update(id: created.reminder.id, due: due.addingTimeInterval(3600), now: now)

        XCTAssertEqual(reminders.created.count, 1, "No se crea otro: se actualiza el que hay.")
        XCTAssertEqual(reminders.updated.count, 1)
    }

    func test_cambiar_solo_el_titulo_conserva_la_hora() async throws {
        let store = store()
        let service = service(persistence: store)
        let created = try await service.create(title: "Dentista", due: due, now: now)

        _ = try await service.update(id: created.reminder.id, title: "Dentista (Dr. Ruiz)", now: now)

        XCTAssertEqual(service.list().first?.title, "Dentista (Dr. Ruiz)")
        XCTAssertEqual(service.list().first?.due, due)
    }

    func test_corregir_el_titulo_de_uno_que_ya_paso_no_se_rechaza() async throws {
        // El usuario corrige el nombre de un recordatorio de ayer. Exigirle que la hora
        // sea futura para cambiar un texto lo dejaría sin poder arreglar nada: la hora
        // solo se valida cuando la hora es lo que se cambia.
        let store = store()
        let service = service(persistence: store)
        let created = try await service.create(title: "Dentista", due: due, now: now)

        let muchLater = due.addingTimeInterval(48 * 3600)
        let updated = try await service.update(
            id: created.reminder.id, title: "Dentista Dr. Ruiz", now: muchLater
        )

        XCTAssertEqual(updated.reminder.title, "Dentista Dr. Ruiz")
        XCTAssertTrue(updated.plan.isLate, "Y se marca como pasado, sin fingir que aún da tiempo.")
        XCTAssertEqual(service.list().first?.title, "Dentista Dr. Ruiz")
    }

    func test_mover_a_una_hora_que_ya_paso_si_se_rechaza() async throws {
        // Cambiar la hora a una que ya pasó sí es un error: el aviso no podría sonar.
        let store = store()
        let service = service(persistence: store)
        let created = try await service.create(title: "Dentista", due: due, now: now)

        do {
            _ = try await service.update(
                id: created.reminder.id,
                due: now.addingTimeInterval(-3600),
                now: now
            )
            XCTFail("Mover al pasado tiene que fallar.")
        } catch {
            XCTAssertEqual(error as? ReminderLeadTimeError, .dueDateInThePast)
        }
    }

    func test_mover_algo_que_no_existe() async throws {
        let service = service(persistence: store())
        do {
            _ = try await service.update(id: UUID(), due: due, now: now)
            XCTFail("Debe decir que no lo encontró.")
        } catch {
            XCTAssertEqual(error as? ReminderServiceError, .notFound)
        }
    }

    // MARK: - Borrar

    func test_borrar_limpia_los_tres_destinos() async throws {
        let store = store()
        let reminders = StubAppleReminders()
        let alerter = StubReminderAlerter()
        let memory = StubReminderMemory()
        let service = service(reminders: reminders, alerter: alerter, memory: memory, persistence: store)
        let created = try await service.create(title: "Dentista", due: due, now: now)

        let outcome = try await service.delete(id: created.reminder.id)

        XCTAssertTrue(outcome.removedFromAppleReminders)
        XCTAssertTrue(outcome.alertsCancelled)
        XCTAssertTrue(outcome.removedFromMemory)
        XCTAssertTrue(service.list().isEmpty)
        XCTAssertTrue(
            alerter.cancelled.contains(created.reminder.id),
            "Sin esto el aviso de Gemma suena para un recordatorio ya borrado."
        )
        XCTAssertEqual(memory.forgotten, [created.reminder.id])
    }

    func test_borrar_cuenta_lo_que_fallo_sin_dejar_de_borrar_el_resto() async throws {
        // Si la app de Apple no deja borrar, el aviso de Gemma hay que retirarlo igual:
        // lo contrario deja sonando un recordatorio que el usuario cree borrado.
        let store = store()
        let reminders = StubAppleReminders()
        let alerter = StubReminderAlerter()
        let service = service(reminders: reminders, alerter: alerter, persistence: store)
        let created = try await service.create(title: "Dentista", due: due, now: now)
        reminders.deleteError = ReminderServiceError.noRemindersCalendar

        let outcome = try await service.delete(id: created.reminder.id)

        XCTAssertFalse(outcome.removedFromAppleReminders)
        XCTAssertTrue(outcome.alertsCancelled)
        XCTAssertFalse(outcome.failures.isEmpty, "Hay que poder contarle al usuario qué quedó sin limpiar.")
        XCTAssertTrue(service.list().isEmpty)
    }

    func test_borrar_algo_que_no_existe() async throws {
        let service = service(persistence: store())
        do {
            _ = try await service.delete(id: UUID())
            XCTFail("Debe decir que no lo encontró.")
        } catch {
            XCTAssertEqual(error as? ReminderServiceError, .notFound)
        }
    }

    func test_borrar_deja_de_vigilar_el_viaje() async throws {
        let store = store()
        let monitor = ReminderMonitor(
            estimator: StubTravelEstimator(seconds: 900),
            alerter: StubReminderAlerter()
        )
        let service = HybridReminderService(
            reminders: StubAppleReminders(),
            alerter: StubReminderAlerter(),
            memory: StubReminderMemory(),
            calculator: ReminderLeadTimeCalculator(estimator: StubTravelEstimator(seconds: 900)),
            planner: ReminderCheckpointPlanner(),
            monitor: monitor,
            persistence: store
        )
        let created = try await service.create(
            title: "Dentista", due: due,
            destination: ReminderDestination(name: "la clínica"), now: now
        )
        let trackedBefore = await monitor.trackedIDs()
        XCTAssertTrue(trackedBefore.contains(created.reminder.id))

        _ = try await service.delete(id: created.reminder.id)

        let trackedAfter = await monitor.trackedIDs()
        XCTAssertFalse(
            trackedAfter.contains(created.reminder.id),
            "Si se sigue vigilando, el monitor reprograma avisos de un recordatorio borrado."
        )
    }
}
