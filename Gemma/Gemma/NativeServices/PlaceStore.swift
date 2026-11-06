import Foundation

/// Lugares conocidos del usuario ("Casa de Marcos", "Oficina").
///
/// Hay una sola instancia en la app, `PlaceStore.shared`, por dos motivos que juntos
/// dejaban la función entera muerta:
///
/// 1. `init(storageURL: nil)` no persiste nada: `persist()` sale sin hacer nada. El
///    almacén por omisión era exactamente ese, así que todo lo guardado desaparecía al
///    cerrar la app.
/// 2. Los tools se reconstruyen en cada turno de conversación y cada uno creaba su
///    propio `PlaceStore()`. Como el estado vive en memoria, `save_place` escribía en un
///    almacén y `list_places` leía otro, vacío: el agente informaba de que no había
///    ningún lugar guardado justo después de decir que lo había guardado.
///
/// Mismo problema y misma solución que `NoteStore.shared` y `ShortcutRegistry.shared`.
public final class PlaceStore: @unchecked Sendable {
    private var places: [String: KnownPlace] = [:]
    private let storageURL: URL?
    private let lock = NSLock()
    /// Cola de subida al servicio de memoria, o `nil` para no espejar (tests).
    private let outbox: MirrorOutbox?

    public init(storageURL: URL? = nil, outbox: MirrorOutbox? = nil) {
        self.storageURL = storageURL
        self.outbox = outbox
        if let url = storageURL, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([KnownPlace].self, from: data) {
                for p in decoded { self.places[p.id] = p }
            }
        }
    }

    /// Almacén único de la app, con persistencia real en disco.
    public static let shared = PlaceStore(storageURL: PlaceStore.defaultStorageURL(), outbox: .shared)

    /// Fichero donde viven los lugares: `gemma_places.json` en el directorio de soporte
    /// de la aplicación, igual que las notas.
    public static func defaultStorageURL() -> URL? {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths.first ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gemma_places.json")
    }

    public func save(place: KnownPlace) {
        lock.lock()
        places[place.id] = place
        persist()
        lock.unlock()
        outbox?.enqueueUpsert(kind: MirrorKind.place, record: Self.record(for: place))
    }

    public func get(id: String) -> KnownPlace? {
        lock.lock()
        defer { lock.unlock() }
        return places[id]
    }

    public func list() -> [KnownPlace] {
        lock.lock()
        defer { lock.unlock() }
        return Array(places.values).sorted { $0.name < $1.name }
    }

    /// Busca un lugar por nombre exacto, ignorando mayúsculas, acentos y espacios
    /// sobrantes. Es lo que permite que `save_place` actualice en vez de duplicar.
    public func place(named name: String) -> KnownPlace? {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.normalize(name)
        return places.values.first { Self.normalize($0.name) == key }
    }

    public func delete(id: String) -> Bool {
        lock.lock()
        guard let removed = places.removeValue(forKey: id) else {
            lock.unlock()
            return false
        }
        persist()
        lock.unlock()
        outbox?.enqueueDelete(kind: MirrorKind.place,
                              recordId: Self.normalize(removed.name), label: removed.name)
        return true
    }

    public func search(query: String) -> [KnownPlace] {
        lock.lock()
        defer { lock.unlock() }
        let cleanQuery = Self.normalize(query)
        if cleanQuery.isEmpty { return Array(places.values) }

        return places.values.filter { place in
            Self.normalize(place.name).contains(cleanQuery)
        }.sorted { $0.visitCount > $1.visitCount }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Debe llamarse con `lock` tomado.
    private func persist() {
        guard let url = storageURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(Array(places.values)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Espejo en el servicio de memoria

extension PlaceStore: MirroredStore {
    public var mirrorKind: String { MirrorKind.place }

    /// La identidad del registro es el nombre normalizado, no el UUID: es la clave con la
    /// que `save_place` ya decide si actualiza o crea, así que es la identidad real de un
    /// lugar para el usuario, y converge entre dispositivos.
    static func record(for place: KnownPlace) -> MirrorRecord {
        MirrorRecord(recordId: normalize(place.name),
                     label: place.name,
                     body: "\(place.latitude), \(place.longitude)",
                     payload: MirrorCodec.encode(place) ?? "",
                     updatedAt: place.lastVisitedAt.timeIntervalSince1970)
    }

    public func mirrorRecords() -> [MirrorRecord] {
        list().map { Self.record(for: $0) }
    }

    public func applyMirror(_ records: [MirrorRecord]) {
        var rebuilt: [String: KnownPlace] = [:]
        for record in records {
            guard let place = MirrorCodec.decode(record.payload, as: KnownPlace.self) else { continue }
            rebuilt[place.id] = place
        }
        lock.lock()
        places = rebuilt
        persist()
        lock.unlock()
    }
}
