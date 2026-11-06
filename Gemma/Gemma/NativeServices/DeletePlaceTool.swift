import Foundation

public final class DeletePlaceTool: AgentTool, Sendable {
    public static let name = "delete_place"
    public static let description = """
    Elimina un lugar conocido utilizando su ID o su nombre. Si varios lugares coinciden \
    con el nombre, no borra nada y devuelve los candidatos para que preguntes al usuario \
    cuál es: borrar no se puede deshacer.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "id_or_name", type: .string, description: "ID o nombre del lugar a eliminar", required: true)
    ]

    private let placeStore: PlaceStore

    public init(placeStore: PlaceStore = .shared) {
        self.placeStore = placeStore
    }

    var placeStoreForTesting: PlaceStore { placeStore }

    public func run(argsJSON: String) async -> String {
        guard let data = argsJSON.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let query = dict["id_or_name"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolJSONOutput.error("Se requiere el argumento 'id_or_name'.")
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Intentar borrar por ID directo
        if placeStore.delete(id: trimmed) {
            return ToolJSONOutput.object(["status": "deleted", "query": trimmed])
        }

        // Buscar por nombre
        let matches = placeStore.search(query: trimmed)
        if matches.isEmpty {
            return ToolJSONOutput.error("No se encontró ningún lugar con '\(trimmed)'.")
        } else if matches.count == 1 {
            let place = matches[0]
            _ = placeStore.delete(id: place.id)
            return ToolJSONOutput.object([
                "status": "deleted",
                "place": place.name,
                "id": place.id
            ])
        } else {
            // Ante la ambigüedad se pregunta: borrar un lugar no se puede deshacer.
            return ToolJSONOutput.object([
                "status": "ambiguous",
                "error": "Existen múltiples lugares que coinciden con '\(trimmed)'. "
                    + "Pregunta al usuario cuál es y vuelve a llamar con el ID exacto.",
                "candidates": matches.map { ["id": $0.id, "name": $0.name] }
            ])
        }
    }
}
