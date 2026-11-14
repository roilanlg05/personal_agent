import Foundation

/// Cambia una alarma ya puesta, sin cancelarla y volverla a crear.
///
/// Sin esta herramienta, "cámbiala a las siete" obligaba al modelo a encadenar
/// `cancel_alarm` + `create_alarm`, y ese camino tiene un fallo peligroso en medio: si la
/// creación falla después de la cancelación, el usuario se queda sin alarma convencido de
/// que la tiene puesta. Aquí es una sola operación que o cambia la alarma o la deja como
/// estaba.
public final class UpdateAlarmTool: AgentTool, Sendable {
    public static let name = "update_alarm"
    public static let description = """
    Cambia una alarma que Gemma ya tiene puesta: la hora, los días o el nombre. \
    Identifícala con 'time' (su hora actual, '06:00'), 'title' (su nombre) o 'id' (de \
    list_alarms), y pasa lo nuevo en 'new_time' ('07:30'), 'new_title' o 'days' \
    ('lunes a viernes', 'todos los días'). Úsalo para mover una alarma en vez de \
    cancelarla y crear otra: si la segunda falla, el usuario se queda sin alarma. Lee \
    'status': 'updated' = cambiada, y 'time' dice la hora nueva; 'not_found' = no hay \
    ninguna que encaje; 'ambiguous' = varias encajan, enséñale 'candidates' y pregunta; \
    'invalid_time' = no entendí la hora nueva, pídesela al usuario en formato 24h; \
    'nothing_to_change' = no mandaste nada nuevo; 'failed' = el sistema no la aceptó, y \
    entonces sigue puesta la hora vieja, dilo así.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "time", type: .string, description: "Hora actual de la alarma, formato 24h ('06:00')", required: false),
        AgentToolParam(name: "title", type: .string, description: "Nombre actual de la alarma", required: false),
        AgentToolParam(name: "id", type: .string, description: "Identificador, tal como lo devuelve list_alarms", required: false),
        AgentToolParam(name: "new_time", type: .string, description: "Hora nueva, formato 24h ('07:30')", required: false),
        AgentToolParam(name: "new_title", type: .string, description: "Nombre nuevo de la alarma", required: false),
        AgentToolParam(name: "days", type: .string, description: "Días nuevos: 'lunes a viernes', 'todos los días', 'lunes,miércoles'", required: false)
    ]

    private let clockService: ClockService

    public init(clockService: ClockService = ClockService()) {
        self.clockService = clockService
    }

    public func run(argsJSON: String) async -> String {
        let time = CreateNoteTool.parseString(named: "time", from: argsJSON)
        let title = CreateNoteTool.parseString(named: "title", from: argsJSON)
        let idText = CreateNoteTool.parseString(named: "id", from: argsJSON)
        let newTime = CreateNoteTool.parseString(named: "new_time", from: argsJSON)
        let newTitle = CreateNoteTool.parseString(named: "new_title", from: argsJSON)
        let daysText = CreateNoteTool.parseString(named: "days", from: argsJSON)

        let alarms = clockService.listAlarms()

        guard time != nil || title != nil || idText != nil else {
            return ToolJSONOutput.object([
                "status": "not_found",
                "message": "Dime cuál cambiar: su hora actual ('time'), su nombre o su 'id'. Llama a list_alarms si no lo sabes.",
                "current": Self.rows(alarms)
            ])
        }
        guard newTime != nil || newTitle != nil || daysText != nil else {
            return ToolJSONOutput.object([
                "status": "nothing_to_change",
                "message": "No mandaste nada nuevo. Pásale 'new_time', 'new_title' o 'days'."
            ])
        }

        // La hora nueva se valida antes de tocar nada: con una hora ilegible no se
        // aplica el resto a medias.
        var newHour: Int? = nil
        var newMinute: Int? = nil
        if let newTime {
            guard let normalized = CancelAlarmTool.normalizeTime(newTime) else {
                return ToolJSONOutput.object([
                    "status": "invalid_time",
                    "received": newTime,
                    "message": "No entendí esa hora. Pídesela al usuario en formato 24h, como '07:30'."
                ])
            }
            let parts = normalized.split(separator: ":")
            newHour = Int(parts[0])
            newMinute = Int(parts[1])
        }

        // Los días se validan igual que la hora: `parseDays` devuelve vacío cuando no
        // entiende, y aplicar eso convertiría la alarma en una sin repetición sin que el
        // usuario lo haya pedido.
        var newDays: [Int]? = nil
        if let daysText {
            let parsed = RoutineHelper.parseDays(daysText)
            guard !parsed.isEmpty else {
                return ToolJSONOutput.object([
                    "status": "invalid_days",
                    "received": daysText,
                    "message": "No entendí esos días. Escríbelos como 'lunes a viernes', 'todos los días' o 'lunes,miércoles'."
                ])
            }
            newDays = parsed
        }

        let matches = Self.matching(alarms, id: idText, time: time, title: title)
        guard !matches.isEmpty else {
            return ToolJSONOutput.object([
                "status": "not_found",
                "requested": idText ?? time ?? title,
                "current": Self.rows(alarms),
                "message": alarms.isEmpty
                    ? "Gemma no tiene ninguna alarma puesta."
                    : "No hay ninguna alarma que encaje. En 'current' está lo que sí hay."
            ])
        }
        guard matches.count == 1 else {
            return ToolJSONOutput.object([
                "status": "ambiguous",
                "requested": idText ?? time ?? title,
                "candidates": Self.rows(matches),
                "message": "Hay varias que encajan. Pregúntale al usuario cuál; no se cambió ninguna."
            ])
        }

        let target = matches[0]
        do {
            let updated = try await clockService.updateAlarm(
                id: target.id,
                title: newTitle,
                hour: newHour,
                minute: newMinute,
                daysOfWeek: newDays
            )
            let alarm = updated.alarm
            let timeText = String(format: "%02d:%02d", alarm.hour, alarm.minute)
            return ToolJSONOutput.object([
                "status": "updated",
                "id": alarm.id.uuidString,
                "title": alarm.title,
                "time": timeText,
                "days_of_week": alarm.daysOfWeek.isEmpty ? nil : alarm.daysOfWeek,
                "repeats": !alarm.daysOfWeek.isEmpty,
                "method": updated.method.rawValue,
                "message": "Alarma cambiada a las \(timeText)\(alarm.daysOfWeek.isEmpty ? "" : " (se repite)")."
            ])
        } catch {
            return ToolJSONOutput.object([
                "status": "failed",
                "id": target.id.uuidString,
                "message": "No se pudo cambiar: \(error.localizedDescription). Sigue puesta a las \(String(format: "%02d:%02d", target.hour, target.minute))."
            ])
        }
    }

    private static func matching(
        _ alarms: [GemmaAlarm],
        id: String?,
        time: String?,
        title: String?
    ) -> [GemmaAlarm] {
        if let id, let uuid = UUID(uuidString: id.trimmingCharacters(in: .whitespaces)) {
            return alarms.filter { $0.id == uuid }
        }
        if let time, let normalized = CancelAlarmTool.normalizeTime(time) {
            let byTime = alarms.filter { String(format: "%02d:%02d", $0.hour, $0.minute) == normalized }
            if !byTime.isEmpty { return byTime }
        }
        if let title {
            let needle = fold(title)
            guard !needle.isEmpty else { return [] }
            let exact = alarms.filter { fold($0.title) == needle }
            if !exact.isEmpty { return exact }
            return alarms.filter { fold($0.title).contains(needle) || needle.contains(fold($0.title)) }
        }
        return []
    }

    private static func rows(_ alarms: [GemmaAlarm]) -> [[String: Any]] {
        alarms.map { alarm in
            ([
                "id": alarm.id.uuidString,
                "title": alarm.title,
                "time": String(format: "%02d:%02d", alarm.hour, alarm.minute),
                "days_of_week": alarm.daysOfWeek.isEmpty ? nil : alarm.daysOfWeek
            ] as [String: Any?]).compactMapValues { $0 }
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
