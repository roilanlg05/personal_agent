import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif

public enum ActivityState: String, Codable, Sendable {
    case automotive
    case walking
    case running
    case cycling
    case stationary
    case unknown
}

public struct ActivitySnapshot: Codable, Sendable, Equatable {
    public let state: ActivityState
    public let confidence: String
    public let timestamp: Date

    public init(state: ActivityState, confidence: String = "high", timestamp: Date = Date()) {
        self.state = state
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

/// Permiso de movimiento, que es obligatorio para leer la actividad.
public enum MotionAuthorization: String, Sendable {
    case notDetermined = "not_determined"
    case denied
    case restricted
    case authorized
    /// El dispositivo no tiene el sensor.
    case unavailable
}

/// Por qué no se sabe qué está haciendo el usuario.
public enum MotionUnknownReason: String, Sendable {
    /// El hardware no soporta detección de actividad.
    case unavailable
    case permissionDenied = "permission_denied"
    /// El sensor funciona, pero no hay ninguna medición reciente.
    case noRecentData = "no_recent_data"
}

/// Lo que se sabe del movimiento del usuario.
///
/// Existe el caso "no lo sé" porque antes no existía: la clase arrancaba con un
/// `stationary` por omisión y lo devolvía como si fuera una medición, así que Gemma
/// afirmaba que el usuario estaba quieto sin haber leído el sensor ni una vez.
public enum MotionReading: Sendable, Equatable {
    case reading(ActivitySnapshot)
    case unknown(reason: MotionUnknownReason)
}

public protocol MotionActivityManaging: Sendable {
    func isActivityAvailable() -> Bool
    func authorizationStatus() -> MotionAuthorization
    /// La actividad más reciente que el sistema registró desde esa fecha, o `nil` si no
    /// registró ninguna.
    func queryRecentActivity(since: Date) async -> ActivitySnapshot?
}

public final class CoreMotionActivityManager: MotionActivityManaging, @unchecked Sendable {
    #if os(iOS)
    private let activityManager = CMMotionActivityManager()
    private let queue = OperationQueue()
    #endif

    public init() {}

    public func isActivityAvailable() -> Bool {
        #if os(iOS)
        return CMMotionActivityManager.isActivityAvailable()
        #else
        return false
        #endif
    }

    public func authorizationStatus() -> MotionAuthorization {
        #if os(iOS)
        guard isActivityAvailable() else { return .unavailable }
        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .notDetermined
        }
        #else
        return .unavailable
        #endif
    }

    /// Consulta el histórico en lugar de abrir un flujo de actualizaciones.
    ///
    /// El sistema guarda la actividad de los últimos días por su cuenta, así que para
    /// responder "¿qué estoy haciendo?" basta preguntarle. Mantener un flujo abierto
    /// gastaría batería todo el día para una pregunta que se hace de vez en cuando, y
    /// además no serviría la primera vez: no habría ninguna lectura todavía.
    public func queryRecentActivity(since: Date) async -> ActivitySnapshot? {
        #if os(iOS)
        guard isActivityAvailable() else { return nil }
        return await withCheckedContinuation { continuation in
            let resumed = SingleUseFlag()
            activityManager.queryActivityStarting(from: since, to: Date(), to: queue) { activities, _ in
                guard resumed.testAndSet() else { return }
                let latest = activities?
                    .filter { Self.state(of: $0) != .unknown }
                    .max(by: { $0.startDate < $1.startDate })
                continuation.resume(returning: latest.map(Self.snapshot(from:)))
            }
        }
        #else
        return nil
        #endif
    }

    #if os(iOS)
    private static func state(of activity: CMMotionActivity) -> ActivityState {
        if activity.automotive { return .automotive }
        if activity.cycling { return .cycling }
        if activity.running { return .running }
        if activity.walking { return .walking }
        if activity.stationary { return .stationary }
        return .unknown
    }

    private static func snapshot(from activity: CMMotionActivity) -> ActivitySnapshot {
        let confidence: String
        switch activity.confidence {
        case .high: confidence = "high"
        case .medium: confidence = "medium"
        case .low: confidence = "low"
        @unknown default: confidence = "unknown"
        }
        return ActivitySnapshot(
            state: state(of: activity),
            confidence: confidence,
            timestamp: activity.startDate
        )
    }
    #endif
}

public final class MotionActivityService: Sendable {
    /// Cuánto hacia atrás se considera "ahora". Más allá de unos minutos, la actividad
    /// ya no describe lo que el usuario está haciendo.
    public static let recentWindow: TimeInterval = 300

    private let manager: any MotionActivityManaging

    public init(manager: any MotionActivityManaging = CoreMotionActivityManager()) {
        self.manager = manager
    }

    public func currentActivity(now: Date = Date()) async -> MotionReading {
        guard manager.isActivityAvailable() else {
            return .unknown(reason: .unavailable)
        }
        switch manager.authorizationStatus() {
        case .denied, .restricted:
            return .unknown(reason: .permissionDenied)
        case .unavailable:
            return .unknown(reason: .unavailable)
        case .authorized, .notDetermined:
            // `notDetermined` sigue adelante: la consulta es lo que dispara el diálogo
            // de permiso la primera vez.
            break
        }

        guard let snapshot = await manager.queryRecentActivity(
            since: now.addingTimeInterval(-Self.recentWindow)
        ) else {
            return .unknown(reason: .noRecentData)
        }
        return .reading(snapshot)
    }
}
