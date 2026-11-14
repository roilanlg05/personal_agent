import Foundation

public struct GemmaNote: Codable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var content: String
    public var tags: [String]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        content: String,
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public protocol NoteStoring: Sendable {
    func saveNote(_ note: GemmaNote) async throws -> GemmaNote
    func searchNotes(query: String) async -> [GemmaNote]
    func allNotes() async -> [GemmaNote]
    func deleteNote(id: String) async throws -> Bool
}

public actor NoteStore: NoteStoring {
    private var notes: [String: GemmaNote] = [:]
    private let fileURL: URL?
    /// Cola de subida al servicio de memoria, o `nil` para no espejar (tests).
    ///
    /// El fichero local sigue siendo la caché que se lee al instante; la cola es lo que
    /// hace que la nota acabe en el servidor y sobreviva a una reinstalación.
    private let outbox: MirrorOutbox?

    public init(fileURL: URL? = nil, outbox: MirrorOutbox? = nil) {
        self.fileURL = fileURL
        self.outbox = outbox
        if let fileURL = fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL),
               let loaded = try? JSONDecoder().decode([String: GemmaNote].self, from: data) {
                self.notes = loaded
            }
        }
    }

    /// Almacén único de la app.
    ///
    /// Cada tool construía antes su propio `defaultStore()`. Todos escribían en el
    /// mismo fichero, pero cada uno cargaba su copia en memoria al crearse, así que
    /// dentro de un mismo turno borrar o editar no veía la nota que se acababa de
    /// crear. Con una sola instancia todas las operaciones ven el mismo estado.
    public static let shared = NoteStore.defaultStore()

    public static func defaultStore() -> NoteStore {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths.first ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("gemma_notes.json")
        return NoteStore(fileURL: file, outbox: .shared)
    }

    public func saveNote(_ note: GemmaNote) async throws -> GemmaNote {
        notes[note.id] = note
        persist()
        outbox?.enqueueUpsert(kind: MirrorKind.note, record: Self.record(for: note))
        return note
    }

    public func searchNotes(query: String) async -> [GemmaNote] {
        let q = Self.foldForSearch(query)
        if q.isEmpty {
            return allNotesSorted()
        }
        return notes.values.filter { note in
            Self.foldForSearch(note.title).contains(q) ||
            Self.foldForSearch(note.content).contains(q) ||
            note.tags.contains(where: { Self.foldForSearch($0).contains(q) })
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Normaliza para buscar: sin mayúsculas y sin acentos.
    ///
    /// Sin plegar los acentos, buscar "reunion" no encuentra "Reunión", que en español
    /// es el caso normal cuando se dicta por voz o se escribe con prisa.
    static func foldForSearch(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public func allNotes() async -> [GemmaNote] {
        return allNotesSorted()
    }

    public func deleteNote(id: String) async throws -> Bool {
        if let removed = notes.removeValue(forKey: id) {
            persist()
            // El borrado también se encola: si solo se quitara de la caché, la nota
            // volvería en la hidratación siguiente, que es exactamente lo que el usuario
            // no quiere cuando borra algo.
            outbox?.enqueueDelete(kind: MirrorKind.note, recordId: removed.id, label: removed.title)
            return true
        }
        return false
    }

    private func allNotesSorted() -> [GemmaNote] {
        return notes.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        guard let fileURL = fileURL else { return }
        if let data = try? JSONEncoder().encode(notes) {
            try? data.write(to: fileURL)
        }
    }
}

// MARK: - Espejo en el servicio de memoria

extension NoteStore: MirroredStore {
    public nonisolated var mirrorKind: String { MirrorKind.note }

    static func record(for note: GemmaNote) -> MirrorRecord {
        MirrorRecord(recordId: note.id,
                     label: note.title.isEmpty ? note.id : note.title,
                     body: note.content,
                     payload: MirrorCodec.encode(note) ?? "",
                     updatedAt: note.updatedAt.timeIntervalSince1970)
    }

    public func mirrorRecords() async -> [MirrorRecord] {
        notes.values.map { Self.record(for: $0) }
    }

    public func applyMirror(_ records: [MirrorRecord]) async {
        var rebuilt: [String: GemmaNote] = [:]
        for record in records {
            guard let note = MirrorCodec.decode(record.payload, as: GemmaNote.self) else { continue }
            rebuilt[note.id] = note
        }
        notes = rebuilt
        persist()
    }
}
