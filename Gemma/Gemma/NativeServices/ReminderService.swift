import Foundation
import UserNotifications
#if canImport(EventKit)
import EventKit
#endif

/// Un recordatorio tal como Gemma lo maneja.
public struct GemmaReminder: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    /// Hora del compromiso.
    public let due: Date
    /// A dónde hay que llegar, si hay sitio.
    public let destination: ReminderDestination?
    public let notes: String?

    public init(
        id: UUID = UUID(),
        title: String,
        due: Date,
        destination: ReminderDestination? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.destination = destination
        self.notes = notes
    }
}

/// Dónde quedó guardado un recordatorio.
///
/// Son tres destinos independientes y cualquiera puede fallar por su cuenta, así que se
/// informa de los tres por separado: decir "recordatorio creado" cuando solo entró en
/// uno dejaría al usuario confiando en un aviso que no existe.
public struct ReminderStorageResult: Sendable, Equatable {
    /// Quedó en la app Recordatorios de Apple, donde el usuario puede verlo y tacharlo.
    public let inAppleReminders: Bool
    /// Gemma programó su propio aviso para la hora calculada.
    public let gemmaAlertScheduled: Bool
    /// Quedó en la memoria de Gemma, para que lo tenga en cuenta al conversar.
    public let inGemmaMemory: Bool
    /// Motivos de lo que no se pudo hacer, para poder explicárselo al usuario.
    public let failures: [String]

    public var anywhere: Bool { inAppleReminders || gemmaAlertScheduled || inGemmaMemory }
}

public struct CreatedReminder: Sendable, Equatable {
    public let reminder: GemmaReminder
    public let plan: ReminderPlan
    /// Todos los momentos en que Gemma va a hablar antes del compromiso.
    public let checkpoints: [ReminderCheckpoint]
    public let storage: ReminderStorageResult
}

/// Un recordatorio puesto, tal como queda apuntado en el dispositivo.
///
/// Existe porque sin él no se puede tocar un recordatorio después de crearlo: `create`
/// devolvía el identificador de la app de Apple y se tiraba, así que no había forma de
/// saber qué recordatorio de Apple correspondía a cuál aviso de Gemma. Para listar, mover
/// de hora o borrar hace falta ese mapeo.
public struct StoredReminder: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let due: Date
    /// Nombre del destino, si había que ir a algún sitio. La coordenada no se guarda: se
    /// vuelve a resolver, porque un lugar puede haberse redefinido entre medias.
    public let destinationName: String?
    public let notes: String?
    /// Cuándo avisa Gemma (el primer punto de control).
    public let alertAt: Date
    public let leaveBy: Date?
    /// Identificador en la app Recordatorios de Apple. `nil` si no llegó a entrar ahí.
    public let appleID: String?

    public init(
        id: UUID,
        title: String,
        due: Date,
        destinationName: String? = nil,
        notes: String? = nil,
        alertAt: Date,
        leaveBy: Date? = nil,
        appleID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.destinationName = destinationName
        self.notes = notes
        self.alertAt = alertAt
        self.leaveBy = leaveBy
        self.appleID = appleID
    }

    /// Reconstruye el recordatorio de dominio a partir de lo apuntado.
    public var reminder: GemmaReminder {
        GemmaReminder(
            id: id,
            title: title,
            due: due,
            destination: destinationName.map { ReminderDestination(name: $0) },
            notes: notes
        )
    }
}

/// La lista de recordatorios que Gemma ha puesto.
///
/// Mismo papel que `ClockPersistence` con las alarmas, y por la misma razón: el servicio
/// se reconstruye en cada turno, así que la lista no puede vivir dentro de él.
public final class ReminderPersistence: @unchecked Sendable {

    public static let shared = ReminderPersistence(defaults: .standard, outbox: .shared)

    private let defaults: UserDefaults
    private let outbox: MirrorOutbox?
    private let lock = NSLock()
    private let storageKey = "gemma.reminders.v1"

