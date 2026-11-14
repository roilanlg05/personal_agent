import Foundation
#if os(iOS)
import AlarmKit
import SwiftUI
#endif

/// Programa alarmas y temporizadores de verdad, con AlarmKit.
///
/// AlarmKit es la API que Apple abrió en iOS 26 precisamente para esto: una alarma del
/// sistema que suena aunque el teléfono esté en silencio o en modo concentración, con su
/// propia pantalla de aviso y su botón de parar. Hasta entonces una app de terceros solo
/// podía programar una notificación local, que no suena en silencio y es fácil de
/// perderse; eso es lo que Gemma hacía y lo que el usuario notó como "alarma ficticia".
///
/// Requisitos: iOS 26 o posterior y la clave `NSAlarmKitUsageDescription` en el
/// Info.plist. Si falta el permiso, se dice; nunca se da por puesta una alarma que no
/// está puesta.
public protocol SystemAlarmScheduling: Sendable {
    /// `true` si esta plataforma puede poner alarmas del sistema.
    var isSupported: Bool { get }
    /// Pide el permiso de alarmas. `false` = el usuario lo denegó.
    func requestAuthorization() async -> Bool
    /// Pone la alarma. Lanza si el sistema la rechaza.
    func schedule(alarm: GemmaAlarm) async throws
    /// Pone un temporizador de cuenta atrás.
    func scheduleCountdown(timer: GemmaTimer) async throws
    /// Cancela una alarma o temporizador ya puesto.
    func cancel(id: UUID) throws
    /// Identificadores que el sistema tiene puestos ahora mismo.
    ///
    /// Es la única fuente de verdad: la lista que Gemma se apunta puede quedarse vieja
    /// si el usuario para una alarma desde la pantalla de aviso.
    func systemAlarmIDs() throws -> Set<UUID>
}

extension SystemAlarmScheduling {
    /// Por omisión, nada: una plataforma sin alarmas del sistema no tiene qué enumerar.
    public func systemAlarmIDs() throws -> Set<UUID> { [] }
}

/// Qué puede ir mal con las alarmas del sistema.
public enum SystemAlarmError: Error, LocalizedError, Equatable {
    case unsupported
    case permissionDenied
    case limitReached

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Este dispositivo no puede poner alarmas del sistema (requiere iOS 26)."
        case .permissionDenied:
            return "Falta el permiso de alarmas. El usuario puede concederlo en Ajustes."
        case .limitReached:
            return "Se alcanzó el número máximo de alarmas que la app puede tener puestas."
        }
    }
}

#if os(iOS)
/// Datos propios que viajan con la alarma, para poder reconocerla luego.
@available(iOS 26.0, *)
public struct GemmaAlarmMetadata: AlarmMetadata {
    public let title: String

    public init(title: String) {
        self.title = title
    }
}

@available(iOS 26.0, *)
public final class AlarmKitScheduler: SystemAlarmScheduling, Sendable {
    public init() {}

    public var isSupported: Bool { true }

    public func requestAuthorization() async -> Bool {
        let manager = AlarmManager.shared
        switch manager.authorizationState {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            // El propio `schedule` también lo pediría, pero preguntando aquí se puede
            // distinguir "el usuario dijo no" de "el sistema falló".
            return (try? await manager.requestAuthorization()) == .authorized
        @unknown default:
            return false
        }
    }

