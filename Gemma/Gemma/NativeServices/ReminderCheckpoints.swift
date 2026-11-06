import Foundation

/// Cada momento en que Gemma habla antes de un compromiso.
public enum ReminderCheckpointKind: String, Sendable {
    /// Se abre la ventana de preparación: "tienes una cita a las 16:15, te queda
    /// cuarenta y cinco minutos para prepararte".
    case headsUp = "heads_up"
    /// A mitad de la preparación: "¿ya te preparaste? sales en 22 minutos".
    case preparationCheck = "preparation_check"
    /// Hora límite de salida.
    case leaveNow = "leave_now"
}

public struct ReminderCheckpoint: Sendable, Equatable {
    public let kind: ReminderCheckpointKind
    /// Cuándo habla Gemma.
    public let at: Date
    /// Hora del compromiso.
    public let due: Date
    /// Hora límite de salida, si hay viaje.
    public let leaveBy: Date?
    /// `true` si este aviso ya llega tarde y sale de inmediato.
    public let isLate: Bool

    private static func clock(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone
        return formatter
    }

    /// Minutos que faltan, truncados hacia abajo.
    ///
    /// Se trunca a propósito: decirle al usuario que tiene 23 minutos cuando tiene 22 y
    /// medio le regala medio minuto que no existe. Al revés nadie llega tarde.
    private static func minutes(from: Date, to: Date) -> Int {
        max(0, Int(to.timeIntervalSince(from) / 60))
    }

    /// Lo que Gemma le dice al usuario en este punto.
    ///
    /// Cada aviso lleva el dato que sirve para decidir en ese instante: al abrir la
    /// ventana, cuánto hay para prepararse; a mitad, cuánto queda para salir; al final,
    /// que salga. Repetir siempre lo mismo haría que el usuario dejara de leerlos.
    public func message(title: String, timeZone: TimeZone = .current) -> String {
        let formatter = Self.clock(timeZone)
        let dueText = formatter.string(from: due)

        switch kind {
        case .headsUp:
            guard let leaveBy else {
                return "Recuerda: \(title) a las \(dueText)."
            }
            let prepMinutes = Self.minutes(from: at, to: leaveBy)
            return "Tienes \(title) a las \(dueText). Te quedan \(prepMinutes) minutos para prepararte; "
                + "sales a las \(formatter.string(from: leaveBy))."

        case .preparationCheck:
            guard let leaveBy else {
                return "¿Todo listo para \(title) a las \(dueText)?"
            }
            let remaining = Self.minutes(from: at, to: leaveBy)
            return "¿Ya te preparaste? Tienes que salir dentro de \(remaining) minutos para llegar a "
                + "\(title) a las \(dueText)."

        case .leaveNow:
            guard let leaveBy else {
                return "Es la hora de \(title)."
            }
            if isLate {
                return "Sal ya para \(title): tendrías que haber salido a las "
                    + "\(formatter.string(from: leaveBy)) para llegar a las \(dueText)."
            }
            return "Sal ya para llegar a \(title) a las \(dueText)."
        }
    }
}

/// Reparte los avisos de un recordatorio a lo largo del tiempo.
///
/// Un solo aviso no sirve: el usuario pidió que Gemma le acompañe. Primero le dice que
/// abra la ventana de preparación, luego le pregunta si ya está listo, y al final le dice
/// que salga. Todo se calcula desde la hora límite de salida, que depende del viaje, y el
/// viaje se recalcula mientras el usuario se mueve (ver `ReminderMonitor`).
///
/// Es puro: recibe el viaje ya estimado y la hora actual, así que las reglas se prueban
/// sin mapas ni reloj real.
public struct ReminderCheckpointPlanner: Sendable {
    /// Cuánto tiempo necesita el usuario para prepararse antes de salir.
    public let preparationTime: TimeInterval
    /// Antelación del aviso cuando no hay sitio al que ir y por tanto no hay viaje que
    /// calcular. Es la regla que pidió el usuario: una hora antes.
    public let fallbackLeadTime: TimeInterval

    public init(
        preparationTime: TimeInterval = 45 * 60,
        fallbackLeadTime: TimeInterval = 60 * 60
    ) {
        self.preparationTime = preparationTime
        self.fallbackLeadTime = fallbackLeadTime
    }

    public func checkpoints(
        due: Date,
        travelTime: TimeInterval?,
        now: Date = Date()
    ) -> [ReminderCheckpoint] {
        guard due > now else { return [] }

        guard let travelTime else {
            // Sin viaje no hay hora de salida que calcular: queda el aviso único con la
            // antelación por omisión.
            let at = due.addingTimeInterval(-fallbackLeadTime)
            guard at > now else { return [] }
            return [ReminderCheckpoint(kind: .headsUp, at: at, due: due, leaveBy: nil, isLate: false)]
        }

        let leaveBy = due.addingTimeInterval(-travelTime)

        // Salir es lo único que no se puede perder: si su hora ya pasó, sale ahora y se
        // dice que va tarde.
        let leaveIsLate = leaveBy <= now
        let leaveCheckpoint = ReminderCheckpoint(
            kind: .leaveNow,
            at: leaveIsLate ? now : leaveBy,
            due: due,
            leaveBy: leaveBy,
            isLate: leaveIsLate
        )

        let prepStart = leaveBy.addingTimeInterval(-preparationTime)
        let prepCheck = prepStart.addingTimeInterval(preparationTime / 2)

        var result: [ReminderCheckpoint] = []
        if prepStart > now {
            result.append(
                ReminderCheckpoint(kind: .headsUp, at: prepStart, due: due, leaveBy: leaveBy, isLate: false)
            )
        }
        if prepCheck > now, !leaveIsLate {
            result.append(
                ReminderCheckpoint(
                    kind: .preparationCheck,
                    at: prepCheck,
                    due: due,
                    leaveBy: leaveBy,
                    isLate: false
                )
            )
        }
        result.append(leaveCheckpoint)
        return result
    }
}
