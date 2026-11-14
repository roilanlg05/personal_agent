import Foundation

/// Traduce cómo llama el usuario a la gente ("mi esposa", "mi jefe") al nombre con el
/// que ese contacto está en la libreta.
///
/// Trae unos cuantos parentescos de fábrica y aprende el resto. Lo aprendido se guarda
/// en disco: las herramientas se reconstruyen en cada turno de conversación, así que un
/// alias que solo viviera en memoria moriría en el turno en que se enseñó.
public final class ContactAliasStore: @unchecked Sendable {
    /// Almacén único de la app.
    ///
    /// Con una instancia por herramienta, el alias que el usuario acababa de enseñar no
    /// existía para la herramienta siguiente: cada una tenía su propia copia.
    public static let shared = ContactAliasStore(outbox: .shared)

    /// Parentescos que Gemma conoce sin que nadie se los enseñe.
    private static let builtInAliases: [String: String] = [
        "esposa": "Amor",
        "mujer": "Amor",
        "novia": "Amor",
        "mama": "Mamá",
        "madre": "Mamá",
        "papa": "Papá",
        "padre": "Papá",
        "hermano": "Hermano",
        "hermana": "Hermana"
    ]

    private let defaults: UserDefaults
    private let storageKey = "gemma.contact.aliases.v1"
    private let lock = NSLock()
    /// Solo los que ha enseñado el usuario. Los de fábrica no se guardan, así que
    /// pueden crecer o corregirse en versiones futuras sin arrastrar los viejos.
    private var learnedAliases: [String: String]
    /// Cola de subida al servicio de memoria, o `nil` para no espejar (tests).
    ///
    /// `resolve(aliasOrName:)` sigue siendo síncrono y sin red a propósito: lo llama el
    /// modelo en mitad de un turno, decidiendo a quién escribir, y no puede esperar a una
    /// petición HTTP que además puede no llegar.
    private let outbox: MirrorOutbox?

    public init(defaults: UserDefaults = .standard, outbox: MirrorOutbox? = nil) {
        self.defaults = defaults
        self.outbox = outbox
        self.learnedAliases = (defaults.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
    }

    /// Enseña o corrige un alias. Lo aprendido pisa lo de fábrica.
    public func setAlias(relationship: String, contactTarget: String) {
        let key = Self.normalize(relationship)
        let target = contactTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !target.isEmpty else { return }

        lock.lock()
        learnedAliases[key] = target
        let snapshot = learnedAliases
        lock.unlock()
        defaults.set(snapshot, forKey: storageKey)
        outbox?.enqueueUpsert(kind: MirrorKind.contactAlias,
                              record: Self.record(relationship: key, contact: target))
    }

    /// Olvida un alias aprendido. Si había uno de fábrica con esa clave, vuelve a valer.
    public func forgetAlias(relationship: String) {
        let key = Self.normalize(relationship)
        lock.lock()
        learnedAliases.removeValue(forKey: key)
        let snapshot = learnedAliases
        lock.unlock()
        defaults.set(snapshot, forKey: storageKey)
        outbox?.enqueueDelete(kind: MirrorKind.contactAlias, recordId: key, label: key)
    }

    /// Alias aprendidos, para poder enseñárselos al usuario.
    public func learned() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return learnedAliases
    }

    /// Devuelve el nombre del contacto si lo que llegó era un alias, o el texto tal cual.
    public func resolve(aliasOrName: String) -> String {
        let key = Self.normalize(aliasOrName)

        lock.lock()
        let learned = learnedAliases
        lock.unlock()

        // Se prueba con el texto entero y sin el determinante: "mi jefe" y "jefe" son
        // la misma cosa para el usuario.
        for candidate in [key, Self.droppingDeterminer(key)] where !candidate.isEmpty {
            if let target = learned[candidate] { return target }
            if let target = Self.builtInAliases[candidate] { return target }
        }
        return aliasOrName
    }

