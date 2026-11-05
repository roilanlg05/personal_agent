import Foundation

/// A shift opportunity as offered to the account by A to Z (types ADD / VOLUNTARY_EXTRA_TIME).
struct AtoZShiftOpportunity: Equatable {
    let id: String              // opaque server id, e.g. "amzn.ls.opportunityid…"
    let type: String            // "ADD" | "VOLUNTARY_EXTRA_TIME"
    let start: Date
    let end: Date
    let isEligible: Bool
    let unclaimableReasonCodes: [String]

    var durationMinutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

/// Every outcome Gemma distinguishes (guidelines §9). `.addConfirmed` is only produced after an
/// independent verification query shows the shift on the user's schedule.
enum AtoZFailure: Error, Equatable {
    case notConfigured                 // integration off / no session stored
    case notLoggedIn                   // no session in RAM (never pasted, or app was restarted)
    case suspended                     // latched after Amazon denied/limited access
    case sessionExpired                // Amazon rejected the session (401 / redirect to login)
    case accessDenied
    case accessLimited(String)         // 429, bot challenge/CAPTCHA, explicit restriction
    case shiftUnavailable
    case scheduleConflict
    case serverError(Int)
    case unknown(String)               // transport failure or unparseable response
    case invalidRequest(String)        // rejected locally before any HTTP

    /// True when Amazon is restricting access: Gemma must stop (latch `suspended`), never retry.
    var requiresSuspension: Bool {
        switch self {
        case .accessDenied, .accessLimited: return true
        default: return false
        }
    }

    /// Short Spanish message for the user / model. Contains no secrets.
    var userMessage: String {
        switch self {
        case .notConfigured: return "No has iniciado sesión en Amazon A to Z. Abre Ajustes (icono de engranaje) en la app y pulsa 'Iniciar sesión en A to Z' para conectarte."
        case .notLoggedIn: return "No hay sesión de A to Z en memoria (la app se reinició o no se guardó). Abre Ajustes → Conectar Amazon A to Z y pega la cookie de nuevo."
        case .suspended: return "El acceso a A to Z está suspendido porque Amazon lo restringió. No voy a reintentar; revísalo en Ajustes."
        case .sessionExpired: return "Amazon rechazó la sesión de A to Z (\(AtoZDiagnostics.last ?? "sin detalle")). Vuelve a copiar la cookie desde una petición a atoz-apps.amazon.work y pégala en Ajustes."
        case .accessDenied: return "Amazon denegó el acceso. He detenido la integración y no voy a reintentar."
        case .accessLimited(let why): return "Amazon limitó el acceso (\(why)). He detenido la integración y no voy a intentar evitarlo."
        case .shiftUnavailable: return "Ese turno ya no está disponible."
        case .scheduleConflict: return "Ese turno no es compatible con tu horario o tus límites."
        case .serverError(let code): return "A to Z respondió con un error del servidor (\(code))."
        case .unknown(let why): return "Resultado desconocido (\(why))."
        case .invalidRequest(let why): return why
        }
    }
}

/// Last server-side rejection detail. Contains ONLY status / host / path / content-type —
/// never cookie values, tokens, or response bodies.
enum AtoZDiagnostics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _last: String?

    static var last: String? {
        lock.lock(); defer { lock.unlock() }
        return _last
    }

    static func record(_ s: String?) {
        lock.lock(); defer { lock.unlock() }
        _last = s
    }
}

/// Result of an add-shift attempt.
enum AtoZAddShiftResult: Equatable {
    case confirmationRequired(prompt: String)
    case dryRun(description: String)
    case confirmed(AtoZShiftOpportunity)
    /// Mutation was sent but acceptance could not be verified. The id is now locked: no new
    /// AddShift for it until a later verification resolves the state.
    case unknownOutcome(AtoZShiftOpportunity, reason: String)
    case failed(AtoZFailure)
}

/// Result of a drop-shift attempt.
enum AtoZDropShiftResult: Equatable {
    case confirmationRequired(prompt: String)
    case dryRun(description: String)
    case confirmed(AtoZShiftOpportunity)
    case unknownOutcome(AtoZShiftOpportunity, reason: String)
    case failed(AtoZFailure)
}

/// Local-time formatting for tool output (Spanish).
enum AtoZFormat {
    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "es_ES"); f.timeZone = .current
        f.dateFormat = "EEEE d 'de' MMMM yyyy"
        return f.string(from: d)
    }
    static func isoDay(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
    static func typeLabel(_ t: String) -> String {
        switch t {
        case "VOLUNTARY_EXTRA_TIME": return "VET"
        case "ADD": return "turno adicional"
        case "DROP": return "soltar turno (drop)"
        case "VOLUNTARY_TIME_OFF": return "VTO"
        default: return t
        }
    }
    /// "martes 4 de noviembre 2026, 5:00 PM–9:00 PM (4 h, VET)"
    static func describe(_ o: AtoZShiftOpportunity) -> String {
        "\(day(o.start)), \(time(o.start))–\(time(o.end)) (\(duration(o.durationMinutes)), \(typeLabel(o.type)))"
    }
}
