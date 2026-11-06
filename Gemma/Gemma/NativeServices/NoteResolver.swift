import Foundation

/// Resultado de buscar la nota a la que se refiere el usuario.
public enum NoteMatch: Sendable {
    case one(GemmaNote)
    /// Varias encajan: hay que preguntar, no elegir.
    case many([GemmaNote])
    case none
}

/// Localiza la nota de la que habla el usuario.
///
/// Lo usan todas las operaciones sobre notas (leer, editar, borrar, compartir) para que
/// "la nota de compras" signifique lo mismo en todas. Sin esto, cada tool resolvía el
/// nombre a su manera y borrar podía afectar a una nota distinta de la que se acababa
/// de leer.
public struct NoteResolver: Sendable {
    private let store: any NoteStoring

    public init(store: any NoteStoring) {
        self.store = store
    }

    public func resolve(_ query: String) async -> NoteMatch {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        // Un identificador exacto manda sobre cualquier búsqueda por texto.
        let everything = await store.allNotes()
        if let byID = everything.first(where: { $0.id == trimmed }) {
            return .one(byID)
        }

        let matches = await store.searchNotes(query: trimmed)
        guard !matches.isEmpty else { return .none }

        let needle = NoteStore.foldForSearch(trimmed)
        guard needle.count >= 2 else { return .many(matches) }

        // Un título idéntico es inequívoco.
        if let exact = matches.first(where: { NoteStore.foldForSearch($0.title) == needle }) {
            return .one(exact)
        }

        // `searchNotes` también mira el cuerpo y las etiquetas, así que puede devolver
        // de más: si el título de una sola nota contiene lo buscado, es esa.
        let titleMatches = matches.filter { note in
            let title = NoteStore.foldForSearch(note.title)
            return title.contains(needle) || needle.contains(title)
        }
        if titleMatches.count == 1 {
            return .one(titleMatches[0])
        }

        let candidates = titleMatches.isEmpty ? matches : titleMatches
        return candidates.count == 1 ? .one(candidates[0]) : .many(candidates)
    }

    /// Títulos disponibles, para orientar al usuario cuando no hay coincidencias.
    public func availableTitles(limit: Int = 10) async -> [String] {
        await store.allNotes().prefix(limit).map(\.title)
    }
}

extension NoteMatch {
    /// Respuesta JSON para los casos en que no se puede actuar sobre una sola nota.
    ///
    /// Centralizado para que leer, editar, borrar y compartir contesten igual ante la
    /// misma situación.
    func failureResponse(query: String, availableTitles: [String], verb: String) -> String? {
        switch self {
        case .one:
            return nil
        case .none:
            return ToolJSONOutput.object([
                "status": "not_found",
                "query": query,
                "available_titles": availableTitles,
                "message": "No hay ninguna nota que encaje con '\(query)'."
            ])
        case .many(let candidates):
            return ToolJSONOutput.object([
                "status": "ambiguous",
                "query": query,
                "candidates": candidates.prefix(8).map { ["id": $0.id, "title": $0.title] },
                "message": "Hay varias notas que encajan con '\(query)'. Pregúntale al usuario cuál quiere \(verb) y vuelve a llamar con el título exacto o el id."
            ])
        }
    }
}
