import Foundation

/// Algo que Gemma puede compartir: una nota, una tarea, una memoria, un insight, un
/// mensaje, un chat.
public struct ShareableItem: Sendable, Equatable {
    /// Tipo de contenido ("note", "task", "memory", ...). Sirve para desambiguar
    /// cuando dos tipos distintos encajan con la misma búsqueda.
    public let kind: String
    public let id: String
    /// Título corto, para preguntarle al usuario cuál quería.
    public let title: String
    /// Texto completo que se comparte.
    public let text: String

    public init(kind: String, id: String, title: String, text: String) {
        self.kind = kind
        self.id = id
        self.title = title
        self.text = text
    }
}

/// Una fuente de cosas compartibles.
///
/// Compartir es transversal: el mismo mecanismo vale para notas, tareas, memorias,
/// insights, mensajes y chats. Cada tipo de contenido aporta su propia fuente y el tool
/// de compartir no necesita saber nada de dónde vive cada cosa.
public protocol ShareableSource: Sendable {
    /// Identificador del tipo, en minúsculas y singular: "note", "task", "memory"...
    var kind: String { get }
    /// Nombre para hablarle al usuario: "nota", "tarea", "memoria"...
    var displayName: String { get }
    /// Elementos que encajan con la búsqueda, el más probable primero.
    func find(matching query: String) async -> [ShareableItem]
    /// Títulos disponibles, para orientar cuando la búsqueda no encuentra nada.
    func availableTitles(limit: Int) async -> [String]
}

// MARK: - Fuente: notas de Gemma

public final class NoteShareSource: ShareableSource, Sendable {
    public let kind = "note"
    public let displayName = "nota"

    private let resolver: NoteResolver

    public init(store: any NoteStoring = NoteStore.shared) {
        self.resolver = NoteResolver(store: store)
    }

    public func find(matching query: String) async -> [ShareableItem] {
        switch await resolver.resolve(query) {
        case .none:
            return []
        case .one(let note):
            return [Self.item(from: note)]
        case .many(let notes):
            return notes.map(Self.item(from:))
        }
    }

    public func availableTitles(limit: Int) async -> [String] {
        await resolver.availableTitles(limit: limit)
    }

    private static func item(from note: GemmaNote) -> ShareableItem {
        ShareableItem(
            kind: "note",
            id: note.id,
            title: note.title,
            text: "\(note.title)\n\n\(note.content)"
        )
    }
}

// MARK: - Tool

public final class ShareTool: AgentTool, Sendable {
    public static let name = "share"
    public static let description = """
    Comparte algo que Gemma tiene guardado: abre la hoja de compartir del sistema con \
    el contenido dentro, para que el usuario lo mande a Notas de Apple, a Mensajes, a \
    Correo o a cualquier persona. Sirve para notas y, a medida que se conecten, para \
    tareas, memorias, insights, mensajes y chats. Úsala SOLO cuando el usuario pida \
    compartir o enviar algo. Se localiza por asunto o título; usa 'kind' para limitar \
    el tipo si el usuario lo dice. Si 'status' es 'ambiguous', varias cosas encajan: \
    pregunta cuál y vuelve a llamar con el título exacto. 'shared' significa que la \
    hoja se abrió, NO que el usuario haya enviado nada: dile que elija destino y \
    confirme.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "query", type: .string, description: "Asunto o título de lo que se quiere compartir (ej. 'la lista de compras')", required: true),
        AgentToolParam(name: "kind", type: .string, description: "Tipo de contenido para limitar la búsqueda: 'note', 'task', 'memory', 'insight', 'message', 'chat'. Omítelo para buscar en todo.", required: false)
    ]

    private let sources: [any ShareableSource]
    private let sharer: (any TextSharing)?

    public init(
        sources: [any ShareableSource] = [NoteShareSource()],
        sharer: (any TextSharing)? = TextSharingFactory.make()
    ) {
        self.sources = sources
        self.sharer = sharer
    }

    public func run(argsJSON: String) async -> String {
        guard let query = CreateNoteTool.parseString(named: "query", from: argsJSON), !query.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'query' con el asunto o título de lo que se quiere compartir.")
        }
        let requestedKind = CreateNoteTool.parseString(named: "kind", from: argsJSON)?.lowercased()

        let searched = requestedKind.map { kind in
            sources.filter { $0.kind == kind }
        } ?? sources

        guard !searched.isEmpty else {
            return ToolJSONOutput.object([
                "status": "unsupported_kind",
                "kind": requestedKind,
                "available_kinds": sources.map(\.kind),
                "message": "Gemma todavía no puede compartir contenido de tipo '\(requestedKind ?? "")'."
            ])
        }

        var found: [ShareableItem] = []
        for source in searched {
            found.append(contentsOf: await source.find(matching: query))
        }

        guard !found.isEmpty else {
            var titles: [String] = []
            for source in searched {
                titles.append(contentsOf: await source.availableTitles(limit: 10))
            }
            return ToolJSONOutput.object([
                "status": "not_found",
                "query": query,
                "available_titles": Array(titles.prefix(10)),
                "message": "No se encontró nada que encaje con '\(query)'."
            ])
        }

        // Varios candidatos: elegir uno sería adivinar, y compartir lo equivocado lo ve
        // quien lo recibe.
        guard found.count == 1, let item = found.first else {
            return ToolJSONOutput.object([
                "status": "ambiguous",
                "query": query,
                "candidates": found.prefix(8).map { ["kind": $0.kind, "id": $0.id, "title": $0.title] },
                "message": "Hay varias cosas que encajan con '\(query)'. Pregúntale al usuario cuál quiere compartir."
            ])
        }

        guard let sharer else {
            return ToolJSONOutput.object([
                "status": "unavailable",
                "title": item.title,
                "message": "Compartir no está disponible en este dispositivo."
            ])
        }

        guard await sharer.share(text: item.text, subject: item.title) else {
            return ToolJSONOutput.object([
                "status": "failed",
                "title": item.title,
                "message": "No se pudo abrir la hoja de compartir."
            ])
        }

        return ToolJSONOutput.object([
            "status": "shared",
            "kind": item.kind,
            "id": item.id,
            "title": item.title,
            "message": "Se abrió la hoja de compartir con '\(item.title)'. Dile al usuario que elija el destino, por ejemplo Notas, y confirme el envío."
        ])
    }
}
