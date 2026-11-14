import Foundation

/// Enumera las alarmas y temporizadores que Gemma tiene puestos.
///
/// ## Por qué hace falta
///
/// Las alarmas de AlarmKit pertenecen a la app que las pone: **no aparecen en la app
/// Reloj de Apple**, y Apple no ofrece ninguna API para escribir ahí. Así que una alarma
/// puesta por Gemma era invisible: el usuario la pedía, Gemma decía que estaba puesta, y
/// él no la encontraba en ninguna parte y daba por hecho que era mentira.
///
/// Esta herramienta es dónde se ven. La fuente de verdad es el sistema, no la lista que
/// Gemma se apunta: si el usuario para una alarma desde su pantalla de aviso, el sistema
/// la suelta y la lista de Gemma se queda vieja.
public final class ListAlarmsTool: AgentTool, Sendable {
    public static let name = "list_alarms"
    public static let description = """
    Enumera las alarmas y los temporizadores que Gemma tiene puestos, con su hora. Úsalo \
    cuando el usuario pregunte qué alarmas tiene, o diga que no encuentra una que le \
    pusiste. IMPORTANTE: las alarmas que pone Gemma NO aparecen en la app Reloj de Apple \
    (Apple no deja escribir ahí); viven en Gemma y suenan igual, con su pantalla de \
    aviso. Si el usuario las busca en la app Reloj, explícale eso y enséñale esta lista. \
    Lee 'status': 'ok' = hay alarmas o temporizadores, 'empty' = no hay ninguno (dilo \
    tal cual, no supongas que se perdieron). En cada alarma, 'in_system' = true \
    significa que el sistema confirma que sigue puesta; false significa que Gemma la \
    tiene apuntada pero el sistema ya no (probablemente el usuario la paró), y entonces \
    dilo en vez de afirmar que sigue activa. Si 'in_system' no viene, no hay nada que \
    contrastar en esta plataforma.
    """
    public static let parameters: [AgentToolParam] = []

    private let clockService: ClockService

    public init(clockService: ClockService = ClockService()) {
        self.clockService = clockService
    }

    public func run(argsJSON: String) async -> String {
        let alarms = clockService.alarmsWithSystemState()
        let timers = clockService.timersWithSystemState()
        let method: AlarmMethod = clockService.usesSystemAlarms ? .systemAlarm : .gemmaNotification

        // `ToolJSONOutput.object` solo quita los `nil` del nivel de arriba, así que las
        // filas se limpian aquí: un `in_system: null` dentro de la fila se leería como
        // una respuesta, y lo que significa es que no hay nada que contrastar.
        let alarmRows: [[String: Any]] = alarms.map { entry in
            ([
                "id": entry.alarm.id.uuidString,
                "title": entry.alarm.title,
                "time": String(format: "%02d:%02d", entry.alarm.hour, entry.alarm.minute),
                "days_of_week": entry.alarm.daysOfWeek.isEmpty ? nil : entry.alarm.daysOfWeek,
                "repeats": !entry.alarm.daysOfWeek.isEmpty,
                "method": method.rawValue,
                "in_system": entry.confirmedBySystem
            ] as [String: Any?]).compactMapValues { $0 }
        }

        let formatter = ISO8601DateFormatter()
        let timerRows: [[String: Any]] = timers.map { entry in
            ([
                "id": entry.timer.id.uuidString,
                "label": entry.timer.label,
                "duration_minutes": entry.timer.durationSeconds / 60,
                "ends_at": formatter.string(from: entry.timer.endsAt),
                "method": method.rawValue,
                "in_system": entry.confirmedBySystem
            ] as [String: Any?]).compactMapValues { $0 }
        }

        let isEmpty = alarmRows.isEmpty && timerRows.isEmpty
        return ToolJSONOutput.object([
            "status": isEmpty ? "empty" : "ok",
            "alarms": alarmRows,
            "timers": timerRows,
            "note": clockService.usesSystemAlarms
                ? "Las alarmas de Gemma son alarmas del sistema y suenan aunque el teléfono esté en silencio, pero no se listan en la app Reloj de Apple: Apple no permite escribir ahí. Se ven aquí."
                : "En este dispositivo Gemma avisa con notificaciones propias, no con alarmas del sistema ni con la app Reloj."
        ])
    }
}
