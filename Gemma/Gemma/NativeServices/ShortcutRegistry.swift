import Foundation

/// Lo que Gemma sabe de un atajo concreto.
public struct ShortcutEntry: Codable, Sendable, Equatable {
    /// Nombre exacto con el que el atajo existe en la app Atajos. Es la clave para
    /// ejecutarlo, así que se guarda tal cual, sin normalizar.
    public let name: String
    /// Para qué sirve, en palabras que el modelo pueda usar para decidir.
    public let purpose: String
    /// Qué se le puede pasar como entrada; `nil` si no acepta nada.
    public let inputDescription: String?
    /// Qué devuelve; `nil` si no produce salida.
    public let outputDescription: String?
    /// Si es `true`, no se ejecuta sin confirmación explícita del usuario.
    public let isSensitive: Bool

    public init(
        name: String,
        purpose: String,
        inputDescription: String? = nil,
        outputDescription: String? = nil,
        isSensitive: Bool = false
    ) {
        self.name = name
        self.purpose = purpose
        self.inputDescription = inputDescription
        self.outputDescription = outputDescription
        self.isSensitive = isSensitive
    }
}

/// Lo que Gemma sabe de los atajos del usuario.
///
/// Existe porque en iOS no hay forma de preguntarle al sistema qué atajos hay. Sin un
/// registro propio, el modelo tendría que adivinar nombres, y un nombre equivocado es
/// un atajo que no se ejecuta. Aquí se guardan los que el usuario ha enseñado a Gemma y
/// los que Gemma instala desde su catálogo.
public final class ShortcutRegistry: @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey = "gemma.shortcuts.registry.v1"
    private let lock = NSLock()
    private var entries: [ShortcutEntry]

    /// Registro único de la app.
    ///
    /// `init` toma una foto de UserDefaults en memoria, así que con una instancia por
    /// tool un atajo recién enseñado con `remember_shortcut` no existía todavía para
    /// `run_shortcut` en el mismo turno: su copia precedía a la escritura.
    public static let shared = ShortcutRegistry(outbox: .shared)

    /// Cola de subida al servicio de memoria, o `nil` para no espejar (tests).
    private let outbox: MirrorOutbox?

    public init(defaults: UserDefaults = .standard, outbox: MirrorOutbox? = nil) {
        self.defaults = defaults
        self.outbox = outbox
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ShortcutEntry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    public func all() -> [ShortcutEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.sorted { $0.name < $1.name }
    }

    /// Guarda o reemplaza lo que se sabe de un atajo. La comparación de nombres ignora
    /// mayúsculas y acentos, para que no acaben dos fichas del mismo atajo.
    public func remember(_ entry: ShortcutEntry) {
        lock.lock()
        let key = Self.normalize(entry.name)
        entries.removeAll { Self.normalize($0.name) == key }
        entries.append(entry)
        persist()
        lock.unlock()
        outbox?.enqueueUpsert(kind: MirrorKind.shortcut, record: Self.record(for: entry))
    }

    public func forget(named name: String) {
        lock.lock()
        let key = Self.normalize(name)
        entries.removeAll { Self.normalize($0.name) == key }
        persist()
        lock.unlock()
        outbox?.enqueueDelete(kind: MirrorKind.shortcut, recordId: key, label: name)
    }

    public func entry(named name: String) -> ShortcutEntry? {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.normalize(name)
        return entries.first { Self.normalize($0.name) == key }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey)
        }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Palabras que delatan un atajo capaz de mover dinero o hacer algo difícil de
    /// deshacer.
    private static let sensitiveKeywords = [
        "paga", "pagar", "pago", "payment", "pay ", "transfer", "transferir", "transferencia",
        "enviar dinero", "send money", "zelle", "venmo", "wire", "retirar", "withdraw",
        "comprar", "purchase", "borrar", "eliminar", "delete", "desbloquear", "unlock"
    ]

    /// Decide si un atajo debe tratarse como sensible solo por su nombre.
    ///
    /// Se aplica al registrar un atajo que el usuario no ha clasificado: ante la duda,
    /// pedir confirmación. El fallo barato es preguntar; el fallo caro es pagar una
    /// tarjeta sin que nadie lo pidiera.
    public static func looksSensitive(_ name: String) -> Bool {
        let normalized = normalize(name)
        return sensitiveKeywords.contains { normalized.contains($0) }
    }
}

// MARK: - Espejo en el servicio de memoria

extension ShortcutRegistry: MirroredStore {
    public var mirrorKind: String { MirrorKind.shortcut }

    /// La identidad del registro es el nombre normalizado, que es también la clave con la
    /// que el registro deduplica en local. Así dos dispositivos que aprendan el mismo
    /// atajo convergen en un solo nodo en vez de crear dos.
    static func record(for entry: ShortcutEntry) -> MirrorRecord {
        MirrorRecord(recordId: normalize(entry.name),
                     label: entry.name,
                     body: entry.purpose,
                     payload: MirrorCodec.encode(entry) ?? "")
    }

    public func mirrorRecords() -> [MirrorRecord] {
        all().map { Self.record(for: $0) }
    }

    public func applyMirror(_ records: [MirrorRecord]) {
        let rebuilt = records.compactMap { MirrorCodec.decode($0.payload, as: ShortcutEntry.self) }
        lock.lock()
        entries = rebuilt
        persist()
        lock.unlock()
    }
}