    public init(defaults: UserDefaults = .standard, outbox: MirrorOutbox? = nil) {
        self.defaults = defaults
        self.outbox = outbox
    }

    public func all() -> [StoredReminder] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([StoredReminder].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.due < $1.due }
    }

    public func get(id: UUID) -> StoredReminder? {
        all().first { $0.id == id }
    }

    /// Añade o reemplaza: el mismo `id` no se duplica, para que mover de hora no deje dos.
    public func add(_ reminder: StoredReminder) {
        lock.lock()
        var current = all()
        current.removeAll { $0.id == reminder.id }
        current.append(reminder)
        write(current)
        lock.unlock()
        outbox?.enqueueUpsert(kind: MirrorKind.reminder, record: ReminderPersistence.record(for: reminder))
    }

    public func remove(id: UUID) {
        lock.lock()
        let remaining = all().filter { $0.id != id }
        write(remaining)
        lock.unlock()
        outbox?.enqueueDelete(kind: MirrorKind.reminder, recordId: id.uuidString, label: "")
    }

    private func write(_ list: [StoredReminder]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: storageKey)
        }
    }

    static func record(for reminder: StoredReminder) -> MirrorRecord {
        let payload = (try? JSONEncoder().encode(reminder)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let formatter = ISO8601DateFormatter()
        return MirrorRecord(
            recordId: reminder.id.uuidString,
            label: reminder.title,
            body: formatter.string(from: reminder.due),
            payload: payload
        )
    }

    public func mirrorRecords() -> [MirrorRecord] {
        all().map { ReminderPersistence.record(for: $0) }
    }

    public func applyMirror(_ records: [MirrorRecord]) {
        let hydrated: [StoredReminder] = records.compactMap { record in
            guard let data = record.payload.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(StoredReminder.self, from: data)
        }
        guard !hydrated.isEmpty else { return }
        lock.lock()
        var current = all()
        for reminder in hydrated where !current.contains(where: { $0.id == reminder.id }) {
            current.append(reminder)
        }
        write(current)
        lock.unlock()
    }
}

// MARK: - La app Recordatorios de Apple

public protocol AppleRemindersManaging: Sendable {
    /// Pide acceso a Recordatorios. `false` = denegado.
    func requestAccess() async -> Bool
    /// Crea el recordatorio con su aviso a la hora indicada. Devuelve su identificador.
    func create(reminder: GemmaReminder, alertAt: Date) async throws -> String
    /// Cambia un recordatorio ya creado, en vez de crear otro al lado.
    func update(appleID: String, reminder: GemmaReminder, alertAt: Date) async throws
    /// Lo quita de la app de Apple.
    func delete(appleID: String) async throws
    /// `true` si el usuario ya lo tachó, `nil` si no se pudo averiguar.
    ///
    /// Sirve para no insistir con un compromiso que el usuario ya dio por hecho en su
    /// app, igual que `list_alarms` contrasta con el sistema en vez de fiarse de la lista
    /// propia.
    func isCompleted(appleID: String) async -> Bool?
}

extension AppleRemindersManaging {
    /// Por omisión no se sabe: una implementación que no lo soporte no debe inventarse
    /// que el recordatorio está pendiente.
    public func isCompleted(appleID: String) async -> Bool? { nil }
}