    private static func droppingDeterminer(_ text: String) -> String {
        for prefix in ["mi ", "el ", "la ", "mis "] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

// MARK: - Espejo en el servicio de memoria

/// Un alias, con forma propia para poder viajar como JSON.
struct MirroredContactAlias: Codable, Sendable {
    let relationship: String
    let contact: String
}

extension ContactAliasStore: MirroredStore {
    public var mirrorKind: String { MirrorKind.contactAlias }

    /// La identidad del registro es el parentesco ya normalizado, que es la clave del
    /// diccionario local. Dos dispositivos que aprendan "mi jefe" convergen.
    static func record(relationship: String, contact: String) -> MirrorRecord {
        MirrorRecord(recordId: relationship,
                     label: relationship,
                     body: contact,
                     payload: MirrorCodec.encode(MirroredContactAlias(relationship: relationship,
                                                                      contact: contact)) ?? "")
    }

    public func mirrorRecords() -> [MirrorRecord] {
        learned().map { Self.record(relationship: $0.key, contact: $0.value) }
    }

    /// Solo toca lo aprendido. Los parentescos de fábrica no se espejan: no son datos del
    /// usuario, y si se subieran, corregir la lista de fábrica en una versión futura no
    /// tendría efecto porque el servidor seguiría devolviendo la vieja.
    public func applyMirror(_ records: [MirrorRecord]) {
        var rebuilt: [String: String] = [:]
        for record in records {
            guard let alias = MirrorCodec.decode(record.payload, as: MirroredContactAlias.self),
                  !alias.relationship.isEmpty, !alias.contact.isEmpty else { continue }
            rebuilt[alias.relationship] = alias.contact
        }
        lock.lock()
        learnedAliases = rebuilt
        lock.unlock()
        defaults.set(rebuilt, forKey: storageKey)
    }
}

/// Enseña a Gemma cómo llama el usuario a una persona.
///
/// Comprueba en la libreta que el contacto exista antes de guardar el apodo. La versión
/// anterior guardaba cualquier cosa y contestaba "ya puedes usar ese apodo para llamar o
/// escribir": con un nombre que no estaba en la libreta esa promesa no se cumplía, y el
/// usuario solo se enteraba la siguiente vez que pedía llamar a su jefe. Si la libreta no
/// se puede consultar, el apodo se guarda igual (perder lo que el usuario acaba de
/// enseñar sería peor) pero se declara sin verificar.
public final class RememberContactAliasTool: AgentTool, Sendable {
    public static let name = "remember_contact_alias"
    public static let description = """
    Guarda a quién se refiere el usuario cuando usa un parentesco o un apodo: 'mi jefe', \
    'el doctor', 'mi hermano mayor'. Úsala en cuanto el usuario lo aclare ('mi jefe es \
    Carlos Pérez'), para no volver a preguntarlo nunca. El 'contact' debe ser el nombre \
    tal como está en la libreta de contactos. A partir de ahí send_message, \
    make_phone_call y search_contacts resuelven ese apodo solos. Antes de guardar se \
    comprueba que ese contacto exista. Lee 'status': 'remembered' = guardado y \
    comprobado en la libreta; 'remembered_ambiguous' = guardado, pero varios contactos \
    llevan ese nombre, enséñale 'candidates' al usuario y ofrece guardar el nombre \
    completo del que quiera; 'contact_not_found' = NO se guardó porque no hay ningún \
    contacto así, pídele al usuario el nombre exacto como aparece en la libreta y no \
    digas que el apodo quedó guardado; 'remembered_unverified' = guardado pero sin poder \
    mirar la libreta (falta permiso de Contactos), así que no afirmes que el contacto \
    existe; 'missing_fields' = falta 'relationship' o 'contact'. Para ver los apodos ya \
    guardados usa list_contact_aliases, y para borrar uno forget_contact_alias.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "relationship", type: .string, description: "El apodo o parentesco que usa el usuario, por ejemplo 'mi jefe'", required: true),
        AgentToolParam(name: "contact", type: .string, description: "Nombre del contacto en la libreta, por ejemplo 'Carlos Pérez'", required: true)
    ]

    private let aliasStore: ContactAliasStore
    private let contacts: any ContactsManaging

    public init(
        aliasStore: ContactAliasStore = .shared,
        contacts: any ContactsManaging = AppleContactsManager()
    ) {
        self.aliasStore = aliasStore
        self.contacts = contacts
    }

    public func run(argsJSON: String) async -> String {
        let relationship = CreateNoteTool.parseString(named: "relationship", from: argsJSON)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let contact = CreateNoteTool.parseString(named: "contact", from: argsJSON)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var missing: [String] = []
        if relationship?.isEmpty != false { missing.append("relationship") }
        if contact?.isEmpty != false { missing.append("contact") }
        guard missing.isEmpty, let relationship, let contact else {
            return ToolJSONOutput.object([
                "status": "missing_fields",
                "required": missing,
                "message": "Faltan datos: \(missing.joined(separator: ", ")). 'relationship' es el apodo que usa el usuario y 'contact' el nombre en la libreta."
            ])
        }

        // Se consulta la libreta ANTES de guardar. El resultado decide si el apodo se
        // guarda y, sobre todo, qué se le puede prometer al usuario.
        var matches: [GemmaContact]? = nil
        var lookupError: NSError? = nil
        do {
            matches = try await contacts.searchContacts(query: contact)
        } catch {
            lookupError = error as NSError
        }

        if let matches, matches.isEmpty {
            // Aquí sí se sabe que no existe, así que no se guarda nada: un apodo que
            // apunta al vacío solo sirve para fallar más tarde, cuando el usuario crea
            // que todo está en orden.
            return ToolJSONOutput.object([
                "status": "contact_not_found",
                "relationship": relationship,
                "contact": contact,
                "message": "No hay ningún contacto llamado «\(contact)» en la libreta, así que el apodo NO se guardó. Pídele al usuario el nombre exacto tal como aparece en Contactos y vuelve a intentarlo."
            ])
        }

        aliasStore.setAlias(relationship: relationship, contactTarget: contact)
        let recordId = ContactAliasStore.normalize(relationship)
        let sync = MirrorStatus.describe(kind: MirrorKind.contactAlias, recordId: recordId)
        let syncNote = MirrorStatus.note(kind: MirrorKind.contactAlias, recordId: recordId)

        guard let matches else {
            // No se pudo mirar la libreta. Se guarda igual, pero sin afirmar que el
            // contacto existe: "no pude comprobar" no es "está comprobado".
            let reason = lookupError?.code == 403
                ? "falta el permiso de Contactos"
                : "la libreta de contactos falló"
            return ToolJSONOutput.object([
                "status": "remembered_unverified",
                "relationship": relationship,
                "contact": contact,
                "verified_in_contacts": false,
                "sync": sync,
                "sync_note": syncNote,
                "message": "Guardado: '\(relationship)' es \(contact). No se pudo comprobar que ese contacto exista porque \(reason), así que si al llamar o escribir no aparece, habrá que corregir el nombre."
            ])
        }

        if matches.count > 1 {
            return ToolJSONOutput.object([
                "status": "remembered_ambiguous",
                "relationship": relationship,
                "contact": contact,
                "verified_in_contacts": true,
                "candidates": matches.prefix(10).map(\.fullName),
                "sync": sync,
                "sync_note": syncNote,
                "message": "Guardado: '\(relationship)' es \(contact). Pero hay \(matches.count) contactos que encajan con ese nombre: enséñaselos al usuario y, si quiere, guarda el nombre completo del que sea para que no haya duda."
            ])
        }

        return ToolJSONOutput.object([
            "status": "remembered",
            "relationship": relationship,
            "contact": contact,
            "verified_in_contacts": true,
            "matched_contact": matches[0].fullName,
            // Honesto sobre dónde quedó: en el dispositivo siempre, en el servidor en
            // cuanto haya red.
            "sync": sync,
            "sync_note": syncNote,
            "message": "Guardado: '\(relationship)' es \(matches[0].fullName), que sí está en la libreta. Ya puedes usar ese apodo para llamar o escribir."
        ])
    }
}
