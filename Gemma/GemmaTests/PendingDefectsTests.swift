import XCTest
@testable import Gemma

// MARK: - Alias de contactos

/// Los alias que el usuario enseña ("mi jefe es Carlos Pérez") tienen que sobrevivir al
/// turno. Las herramientas se reconstruyen en cada turno, así que una instancia por
/// herramienta pierde todo lo aprendido.
final class ContactAliasStoreTests: XCTestCase {

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "gemma.tests.aliases.\(UUID().uuidString)")!
    }

    func test_aliasAprendidoSobreviveAOtraInstancia() {
        let defaults = suite()
        ContactAliasStore(defaults: defaults).setAlias(relationship: "mi jefe", contactTarget: "Carlos Pérez")

        // Otra instancia = el turno siguiente.
        let later = ContactAliasStore(defaults: defaults)
        XCTAssertEqual(later.resolve(aliasOrName: "mi jefe"), "Carlos Pérez")
    }

    func test_hayUnaInstanciaCompartida() {
        ContactAliasStore.shared.setAlias(relationship: "test-alias-compartido", contactTarget: "Alguien")
        XCTAssertEqual(ContactAliasStore.shared.resolve(aliasOrName: "test-alias-compartido"), "Alguien")
        ContactAliasStore.shared.forgetAlias(relationship: "test-alias-compartido")
    }

    func test_aliasDeFabricaSiguenFuncionando() {
        let store = ContactAliasStore(defaults: suite())
        XCTAssertEqual(store.resolve(aliasOrName: "mi esposa"), "Amor")
        XCTAssertEqual(store.resolve(aliasOrName: "MAMÁ"), "Mamá")
    }

    func test_elAliasDelUsuarioPisaElDeFabrica() {
        let store = ContactAliasStore(defaults: suite())
        store.setAlias(relationship: "esposa", contactTarget: "Ana Gómez")
        XCTAssertEqual(store.resolve(aliasOrName: "mi esposa"), "Ana Gómez")
    }

    func test_loDesconocidoSeDevuelveIntacto() {
        let store = ContactAliasStore(defaults: suite())
        XCTAssertEqual(store.resolve(aliasOrName: "Pedro Ramírez"), "Pedro Ramírez")
    }

    func test_olvidarAliasVuelveAlValorDeFabrica() {
        let defaults = suite()
        let store = ContactAliasStore(defaults: defaults)
        store.setAlias(relationship: "esposa", contactTarget: "Ana Gómez")
        store.forgetAlias(relationship: "esposa")
        XCTAssertEqual(store.resolve(aliasOrName: "esposa"), "Amor")
    }

    func test_herramientaParaEnsenarAlias() async throws {
        let defaults = suite()
        let store = ContactAliasStore(defaults: defaults)
        let tool = RememberContactAliasTool(aliasStore: store)

        let out = await tool.run(argsJSON: #"{"relationship": "mi jefe", "contact": "Carlos Pérez"}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(json["status"] as? String, "remembered")
        XCTAssertEqual(ContactAliasStore(defaults: defaults).resolve(aliasOrName: "mi jefe"), "Carlos Pérez")
    }

    func test_herramientaExigeAmbosArgumentos() async throws {
        let tool = RememberContactAliasTool(aliasStore: ContactAliasStore(defaults: suite()))
        let out = await tool.run(argsJSON: #"{"relationship": "mi jefe"}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertNotNil(json["error"])
    }
}

// MARK: - Alarmas y temporizadores

final class StubClockScheduler: ClockScheduling, @unchecked Sendable {
    var authorizationGranted: Bool
    var errorToThrow: Error?
    private(set) var scheduledAlarms: [GemmaAlarm] = []
    private(set) var scheduledTimers: [GemmaTimer] = []
    private(set) var authorizationRequests = 0

    init(authorizationGranted: Bool = true, errorToThrow: Error? = nil) {
        self.authorizationGranted = authorizationGranted
        self.errorToThrow = errorToThrow
    }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return authorizationGranted
    }

    func scheduleAlarmNotification(alarm: GemmaAlarm) async throws {
        if let errorToThrow { throw errorToThrow }
        scheduledAlarms.append(alarm)
    }

    func scheduleTimerNotification(timer: GemmaTimer) async throws {
        if let errorToThrow { throw errorToThrow }
        scheduledTimers.append(timer)
    }
}