#if canImport(EventKit)
public final class EventKitRemindersManager: AppleRemindersManaging, @unchecked Sendable {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public func requestAccess() async -> Bool {
        // En iOS 17 y macOS 14 el acceso a recordatorios se pide con su propia API y
        // necesita `NSRemindersFullAccessUsageDescription` en el Info.plist; sin la
        // clave el proceso se termina al pedirlo.
        if #available(iOS 17.0, macOS 14.0, *) {
            return (try? await store.requestFullAccessToReminders()) ?? false
        }
        return (try? await store.requestAccess(to: .reminder)) ?? false
    }

    public func create(reminder: GemmaReminder, alertAt: Date) async throws -> String {
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw ReminderServiceError.noRemindersCalendar
        }

        let item = EKReminder(eventStore: store)
        item.calendar = calendar
        item.title = reminder.title
        item.notes = reminder.notes
        item.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: reminder.due
        )
        // El aviso va a la hora calculada, no a la del compromiso: avisar cuando ya
        // tendría que estar allí no sirve de nada.
        item.addAlarm(EKAlarm(absoluteDate: alertAt))

        try store.save(item, commit: true)
        return item.calendarItemIdentifier
    }

    public func update(appleID: String, reminder: GemmaReminder, alertAt: Date) async throws {
        guard let item = store.calendarItem(withIdentifier: appleID) as? EKReminder else {
            throw ReminderServiceError.notFoundInAppleReminders
        }
        item.title = reminder.title
        item.notes = reminder.notes
        item.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: reminder.due
        )
        // Se reemplazan los avisos en vez de añadir otro: si no, el recordatorio movido
        // avisaría también a la hora vieja.
        for alarm in item.alarms ?? [] { item.removeAlarm(alarm) }
        item.addAlarm(EKAlarm(absoluteDate: alertAt))
        try store.save(item, commit: true)
    }

    public func delete(appleID: String) async throws {
        guard let item = store.calendarItem(withIdentifier: appleID) as? EKReminder else {
            throw ReminderServiceError.notFoundInAppleReminders
        }
        try store.remove(item, commit: true)
    }

    public func isCompleted(appleID: String) async -> Bool? {
        guard let item = store.calendarItem(withIdentifier: appleID) as? EKReminder else { return nil }
        return item.isCompleted
    }
}
#endif

// MARK: - El aviso propio de Gemma

/// Programa el aviso con el que Gemma le habla al usuario.
///
/// Es la mitad "de Gemma" del híbrido: el recordatorio de Apple lo ve el usuario en su
/// app, pero este aviso es el que trae el texto calculado ("sal a las 08:15 para llegar
/// a las 08:30") y el que hace que el usuario vuelva a Gemma.
public protocol ReminderAlerting: Sendable {
    func requestAuthorization() async -> Bool
    /// Programa un aviso. `kind` distingue los varios avisos del mismo recordatorio, para
    /// poder reemplazarlos cuando el viaje cambia.
    func scheduleAlert(
        id: UUID,
        kind: ReminderCheckpointKind,
        title: String,
        body: String,
        at date: Date
    ) async throws
    /// Borra todos los avisos pendientes de ese recordatorio.
    func cancelAlerts(id: UUID)
}

public final class NotificationReminderAlerter: ReminderAlerting, Sendable {
    public init() {}

    private static func identifier(_ id: UUID, _ kind: ReminderCheckpointKind) -> String {
        "gemma.reminder.\(id.uuidString).\(kind.rawValue)"
    }

    private static func allIdentifiers(_ id: UUID) -> [String] {
        [ReminderCheckpointKind.headsUp, .preparationCheck, .leaveNow].map { identifier(id, $0) }
    }

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

    public func scheduleAlert(
        id: UUID,
        kind: ReminderCheckpointKind,
        title: String,
        body: String,
        at date: Date
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Así la app sabe, al abrirse desde el aviso, de qué recordatorio se trata y en
        // qué punto está, para poder seguir la conversación donde el aviso la dejó.
        content.userInfo = [
            "gemma.reminder.id": id.uuidString,
            "gemma.reminder.checkpoint": kind.rawValue
        ]

        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: Self.identifier(id, kind),
                content: content,
                trigger: trigger
            )
        )
    }

    public func cancelAlerts(id: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: Self.allIdentifiers(id))
    }
}

// MARK: - La memoria de Gemma

/// Guarda el recordatorio en la memoria de Gemma.
///
/// Es lo que hace que Gemma pueda hablar del recordatorio en una conversación ("tienes
/// la reunión a las 8:30") sin depender de la app Recordatorios, que no puede consultar
/// a mitad de una frase.
public protocol ReminderMemoryWriting: Sendable {
    func remember(_ reminder: GemmaReminder, plan: ReminderPlan) async throws
    /// Lo borra de la memoria. Sin esto, Gemma sigue hablando de un compromiso que el
    /// usuario ya canceló.
    func forget(_ reminder: GemmaReminder) async throws
}

