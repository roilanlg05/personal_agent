import Foundation

public final class CreateNoteTool: AgentTool, Sendable {
    public static let name = "create_note"
    public static let description = """
    Crea y guarda una nota en el gestor de notas de Gemma. Las notas viven aquí: son \
    recuperables con search_notes y persisten entre conversaciones. NO se escriben en \
    Notas de Apple; si el usuario quiere mandar una a Notas de Apple o a una persona, \
    eso es share_note, y solo cuando lo pida. Usa un título corto y descriptivo, porque \
    es por lo que se buscará después.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "title", type: .string, description: "Título breve y descriptivo de la nota", required: true),
        AgentToolParam(name: "content", type: .string, description: "Cuerpo o contenido completo de la nota", required: true),
        AgentToolParam(name: "tags", type: .string, description: "Etiquetas separadas por comas (ej. 'ideas, trabajo, compras')", required: false)
    ]

    private let store: any NoteStoring

    public init(store: any NoteStoring = NoteStore.shared) {
        self.store = store
    }

    public func run(argsJSON: String) async -> String {
        guard let title = Self.parseString(named: "title", from: argsJSON), !title.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'title' para la nota.")
        }
        guard let content = Self.parseString(named: "content", from: argsJSON), !content.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'content' para la nota.")
        }

        let tags = (Self.parseString(named: "tags", from: argsJSON) ?? "")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        do {
            let saved = try await store.saveNote(GemmaNote(title: title, content: content, tags: tags))
            // La nota ya está en este dispositivo. Decir si además está en el servidor o
            // si solo está en la cola: "guardado" a secas cuando sigue en la cola es
            // media verdad, y el modelo se la repite al usuario como un hecho.
            let sync = MirrorStatus.describe(kind: MirrorKind.note, recordId: saved.id)
            return ToolJSONOutput.object([
                "status": "created",
                "id": saved.id,
                "title": saved.title,
                "tags": saved.tags,
                "sync": sync,
                "sync_note": MirrorStatus.note(kind: MirrorKind.note, recordId: saved.id),
                "message": "Nota '\(saved.title)' guardada en las notas de Gemma."
            ])
        } catch {
            return ToolJSONOutput.error("No se pudo guardar la nota: \(error.localizedDescription)")
        }
    }

    static func parseString(named name: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = dict[name] as? String else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