/// Una alarma que nunca suena es peor que una alarma que no se creó: el usuario confía
/// en ella. Sin permiso de notificaciones no suena nada, así que hay que pedirlo y
/// decirlo cuando falta.
final class ClockServiceTests: XCTestCase {

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "gemma.tests.clock.\(UUID().uuidString)")!
    }

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    func test_sinPermisoDeNotificacionesNoSeCreaLaAlarma() async throws {
        let scheduler = StubClockScheduler(authorizationGranted: false)
        let service = notificationOnly(scheduler)

        do {
            _ = try await service.createAlarm(title: "Medicina", hour: 8, minute: 0)
            XCTFail("Sin permiso no se puede prometer una alarma.")
        } catch let error as ClockError {
            XCTAssertEqual(error, .notificationsDenied)
        }

        XCTAssertEqual(scheduler.authorizationRequests, 1)
        XCTAssertTrue(scheduler.scheduledAlarms.isEmpty)
        XCTAssertTrue(service.listAlarms().isEmpty, "No se guarda lo que no se programó.")
    }

    /// Servicio que solo tiene la vía de notificación (macOS, o iOS anterior a 26).
    private func notificationOnly(
        _ scheduler: StubClockScheduler = StubClockScheduler()
    ) -> ClockService {
        ClockService(
            systemScheduler: MockSystemAlarmScheduler(isSupported: false),
            scheduler: scheduler,
            defaults: suite()
        )
    }

    func test_conAlarmKitLaAlarmaEsDelSistema() async throws {
        // Lo que el usuario pedía: una alarma de verdad, no un aviso.
        let system = MockSystemAlarmScheduler()
        let service = ClockService(
            systemScheduler: system,
            scheduler: StubClockScheduler(),
            defaults: suite()
        )

        let result = try json(await CreateAlarmTool(clockService: service)
            .run(argsJSON: #"{"title": "Despertar", "hour": 7, "minute": 30}"#))

        XCTAssertEqual(result["status"] as? String, "created")
        XCTAssertEqual(result["method"] as? String, "system_alarm")
        XCTAssertEqual(system.scheduledAlarms.first?.hour, 7)
        XCTAssertEqual(system.scheduledAlarms.first?.minute, 30)
        let message = try XCTUnwrap(result["message"] as? String)
        XCTAssertTrue(message.contains("silencio"))
    }

    func test_sinAlarmKitEsSoloUnAvisoYLoDice() async throws {
        let result = try json(await CreateAlarmTool(clockService: notificationOnly())
            .run(argsJSON: #"{"title": "Despertar", "hour": 7, "minute": 30}"#))

        XCTAssertEqual(result["status"] as? String, "created")
        XCTAssertEqual(result["method"] as? String, "gemma_notification")
        let message = try XCTUnwrap(result["message"] as? String)
        XCTAssertTrue(message.contains("NO suena"))
    }

    func test_permisoDeAlarmasDenegadoNoDegradaEnSilencio() async throws {
        // Caer a una notificación sin decirlo devolvería al usuario al mismo problema:
        // creer que tiene una alarma que no tiene.
        let system = MockSystemAlarmScheduler(authorizationGranted: false)
        let notifications = StubClockScheduler()
        let service = ClockService(systemScheduler: system, scheduler: notifications, defaults: suite())

        let result = try json(await CreateAlarmTool(clockService: service)
            .run(argsJSON: #"{"title": "Despertar", "hour": 7, "minute": 30}"#))

        XCTAssertEqual(result["status"] as? String, "permission_required")
        XCTAssertTrue(system.scheduledAlarms.isEmpty)
        XCTAssertTrue(notifications.scheduledAlarms.isEmpty)
        XCTAssertTrue(service.listAlarms().isEmpty, "No se guarda lo que no se puso.")
    }

    func test_temporizadorDelSistemaCuandoSePuede() async throws {
        let system = MockSystemAlarmScheduler()
        let service = ClockService(systemScheduler: system, scheduler: StubClockScheduler(), defaults: suite())

        let result = try json(await CreateTimerTool(clockService: service)
            .run(argsJSON: #"{"duration_seconds": 300, "label": "Pasta"}"#))

        XCTAssertEqual(result["method"] as? String, "system_alarm")
        XCTAssertEqual(system.scheduledTimers.first?.durationSeconds, 300)
    }

    func test_limiteDeAlarmasSeReportaAparte() async throws {
        let system = MockSystemAlarmScheduler(errorToThrow: SystemAlarmError.limitReached)
        let service = ClockService(systemScheduler: system, scheduler: StubClockScheduler(), defaults: suite())

        let result = try json(await CreateAlarmTool(clockService: service)
            .run(argsJSON: #"{"title": "Despertar", "hour": 7, "minute": 30}"#))

        XCTAssertEqual(result["status"] as? String, "limit_reached")
    }

    func test_sinPermisoElToolPideElPermisoAlUsuario() async throws {
        let service = notificationOnly(StubClockScheduler(authorizationGranted: false))
        let tool = CreateAlarmTool(clockService: service)

        let result = try json(await tool.run(argsJSON: #"{"title": "Medicina", "hour": 8, "minute": 0}"#))

        XCTAssertEqual(result["status"] as? String, "permission_required")
        let message = try XCTUnwrap(result["message"] as? String)
        XCTAssertTrue(message.lowercased().contains("notificaci"))
    }

    func test_conPermisoSeCreaYSeGuarda() async throws {
        let scheduler = StubClockScheduler(authorizationGranted: true)
        let service = notificationOnly(scheduler)

        let scheduled = try await service.createAlarm(title: "Medicina", hour: 8, minute: 5)

        XCTAssertEqual(scheduled.method, .gemmaNotification)
        XCTAssertEqual(scheduler.scheduledAlarms, [scheduled.alarm])
        XCTAssertEqual(service.listAlarms(), [scheduled.alarm])
    }

    func test_temporizadorTambienExigePermiso() async throws {
        let service = notificationOnly(StubClockScheduler(authorizationGranted: false))
        let tool = CreateTimerTool(clockService: service)

        let result = try json(await tool.run(argsJSON: #"{"duration_seconds": 300, "label": "Pasta"}"#))
        XCTAssertEqual(result["status"] as? String, "permission_required")
        XCTAssertTrue(service.listTimers().isEmpty)
    }

    func test_laDescripcionObligaADistinguirLosDosResultados() {
        // Una alarma del sistema y un aviso de Gemma no son lo mismo, y el modelo tiene
        // que contarle al usuario cuál de las dos consiguió.
        let description = CreateAlarmTool.description.lowercased()
        XCTAssertTrue(description.contains("system_alarm"))
        XCTAssertTrue(description.contains("gemma_notification"))
        XCTAssertTrue(description.contains("nunca digas"))
    }
}

// MARK: - Actividad de movimiento

final class StubMotionManager: MotionActivityManaging, @unchecked Sendable {
    var available: Bool
    var authorization: MotionAuthorization
    var recent: ActivitySnapshot?

    init(
        available: Bool = true,
        authorization: MotionAuthorization = .authorized,
        recent: ActivitySnapshot? = nil
    ) {
        self.available = available
        self.authorization = authorization
        self.recent = recent
    }

    func isActivityAvailable() -> Bool { available }
    func authorizationStatus() -> MotionAuthorization { authorization }
    func queryRecentActivity(since: Date) async -> ActivitySnapshot? { recent }
}

/// Decir "estás quieto" sin haber medido nada es inventar un dato. El valor por omisión
/// de la clase era exactamente eso, y el modelo lo repetía como una lectura.
final class MotionActivityTests: XCTestCase {

    private func json(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    func test_sinLecturaNoSeInventaQueEstaQuieto() async throws {
        let service = MotionActivityService(manager: StubMotionManager(recent: nil))
        let reading = await service.currentActivity()
        XCTAssertEqual(reading, .unknown(reason: .noRecentData))
    }

    func test_elToolDiceQueNoLoSabe() async throws {
        let tool = CurrentActivityTool(
            motionService: MotionActivityService(manager: StubMotionManager(recent: nil))
        )
        let result = try json(await tool.run(argsJSON: "{}"))

        XCTAssertEqual(result["status"] as? String, "unknown")
        XCTAssertNil(result["activity"], "Sin medición no se reporta actividad.")
        XCTAssertNil(result["is_driving"])
        XCTAssertEqual(result["reason"] as? String, "no_recent_data")
    }

    func test_hardwareSinSoporteSeDistingueDeFaltaDeDatos() async throws {
        let service = MotionActivityService(manager: StubMotionManager(available: false))
        let reading = await service.currentActivity()
        XCTAssertEqual(reading, .unknown(reason: .unavailable))
    }

    func test_permisoDenegadoSeDistingueYElToolLoPide() async throws {
        let manager = StubMotionManager(authorization: .denied)
        let tool = CurrentActivityTool(motionService: MotionActivityService(manager: manager))

        let result = try json(await tool.run(argsJSON: "{}"))

        XCTAssertEqual(result["status"] as? String, "permission_required")
        XCTAssertNil(result["activity"])
    }

    func test_conLecturaRealLaReporta() async throws {
        let snapshot = ActivitySnapshot(state: .automotive, confidence: "high", timestamp: Date())
        let tool = CurrentActivityTool(
            motionService: MotionActivityService(manager: StubMotionManager(recent: snapshot))
        )

        let result = try json(await tool.run(argsJSON: "{}"))

        XCTAssertEqual(result["status"] as? String, "ok")
        XCTAssertEqual(result["activity"] as? String, "automotive")
        XCTAssertEqual(result["confidence"] as? String, "high")
        XCTAssertEqual(result["is_driving"] as? Bool, true)
    }

    func test_laSalidaEsJSONValidoYNoTextoArmadoAMano() async throws {
        let snapshot = ActivitySnapshot(state: .walking, confidence: "low", timestamp: Date())
        let tool = CurrentActivityTool(
            motionService: MotionActivityService(manager: StubMotionManager(recent: snapshot))
        )
        let out = await tool.run(argsJSON: "{}")

        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertFalse(out.contains("\n        {"), "La salida ya no se arma interpolando texto.")
    }
}
