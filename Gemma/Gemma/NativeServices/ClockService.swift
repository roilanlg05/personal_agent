import Foundation
import UserNotifications

public struct GemmaAlarm: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let hour: Int
    public let minute: Int
    public let daysOfWeek: [Int] // 1 = Sunday, 7 = Saturday (Calendar standards)
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        hour: Int,
        minute: Int,
        daysOfWeek: [Int] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.hour = hour
        self.minute = minute
        self.daysOfWeek = daysOfWeek
        self.isEnabled = isEnabled
    }
}

public struct GemmaTimer: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let label: String
    public let durationSeconds: Int
    public let scheduledAt: Date
    public var endsAt: Date { scheduledAt.addingTimeInterval(TimeInterval(durationSeconds)) }

    public init(
        id: UUID = UUID(),
        label: String,
        durationSeconds: Int,
        scheduledAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.durationSeconds = durationSeconds
        self.scheduledAt = scheduledAt
    }
}

/// Qué puede ir mal al programar una alarma o un temporizador.
public enum ClockError: Error, LocalizedError, Equatable {
    /// El usuario no ha concedido notificaciones, así que nada sonaría.
    case notificationsDenied
    /// Gemma no tiene apuntada ninguna alarma con ese identificador.
    case alarmNotFound

    public var errorDescription: String? {
        switch self {
        case .notificationsDenied:
            return "Falta el permiso de notificaciones, así que no sonaría nada."
        case .alarmNotFound:
            return "Gemma no tiene esa alarma apuntada."
        }
    }
}

/// Con qué mecanismo quedó puesta la alarma.
///
/// No son equivalentes y el usuario tiene que saber cuál le tocó: una alarma del
/// sistema suena en silencio y en modo concentración, y una notificación no.
public enum AlarmMethod: String, Sendable {
    /// AlarmKit: alarma del sistema, con su pantalla de aviso y su botón de parar.
    case systemAlarm = "system_alarm"
    /// Notificación local de Gemma. Es lo único disponible antes de iOS 26.
    case gemmaNotification = "gemma_notification"
}

public struct ScheduledAlarm: Sendable, Equatable {
    public let alarm: GemmaAlarm
    public let method: AlarmMethod
}

public struct ScheduledTimer: Sendable, Equatable {
    public let timer: GemmaTimer
    public let method: AlarmMethod
}

public protocol ClockScheduling: Sendable {
    /// Pide (o comprueba) el permiso de notificaciones. `false` = no sonará nada.
    func requestAuthorization() async -> Bool
    func scheduleAlarmNotification(alarm: GemmaAlarm) async throws
    func scheduleTimerNotification(timer: GemmaTimer) async throws
    /// Retira la notificación de una alarma o temporizador ya programado.
    ///
    /// Sin esto, cancelar en la lista de Gemma dejaba la notificación en el centro del
    /// sistema: la alarma "cancelada" seguía sonando a su hora.
    func cancelNotification(id: UUID) async
}

extension ClockScheduling {
    /// Por omisión no hace nada, para no romper implementaciones que no programan
    /// notificaciones.
    public func cancelNotification(id: UUID) async {}
}

public final class MockClockScheduler: ClockScheduling, @unchecked Sendable {
    public var scheduledAlarms: [GemmaAlarm] = []
    public var scheduledTimers: [GemmaTimer] = []
    public var cancelledNotifications: [UUID] = []
    public var authorizationGranted = true

    public init() {}

    public func requestAuthorization() async -> Bool { authorizationGranted }

    public func scheduleAlarmNotification(alarm: GemmaAlarm) async throws {
        scheduledAlarms.append(alarm)
    }

    public func scheduleTimerNotification(timer: GemmaTimer) async throws {
        scheduledTimers.append(timer)
    }

    public func cancelNotification(id: UUID) async {
        cancelledNotifications.append(id)
        scheduledAlarms.removeAll { $0.id == id }
        scheduledTimers.removeAll { $0.id == id }
    }
}

public final class SystemClockScheduler: ClockScheduling, Sendable {
    public init() {}

