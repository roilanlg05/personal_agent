import XCTest
@testable import Gemma

/// CRUD completo de las notas de Gemma. El punto delicado es que las cuatro
/// operaciones localicen la MISMA nota ante la misma frase: si leer y borrar
/// resolvieran distinto, el usuario borraría algo que no esperaba.
final class NoteCRUDTests: XCTestCase {

    private func note(_ title: String, content: String = "contenido", tags: [String] = []) -> GemmaNote {
        GemmaNote(title: title, content: content, tags: tags)
    }

    // MARK: - Resolvedor común

    func test_resolver_exactTitle() async {
        let store = InMemoryNoteStore(seed: [note("Compras"), note("Compras de la oficina")])
        guard case .one(let found) = await NoteResolver(store: store).resolve("Compras") else {
            return XCTFail("Un título idéntico es inequívoco")
        }
        XCTAssertEqual(found.title, "Compras")
    }

    func test_resolver_byID() async {
        let target = note("Reunión del lunes")
        let store = InMemoryNoteStore(seed: [target, note("Otra")])
        guard case .one(let found) = await NoteResolver(store: store).resolve(target.id) else {
            return XCTFail("El id debe resolver directo")
        }
        XCTAssertEqual(found.id, target.id)
    }

    func test_resolver_accentInsensitive() async {
        let store = InMemoryNoteStore(seed: [note("Reunión del lunes")])
        guard case .one = await NoteResolver(store: store).resolve("reunion del lunes") else {
            return XCTFail("Debe encontrarla sin acentos")
        }
    }

