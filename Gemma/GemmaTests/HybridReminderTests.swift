import XCTest
@testable import Gemma

final class StubAppleReminders: AppleRemindersManaging, @unchecked Sendable {
    var accessGranted: Bool
    var errorToThrow: Error?
    private(set) var created: [(reminder: GemmaReminder, alertAt: Date)] = []

    init(accessGranted: Bool = true, errorToThrow: Error? = nil) {
        self.accessGranted = accessGranted
        self.errorToThrow = errorToThrow
    }

    /// Identificadores que el usuario ya tachó en la app de Apple.
    var completed: Set<String> = []
    var updateError: Error?
    var deleteError: Error?
    private(set) var updated: [(appleID: String, reminder: GemmaReminder, alertAt: Date)] = []
    private(set) var deleted: [String] = []

    func requestAccess() async -> Bool { accessGranted }

    func create(reminder: GemmaReminder, alertAt: Date) async throws -> String {
        if let errorToThrow { throw errorToThrow }
        created.append((reminder, alertAt))
        return reminder.id.uuidString
    }

    func update(appleID: String, reminder: GemmaReminder, alertAt: Date) async throws {
        if let updateError { throw updateError }
        updated.append((appleID, reminder, alertAt))
    }

    func delete(appleID: String) async throws {
        if let deleteError { throw deleteError }
        deleted.append(appleID)
    }

    func isCompleted(appleID: String) async -> Bool? {
        completed.contains(appleID)
    }
}

final class StubReminderAlerter: ReminderAlerting, @unchecked Sendable {
    var authorized: Bool
    var errorToThrow: Error?
    private(set) var scheduled: [(id: UUID, kind: ReminderCheckpointKind, body: String, date: Date)] = []
    private(set) var cancelled: [UUID] = []

    init(authorized: Bool = true, errorToThrow: Error? = nil) {
        self.authorized = authorized
        self.errorToThrow = errorToThrow
    }

    func requestAuthorization() async -> Bool { authorized }

    func scheduleAlert(
        id: UUID,
        kind: ReminderCheckpointKind,
        title: String,
        body: String,
        at date: Date
    ) async throws {
        if let errorToThrow { throw errorToThrow }
        scheduled.append((id, kind, body, date))
    }

    func cancelAlerts(id: UUID) { cancelled.append(id) }
}

final class StubReminderMemory: ReminderMemoryWriting, @unchecked Sendable {
    var errorToThrow: Error?
    private(set) var remembered: [(reminder: GemmaReminder, plan: ReminderPlan)] = []

    init(errorToThrow: Error? = nil) {
        self.errorToThrow = errorToThrow
    }

    private(set) var forgotten: [UUID] = []
    var forgetError: Error?

    func remember(_ reminder: GemmaReminder, plan: ReminderPlan) async throws {
        if let errorToThrow { throw errorToThrow }
        remembered.append((reminder, plan))
    }

    func forget(_ reminder: GemmaReminder) async throws {
        if let forgetError { throw forgetError }
        forgotten.append(reminder.id)
    }
}

/// Híbrido quiere decir tres destinos a la vez. Lo que estas pruebas protegen es que
/// ninguno se dé por hecho: si uno falla, la salida lo dice en lugar de dejar al usuario
/// confiando en un aviso que no existe.
final class HybridReminderTests: XCTestCase {

    private var due: Date { ISO8601Dates.parse("2026-11-06T08:30:00Z")! }
    private var now: Date { ISO8601Dates.parse("2026-11-06T06:00:00Z")! }

    private func service(
        reminders: StubAppleReminders? = StubAppleReminders(),
        alerter: StubReminderAlerter = StubReminderAlerter(),
        memory: StubReminderMemory = StubReminderMemory(),
        travel: TimeInterval? = 15 * 60
    ) -> HybridReminderService {
        HybridReminderService(
            reminders: reminders,
            alerter: alerter,
            memory: memory,
            calculator: ReminderLeadTimeCalculator(estimator: StubTravelEstimator(seconds: travel))
        )
    }

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    // MARK: - Los tres destinos

    func test_guardaEnLosTresSitios() async throws {
        let reminders = StubAppleReminders()
        let alerter = StubReminderAlerter()
        let memory = StubReminderMemory()

        let created = try await service(reminders: reminders, alerter: alerter, memory: memory)
            .create(
                title: "trabajo",
                due: due,
                destination: ReminderDestination(name: "Trabajo"),
                now: now
            )

        XCTAssertTrue(created.storage.inAppleReminders)
        XCTAssertTrue(created.storage.gemmaAlertScheduled)
        XCTAssertTrue(created.storage.inGemmaMemory)
        XCTAssertTrue(created.storage.failures.isEmpty)

        // Tres avisos repartidos, no uno: preparación, comprobación y salida.
        XCTAssertEqual(
            alerter.scheduled.map(\.kind),
            [.headsUp, .preparationCheck, .leaveNow]
        )
        XCTAssertEqual(alerter.scheduled.first?.date, ISO8601Dates.parse("2026-11-06T07:30:00Z"))
        XCTAssertEqual(alerter.scheduled.last?.date, ISO8601Dates.parse("2026-11-06T08:15:00Z"))
        // El recordatorio de Apple avisa en el primero de todos.
        XCTAssertEqual(reminders.created.first?.alertAt, ISO8601Dates.parse("2026-11-06T07:30:00Z"))
        XCTAssertEqual(memory.remembered.first?.plan.leaveBy, ISO8601Dates.parse("2026-11-06T08:15:00Z"))
    }

