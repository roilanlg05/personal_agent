import Foundation

/// Qué pasó al revisar un recordatorio.
public enum ReminderRefreshOutcome: Sendable, Equatable {
    /// Todavía está lejos: no se gasta ni mapa ni batería.
    case outsideWindow(UUID)
    /// Se recalculó y el viaje sigue dando la misma hora de salida.
    case unchanged(UUID)
    /// El viaje cambió y los avisos se movieron.
    case rescheduled(id: UUID, leaveBy: Date?, previousLeaveBy: Date?)
    /// La hora ya pasó: deja de seguirse.
    case finished(UUID)
}

/// Lo que el monitor guarda de cada recordatorio que sigue.
struct TrackedReminder: Sendable {
    let reminder: GemmaReminder
    var leaveBy: Date?
    var travelTime: TimeInterval?
    var checkpoints: [ReminderCheckpoint]
}

/// Vuelve a calcular el viaje mientras el usuario se mueve, y mueve los avisos.
///
/// ## Por qué hace falta
///
/// La hora de salida de un recordatorio se calcula desde donde está el usuario, y el
/// usuario se mueve. Si el aviso se calcula una sola vez al crearlo, a las tres de la
/// tarde puede estar en casa a quince minutos del trabajo y a las cuatro en otro barrio
/// a cuarenta. El aviso quedaría mal y llegaría tarde.
///
/// Así que, **a partir de una hora antes** del compromiso, el monitor recalcula el viaje
/// desde la posición actual, y si la hora de salida se mueve lo suficiente, reprograma
/// todos los avisos pendientes.
///
/// ## Lo que no hace
///
/// No sigue la posición con la app cerrada: eso exigiría el permiso de ubicación
/// "siempre", que Gemma no pide. El seguimiento ocurre mientras la app está viva, y los
/// avisos ya programados siguen sonando igual aunque no se pueda recalcular. En el peor
/// caso el aviso es el de la última estimación, nunca ninguno.
public actor ReminderMonitor {
    /// Desde cuánto antes del compromiso se empieza a recalcular.
    public static let defaultWindow: TimeInterval = 60 * 60
    /// Cuánto tiene que moverse la hora de salida para merecer reprogramar los avisos.
    /// Por debajo de esto, mover las notificaciones solo haría ruido.
    public static let defaultTolerance: TimeInterval = 2 * 60

    private let estimator: any TravelTimeEstimating
    private let alerter: any ReminderAlerting
    private let planner: ReminderCheckpointPlanner
    private let window: TimeInterval
    private let tolerance: TimeInterval

    private var tracked: [UUID: TrackedReminder] = [:]

    /// Monitor único de la app.
    ///
    /// Las herramientas se reconstruyen en cada turno de conversación, así que un
    /// monitor por herramienta olvidaría lo que estaba siguiendo en cuanto el turno
    /// terminara.
    public static let shared = ReminderMonitor()

    public init(
        estimator: any TravelTimeEstimating = MapKitTravelTimeEstimator(),
        alerter: any ReminderAlerting = NotificationReminderAlerter(),
        planner: ReminderCheckpointPlanner = ReminderCheckpointPlanner(),
        window: TimeInterval = ReminderMonitor.defaultWindow,
        tolerance: TimeInterval = ReminderMonitor.defaultTolerance
    ) {
        self.estimator = estimator
        self.alerter = alerter
        self.planner = planner
        self.window = window
        self.tolerance = tolerance
    }

    /// Empieza a seguir un recordatorio recién creado.
    public func track(
        _ reminder: GemmaReminder,
        travelTime: TimeInterval?,
        checkpoints: [ReminderCheckpoint]
    ) {
        tracked[reminder.id] = TrackedReminder(
            reminder: reminder,
            leaveBy: checkpoints.first?.leaveBy,
            travelTime: travelTime,
            checkpoints: checkpoints
        )
    }

    public func untrack(id: UUID) {
        tracked.removeValue(forKey: id)
        alerter.cancelAlerts(id: id)
    }

    public func trackedIDs() -> Set<UUID> { Set(tracked.keys) }

    public func checkpoints(for id: UUID) -> [ReminderCheckpoint] {
        tracked[id]?.checkpoints ?? []
    }

    /// Revisa todos los recordatorios seguidos. Se llama al abrir la app y cada pocos
    /// minutos mientras está viva.
    public func refresh(now: Date = Date()) async -> [ReminderRefreshOutcome] {
        var outcomes: [ReminderRefreshOutcome] = []
        for id in tracked.keys {
            outcomes.append(await refresh(id: id, now: now))
        }
        return outcomes
    }

    func refresh(id: UUID, now: Date) async -> ReminderRefreshOutcome {
        guard let entry = tracked[id] else { return .finished(id) }
        let reminder = entry.reminder

        guard reminder.due > now else {
            // Ya pasó: se suelta y se limpian los avisos que quedaran colgando.
            tracked.removeValue(forKey: id)
            alerter.cancelAlerts(id: id)
            return .finished(id)
        }

        guard reminder.due.timeIntervalSince(now) <= window else {
            return .outsideWindow(id)
        }
        guard let destination = reminder.destination else {
            // Sin sitio no hay viaje que recalcular: su aviso único ya está puesto.
            return .unchanged(id)
        }

        guard let travel = try? await estimator.travelTime(to: destination) else {
            // El mapa no contesta ahora: se queda la estimación anterior, que es mejor
            // que ninguna.
            return .unchanged(id)
        }

        let newLeaveBy = reminder.due.addingTimeInterval(-travel)
        if let previous = entry.leaveBy,
           abs(newLeaveBy.timeIntervalSince(previous)) < tolerance {
            return .unchanged(id)
        }

        let checkpoints = planner.checkpoints(due: reminder.due, travelTime: travel, now: now)
        alerter.cancelAlerts(id: id)
        for checkpoint in checkpoints {
            try? await alerter.scheduleAlert(
                id: id,
                kind: checkpoint.kind,
                title: "Gemma",
                body: checkpoint.message(title: reminder.title),
                at: checkpoint.at
            )
        }

        tracked[id] = TrackedReminder(
            reminder: reminder,
            leaveBy: newLeaveBy,
            travelTime: travel,
            checkpoints: checkpoints
        )
        return .rescheduled(id: id, leaveBy: newLeaveBy, previousLeaveBy: entry.leaveBy)
    }
}


/// Mantiene el monitor despierto mientras la app está viva.
///
/// No hay seguimiento con la app cerrada: eso pediría el permiso de ubicación "siempre",
/// que Gemma no pide. Lo que sí se puede es revisar al abrir la app y cada pocos minutos
/// mientras está abierta, que es cuando el usuario está decidiendo si sale.
public actor ReminderMonitorDriver {
    public static let shared = ReminderMonitorDriver()

    private let monitor: ReminderMonitor
    private let interval: TimeInterval
    private var loop: Task<Void, Never>?

    public init(monitor: ReminderMonitor = .shared, interval: TimeInterval = 5 * 60) {
        self.monitor = monitor
        self.interval = interval
    }

    /// Arranca la revisión periódica. Llamarlo dos veces no crea dos bucles.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [monitor, interval] in
            while !Task.isCancelled {
                _ = await monitor.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Revisión inmediata, para cuando la app vuelve al primer plano: ahí es cuando más
    /// probable es que el usuario se haya movido desde la última vez.
    public func refreshNow() async {
        _ = await monitor.refresh()
    }
}
