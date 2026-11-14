import Foundation

/// delete_calendar_event — borra un evento del calendario de Apple por su ID.
///
/// Su único defecto era el camino de argumentos: faltaba el `id` y devolvía
/// `{"error": ...}`, sin el `status` que su descripción le dice al modelo que lea.
public final class DeleteCalendarEventTool: AgentTool, Sendable {
    public static let name = "delete_calendar_event"
    public static let description = """
    Elimina un evento del calendario de Apple usando su ID. Lee 'status': 'deleted' = \
    borrado, el 'id' confirma cuál; 'not_found' = ese evento no existe en el calendario, \
    así que NO borraste nada — dilo tal cual; 'missing_fields' = falta el 'id', búscalo \
    primero con list_calendar_events; 'permission_required' = hay que conceder el acceso \
    al calendario, pídeselo; 'error' = el sistema no lo borró, no digas que sí.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "id", type: .string, description: "Identificador único del evento a eliminar", required: true)
    ]

    private let service: AppleCalendarService

    public init(service: AppleCalendarService = AppleCalendarService()) {
        self.service = service
    }

    public func run(argsJSON: String) async -> String {
        let dict = (argsJSON.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        } as? [String: Any]) ?? [:]
        let id = (dict["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else {
            return ToolJSONOutput.object([
                "status": "missing_fields",
                "required": ["id"],
                "message": "Falta el 'id' del evento que hay que borrar. Localízalo primero con list_calendar_events; no borres a ciegas."
            ])
        }

        do {
            let success = try await service.deleteEvent(id: id)
            guard success else {
                return ToolJSONOutput.object([
                    "status": "error",
                    "id": id,
                    "message": "El calendario no borró el evento. Sigue ahí: NO le digas al usuario que lo eliminaste."
                ])
            }
            return ToolJSONOutput.object(["status": "deleted", "id": id])
        } catch {
            return CalendarToolFailure.json(error)
        }
    }
}