    public func schedule(alarm: GemmaAlarm) async throws {
        let schedule = Alarm.Schedule.relative(
            Alarm.Schedule.Relative(
                time: Alarm.Schedule.Relative.Time(hour: alarm.hour, minute: alarm.minute),
                repeats: Self.recurrence(for: alarm.daysOfWeek)
            )
        )
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: schedule,
            attributes: Self.alarmAttributes(title: alarm.title)
        )
        try await Self.submit(id: alarm.id, configuration: configuration)
    }

    public func scheduleCountdown(timer: GemmaTimer) async throws {
        let configuration = AlarmManager.AlarmConfiguration.timer(
            duration: TimeInterval(max(1, timer.durationSeconds)),
            attributes: Self.timerAttributes(
                title: timer.label.isEmpty ? "Temporizador" : timer.label
            )
        )
        try await Self.submit(id: timer.id, configuration: configuration)
    }

    public func cancel(id: UUID) throws {
        try AlarmManager.shared.cancel(id: id)
    }

    public func systemAlarmIDs() throws -> Set<UUID> {
        Set(try AlarmManager.shared.alarms.map(\.id))
    }

    private static func submit(
        id: UUID,
        configuration: AlarmManager.AlarmConfiguration<GemmaAlarmMetadata>
    ) async throws {
        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        } catch AlarmManager.AlarmError.maximumLimitReached {
            throw SystemAlarmError.limitReached
        }
    }

    /// Presentación de una alarma: **solo** la alerta.
    ///
    /// Añadirle un bloque `countdown` compila igual pero el sistema rechaza la alarma
    /// entera con `com.apple.AlarmKit.Alarm error 0`, sin userInfo ni error subyacente.
    /// El countdown describe una cuenta atrás en marcha, y una alarma no tiene ninguna:
    /// solo una hora a la que suena. Comprobado en el iPhone: misma alarma con y sin
    /// countdown, la primera falla y la segunda entra (`AlarmKitDeviceTests`).
    private static func alarmAttributes(title: String) -> AlarmAttributes<GemmaAlarmMetadata> {
        AlarmAttributes(
            presentation: AlarmPresentation(alert: alert(title: title)),
            metadata: GemmaAlarmMetadata(title: title),
            tintColor: .accentColor
        )
    }

    /// Presentación de un temporizador: la alerta del final más la cuenta atrás que se
    /// ve mientras corre. Aquí el countdown sí corresponde.
    private static func timerAttributes(title: String) -> AlarmAttributes<GemmaAlarmMetadata> {
        AlarmAttributes(
            presentation: AlarmPresentation(
                alert: alert(title: title),
                countdown: AlarmPresentation.Countdown(
                    title: LocalizedStringResource(stringLiteral: title)
                )
            ),
            metadata: GemmaAlarmMetadata(title: title),
            tintColor: .accentColor
        )
    }

    private static func alert(title: String) -> AlarmPresentation.Alert {
        AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: title),
            stopButton: AlarmButton(
                text: "Parar",
                textColor: .white,
                systemImageName: "stop.fill"
            )
        )
    }

    /// Traduce los días de `GemmaAlarm` (1 = domingo) a la repetición de AlarmKit.
    private static func recurrence(for daysOfWeek: [Int]) -> Alarm.Schedule.Relative.Recurrence {
        guard !daysOfWeek.isEmpty else { return .never }
        let weekdays: [Locale.Weekday] = daysOfWeek.compactMap { day in
            switch day {
            case 1: return .sunday
            case 2: return .monday
            case 3: return .tuesday
            case 4: return .wednesday
            case 5: return .thursday
            case 6: return .friday
            case 7: return .saturday
            default: return nil
            }
        }
        return weekdays.isEmpty ? .never : .weekly(weekdays)
    }
}
#endif

/// Plataforma sin alarmas del sistema (macOS, o iOS anterior a 26).
public final class UnsupportedAlarmScheduler: SystemAlarmScheduling, Sendable {
    public init() {}

    public var isSupported: Bool { false }
    public func requestAuthorization() async -> Bool { false }
    public func schedule(alarm: GemmaAlarm) async throws { throw SystemAlarmError.unsupported }
    public func scheduleCountdown(timer: GemmaTimer) async throws { throw SystemAlarmError.unsupported }
    public func cancel(id: UUID) throws { throw SystemAlarmError.unsupported }
}

public enum SystemAlarmSchedulerFactory {
    public static func make() -> any SystemAlarmScheduling {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return AlarmKitScheduler()
        }
        #endif
        return UnsupportedAlarmScheduler()
    }
}

/// Doble de pruebas.
public final class MockSystemAlarmScheduler: SystemAlarmScheduling, @unchecked Sendable {
    public var isSupported: Bool
    public var authorizationGranted: Bool
    public var errorToThrow: Error?
    public private(set) var scheduledAlarms: [GemmaAlarm] = []
    public private(set) var scheduledTimers: [GemmaTimer] = []
    public private(set) var cancelled: [UUID] = []
    public private(set) var authorizationRequests = 0

    public init(
        isSupported: Bool = true,
        authorizationGranted: Bool = true,
        errorToThrow: Error? = nil
    ) {
        self.isSupported = isSupported
        self.authorizationGranted = authorizationGranted
        self.errorToThrow = errorToThrow
    }

    public func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return authorizationGranted
    }

    public func schedule(alarm: GemmaAlarm) async throws {
        if let errorToThrow { throw errorToThrow }
        scheduledAlarms.append(alarm)
    }

    public func scheduleCountdown(timer: GemmaTimer) async throws {
        if let errorToThrow { throw errorToThrow }
        scheduledTimers.append(timer)
    }

    public func cancel(id: UUID) throws {
        if let errorToThrow { throw errorToThrow }
        cancelled.append(id)
        scheduledAlarms.removeAll { $0.id == id }
        scheduledTimers.removeAll { $0.id == id }
    }

    public func systemAlarmIDs() throws -> Set<UUID> {
        if let errorToThrow { throw errorToThrow }
        return Set(scheduledAlarms.map(\.id) + scheduledTimers.map(\.id))
    }

    /// Simula que el sistema perdió lo puesto: el usuario paró la alarma desde su
    /// pantalla de aviso, por ejemplo.
    public func forgetAll() {
        scheduledAlarms.removeAll()
        scheduledTimers.removeAll()
    }
}