public final class MemoryServiceReminderWriter: ReminderMemoryWriting, Sendable {
    public init() {}

    public func remember(_ reminder: GemmaReminder, plan: ReminderPlan) async throws {
        guard let memory = await MemoryToolbox.shared.memory else {
            throw ReminderServiceError.memoryUnavailable
        }
        let formatter = ISO8601DateFormatter()
        var extra: [String: Any] = [
            "status": "pending",
            "due": formatter.string(from: reminder.due),
            "alert_at": formatter.string(from: plan.alertAt),
            "basis": plan.basis.rawValue,
            "reminder_id": reminder.id.uuidString
        ]
        if let leaveBy = plan.leaveBy {
            extra["leave_by"] = formatter.string(from: leaveBy)
        }
        if let destination = reminder.destination {
            extra["destination"] = destination.name
        }

        _ = try await memory.save(
            kind: "reminder",
            label: reminder.title,
            body: reminder.notes,
            extra: ToolJSONOutput.object(extra),
            sourceRef: nil
        )
    }

    public func forget(_ reminder: GemmaReminder) async throws {
        guard let memory = await MemoryToolbox.shared.memory else {
            throw ReminderServiceError.memoryUnavailable
        }
        _ = try await memory.forget(label: reminder.title, id: nil)
    }
}

public enum ReminderServiceError: Error, LocalizedError, Equatable {
    case noRemindersCalendar
    case memoryUnavailable
    /// Ninguno de los tres destinos aceptó el recordatorio.
    case nothingStored([String])
    /// Gemma no tiene apuntado ningún recordatorio con ese identificador.
    case notFound
    /// Estaba apuntado, pero la app de Apple ya no lo tiene.
    case notFoundInAppleReminders

    public var errorDescription: String? {
        switch self {
        case .noRemindersCalendar:
            return "No hay ninguna lista de Recordatorios donde guardarlo."
        case .memoryUnavailable:
            return "La memoria de Gemma no está disponible."
        case .nothingStored(let reasons):
            return "No se pudo guardar el recordatorio en ningún sitio: \(reasons.joined(separator: "; "))"
        case .notFound:
            return "Gemma no tiene ese recordatorio apuntado."
        case .notFoundInAppleReminders:
            return "El recordatorio ya no está en la app Recordatorios."
        }
    }
}

/// Qué se consiguió limpiar al borrar un recordatorio.
///
/// Se informa de los tres destinos por separado por la misma razón que al crearlo: si la
/// app de Apple no deja borrarlo pero el aviso de Gemma sí se retiró, el usuario tiene
/// que saber que le queda uno tachado a mano.
public struct ReminderDeletion: Sendable, Equatable {
    public let removedFromAppleReminders: Bool
    public let alertsCancelled: Bool
    public let removedFromMemory: Bool
    public let failures: [String]

    public init(
        removedFromAppleReminders: Bool,
        alertsCancelled: Bool,
        removedFromMemory: Bool,
        failures: [String]
    ) {
        self.removedFromAppleReminders = removedFromAppleReminders
        self.alertsCancelled = alertsCancelled
        self.removedFromMemory = removedFromMemory
        self.failures = failures
    }
}

// MARK: - El servicio híbrido

