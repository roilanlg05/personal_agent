import Foundation

/// Desaprender lo que Gemma aprendió mal.
///
/// `ShortcutRegistry.forget(named:)`, `ContactAliasStore.forgetAlias(_:)` y
/// `ContactAliasStore.learned()` ya existían en los almacenes: lo único que faltaba era
/// una herramienta que los expusiera. El efecto práctico era que Gemma podía aprender que
/// "mi hermano" es un contacto equivocado, y no había forma de corregirla: el alias malo
/// se quedaba para siempre y seguía desviando llamadas y mensajes.

/// forget_shortcut — quita un atajo del registro de Gemma.
public final class ForgetShortcutTool: AgentTool, Sendable {
    public static let name = "forget_shortcut"
    public static let description = """
    Quita un atajo del registro de Gemma, cuando el usuario diga que ya no existe, que \
    lo borró de la app Atajos, o que Gemma lo apuntó mal. OJO: esto solo borra lo que \
    Gemma recuerda; NO borra el atajo de la app Atajos del usuario, porque Apple no deja \
    hacerlo. Si lo que quiere es borrarlo de verdad, dile que lo haga él en la app \
    Atajos. Lee 'status': 'forgotten' = quitado del registro; 'not_found' = Gemma no \
    tenía apuntado ningún atajo con ese nombre, no digas que lo borraste. Usa \
    list_shortcuts para ver los nombres exactos.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "name", type: .string, description: "Nombre del atajo tal como aparece en list_shortcuts", required: true)
    ]

    private let registry: ShortcutRegistry

    public init(registry: ShortcutRegistry = .shared) {
        self.registry = registry
    }

    public func run(argsJSON: String) async -> String {
        guard let name = CreateNoteTool.parseString(named: "name", from: argsJSON), !name.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'name' con el nombre del atajo.")
        }
        guard let entry = registry.entry(named: name) else {
            return ToolJSONOutput.object([
                "status": "not_found",
                "requested": name,
                "known": registry.all().prefix(20).map(\.name),
                "message": "Gemma no tiene apuntado ningún atajo llamado '\(name)'. En 'known' están los que sí conoce."
            ])
        }
        registry.forget(named: entry.name)
        return ToolJSONOutput.object([
            "status": "forgotten",
            "name": entry.name,
            "message": "Gemma ya no recuerda el atajo «\(entry.name)». Sigue existiendo en la app Atajos del usuario: Apple no permite borrarlo desde aquí."
        ])
    }
}

/// list_contact_aliases — qué parentescos y apodos tiene aprendidos Gemma.
public final class ListContactAliasesTool: AgentTool, Sendable {
    public static let name = "list_contact_aliases"
    public static let description = """
    Enumera los parentescos y apodos que Gemma ha aprendido ('mi esposa' → 'Ana Ruiz'). \
    Úsalo cuando el usuario pregunte qué sabe Gemma de su gente, o antes de corregir un \
    alias mal aprendido. Lee 'status': 'ok' = hay alias, 'empty' = Gemma no ha aprendido \
    ninguno todavía. Cada fila trae 'relationship' (cómo lo llama el usuario) y \
    'contact' (a quién apunta).
    """
    public static let parameters: [AgentToolParam] = []

    private let aliasStore: ContactAliasStore

    public init(aliasStore: ContactAliasStore = .shared) {
        self.aliasStore = aliasStore
    }

    public func run(argsJSON: String) async -> String {
        let learned = aliasStore.learned()
        return ToolJSONOutput.object([
            "status": learned.isEmpty ? "empty" : "ok",
            "aliases": learned.sorted { $0.key < $1.key }.map { entry in
                ["relationship": entry.key, "contact": entry.value]
            },
            "message": learned.isEmpty
                ? "Gemma no ha aprendido ningún parentesco ni apodo todavía."
                : "Gemma tiene \(learned.count) alias aprendido(s)."
        ])
    }
}

/// forget_contact_alias — desaprende un parentesco mal aprendido.
public final class ForgetContactAliasTool: AgentTool, Sendable {
    public static let name = "forget_contact_alias"
    public static let description = """
    Hace que Gemma desaprenda un parentesco o apodo ('mi hermano', 'el jefe'), cuando lo \
    aprendió mal o apunta a la persona equivocada. Es lo que hay que usar antes de \
    volver a enseñárselo con remember_contact_alias si el contacto cambió. Lee 'status': \
    'forgotten' = desaprendido, ya no resuelve a ese contacto; 'not_found' = Gemma no \
    tenía ese alias aprendido, no digas que lo borraste. Usa list_contact_aliases para \
    ver cuáles hay.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "relationship", type: .string, description: "El parentesco o apodo a desaprender, p. ej. 'mi hermano'", required: true)
    ]

    private let aliasStore: ContactAliasStore

    public init(aliasStore: ContactAliasStore = .shared) {
        self.aliasStore = aliasStore
    }

    public func run(argsJSON: String) async -> String {
        guard let relationship = CreateNoteTool.parseString(named: "relationship", from: argsJSON),
              !relationship.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'relationship' con el parentesco o apodo.")
        }
        let learned = aliasStore.learned()
        let key = relationship.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Se busca de forma tolerante porque el usuario no escribe la clave igual que
        // cuando la enseñó ("mi esposa" / "Mi Esposa").
        let match = learned.first { entry in
            entry.key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == key
        }
        guard let match else {
            return ToolJSONOutput.object([
                "status": "not_found",
                "requested": relationship,
                "known": learned.keys.sorted(),
                "message": "Gemma no tiene aprendido '\(relationship)'. En 'known' están los que sí."
            ])
        }
        aliasStore.forgetAlias(relationship: match.key)

        // Hay alias de fábrica, y al borrar el aprendido vuelven a valer. Afirmar "ya no
        // asocio nada" cuando el de fábrica sigue resolviendo sería mentir, y el usuario
        // lo descubriría la próxima vez que dijera "llama a mi hermano".
        let stillResolves = aliasStore.resolve(aliasOrName: match.key)
        let fallback = stillResolves == match.key ? nil : stillResolves

        return ToolJSONOutput.object([
            "status": "forgotten",
            "relationship": match.key,
            "was": match.value,
            "now_resolves_to": fallback,
            "message": fallback == nil
                ? "Gemma ya no asocia '\(match.key)' con nadie. Si hay que enseñárselo de nuevo, usa remember_contact_alias."
                : "Gemma ya no recuerda que '\(match.key)' era \(match.value), pero vuelve a valer el valor por omisión: ahora '\(match.key)' resuelve a «\(fallback!)». Si eso tampoco es correcto, usa remember_contact_alias para fijar el bueno."
        ])
    }
}
