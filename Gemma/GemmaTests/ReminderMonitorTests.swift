import XCTest
@testable import Gemma

/// El usuario se mueve, así que la hora de salida cambia. Lo que estas pruebas protegen
/// es que el aviso siga siendo correcto cuando eso pasa, y que no se gaste mapa ni
/// batería cuando todavía falta mucho.
final class ReminderMonitorTests: XCTestCase {

    private var due: Date { ISO8601Dates.parse("2026-11-06T16:15:00Z")! }

    private func reminder() -> GemmaReminder {
        GemmaReminder(title: "la cita", due: due, destination: ReminderDestination(name: "Clínica"))
    }

    private func monitor(
        travel: TimeInterval?,
        alerter: StubReminderAlerter,
        estimator: StubTravelEstimator? = nil
    ) -> ReminderMonitor {
        ReminderMonitor(
            estimator: estimator ?? StubTravelEstimator(seconds: travel),
            alerter: alerter,
            planner: ReminderCheckpointPlanner()
        )
    }

    private func track(
        _ monitor: ReminderMonitor,
        _ reminder: GemmaReminder,
        travel: TimeInterval,
        now: String
    ) async {
        let checkpoints = ReminderCheckpointPlanner().checkpoints(
            due: reminder.due,
            travelTime: travel,
            now: ISO8601Dates.parse(now)!
        )
        await monitor.track(reminder, travelTime: travel, checkpoints: checkpoints)
    }

    // MARK: - La ventana de una hora

    func test_lejosDelCompromisoNiSeConsultaElMapa() async {
        let estimator = StubTravelEstimator(seconds: 15 * 60)
        let alerter = StubReminderAlerter()
        let monitor = monitor(travel: nil, alerter: alerter, estimator: estimator)
        let reminder = reminder()
        await track(monitor, reminder, travel: 15 * 60, now: "2026-11-06T12:00:00Z")

        // Faltan cuatro horas: fuera de la ventana de seguimiento.
        let outcomes = await monitor.refresh(now: ISO8601Dates.parse("2026-11-06T12:15:00Z")!)

        XCTAssertEqual(outcomes, [.outsideWindow(reminder.id)])
        XCTAssertTrue(estimator.requestedDestinations.isEmpty, "No se gasta mapa tan pronto.")
        XCTAssertTrue(alerter.scheduled.isEmpty)
    }

    func test_dentroDeLaUltimaHoraSiSeRecalcula() async {
        let estimator = StubTravelEstimator(seconds: 15 * 60)
        let monitor = monitor(travel: nil, alerter: StubReminderAlerter(), estimator: estimator)
        await track(monitor, reminder(), travel: 15 * 60, now: "2026-11-06T12:00:00Z")

        _ = await monitor.refresh(now: ISO8601Dates.parse("2026-11-06T15:30:00Z")!)

        XCTAssertEqual(estimator.requestedDestinations, ["Clínica"])
    }

    // MARK: - El viaje cambia

    func test_siElUsuarioSeAlejaLosAvisosSeAdelantan() async throws {
        // Se creó con 15 minutos de viaje (salida 16:00). Ahora está a 40 minutos, así
        // que hay que salir a las 15:35: el aviso de salir se adelanta 25 minutos.
        let alerter = StubReminderAlerter()
        let monitor = monitor(travel: 40 * 60, alerter: alerter)
        let reminder = reminder()
        await track(monitor, reminder, travel: 15 * 60, now: "2026-11-06T12:00:00Z")

        let outcomes = await monitor.refresh(now: ISO8601Dates.parse("2026-11-06T15:20:00Z")!)

        guard case .rescheduled(let id, let leaveBy, let previous) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("Debió reprogramar: \(outcomes)")
        }
        XCTAssertEqual(id, reminder.id)
        XCTAssertEqual(leaveBy, ISO8601Dates.parse("2026-11-06T15:35:00Z"))
        XCTAssertEqual(previous, ISO8601Dates.parse("2026-11-06T16:00:00Z"))