/// Crea recordatorios en los tres sitios a la vez.
///
/// El usuario lo pidió así: alarmas y temporizadores nativos (eso lo hace `ClockService`
/// con AlarmKit), y los recordatorios **híbridos**. Híbrido significa tres cosas a la
/// vez, cada una con su razón de ser:
///
/// 1. **App Recordatorios de Apple**, para que el recordatorio exista donde el usuario
///    ya mira, se sincronice con sus otros dispositivos y pueda tacharlo a mano.
/// 2. **Aviso propio de Gemma** a la hora calculada, que es el que trae el texto útil
///    ("sal a las 08:15") y el que devuelve al usuario a la conversación.
/// 3. **Memoria de Gemma**, para que Gemma sepa del compromiso mientras habla, sin
///    tener que consultar nada.
///
/// Los tres son independientes y se informa de los tres: un recordatorio que solo entró
/// en uno no es "creado" sin más.
public final class HybridReminderService: Sendable {
    private let reminders: (any AppleRemindersManaging)?
    private let alerter: any ReminderAlerting
    private let memory: any ReminderMemoryWriting
    private let calculator: ReminderLeadTimeCalculator
    private let planner: ReminderCheckpointPlanner
    private let monitor: ReminderMonitor?
    private let persistence: ReminderPersistence

    public init(
        reminders: (any AppleRemindersManaging)? = HybridReminderService.defaultRemindersManager(),
        alerter: any ReminderAlerting = NotificationReminderAlerter(),
        memory: any ReminderMemoryWriting = MemoryServiceReminderWriter(),
        calculator: ReminderLeadTimeCalculator = ReminderLeadTimeCalculator(),
        planner: ReminderCheckpointPlanner = ReminderCheckpointPlanner(),
        monitor: ReminderMonitor? = .shared,
        persistence: ReminderPersistence = .shared
    ) {
        self.reminders = reminders
        self.alerter = alerter
        self.memory = memory
        self.calculator = calculator
        self.planner = planner
        self.monitor = monitor
        self.persistence = persistence
    }

    public static func defaultRemindersManager() -> (any AppleRemindersManaging)? {
        #if canImport(EventKit)
        return EventKitRemindersManager()
        #else
        return nil
        #endif
    }

    public func create(
        title: String,
        due: Date,
        destination: ReminderDestination? = nil,
        notes: String? = nil,
        now: Date = Date()
    ) async throws -> CreatedReminder {
        let plan = try await calculator.plan(due: due, destination: destination, now: now)
        let reminder = GemmaReminder(title: title, due: due, destination: destination, notes: notes)
        // Los avisos van repartidos: abrir la preparación, comprobar que ya está listo,
        // y salir. Uno solo llegaría tarde o demasiado pronto.
        let checkpoints = planner.checkpoints(due: due, travelTime: plan.travelTime, now: now)
        let firstAlert = checkpoints.first?.at ?? plan.alertAt

        var failures: [String] = []

        var inAppleReminders = false
        var appleID: String? = nil
        if let reminders {
            if await reminders.requestAccess() {
                do {
                    // El identificador se guarda: es lo único que permite después mover
                    // de hora o borrar el recordatorio de Apple en vez de duplicarlo.
                    appleID = try await reminders.create(reminder: reminder, alertAt: firstAlert)
                    inAppleReminders = true
                } catch {
                    failures.append("Recordatorios: \(error.localizedDescription)")
                }
            } else {
                failures.append("Falta el permiso de Recordatorios.")
            }
        } else {
            failures.append("Esta plataforma no tiene app Recordatorios.")
        }

        var alertScheduled = false
        if await alerter.requestAuthorization() {
            for checkpoint in checkpoints {
                do {
                    try await alerter.scheduleAlert(
                        id: reminder.id,
                        kind: checkpoint.kind,
                        title: "Gemma",
                        body: checkpoint.message(title: title),
                        at: checkpoint.at
                    )
                    alertScheduled = true
                } catch {
                    failures.append("Aviso de Gemma (\(checkpoint.kind.rawValue)): \(error.localizedDescription)")
                }
            }
        } else {
            failures.append("Falta el permiso de notificaciones, así que Gemma no podrá avisar.")
        }

        var inMemory = false
        do {
            try await memory.remember(reminder, plan: plan)
            inMemory = true
        } catch {
            failures.append("Memoria: \(error.localizedDescription)")
        }

        let storage = ReminderStorageResult(
            inAppleReminders: inAppleReminders,
            gemmaAlertScheduled: alertScheduled,
            inGemmaMemory: inMemory,
            failures: failures
        )
        guard storage.anywhere else {
            throw ReminderServiceError.nothingStored(failures)
        }

        // El viaje se vuelve a calcular mientras el usuario se mueve: a partir de una
        // hora antes, el monitor reprograma estos avisos si la hora de salida cambia.
        if let monitor, destination != nil {
            await monitor.track(reminder, travelTime: plan.travelTime, checkpoints: checkpoints)
        }

        persistence.add(StoredReminder(
            id: reminder.id,
            title: title,
            due: due,
            destinationName: destination?.name,
            notes: notes,
            alertAt: firstAlert,
            leaveBy: plan.leaveBy,
            appleID: appleID
        ))

        return CreatedReminder(
            reminder: reminder,
            plan: plan,
            checkpoints: checkpoints,
            storage: storage
        )
    }

