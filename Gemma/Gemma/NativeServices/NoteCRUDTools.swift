import Foundation

// MARK: - Editar

public final class UpdateNoteTool: AgentTool, Sendable {
    public static let name = "update_note"
    public static let description = """
    Edita una nota guardada en Gemma: cambia su título, su contenido o sus etiquetas. \
    Se localiza por título, asunto o id. Para AÑADIR algo a una nota sin perder lo que \
    ya tenía (ej. "añade pan a la lista de compras") usa mode='append'; para sustituir \
    el contenido entero usa mode='replace'. Si 'status' es 'ambiguous', varias notas \
    encajan: pregunta cuál y vuelve a llamar con el título exacto o el id.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "query", type: .string, description: "Título, asunto o id de la nota a editar", required: true),
        AgentToolParam(name: "content", type: .string, description: "Texto a añadir o con el que sustituir el contenido", required: false),
        AgentToolParam(name: "mode", type: .string, description: "'append' para añadir al final (por defecto) o 'replace' para sustituir todo el contenido", required: false),
        AgentToolParam(name: "title", type: .string, description: "Título nuevo, si hay que renombrar la nota", required: false),
        AgentToolParam(name: "tags", type: .string, description: "Etiquetas nuevas separadas por comas; sustituyen a las anteriores", required: false)
    ]

    private let store: any NoteStoring
    private let resolver: NoteResolver

    public init(store: any NoteStoring = NoteStore.shared) {
        self.store = store
        self.resolver = NoteResolver(store: store)
    }

    public func run(argsJSON: String) async -> String {
        guard let query = CreateNoteTool.parseString(named: "query", from: argsJSON), !query.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'query' con el título, asunto o id de la nota a editar.")
        }

        let newContent = CreateNoteTool.parseString(named: "content", from: argsJSON)
        let newTitle = CreateNoteTool.parseString(named: "title", from: argsJSON)
        let tagsArgument = CreateNoteTool.parseString(named: "tags", from: argsJSON)

        guard newContent?.isEmpty == false || newTitle?.isEmpty == false || tagsArgument != nil else {
            return ToolJSONOutput.error("No hay nada que cambiar: indica 'content', 'title' o 'tags'.")
        }

        let match = await resolver.resolve(query)
        if let failure = match.failureResponse(
            query: query,
            availableTitles: await resolver.availableTitles(),
            verb: "editar"
        ) {
            return failure
        }
        guard case .one(let note) = match else {
            return ToolJSONOutput.error("No se pudo determinar la nota a editar.")
        }

        // Por omisión se añade, no se sustituye: perder el contenido de una nota por
        // una orden ambigua es un daño que el usuario no puede deshacer.
        let mode = (CreateNoteTool.parseString(named: "mode", from: argsJSON) ?? "append").lowercased()
        let replaces = (mode == "replace" || mode == "sustituir" || mode == "reemplazar")

        var updated = note
        if let newContent, !newContent.isEmpty {
            updated.content = replaces ? newContent : "\(note.content)\n\(newContent)"
        }
        if let newTitle, !newTitle.isEmpty {
            updated.title = newTitle
        }
        if let tagsArgument {
            updated.tags = tagsArgument
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        updated.updatedAt = Date()

        do {
            // `saveNote` reemplaza por id, así que guardar la copia modificada actualiza
            // la nota existente en lugar de crear otra.
            let saved = try await store.saveNote(updated)
            return ToolJSONOutput.object([
                "status": "updated",
                "id": saved.id,
                "title": saved.title,
                "tags": saved.tags,
                "content": saved.content,
                "mode": replaces ? "replace" : "append",
                "message": "Nota '\(saved.title)' actualizada."
            ])
        } catch {
            return ToolJSONOutput.error("No se pudo actualizar la nota: \(error.localizedDescription)")
        }
    }
}

// MARK: - Borrar

public final class DeleteNoteTool: AgentTool, Sendable {
    public static let name = "delete_note"
    public static let description = """
    Borra una nota guardada en Gemma. Se localiza por título, asunto o id. Borrar no se \
    puede deshacer, así que si 'status' es 'ambiguous' NUNCA elijas por tu cuenta: \
    pregunta al usuario cuál y vuelve a llamar con el título exacto o el id. La \
    respuesta incluye el contenido borrado, por si el usuario se arrepiente y hay que \
    crearla de nuevo.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "query", type: .string, description: "Título, asunto o id de la nota a borrar", required: true)
    ]

    private let store: any NoteStoring
    private let resolver: NoteResolver

    public init(store: any NoteStoring = NoteStore.shared) {
        self.store = store
        self.resolver = NoteResolver(store: store)
    }

    public func run(argsJSON: String) async -> String {
        guard let query = CreateNoteTool.parseString(named: "query", from: argsJSON), !query.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'query' con el título, asunto o id de la nota a borrar.")
        }

        let match = await resolver.resolve(query)
        if let failure = match.failureResponse(
            query: query,
            availableTitles: await resolver.availableTitles(),
            verb: "borrar"
        ) {
            return failure
        }
        guard case .one(let note) = match else {
            return ToolJSONOutput.error("No se pudo determinar la nota a borrar.")
        }

        do {
            let deleted = try await store.deleteNote(id: note.id)
            guard deleted else {
                return ToolJSONOutput.object([
                    "status": "not_found",
                    "query": query,
                    "message": "La nota '\(note.title)' ya no estaba guardada."
                ])
            }
            return ToolJSONOutput.object([
                "status": "deleted",
                "id": note.id,
                "title": note.title,
                // Se devuelve el contenido para poder recrearla si el usuario se
                // arrepiente: el almacén no tiene papelera.
                "deleted_content": note.content,
                "message": "Nota '\(note.title)' borrada."
            ])
        } catch {
            return ToolJSONOutput.error("No se pudo borrar la nota: \(error.localizedDescription)")
        }
    }
}

// MARK: - Leer una concreta

public final class ReadNoteTool: AgentTool, Sendable {
    public static let name = "read_note"
    public static let description = """
    Lee una nota concreta de Gemma por título, asunto o id, y devuelve su contenido \
    completo. Úsala cuando el usuario quiera saber qué dice una nota en particular; \
    para buscar entre varias usa search_notes. Si 'status' es 'ambiguous', pregunta al \
    usuario cuál quería.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "query", type: .string, description: "Título, asunto o id de la nota a leer", required: true)
    ]

    private let resolver: NoteResolver

    public init(store: any NoteStoring = NoteStore.shared) {
        self.resolver = NoteResolver(store: store)
    }

    public func run(argsJSON: String) async -> String {
        guard let query = CreateNoteTool.parseString(named: "query", from: argsJSON), !query.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'query' con el título, asunto o id de la nota a leer.")
        }

        let match = await resolver.resolve(query)
        if let failure = match.failureResponse(
            query: query,
            availableTitles: await resolver.availableTitles(),
            verb: "leer"
        ) {
            return failure
        }
        guard case .one(let note) = match else {
            return ToolJSONOutput.error("No se pudo determinar la nota a leer.")
        }

        let formatter = ISO8601DateFormatter()
        return ToolJSONOutput.object([
            "status": "ok",
            "id": note.id,
            "title": note.title,
            "content": note.content,
            "tags": note.tags,
            "created_at": formatter.string(from: note.createdAt),
            "updated_at": formatter.string(from: note.updatedAt)
        ])
    }
}
