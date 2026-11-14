import Foundation

public final class CreateAlarmTool: AgentTool, Sendable {
    public static let name = "create_alarm"
    public static let description = """
    Pone una alarma para una hora concreta. Lee 'status' y 'method': 'created' con \
    method 'system_alarm' = alarma del sistema de verdad, suena aunque el teléfono esté \
    en silencio o en modo concentración; 'created' con method 'gemma_notification' = \
    solo una notificación, que NO suena en silencio, así que dilo tal cual. \
    'permission_required' = falta el permiso y NO sonaría nada, pídeselo al usuario. \
    'limit_reached' = hay que borrar otra alarma antes. Nunca digas que la alarma suena \
    en silencio si el method no es 'system_alarm'. Y nunca le digas al usuario que la \
    verá en la app Reloj de Apple: las alarmas de Gemma no salen ahí, se ven con \
    list_alarms. Si dice que no la encuentra, no es que falle: explícaselo.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Título o descripción de la alarma (ej. 'Despertador', 'Tomar medicina')", required: true),
        AgentToolParam(name: "hour", type: .integer, description: "Hora de la alarma en formato 24 horas (0-23)", required: true),
        AgentToolParam(name: "minute", type: .integer, description: "Minuto de la alarma (0-59)", required: true)
    ]

    private let clockService: ClockService

    public init(clockService: ClockService = ClockService()) {
        self.clockService = clockService
    }

    public func run(argsJSON: String) async -> String {
        guard let title = parseString(named: "title", from: argsJSON),
              let hour = parseInt(named: "hour", from: argsJSON),
              let minute = parseInt(named: "minute", from: argsJSON) else {
            return ToolJSONOutput.error("Se requieren 'title', 'hour' (0-23) y 'minute' (0-59).")
        }

        guard hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59 else {
            return ToolJSONOutput.error("Hora o minuto fuera de rango válido (0-23, 0-59).")
        }

        let timeStr = String(format: "%02d:%02d", hour, minute)

        do {
            let scheduled = try await clockService.createAlarm(title: title, hour: hour, minute: minute)
            let isReal = scheduled.method == .systemAlarm
            return ToolJSONOutput.object([
                "status": "created",
                "method": scheduled.method.rawValue,
                "id": scheduled.alarm.id.uuidString,
                "title": scheduled.alarm.title,
                "time": timeStr,
                "message": isReal
                    ? "Alarma del sistema puesta a las \(timeStr). Suena aunque el teléfono esté en silencio. No sale en la app Reloj de Apple (Apple no deja escribir ahí): vive en Gemma, y se puede ver con list_alarms."
                    : "Programado un aviso de Gemma para las \(timeStr). Es una notificación, así que NO suena si el teléfono está en silencio."
            ])
        } catch SystemAlarmError.permissionDenied {
            // Prometer una alarma que no va a sonar es el peor fallo posible aquí.
            return ToolJSONOutput.object([
                "status": "permission_required",
                "message": "Gemma necesita permiso para poner alarmas. Pídele al usuario que lo conceda cuando el sistema lo pregunte, o en Ajustes > Gemma."
            ])
        } catch SystemAlarmError.limitReached {
            return ToolJSONOutput.object([
                "status": "limit_reached",
                "message": "Gemma ya tiene puestas todas las alarmas que el sistema le permite. Hay que borrar alguna antes."
            ])
        } catch ClockError.notificationsDenied {
            return ToolJSONOutput.object([
                "status": "permission_required",
                "message": "Gemma no tiene permiso para enviar notificaciones, así que el aviso no sonaría. Pídele al usuario que lo active en Ajustes > Notificaciones > Gemma."
            ])
        } catch {
            return ToolJSONOutput.error("No se pudo poner la alarma: \(error.localizedDescription)")
        }
    }

    private func parseString(named name: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let val = dict[name] as? String, !val.isEmpty else {
            return nil
        }
        return val
    }

    private func parseInt(named name: String, from json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let i = dict[name] as? Int { return i }
        if let n = dict[name] as? NSNumber { return n.intValue }
        if let s = dict[name] as? String { return Int(s) }
        return nil
    }
}