    // MARK: - Leer

    /// Los recordatorios que Gemma tiene puestos, de más próximo a más lejano.
    public func list() -> [StoredReminder] { persistence.all() }

    public func get(id: UUID) -> StoredReminder? { persistence.get(id: id) }

    /// Lo apuntado, contrastado con la app de Apple.
    ///
    /// `completedInApple` es `nil` cuando no hay nada que contrastar (no entró en la app,
    /// o la app no contestó); `true` cuando el usuario ya lo tachó, y entonces insistir
    /// con el compromiso sería no estar escuchando.
    public func listWithAppleState() async -> [(stored: StoredReminder, completedInApple: Bool?)] {
        var rows: [(stored: StoredReminder, completedInApple: Bool?)] = []
        for stored in persistence.all() {
            var completed: Bool? = nil
            if let appleID = stored.appleID, let reminders {
                completed = await reminders.isCompleted(appleID: appleID)
            }
            rows.append((stored, completed))
        }
        return rows
    }

    // MARK: - Mover de hora o cambiar

    /// Cambia un recordatorio ya puesto. Lo que no se pasa, no se toca.
    ///
    /// Mover la hora obliga a recalcular el plan entero (el aviso, la hora de salida y
    /// los puntos de control), así que los avisos viejos se retiran antes de programar
    /// los nuevos: dejarlos puestos haría que Gemma avisara a las dos horas.
    public func update(
        id: UUID,
        title: String? = nil,
        due: Date? = nil,
        destination: ReminderDestination? = nil,
        notes: String? = nil,
        now: Date = Date()
    ) async throws -> CreatedReminder {
        guard let existing = persistence.get(id: id) else { throw ReminderServiceError.notFound }

        let newTitle = title ?? existing.title
        let newDue = due ?? existing.due
        let newDestination = destination ?? existing.destinationName.map { ReminderDestination(name: $0) }
        let newNotes = notes ?? existing.notes

        // Si la hora no se toca, que ya haya pasado no es un error del usuario: está
        // corrigiendo el título o las notas de un recordatorio viejo, y rechazárselo con
        // "esa hora ya pasó" sería no dejarle arreglar nada. Solo se exige hora futura
        // cuando la hora es lo que se está cambiando.
        let plan: ReminderPlan
        do {
            plan = try await calculator.plan(due: newDue, destination: newDestination, now: now)
        } catch ReminderLeadTimeError.dueDateInThePast where due == nil {
            plan = ReminderPlan(
                due: newDue,
                alertAt: now,
                leaveBy: nil,
                travelTime: nil,
                basis: .fixedHourBefore,
                isLate: true
            )
        }
        let reminder = GemmaReminder(
            id: id, title: newTitle, due: newDue,
            destination: newDestination, notes: newNotes
        )
        let checkpoints = planner.checkpoints(due: newDue, travelTime: plan.travelTime, now: now)
        let firstAlert = checkpoints.first?.at ?? plan.alertAt

        var failures: [String] = []

        // 1. La app de Apple: se actualiza el que hay, no se crea otro.
        var inAppleReminders = false
        var appleID = existing.appleID
        if let reminders, await reminders.requestAccess() {
            do {
                if let appleID {
                    try await reminders.update(appleID: appleID, reminder: reminder, alertAt: firstAlert)
                } else {
                    // No había entrado al crearlo (sin permiso, por ejemplo): se
                    // aprovecha para meterlo ahora.
                    appleID = try await reminders.create(reminder: reminder, alertAt: firstAlert)
                }
                inAppleReminders = true
            } catch {
                failures.append("Recordatorios: \(error.localizedDescription)")
            }
        } else if reminders != nil {
            failures.append("Falta el permiso de Recordatorios.")
        }

        // 2. Los avisos de Gemma: fuera los viejos antes de poner los nuevos.
        alerter.cancelAlerts(id: id)
        var alertScheduled = false
        if await alerter.requestAuthorization() {
            for checkpoint in checkpoints {
                do {
                    try await alerter.scheduleAlert(
                        id: id, kind: checkpoint.kind, title: "Gemma",
                        body: checkpoint.message(title: newTitle), at: checkpoint.at
                    )
                    alertScheduled = true
                } catch {
                    failures.append("Aviso de Gemma (\(checkpoint.kind.rawValue)): \(error.localizedDescription)")
                }
            }
        } else {
            failures.append("Falta el permiso de notificaciones, así que Gemma no podrá avisar.")
        }

        // 3. La memoria: se reescribe con la hora nueva.
        var inMemory = false
        do {
            try await memory.remember(reminder, plan: plan)
            inMemory = true
        } catch {
            failures.append("Memoria: \(error.localizedDescription)")
        }

        if let monitor {
            if newDestination != nil {
                await monitor.track(reminder, travelTime: plan.travelTime, checkpoints: checkpoints)
            } else {
                // Ya no hay a dónde ir: seguir vigilando el viaje reprogramaría avisos
                // de un trayecto que no existe.
                await monitor.untrack(id: id)
            }
        }

        persistence.add(StoredReminder(
            id: id, title: newTitle, due: newDue,
            destinationName: newDestination?.name, notes: newNotes,
            alertAt: firstAlert, leaveBy: plan.leaveBy, appleID: appleID
        ))

        return CreatedReminder(
            reminder: reminder,
            plan: plan,
            checkpoints: checkpoints,
            storage: ReminderStorageResult(
                inAppleReminders: inAppleReminders,
                gemmaAlertScheduled: alertScheduled,
                inGemmaMemory: inMemory,
                failures: failures
            )
        )
    }