        XCTAssertEqual(alerter.cancelled, [reminder.id], "Los avisos viejos se borran.")
        XCTAssertEqual(alerter.scheduled.last?.date, ISO8601Dates.parse("2026-11-06T15:35:00Z"))
    }

    func test_siSeAcercaLosAvisosSeRetrasan() async throws {
        let alerter = StubReminderAlerter()
        let monitor = monitor(travel: 5 * 60, alerter: alerter)
        await track(monitor, reminder(), travel: 15 * 60, now: "2026-11-06T12:00:00Z")

        let outcomes = await monitor.refresh(now: ISO8601Dates.parse("2026-11-06T15:20:00Z")!)

        guard case .rescheduled(_, let leaveBy, _) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("Debió reprogramar: \(outcomes)")
        }
        XCTAssertEqual(leaveBy, ISO8601Dates.parse("2026-11-06T16:10:00Z"))
    }

    func test_uncambioMinimoNoMueveNada() async {
        // Un minuto de diferencia no merece reprogramar: solo haría ruido de avisos.
        let alerter = StubReminderAlerter()
        let monitor = monitor(travel: 16 * 60, alerter: alerter)
        let reminder = reminder()
        await track(monitor, reminder, travel: 15 * 60, now: "2026-11-06T12:00:00Z")

        let outcomes = await monitor.refresh(now: ISO8601Dates.parse("2026-11-06T15:20:00Z")!)

        XCTAssertEqual(outcomes, [.unchanged(reminder.id)])
        XCTAssertTrue(alerter.scheduled.isEmpty)
        XCTAssertTrue(alerter.cancelled.isEmpty)
    }

    func test_siElMapaNoContestaSeQuedaLaEstimacionAnterior() async {
        let alerter = StubReminderAlerter()
        let monitor = monitor(travel: nil, alerter: alerter)
        let reminder = reminder()
        await track(monitor, reminder, travel: 15 * 60, now: "2026-11-06T12:00:00Z")

        let outcomes = await monitor.refresh(now: ISO8601Dates.parse("2026-11-06T15:20:00Z")!)

        XCTAssertEqual(outcomes, [.unchanged(reminder.id)])
        XCTAssertTrue(alerter.cancelled.isEmpty, "No se borra un aviso bueno por no poder recalcular.")
    }

    // MARK: - Ya tarde y ya pasado

    func test_siLaSalidaYaPasoElAvisoSaleDeInmediato() async throws {
        // Son las 15:50 y ahora el viaje es de 40 minutos: tendría que haber salido a
        // las 15:35.
        let alerter = StubReminderAlerter()
        let monitor = monitor(travel: 40 * 60, alerter: alerter)
        await track(monitor, reminder(), travel: 15 * 60, now: "2026-11-06T12:00:00Z")

        let now = ISO8601Dates.parse("2026-11-06T15:50:00Z")!
        _ = await monitor.refresh(now: now)

        let leaveAlert = try XCTUnwrap(alerter.scheduled.first { $0.kind == .leaveNow })
        XCTAssertEqual(leaveAlert.date, now)
        XCTAssertTrue(leaveAlert.body.lowercased().contains("ya"), "Debe urgir: \(leaveAlert.body)")
    }

    func test_unCompromisoPasadoSeSueltaYSeLimpia() async {
        let alerter = StubReminderAlerter()
        let monitor = monitor(travel: 15 * 60, alerter: alerter)
        let reminder = reminder()
        await track(monitor, reminder, travel: 15 * 60, now: "2026-11-06T12:00:00Z")

        let outcomes = await monitor.refresh(now: ISO8601Dates.parse("2026-11-06T17:00:00Z")!)

        XCTAssertEqual(outcomes, [.finished(reminder.id)])
        XCTAssertEqual(alerter.cancelled, [reminder.id])
        let tracked = await monitor.trackedIDs()
        XCTAssertTrue(tracked.isEmpty)
    }

    // MARK: - Sin lugar no hay nada que recalcular

    func test_sinLugarNoSeConsultaElMapa() async {
        let estimator = StubTravelEstimator(seconds: 15 * 60)
        let monitor = monitor(travel: nil, alerter: StubReminderAlerter(), estimator: estimator)
        let reminder = GemmaReminder(title: "la reunión", due: due)
        let checkpoints = ReminderCheckpointPlanner().checkpoints(
            due: due, travelTime: nil, now: ISO8601Dates.parse("2026-11-06T12:00:00Z")!
        )
        await monitor.track(reminder, travelTime: nil, checkpoints: checkpoints)

        let outcomes = await monitor.refresh(now: ISO8601Dates.parse("2026-11-06T15:30:00Z")!)

        XCTAssertEqual(outcomes, [.unchanged(reminder.id)])
        XCTAssertTrue(estimator.requestedDestinations.isEmpty)
    }

    // MARK: - Alta y baja

    func test_untrackCancelaLosAvisos() async {
        let alerter = StubReminderAlerter()
        let monitor = monitor(travel: 15 * 60, alerter: alerter)
        let reminder = reminder()
        await track(monitor, reminder, travel: 15 * 60, now: "2026-11-06T12:00:00Z")

        await monitor.untrack(id: reminder.id)

        XCTAssertEqual(alerter.cancelled, [reminder.id])
        let tracked = await monitor.trackedIDs()
        XCTAssertTrue(tracked.isEmpty)
    }

    func test_elServicioDaDeAltaLosRecordatoriosConLugar() async throws {
        let alerter = StubReminderAlerter()
        let monitor = monitor(travel: 15 * 60, alerter: StubReminderAlerter())
        let service = HybridReminderService(
            reminders: StubAppleReminders(),
            alerter: alerter,
            memory: StubReminderMemory(),
            calculator: ReminderLeadTimeCalculator(estimator: StubTravelEstimator(seconds: 15 * 60)),
            planner: ReminderCheckpointPlanner(),
            monitor: monitor
        )

        let created = try await service.create(
            title: "la cita",
            due: due,
            destination: ReminderDestination(name: "Clínica"),
            now: ISO8601Dates.parse("2026-11-06T12:00:00Z")!
        )

        let tracked = await monitor.trackedIDs()
        XCTAssertEqual(tracked, [created.reminder.id])
    }

    func test_elServicioNoSigueLoQueNoTieneLugar() async throws {
        let monitor = monitor(travel: nil, alerter: StubReminderAlerter())
        let service = HybridReminderService(
            reminders: StubAppleReminders(),
            alerter: StubReminderAlerter(),
            memory: StubReminderMemory(),
            calculator: ReminderLeadTimeCalculator(estimator: StubTravelEstimator(seconds: nil)),
            planner: ReminderCheckpointPlanner(),
            monitor: monitor
        )

        _ = try await service.create(
            title: "la reunión",
            due: due,
            now: ISO8601Dates.parse("2026-11-06T12:00:00Z")!
        )

        let tracked = await monitor.trackedIDs()
        XCTAssertTrue(tracked.isEmpty, "Sin sitio no hay viaje que recalcular.")
    }
}
