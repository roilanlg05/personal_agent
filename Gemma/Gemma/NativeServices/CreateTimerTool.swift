import Foundation

public final class CreateTimerTool: AgentTool, Sendable {
    public static let name = "create_timer"
    public static let description = """
    Pone un temporizador de N segundos (300 = 5 minutos), con una etiqueta opcional. Lee \
    'status' y 'method': 'created' con method 'system_alarm' = temporizador del sistema, \
    con cuenta atrás en pantalla, suena aunque el teléfono esté en silencio; 'created' \
    con method 'gemma_notification' = solo una notificación, que NO suena en silencio. \
    'permission_required' = falta el permiso y NO sonaría nada, pídeselo al usuario.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "duration_seconds", type: .integer, description: "Duración del temporizador en segundos", required: true),
        AgentToolParam(name: "label", type: .string, description: "Etiqueta o motivo del temporizador (ej. 'Hervir pasta', 'Descanso')", required: false)
    ]

    private let clockService: ClockService

    public init(clockService: ClockService = ClockService()) {
        self.clockService = clockService
    }

    public func run(argsJSON: String) async -> String {
        guard let duration = parseInt(named: "duration_seconds", from: argsJSON), duration > 0 else {
            return ToolJSONOutput.error("Se requiere 'duration_seconds' mayor a 0.")
        }

        let label = parseString(named: "label", from: argsJSON) ?? "Temporizador"

        do {
            let scheduled = try await clockService.createTimer(durationSeconds: duration, label: label)
            let timer = scheduled.timer
            let mins = duration / 60
            let secs = duration % 60
            let formatted = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
            return ToolJSONOutput.object([
                "status": "started",
                "method": scheduled.method.rawValue,
                "id": timer.id.uuidString,
                "label": timer.label,
                "duration_seconds": timer.durationSeconds,
                "formatted_duration": formatted,
                "message": scheduled.method == .systemAlarm
                    ? "Temporizador del sistema de \(formatted) en marcha. Suena aunque el teléfono esté en silencio."
                    : "Aviso de Gemma programado en \(formatted). Es una notificación, así que NO suena si el teléfono está en silencio."
            ])
        } catch SystemAlarmError.permissionDenied {
            return ToolJSONOutput.object([
                "status": "permission_required",
                "message": "Gemma necesita permiso para poner temporizadores. Pídele al usuario que lo conceda cuando el sistema lo pregunte, o en Ajustes > Gemma."
            ])
        } catch SystemAlarmError.limitReached {
            return ToolJSONOutput.object([
                "status": "limit_reached",
                "message": "Gemma ya tiene en marcha todos los temporizadores que el sistema le permite."
            ])
        } catch ClockError.notificationsDenied {
            return ToolJSONOutput.object([
                "status": "permission_required",
                "message": "Gemma no tiene permiso para enviar notificaciones, así que el aviso no sonaría. Pídele al usuario que lo active en Ajustes > Notificaciones > Gemma."
            ])
        } catch {
            return ToolJSONOutput.error("No se pudo programar el aviso: \(error.localizedDescription)")
        }
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

    private func parseString(named name: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let val = dict[name] as? String, !val.isEmpty else {
            return nil
        }
        return val
    }
}