    func test_resolver_severalCandidates() async {
        let store = InMemoryNoteStore(seed: [note("Compras del sábado"), note("Compras de la oficina")])
        guard case .many(let candidates) = await NoteResolver(store: store).resolve("compras") else {
            return XCTFail("Con dos candidatos hay que preguntar")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    func test_resolver_none() async {
        let store = InMemoryNoteStore(seed: [note("Compras")])
        guard case .none = await NoteResolver(store: store).resolve("impuestos") else {
            return XCTFail("No debería encontrar nada")
        }
    }

    func test_allNoteToolsResolveTheSameNote() async throws {
        // La garantía que importa: la misma frase apunta a la misma nota en los cuatro.
        let target = note("Lista de compras", content: "leche")
        let seed = [target, note("Ideas de regalos")]
        let args = #"{"query": "lista de compras"}"#

        let readStore = InMemoryNoteStore(seed: seed)
        let readOut = await ReadNoteTool(store: readStore).run(argsJSON: args)
        let readParsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(readOut.utf8)) as? [String: Any])

        let deleteStore = InMemoryNoteStore(seed: seed)
        let deleteOut = await DeleteNoteTool(store: deleteStore).run(argsJSON: args)
        let deleteParsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(deleteOut.utf8)) as? [String: Any])

        let updateStore = InMemoryNoteStore(seed: seed)
        let updateOut = await UpdateNoteTool(store: updateStore)
            .run(argsJSON: #"{"query": "lista de compras", "content": "pan"}"#)
        let updateParsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(updateOut.utf8)) as? [String: Any])

        XCTAssertEqual(readParsed["id"] as? String, target.id)
        XCTAssertEqual(deleteParsed["id"] as? String, target.id)
        XCTAssertEqual(updateParsed["id"] as? String, target.id)
    }

    // MARK: - read_note

    func test_read_returnsFullContent() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras", content: "leche\npan", tags: ["casa"])])
        let out = await ReadNoteTool(store: store).run(argsJSON: #"{"query": "Compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "ok")
        XCTAssertEqual(parsed["content"] as? String, "leche\npan")
        XCTAssertEqual(parsed["tags"] as? [String], ["casa"])
        XCTAssertNotNil(parsed["updated_at"])
    }

    func test_read_ambiguous_asks() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras del sábado"), note("Compras de la oficina")])
        let out = await ReadNoteTool(store: store).run(argsJSON: #"{"query": "compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "ambiguous")
        XCTAssertEqual((parsed["candidates"] as? [[String: Any]])?.count, 2)
    }

    func test_read_notFound_listsAvailableTitles() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras")])
        let out = await ReadNoteTool(store: store).run(argsJSON: #"{"query": "impuestos"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "not_found")
        XCTAssertEqual(parsed["available_titles"] as? [String], ["Compras"])
    }

    // MARK: - update_note

    func test_update_appendsByDefaultAndKeepsOldContent() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras", content: "leche")])
        let out = await UpdateNoteTool(store: store)
            .run(argsJSON: #"{"query": "Compras", "content": "pan"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "updated")
        XCTAssertEqual(parsed["mode"] as? String, "append")
        XCTAssertEqual(
            parsed["content"] as? String, "leche\npan",
            "Por omisión debe añadir: sustituir sin que lo pidan destruye la nota"
        )
    }

    func test_update_replaceOnlyWhenAsked() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras", content: "leche")])
        let out = await UpdateNoteTool(store: store)
            .run(argsJSON: #"{"query": "Compras", "content": "solo pan", "mode": "replace"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["content"] as? String, "solo pan")
    }

    func test_update_doesNotCreateASecondNote() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras", content: "leche")])
        _ = await UpdateNoteTool(store: store).run(argsJSON: #"{"query": "Compras", "content": "pan"}"#)
        XCTAssertEqual(store.count(), 1, "Editar no debe duplicar la nota")
    }

    func test_update_renameAndRetags() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras", tags: ["viejo"])])
        let out = await UpdateNoteTool(store: store)
            .run(argsJSON: #"{"query": "Compras", "title": "Compras del mes", "tags": "casa, mensual"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["title"] as? String, "Compras del mes")
        XCTAssertEqual(parsed["tags"] as? [String], ["casa", "mensual"])
    }

    func test_update_bumpsUpdatedAt() async throws {
        let old = GemmaNote(
            title: "Compras", content: "leche", tags: [],
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        let store = InMemoryNoteStore(seed: [old])
        _ = await UpdateNoteTool(store: store).run(argsJSON: #"{"query": "Compras", "content": "pan"}"#)
        let all = await store.allNotes()
        let reloaded = try XCTUnwrap(all.first)
        XCTAssertGreaterThan(reloaded.updatedAt.timeIntervalSince1970, 0)
    }

    func test_update_nothingToChange_isAnError() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras")])
        let out = await UpdateNoteTool(store: store).run(argsJSON: #"{"query": "Compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertNotNil(parsed["error"])
    }

    func test_update_ambiguous_changesNothing() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras del sábado", content: "a"), note("Compras de la oficina", content: "b")])
        let out = await UpdateNoteTool(store: store)
            .run(argsJSON: #"{"query": "compras", "content": "x", "mode": "replace"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "ambiguous")
        let contents = Set(await store.allNotes().map(\.content))
        XCTAssertEqual(contents, ["a", "b"], "Ante la duda no se toca ninguna")
    }

    // MARK: - delete_note

    func test_delete_removesTheNote() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras", content: "leche"), note("Ideas")])
        let out = await DeleteNoteTool(store: store).run(argsJSON: #"{"query": "Compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "deleted")
        XCTAssertEqual(parsed["title"] as? String, "Compras")
        XCTAssertEqual(store.count(), 1)
    }

    func test_delete_returnsContentSoItCanBeRecreated() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras", content: "leche\npan")])
        let out = await DeleteNoteTool(store: store).run(argsJSON: #"{"query": "Compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(
            parsed["deleted_content"] as? String, "leche\npan",
            "El almacén no tiene papelera: devolver el contenido es la única vuelta atrás"
        )
    }

    func test_delete_ambiguous_deletesNothing() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras del sábado"), note("Compras de la oficina")])
        let out = await DeleteNoteTool(store: store).run(argsJSON: #"{"query": "compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "ambiguous")
        XCTAssertEqual(store.count(), 2, "Borrar no se deshace: ante la duda, nada")
    }

    func test_delete_notFound() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras")])
        let out = await DeleteNoteTool(store: store).run(argsJSON: #"{"query": "impuestos"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "not_found")
        XCTAssertEqual(store.count(), 1)
    }

    func test_delete_byID() async throws {
        let target = note("Compras")
        let store = InMemoryNoteStore(seed: [target, note("Ideas")])
        let args = try String(
            data: JSONSerialization.data(withJSONObject: ["query": target.id]), encoding: .utf8
        ) ?? "{}"
        let out = await DeleteNoteTool(store: store).run(argsJSON: args)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "deleted")
        XCTAssertEqual(store.count(), 1)
    }

    func test_delete_missingQuery_returnsValidErrorJSON() async throws {
        let out = await DeleteNoteTool(store: InMemoryNoteStore()).run(argsJSON: "{}")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertNotNil(parsed["error"])
    }

    // MARK: - search_notes

    func test_search_returnsValidJSONWithAwkwardContent() async throws {
        let store = InMemoryNoteStore(seed: [
            note(#"Lista "rara""#, content: "línea1\nlínea2\tcon tab \\ barra")
        ])
        let out = await SearchNotesTool(store: store).run(argsJSON: #"{"query": "rara"}"#)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
            "La salida debe ser JSON válido. Obtenido: \(out)"
        )
        XCTAssertEqual(parsed["count"] as? Int, 1)
        let notes = try XCTUnwrap(parsed["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.first?["title"] as? String, #"Lista "rara""#)
        XCTAssertEqual(notes.first?["content"] as? String, "línea1\nlínea2\tcon tab \\ barra")
    }

    func test_search_emptyQueryListsEverything() async throws {
        let store = InMemoryNoteStore(seed: [note("A"), note("B")])
        let out = await SearchNotesTool(store: store).run(argsJSON: "{}")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 2)
    }

    func test_search_noMatches_saysSo() async throws {
        let store = InMemoryNoteStore(seed: [note("Compras")])
        let out = await SearchNotesTool(store: store).run(argsJSON: #"{"query": "impuestos"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["count"] as? Int, 0)
        XCTAssertTrue((parsed["message"] as? String ?? "").contains("impuestos"))
    }

    func test_search_respectsLimit() async throws {
        let store = InMemoryNoteStore(seed: (1...5).map { note("Nota \($0)") })
        let out = await SearchNotesTool(store: store).run(argsJSON: #"{"limit": 2}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual((parsed["notes"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(parsed["count"] as? Int, 5, "'count' informa del total, aunque se devuelvan menos")
    }

    // MARK: - Ciclo completo

    func test_fullLifecycle() async throws {
        let store = InMemoryNoteStore()

        _ = await CreateNoteTool(store: store).run(argsJSON: #"{"title": "Compras", "content": "leche"}"#)
        XCTAssertEqual(store.count(), 1)

        _ = await UpdateNoteTool(store: store).run(argsJSON: #"{"query": "Compras", "content": "pan"}"#)
        let readOut = await ReadNoteTool(store: store).run(argsJSON: #"{"query": "Compras"}"#)
        let readParsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(readOut.utf8)) as? [String: Any])
        XCTAssertEqual(readParsed["content"] as? String, "leche\npan")

        let deleteOut = await DeleteNoteTool(store: store).run(argsJSON: #"{"query": "Compras"}"#)
        let deleteParsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(deleteOut.utf8)) as? [String: Any])
        XCTAssertEqual(deleteParsed["status"] as? String, "deleted")
        XCTAssertEqual(store.count(), 0)
    }
}