    // MARK: - Borrar

    /// Borra un recordatorio de los tres sitios.
    ///
    /// Cada destino se limpia por separado y un fallo no detiene a los demás: si la app
    /// de Apple no deja borrarlo, el aviso de Gemma hay que retirarlo igualmente, porque
    /// lo contrario deja sonando un recordatorio que el usuario cree borrado.
    public func delete(id: UUID) async throws -> ReminderDeletion {
        guard let existing = persistence.get(id: id) else { throw ReminderServiceError.notFound }

        var failures: [String] = []

        var removedFromApple = false
        if let appleID = existing.appleID, let reminders {
            if await reminders.requestAccess() {
                do {
                    try await reminders.delete(appleID: appleID)
                    removedFromApple = true
                } catch {
                    failures.append("Recordatorios: \(error.localizedDescription)")
                }
            } else {
                failures.append("Falta el permiso de Recordatorios, así que sigue en la app de Apple.")
            }
        }

        // Retirar los avisos no puede fallar y es lo más importante: es lo que suena.
        alerter.cancelAlerts(id: id)
        await monitor?.untrack(id: id)

        var removedFromMemory = false
        do {
            try await memory.forget(existing.reminder)
            removedFromMemory = true
        } catch {
            failures.append("Memoria: \(error.localizedDescription)")
        }

        persistence.remove(id: id)

        return ReminderDeletion(
            removedFromAppleReminders: removedFromApple,
            alertsCancelled: true,
            removedFromMemory: removedFromMemory,
            failures: failures
        )
    }
}