    /// Sin este permiso el sistema acepta la petición y luego no suena nada, que es la
    /// peor forma de fallar para algo en lo que el usuario confía para despertarse.
    public func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default:
            return false
        }
    }

    public func scheduleAlarmNotification(alarm: GemmaAlarm) async throws {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "⏰ Alarma: \(alarm.title)"
        content.body = String(format: "%02d:%02d", alarm.hour, alarm.minute)
        content.sound = .defaultCritical

        var dateComponents = DateComponents()
        dateComponents.hour = alarm.hour
        dateComponents.minute = alarm.minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: !alarm.daysOfWeek.isEmpty)
        let request = UNNotificationRequest(identifier: "gemma.alarm.\(alarm.id.uuidString)", content: content, trigger: trigger)
        try await center.add(request)
    }

    public func scheduleTimerNotification(timer: GemmaTimer) async throws {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "⏱️ Temporizador terminado"
        content.body = timer.label.isEmpty ? "El temporizador ha finalizado." : timer.label
        content.sound = .defaultCritical

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1.0, TimeInterval(timer.durationSeconds)), repeats: false)
        let request = UNNotificationRequest(identifier: "gemma.timer.\(timer.id.uuidString)", content: content, trigger: trigger)
        try await center.add(request)
    }

    /// Retira las dos formas posibles del identificador, porque desde aquí no se sabe si
    /// el `id` era de una alarma o de un temporizador, y retirar una que no existe no
    /// cuesta nada.
    public func cancelNotification(id: UUID) async {
        let center = UNUserNotificationCenter.current()
        let identifiers = ["gemma.alarm.\(id.uuidString)", "gemma.timer.\(id.uuidString)"]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Pone alarmas y temporizadores, y dice con qué mecanismo quedaron puestos.
///
/// Desde iOS 26 existe AlarmKit, que da alarmas del sistema de verdad: suenan en
/// silencio y en modo concentración, con pantalla de aviso propia. Esa es la vía
/// principal. En lo que no la soporta queda la notificación local, que es más débil, y
/// entonces la salida lo dice en lugar de dejar al usuario creyendo que puso una alarma
/// que no puso.
public final class ClockService: @unchecked Sendable {
    private let systemScheduler: any SystemAlarmScheduling
    private let scheduler: any ClockScheduling
    private let persistence: ClockPersistence

    public init(
        systemScheduler: any SystemAlarmScheduling = SystemAlarmSchedulerFactory.make(),
        scheduler: any ClockScheduling = SystemClockScheduler(),
        defaults: UserDefaults = .standard,
        outbox: MirrorOutbox? = nil
    ) {
        self.systemScheduler = systemScheduler
        self.scheduler = scheduler
        // `defaults == .standard` es el caso de producción, y ahí se usa el almacén
        // compartido, que es el que está registrado en el espejo. Con otros `defaults`
        // (tests) se construye uno aislado.
        if defaults == .standard && outbox == nil {
            self.persistence = .shared
        } else {
            self.persistence = ClockPersistence(defaults: defaults, outbox: outbox)
        }
    }

    /// Pone una alarma, con la mejor vía que exista en este dispositivo.
    ///
    /// Si hay alarmas del sistema (iOS 26+) se usan esas y no se cae a la notificación
    /// cuando falta el permiso: degradar en silencio devolvería al usuario justo al
    /// problema que notó, creyendo que tiene una alarma de verdad.
    public func createAlarm(title: String, hour: Int, minute: Int, days: [Int] = []) async throws -> ScheduledAlarm {
        let alarm = GemmaAlarm(title: title, hour: hour, minute: minute, daysOfWeek: days)

        if systemScheduler.isSupported {
            guard await systemScheduler.requestAuthorization() else {
                throw SystemAlarmError.permissionDenied
            }
            try await systemScheduler.schedule(alarm: alarm)
            remember(alarm)
            return ScheduledAlarm(alarm: alarm, method: .systemAlarm)
        }

        guard await scheduler.requestAuthorization() else {
            throw ClockError.notificationsDenied
        }
        try await scheduler.scheduleAlarmNotification(alarm: alarm)
        remember(alarm)
        return ScheduledAlarm(alarm: alarm, method: .gemmaNotification)
    }

    public func createTimer(durationSeconds: Int, label: String) async throws -> ScheduledTimer {
        let timer = GemmaTimer(label: label, durationSeconds: durationSeconds)

        if systemScheduler.isSupported {
            guard await systemScheduler.requestAuthorization() else {
                throw SystemAlarmError.permissionDenied
            }
            try await systemScheduler.scheduleCountdown(timer: timer)
            remember(timer)
            return ScheduledTimer(timer: timer, method: .systemAlarm)
        }

        guard await scheduler.requestAuthorization() else {
            throw ClockError.notificationsDenied
        }
        try await scheduler.scheduleTimerNotification(timer: timer)
        remember(timer)
        return ScheduledTimer(timer: timer, method: .gemmaNotification)
    }

    private func remember(_ alarm: GemmaAlarm) {
        persistence.add(alarm: alarm)
    }

    private func remember(_ timer: GemmaTimer) {
        persistence.add(timer: timer)
    }

    public func listAlarms() -> [GemmaAlarm] { persistence.alarms() }

    public func listTimers() -> [GemmaTimer] { persistence.timers() }

    /// Cambia una alarma ya puesta: la hora, los días o el título.
    ///
    /// Existe para que "cámbiala a las siete" no obligue al modelo a cancelar y crear
    /// otra. Ese camino tiene dos puntos de fallo seguidos, y el malo es el segundo: si
    /// la creación falla después de la cancelación, el usuario se queda sin alarma
    /// creyendo que la tiene.
    ///
    /// Aquí la alarma nueva se programa **antes** de apuntar el cambio, y si el sistema
    /// la rechaza se propaga el error con lo apuntado intacto: la alarma vieja sigue
    /// siendo la que Gemma conoce.
    public func updateAlarm(
        id: UUID,
        title: String? = nil,
        hour: Int? = nil,
        minute: Int? = nil,
        daysOfWeek: [Int]? = nil
    ) async throws -> ScheduledAlarm {
        guard let existing = persistence.alarms().first(where: { $0.id == id }) else {
            throw ClockError.alarmNotFound
        }

        let updated = GemmaAlarm(
            id: id,
            title: title ?? existing.title,
            hour: hour ?? existing.hour,
            minute: minute ?? existing.minute,
            daysOfWeek: daysOfWeek ?? existing.daysOfWeek,
            isEnabled: existing.isEnabled
        )

        if systemScheduler.isSupported {
            guard await systemScheduler.requestAuthorization() else {
                throw SystemAlarmError.permissionDenied
            }
            // La vieja se cancela primero porque AlarmKit identifica la alarma por su
            // `id`: dejarla puesta haría que sonara también a la hora antigua.
            try? systemScheduler.cancel(id: id)
            try await systemScheduler.schedule(alarm: updated)
            remember(updated)
            return ScheduledAlarm(alarm: updated, method: .systemAlarm)
        }

        guard await scheduler.requestAuthorization() else {
            throw ClockError.notificationsDenied
        }
        await scheduler.cancelNotification(id: id)
        try await scheduler.scheduleAlarmNotification(alarm: updated)
        remember(updated)
        return ScheduledAlarm(alarm: updated, method: .gemmaNotification)
    }

    // MARK: - Cancelación

    /// Qué pasó al intentar cancelar.
    ///
    /// `wasNotScheduled` existe porque las dos listas pueden discrepar: si el usuario
    /// paró la alarma desde su pantalla de aviso, el sistema ya la soltó y lo único que
    /// queda por hacer es limpiar la lista de Gemma. Contar eso como una cancelación
    /// sería atribuirse algo que no se hizo.
    public enum CancelOutcome: String, Sendable, Equatable {
        case cancelled
        case wasNotScheduled = "was_not_scheduled"
        case notFound = "not_found"
    }

    /// Cancela una alarma puesta por Gemma.
    ///
    /// Se cancela primero en el sistema y solo después se limpia la lista: si el sistema
    /// falla, la alarma sigue puesta y Gemma tiene que seguir sabiéndolo. Lo contrario
    /// dejaría una alarma sonando que Gemma cree cancelada, que es peor que no poder
    /// cancelarla.
    public func cancelAlarm(id: UUID) async throws -> CancelOutcome {
        guard persistence.alarms().contains(where: { $0.id == id }) else { return .notFound }
        let outcome = try await cancelInSystem(id: id)
        persistence.remove(alarmID: id)
        return outcome
    }

    public func cancelTimer(id: UUID) async throws -> CancelOutcome {
        guard persistence.timers().contains(where: { $0.id == id }) else { return .notFound }
        let outcome = try await cancelInSystem(id: id)
        persistence.remove(timerID: id)
        return outcome
    }

    private func cancelInSystem(id: UUID) async throws -> CancelOutcome {
        guard systemScheduler.isSupported else {
            // Sin alarmas del sistema la alarma es una notificación local, y hay que
            // retirarla del centro de notificaciones o seguirá sonando.
            await scheduler.cancelNotification(id: id)
            return .cancelled
        }
        // Si el sistema ya no la tiene, no hay nada que cancelar y `cancel` podría
        // fallar por eso; se comprueba antes para no confundirlo con un fallo real.
        if let known = try? systemScheduler.systemAlarmIDs(), !known.contains(id) {
            await scheduler.cancelNotification(id: id)
            return .wasNotScheduled
        }
        try systemScheduler.cancel(id: id)
        await scheduler.cancelNotification(id: id)
        return .cancelled
    }

    /// `true` si esta plataforma pone alarmas del sistema.
    public var usesSystemAlarms: Bool { systemScheduler.isSupported }

    /// Lo que Gemma tiene apuntado, contrastado con lo que el sistema tiene puesto.
    ///
    /// Las dos listas pueden discrepar: si el usuario para una alarma desde su pantalla
    /// de aviso, el sistema la suelta y Gemma sigue teniéndola apuntada. Contarle que
    /// sigue puesta sería mentirle, así que cada registro dice si el sistema lo confirma.
    ///
    /// `nil` en `confirmedBySystem` significa "no hay nada que contrastar": o la
    /// plataforma no tiene alarmas del sistema, o el sistema no contestó.
    public func alarmsWithSystemState() -> [(alarm: GemmaAlarm, confirmedBySystem: Bool?)] {
        let known = systemIDs()
        return persistence.alarms().map { alarm in
            (alarm, known.map { ids in ids.contains(alarm.id) })
        }
    }

    public func timersWithSystemState() -> [(timer: GemmaTimer, confirmedBySystem: Bool?)] {
        let known = systemIDs()
        return persistence.timers().map { timer in
            (timer, known.map { ids in ids.contains(timer.id) })
        }
    }

    private func systemIDs() -> Set<UUID>? {
        guard systemScheduler.isSupported else { return nil }
        return try? systemScheduler.systemAlarmIDs()
    }
}

// MARK: - Dónde quedan apuntadas las alarmas y los temporizadores

/// La lista de alarmas y temporizadores que Gemma ha puesto.
///
/// Estaba dentro de `ClockService`, que se reconstruye en cada turno. Se saca aquí para
/// que el espejo del servicio de memoria tenga a quién preguntar y a quién entregar:
/// `ClockService` sigue exponiendo `listAlarms()` y `listTimers()` igual que antes.
///
/// Lo que se espeja es la LISTA, no la programación. Hidratar la alarma de otro
/// dispositivo no la vuelve a armar aquí: armar una alarma del sistema por nuestra
/// cuenta haría sonar a las 7:00 un teléfono que el usuario no programó. Lo que se
/// recupera es que Gemma sepa qué alarmas tiene el usuario puestas.
public final class ClockPersistence: @unchecked Sendable {

    public static let shared = ClockPersistence(defaults: .standard, outbox: .shared)

    private let defaults: UserDefaults
    private let outbox: MirrorOutbox?
    private let lock = NSLock()
    private let alarmsKey = "gemma.alarms.v1"
    private let timersKey = "gemma.timers.v1"

    public init(defaults: UserDefaults = .standard, outbox: MirrorOutbox? = nil) {
        self.defaults = defaults
        self.outbox = outbox
    }

    public func alarms() -> [GemmaAlarm] {
        guard let data = defaults.data(forKey: alarmsKey),
              let decoded = try? JSONDecoder().decode([GemmaAlarm].self, from: data) else {
            return []
        }
        return decoded
    }

    public func timers() -> [GemmaTimer] {
        guard let data = defaults.data(forKey: timersKey),
              let decoded = try? JSONDecoder().decode([GemmaTimer].self, from: data) else {
            return []
        }
        return decoded
    }

    public func add(alarm: GemmaAlarm) {
        lock.lock()
        var current = alarms()
        current.removeAll { $0.id == alarm.id }
        current.append(alarm)
        write(alarms: current)
        lock.unlock()
        outbox?.enqueueUpsert(kind: MirrorKind.alarm, record: ClockPersistence.record(for: alarm))
    }

    public func add(timer: GemmaTimer) {
        lock.lock()
        var current = timers()
        current.removeAll { $0.id == timer.id }
        current.append(timer)
        write(timers: current)
        lock.unlock()
        outbox?.enqueueUpsert(kind: MirrorKind.timer, record: ClockPersistence.record(for: timer))
    }

    public func remove(alarmID: UUID) {
        lock.lock()
        let remaining = alarms().filter { $0.id != alarmID }
        write(alarms: remaining)
        lock.unlock()
        outbox?.enqueueDelete(kind: MirrorKind.alarm, recordId: alarmID.uuidString, label: "")
    }

    public func remove(timerID: UUID) {
        lock.lock()
        let remaining = timers().filter { $0.id != timerID }
        write(timers: remaining)
        lock.unlock()
        outbox?.enqueueDelete(kind: MirrorKind.timer, recordId: timerID.uuidString, label: "")
    }

    func replace(alarms list: [GemmaAlarm]) {
        lock.lock()
        write(alarms: list)
        lock.unlock()
    }

    func replace(timers list: [GemmaTimer]) {
        lock.lock()
        write(timers: list)
        lock.unlock()
    }

    private func write(alarms list: [GemmaAlarm]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: alarmsKey)
        }
    }

    private func write(timers list: [GemmaTimer]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: timersKey)
        }
    }

    static func record(for alarm: GemmaAlarm) -> MirrorRecord {
        MirrorRecord(recordId: alarm.id.uuidString,
                     label: alarm.title.isEmpty ? "Alarma \(alarm.hour):\(alarm.minute)" : alarm.title,
                     body: String(format: "%02d:%02d", alarm.hour, alarm.minute),
                     payload: MirrorCodec.encode(alarm) ?? "")
    }

    static func record(for timer: GemmaTimer) -> MirrorRecord {
        MirrorRecord(recordId: timer.id.uuidString,
                     label: timer.label.isEmpty ? "Temporizador" : timer.label,
                     body: "\(timer.durationSeconds) s",
                     payload: MirrorCodec.encode(timer) ?? "",
                     updatedAt: timer.scheduledAt.timeIntervalSince1970)
    }
}

/// Las alarmas, vistas por el espejo.
///
/// Son dos conformidades y no una porque alarmas y temporizadores son `kind` distintos
/// en el servidor, y un `MirroredStore` representa exactamente un `kind`.
struct AlarmMirror: MirroredStore {
    let persistence: ClockPersistence
    var mirrorKind: String { MirrorKind.alarm }

    func mirrorRecords() -> [MirrorRecord] {
        persistence.alarms().map { ClockPersistence.record(for: $0) }
    }

    func applyMirror(_ records: [MirrorRecord]) {
        persistence.replace(alarms: records.compactMap { MirrorCodec.decode($0.payload, as: GemmaAlarm.self) })
    }
}

/// Los temporizadores, vistos por el espejo.
struct TimerMirror: MirroredStore {
    let persistence: ClockPersistence
    var mirrorKind: String { MirrorKind.timer }

    func mirrorRecords() -> [MirrorRecord] {
        persistence.timers().map { ClockPersistence.record(for: $0) }
    }

    func applyMirror(_ records: [MirrorRecord]) {
        persistence.replace(timers: records.compactMap { MirrorCodec.decode($0.payload, as: GemmaTimer.self) })
    }
}