    func test_elAvisoDeGemmaLlevaLaHoraDeSalida() async throws {
        let alerter = StubReminderAlerter()
        _ = try await service(alerter: alerter).create(
            title: "el trabajo",
            due: due,
            destination: ReminderDestination(name: "Trabajo"),
            now: now
        )

        let body = try XCTUnwrap(alerter.scheduled.first?.body)
        XCTAssertTrue(body.contains("prepararte"), "El primer aviso abre la preparación: \(body)")
        let last = try XCTUnwrap(alerter.scheduled.last?.body)
        XCTAssertTrue(last.lowercased().contains("sal"), "El último dice que salga: \(last)")
    }

    // MARK: - Fallos parciales

    func test_sinPermisoDeRecordatoriosSigueAvisandoYLoDice() async throws {
        let reminders = StubAppleReminders(accessGranted: false)
        let alerter = StubReminderAlerter()

        let created = try await service(reminders: reminders, alerter: alerter)
            .create(title: "reunión", due: due, now: now)

        XCTAssertFalse(created.storage.inAppleReminders)
        XCTAssertTrue(created.storage.gemmaAlertScheduled, "El aviso de Gemma no depende de Recordatorios.")
        XCTAssertTrue(created.storage.failures.contains { $0.contains("permiso de Recordatorios") })
    }

    func test_sinPermisoDeNotificacionesLoDiceYNoLoOculta() async throws {
        let created = try await service(alerter: StubReminderAlerter(authorized: false))
            .create(title: "reunión", due: due, now: now)

        XCTAssertFalse(created.storage.gemmaAlertScheduled)
        XCTAssertTrue(created.storage.failures.contains { $0.contains("notificaciones") })
    }

    func test_siLaMemoriaFallaElRecordatorioSigueExistiendo() async throws {
        let memory = StubReminderMemory(errorToThrow: ReminderServiceError.memoryUnavailable)
        let created = try await service(memory: memory).create(title: "reunión", due: due, now: now)

        XCTAssertFalse(created.storage.inGemmaMemory)
        XCTAssertTrue(created.storage.inAppleReminders)
        XCTAssertFalse(created.storage.failures.isEmpty)
    }

    func test_siFallanLosTresEsUnError() async {
        let service = HybridReminderService(
            reminders: StubAppleReminders(accessGranted: false),
            alerter: StubReminderAlerter(authorized: false),
            memory: StubReminderMemory(errorToThrow: ReminderServiceError.memoryUnavailable),
            calculator: ReminderLeadTimeCalculator(estimator: StubTravelEstimator(seconds: nil))
        )

        do {
            _ = try await service.create(title: "reunión", due: due, now: now)
            XCTFail("Sin ningún destino no hay recordatorio que prometer.")
        } catch let error as ReminderServiceError {
            guard case .nothingStored(let reasons) = error else {
                return XCTFail("Error inesperado: \(error)")
            }
            XCTAssertEqual(reasons.count, 3)
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    // MARK: - El tool

    func test_elToolReportaCuandoAvisaYDondeQuedo() async throws {
        let tool = CreateReminderTool(service: service())
        let args = #"{"title": "el trabajo", "due_date": "2036-11-06T08:30:00Z", "place": "Trabajo"}"#

        let result = try json(await tool.run(argsJSON: args))

        XCTAssertEqual(result["status"] as? String, "created")
        XCTAssertNotNil(result["alert_at"])
        XCTAssertNotNil(result["leave_by"])
        XCTAssertEqual(result["travel_minutes"] as? Int, 15)
        XCTAssertEqual(result["basis"] as? String, "travel_time")
        XCTAssertEqual(result["place"] as? String, "Trabajo")
        let stored = try XCTUnwrap(result["stored_in"] as? [String])
        XCTAssertEqual(Set(stored), ["apple_reminders", "gemma_alert", "gemma_memory"])
        XCTAssertNil(result["warnings"])
    }

    func test_elToolSinLugarAvisaUnaHoraAntes() async throws {
        let tool = CreateReminderTool(service: service(travel: nil))
        let result = try json(await tool.run(argsJSON: #"{"title": "reunión", "due_date": "2036-11-06T08:30:00Z"}"#))

        XCTAssertEqual(result["basis"] as? String, "fixed_lead_time")
        XCTAssertEqual(result["alert_at"] as? String, "2036-11-06T07:30:00Z")
        XCTAssertNil(result["leave_by"])
    }

    func test_elToolRechazaUnaFechaInvalida() async throws {
        let tool = CreateReminderTool(service: service())
        let result = try json(await tool.run(argsJSON: #"{"title": "reunión", "due_date": "mañana a las 8"}"#))

        XCTAssertEqual(result["status"] as? String, "invalid_date")
    }

    func test_elToolRechazaUnaFechaPasada() async throws {
        let tool = CreateReminderTool(service: service())
        let result = try json(await tool.run(argsJSON: #"{"title": "reunión", "due_date": "2020-01-01T08:30:00Z"}"#))

        XCTAssertEqual(result["status"] as? String, "invalid_date")
    }

    func test_elToolAvisaDeLoQueFalta() async throws {
        let tool = CreateReminderTool(service: service(reminders: StubAppleReminders(accessGranted: false)))
        let result = try json(await tool.run(argsJSON: #"{"title": "reunión", "due_date": "2036-11-06T08:30:00Z"}"#))

        XCTAssertEqual(result["status"] as? String, "created")
        let stored = try XCTUnwrap(result["stored_in"] as? [String])
        XCTAssertFalse(stored.contains("apple_reminders"))
        XCTAssertNotNil(result["warnings"])
    }

    func test_laDescripcionExplicaElHibridoYElLugar() {
        let description = CreateReminderTool.description.lowercased()
        XCTAssertTrue(description.contains("place"))
        XCTAssertTrue(description.contains("recordatorios"))
        XCTAssertTrue(description.contains("memoria"))
        XCTAssertTrue(description.contains("stored_in"))
    }
}
