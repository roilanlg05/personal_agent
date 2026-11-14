import Foundation

public final class ListCalendarEventsTool: AgentTool, Sendable {
    public static let name = "get_calendar_events"
    public static let description = """
    Consulta los eventos del calendario de Apple en una ventana de fechas. Estados: \
    'ok' (la lista 'events' es la agenda real, puede estar vacía), 'permission_required' \
    (el usuario no ha concedido el acceso al calendario: pídeselo, NO digas que no tiene \
    nada apuntado) y 'error'. Si el estado no es 'ok' no hay campo 'events'.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "start_date", type: .string, description: "Fecha y hora de inicio de la búsqueda en formato ISO8601 (ej. 2026-11-05T00:00:00Z)", required: true),
        AgentToolParam(name: "end_date", type: .string, description: "Fecha y hora de fin de la búsqueda en formato ISO8601 (ej. 2026-11-05T23:59:59Z)", required: true)
    ]

    private let service: AppleCalendarService

    public init(service: AppleCalendarService = AppleCalendarService()) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        guard let data = argsJSON.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let startStr = dict["start_date"] as? String,
              let endStr = dict["end_date"] as? String else {
            return ToolJSONOutput.error("Argumentos inválidos. Se requiere 'start_date' y 'end_date'.")
        }

        guard let start = ISO8601Dates.parse(startStr), let end = ISO8601Dates.parse(endStr) else {
            return ToolJSONOutput.error(
                "Formato de fecha inválido. Debe ser ISO8601 (ej. 2026-11-05T00:00:00Z)."
            )
        }

        do {
            let events = try await service.getEvents(from: start, to: end)
            return ToolJSONOutput.object([
                "status": "ok",
                "count": events.count,
                "events": events.map { $0.jsonObject }
            ])
        } catch {
            return CalendarToolFailure.json(error)
        }
    }
}
