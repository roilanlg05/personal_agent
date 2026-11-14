import XCTest
@testable import Gemma

final class MockTextSharer: TextSharing, @unchecked Sendable {
    var shouldPresent: Bool
    private(set) var shared: [(text: String, subject: String?)] = []

    init(shouldPresent: Bool = true) {
        self.shouldPresent = shouldPresent
    }

    func share(text: String, subject: String?) async -> Bool {
        shared.append((text, subject))
        return shouldPresent
    }
}

/// Almacén en memoria, para no tocar el disco en los tests.
final class InMemoryNoteStore: NoteStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [String: GemmaNote] = [:]
    private var failOnSave = false

    init(seed: [GemmaNote] = []) {
        for note in seed { notes[note.id] = note }
    }

    func setFailOnSave(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        failOnSave = value
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return notes.count
    }

    func saveNote(_ note: GemmaNote) async throws -> GemmaNote {
        lock.lock()
        let shouldFail = failOnSave
        lock.unlock()
        if shouldFail {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "disco lleno"])
        }
        lock.lock(); defer { lock.unlock() }
        notes[note.id] = note
        return note
    }

    /// Imita a `NoteStore`: busca en título, contenido y etiquetas.
    func searchNotes(query: String) async -> [GemmaNote] {
        lock.lock(); defer { lock.unlock() }
        let needle = NoteStore.foldForSearch(query)
        if needle.isEmpty { return Array(notes.values) }
        return notes.values.filter { note in
            NoteStore.foldForSearch(note.title).contains(needle)
                || NoteStore.foldForSearch(note.content).contains(needle)
                || note.tags.contains { NoteStore.foldForSearch($0).contains(needle) }
        }
    }

    func allNotes() async -> [GemmaNote] {
        lock.lock(); defer { lock.unlock() }
        return Array(notes.values)
    }

    func deleteNote(id: String) async throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return notes.removeValue(forKey: id) != nil
    }
}

/// `create_note` guarda en el gestor de notas de Gemma. Nada más: llevar una nota a
/// Notas de Apple o a una persona es `share_note`, y solo cuando el usuario lo pide.
final class CreateNoteToolTests: XCTestCase {

    func test_metadata() {
        XCTAssertEqual(CreateNoteTool.name, "create_note")
        XCTAssertTrue(CreateNoteTool.parameters.contains { $0.name == "title" && $0.required })
        XCTAssertTrue(CreateNoteTool.parameters.contains { $0.name == "content" && $0.required })
        XCTAssertFalse(
            CreateNoteTool.parameters.contains { $0.name == "send_to_apple_notes" },
            "Compartir con Notas de Apple ya no es parte de crear una nota"
        )
    }

