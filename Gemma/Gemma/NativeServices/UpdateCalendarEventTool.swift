import Foundation

public final class UpdateCalendarEventTool: AgentTool, Sendable {
    public static let name = "update_calendar_event"
    public static let description = """
    Modifica un evento existente del calendario de Apple usando su ID. Las fechas deben \
    ir en ISO8601 (ej. 2026-11-05T14:00:00Z); si una fecha no se entiende, el tool NO \
    toca el evento y devuelve un error. Estados: 'updated', 'permission_required', \
    'not_found' y 'error'.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "id", type: .string, description: "Identificador único del evento a modificar", required: true),
        AgentToolParam(name: "title", type: .string, description: "Nuevo título o resumen del evento", required: false),
        AgentToolParam(name: "start_date", type: .string, description: "Nueva fecha y hora de inicio en formato ISO8601 (ej. 2026-11-05T14:00:00Z)", required: false),
        AgentToolParam(name: "end_date", type: .string, description: "Nueva fecha y hora de finalización en formato ISO8601 (ej. 2026-11-05T15:00:00Z)", required: false),
        AgentToolParam(name: "location", type: .string, description: "Nueva ubicación o lugar del evento", required: false),
        AgentToolParam(name: "notes", type: .string, description: "Nuevas notas o descripción adicional", required: false)
    ]

    private let service: AppleCalendarService

    public init(service: AppleCalendarService = AppleCalendarService()) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        guard let data = argsJSON.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = dict["id"] as? String else {
            return ToolJSONOutput.error("Argumento 'id' requerido para modificar un evento.")
        }

        // Una fecha presente pero ilegible NO puede tratarse como "no cambiar la fecha":
        // `updateEvent` interpreta `nil` como eso mismo, el evento se quedaba en su hora
        // original y el tool respondía "updated". El usuario se perdía la cita.
        var startDate: Date? = nil
        if let startStr = dict["start_date"] as? String {
            guard let parsed = ISO8601Dates.parse(startStr) else {
                return ToolJSONOutput.error(
                    "No se entiende 'start_date': \"\(startStr)\". Debe ser ISO8601 "
                    + "(ej. 2026-11-05T14:00:00Z). El evento NO se ha modificado."
                )
            }
            startDate = parsed
        }

        var endDate: Date? = nil
        if let endStr = dict["end_date"] as? String {
            guard let parsed = ISO8601Dates.parse(endStr) else {
                return ToolJSONOutput.error(
                    "No se entiende 'end_date': \"\(endStr)\". Debe ser ISO8601 "
                    + "(ej. 2026-11-05T15:00:00Z). El evento NO se ha modificado."
                )
            }
            endDate = parsed
        }

        let title = dict["title"] as? String
        let location = dict["location"] as? String
        let notes = dict["notes"] as? String

        do {
            let updated = try await service.updateEvent(
                id: id,
                title: title,
                startDate: startDate,
                endDate: endDate,
                location: location,
                notes: notes
            )
            return ToolJSONOutput.object(["status": "updated", "event": updated.jsonObject])
        } catch {
            return CalendarToolFailure.json(error)
        }
    }
}
