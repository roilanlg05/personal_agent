import Foundation

public final class SearchNotesTool: AgentTool, Sendable {
    public static let name = "search_notes"
    public static let description = """
    Busca entre las notas guardadas en Gemma por palabras del título, del contenido o \
    de las etiquetas. Deja 'query' vacío para listar las más recientes. Devuelve título, \
    contenido y etiquetas de cada coincidencia. Para leer una nota concreta usa \
    read_note; para editarla, update_note; para borrarla, delete_note.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "query", type: .string, description: "Palabra clave o tema a buscar (vacío para listar las más recientes)", required: false),
        AgentToolParam(name: "limit", type: .integer, description: "Máximo de notas a devolver (por defecto 20)", required: false)
    ]

    private let store: any NoteStoring

    public init(store: any NoteStoring = NoteStore.shared) {
        self.store = store
    }

    public func run(argsJSON: String) async -> String {
        let query = CreateNoteTool.parseString(named: "query", from: argsJSON) ?? ""
        let limit = Self.parseInt(named: "limit", from: argsJSON) ?? 20

        let notes = await store.searchNotes(query: query)
        let formatter = ISO8601DateFormatter()

        return ToolJSONOutput.object([
            "status": "ok",
            "count": notes.count,
            "query": query,
            "notes": notes.prefix(max(1, limit)).map { note in
                [
                    "id": note.id,
                    "title": note.title,
                    "content": note.content,
                    "tags": note.tags,
                    "updated_at": formatter.string(from: note.updatedAt)
                ]
            },
            "message": notes.isEmpty
                ? (query.isEmpty ? "No hay notas guardadas en Gemma." : "Ninguna nota encaja con '\(query)'.")
                : "\(notes.count) notas encontradas."
        ])
    }

    private static func parseInt(named name: String, from json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let value = dict[name] as? Int { return value }
        if let number = dict[name] as? NSNumber { return number.intValue }
        if let text = dict[name] as? String { return Int(text) }
        return nil
    }
}