    func test_savesInGemmaAndReportsCreated() async throws {
        let store = InMemoryNoteStore()
        let out = await CreateNoteTool(store: store)
            .run(argsJSON: #"{"title": "Compras", "content": "Leche\npan"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "created")
        XCTAssertEqual(parsed["title"] as? String, "Compras")
        XCTAssertEqual(store.count(), 1)
        XCTAssertTrue((parsed["message"] as? String ?? "").contains("notas de Gemma"))
    }

    func test_savesTagsCleanly() async throws {
        let out = await CreateNoteTool(store: InMemoryNoteStore())
            .run(argsJSON: #"{"title": "T", "content": "C", "tags": "ideas, trabajo ,, compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["tags"] as? [String], ["ideas", "trabajo", "compras"])
    }

    func test_outputIsValidJSONWithAwkwardContent() async throws {
        let args = try String(
            data: JSONSerialization.data(withJSONObject: [
                "title": #"Lista "rara" \ con barra"#,
                "content": "línea1\nlínea2\ttab"
            ]),
            encoding: .utf8
        ) ?? "{}"
        let out = await CreateNoteTool(store: InMemoryNoteStore()).run(argsJSON: args)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
            "Salida inválida: \(out)"
        )
        XCTAssertEqual(parsed["title"] as? String, #"Lista "rara" \ con barra"#)
    }

    func test_missingArguments_returnValidErrorJSON() async throws {
        let tool = CreateNoteTool(store: InMemoryNoteStore())
        for args in ["{}", #"{"title": "T"}"#, #"{"content": "C"}"#, #"{"title": "", "content": "C"}"#] {
            let out = await tool.run(argsJSON: args)
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
            XCTAssertNotNil(parsed["error"], "Argumentos '\(args)' deberían dar error")
        }
    }

    func test_storeFailure_isReported() async throws {
        let store = InMemoryNoteStore()
        store.setFailOnSave(true)
        let out = await CreateNoteTool(store: store).run(argsJSON: #"{"title": "T", "content": "C"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertNotNil(parsed["error"])
    }
}

/// Compartir es transversal: el mismo tool sirve para notas, tareas, memorias,
/// insights, mensajes y chats. Estas pruebas usan notas y una fuente falsa de tareas
/// para comprobar que el mecanismo no sabe nada del tipo de contenido.
final class FakeShareSource: ShareableSource, @unchecked Sendable {
    let kind: String
    let displayName: String
    var items: [ShareableItem]

    init(kind: String, displayName: String, items: [ShareableItem]) {
        self.kind = kind
        self.displayName = displayName
        self.items = items
    }

    func find(matching query: String) async -> [ShareableItem] {
        let needle = query.lowercased()
        return items.filter { $0.title.lowercased().contains(needle) }
    }

    func availableTitles(limit: Int) async -> [String] {
        items.prefix(limit).map(\.title)
    }
}

final class ShareToolTests: XCTestCase {

    private func note(_ title: String, content: String = "contenido", tags: [String] = []) -> GemmaNote {
        GemmaNote(title: title, content: content, tags: tags)
    }

    private func noteSource(_ notes: [GemmaNote]) -> NoteShareSource {
        NoteShareSource(store: InMemoryNoteStore(seed: notes))
    }

    func test_metadata() {
        XCTAssertEqual(ShareTool.name, "share")
        XCTAssertTrue(ShareTool.parameters.contains { $0.name == "query" && $0.required })
        XCTAssertTrue(ShareTool.parameters.contains { $0.name == "kind" && !$0.required })
    }

    func test_sharesNoteWithTitleAndBody() async throws {
        let sharer = MockTextSharer()
        let out = await ShareTool(sources: [noteSource([note("Lista de compras", content: "Leche\npan")])], sharer: sharer)
            .run(argsJSON: #"{"query": "lista de compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "shared")
        XCTAssertEqual(parsed["kind"] as? String, "note")
        XCTAssertEqual(sharer.shared.first?.subject, "Lista de compras")
        XCTAssertEqual(sharer.shared.first?.text, "Lista de compras\n\nLeche\npan")
    }

    func test_sharedStatusDoesNotClaimItWasSent() async throws {
        let out = await ShareTool(sources: [noteSource([note("Compras")])], sharer: MockTextSharer())
            .run(argsJSON: #"{"query": "Compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertTrue((parsed["message"] as? String ?? "").contains("elija el destino"))
    }

    func test_worksForAnyKindNotJustNotes() async throws {
        let tasks = FakeShareSource(
            kind: "task", displayName: "tarea",
            items: [ShareableItem(kind: "task", id: "t1", title: "Llamar al fontanero", text: "Llamar al fontanero el martes")]
        )
        let sharer = MockTextSharer()
        let out = await ShareTool(sources: [noteSource([]), tasks], sharer: sharer)
            .run(argsJSON: #"{"query": "fontanero"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "shared")
        XCTAssertEqual(parsed["kind"] as? String, "task")
        XCTAssertEqual(sharer.shared.first?.text, "Llamar al fontanero el martes")
    }

    func test_kindLimitsTheSearch() async throws {
        let tasks = FakeShareSource(
            kind: "task", displayName: "tarea",
            items: [ShareableItem(kind: "task", id: "t1", title: "Compras de la oficina", text: "x")]
        )
        let sharer = MockTextSharer()
        let out = await ShareTool(sources: [noteSource([note("Compras del sábado")]), tasks], sharer: sharer)
            .run(argsJSON: #"{"query": "compras", "kind": "task"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "shared")
        XCTAssertEqual(parsed["kind"] as? String, "task")
    }

    func test_sameQueryAcrossKinds_asksInsteadOfGuessing() async throws {
        let tasks = FakeShareSource(
            kind: "task", displayName: "tarea",
            items: [ShareableItem(kind: "task", id: "t1", title: "Compras", text: "x")]
        )
        let sharer = MockTextSharer()
        let out = await ShareTool(sources: [noteSource([note("Compras")]), tasks], sharer: sharer)
            .run(argsJSON: #"{"query": "Compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "ambiguous")
        let kinds = Set((parsed["candidates"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String })
        XCTAssertEqual(kinds, ["note", "task"])
        XCTAssertTrue(sharer.shared.isEmpty)
    }

    func test_unknownKind_isReportedWithTheAvailableOnes() async throws {
        let out = await ShareTool(sources: [noteSource([note("Compras")])], sharer: MockTextSharer())
            .run(argsJSON: #"{"query": "algo", "kind": "factura"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "unsupported_kind")
        XCTAssertEqual(parsed["available_kinds"] as? [String], ["note"])
    }

    func test_partialTitleMatchIsEnoughWhenUnique() async throws {
        let out = await ShareTool(
            sources: [noteSource([note("Lista de compras del sábado"), note("Ideas de regalos")])],
            sharer: MockTextSharer()
        ).run(argsJSON: #"{"query": "compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "shared")
        XCTAssertEqual(parsed["title"] as? String, "Lista de compras del sábado")
    }

    func test_severalNotesMatch_asksInsteadOfGuessing() async throws {
        let sharer = MockTextSharer()
        let out = await ShareTool(
            sources: [noteSource([note("Compras del sábado"), note("Compras de la oficina")])],
            sharer: sharer
        ).run(argsJSON: #"{"query": "compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "ambiguous")
        XCTAssertEqual((parsed["candidates"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue(sharer.shared.isEmpty)
    }

    func test_exactTitleWinsOverPartialMatches() async throws {
        let out = await ShareTool(
            sources: [noteSource([note("Compras"), note("Compras de la oficina")])],
            sharer: MockTextSharer()
        ).run(argsJSON: #"{"query": "Compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "shared")
        XCTAssertEqual(parsed["title"] as? String, "Compras")
    }

    func test_matchIsAccentAndCaseInsensitive() async throws {
        let out = await ShareTool(sources: [noteSource([note("Reunión del lunes")])], sharer: MockTextSharer())
            .run(argsJSON: #"{"query": "reunion del lunes"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "shared")
    }

    func test_noMatch_reportsNotFoundWithAvailableTitles() async throws {
        let sharer = MockTextSharer()
        let out = await ShareTool(sources: [noteSource([note("Ideas de regalos")])], sharer: sharer)
            .run(argsJSON: #"{"query": "impuestos"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])

        XCTAssertEqual(parsed["status"] as? String, "not_found")
        XCTAssertEqual(parsed["available_titles"] as? [String], ["Ideas de regalos"])
        XCTAssertTrue(sharer.shared.isEmpty)
    }

    func test_presentationFailure_isReportedAsFailed() async throws {
        let out = await ShareTool(sources: [noteSource([note("Compras")])], sharer: MockTextSharer(shouldPresent: false))
            .run(argsJSON: #"{"query": "Compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "failed")
    }

    func test_noSharerAvailable_reportsUnavailable() async throws {
        let out = await ShareTool(sources: [noteSource([note("Compras")])], sharer: nil)
            .run(argsJSON: #"{"query": "Compras"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "unavailable")
    }

    func test_missingQuery_returnsValidErrorJSON() async throws {
        let out = await ShareTool(sources: [noteSource([])], sharer: MockTextSharer()).run(argsJSON: "{}")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertNotNil(parsed["error"])
    }

    func test_bodyOnlyMatchWithSeveralHits_asksInsteadOfGuessing() async throws {
        let sharer = MockTextSharer()
        let out = await ShareTool(
            sources: [noteSource([
                note("Reunión", content: "hablar de impuestos"),
                note("Pendientes", content: "revisar impuestos")
            ])],
            sharer: sharer
        ).run(argsJSON: #"{"query": "impuestos"}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["status"] as? String, "ambiguous")
        XCTAssertTrue(sharer.shared.isEmpty)
    }
}
