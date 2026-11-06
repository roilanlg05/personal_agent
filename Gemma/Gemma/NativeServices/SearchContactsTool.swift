import Foundation

/// Busca en la libreta de contactos, resolviendo antes los apodos que el usuario haya
/// enseñado ("mi jefe", "mi hermana").
///
/// La versión anterior devolvía `ToolJSONOutput.error(...)` cuando iOS negaba el acceso a
/// Contactos. El modelo recibía un error genérico indistinguible de una búsqueda vacía y
/// le contaba al usuario que no tenía ningún contacto con ese nombre, cuando en realidad
/// nunca pudo abrir la libreta. Aquí "no pude mirar" y "miré y no hay" son dos estados
/// distintos, y el segundo además distingue si lo que falló fue el apodo.
public final class SearchContactsTool: AgentTool, Sendable {
    /// Tope de contactos devueltos. Buscar "a" puede devolver toda la libreta, y volcarla
    /// entera en la conversación no ayuda a nadie: el conteo real se da aparte.
    private static let maxReturned = 25

    public static let name = "search_contacts"
    public static let description = """
    Busca contactos en la libreta del teléfono por nombre, apodo o parentesco ('mamá', \
    'mi jefe', 'Marcos'). Resuelve sola los apodos que el usuario haya enseñado con \
    remember_contact_alias. Lee 'status': 'found' = hay resultados en 'contacts' y \
    'count' dice cuántos (si 'truncated' es true solo van los primeros, no afirmes que \
    son todos); 'not_found' = se buscó y no hay nadie, y si 'alias_used' es true el \
    problema puede ser el apodo, no el contacto, así que ofrece corregirlo; \
    'permission_required' = falta el permiso de Contactos, que se concede en Ajustes, y \
    aquí NO puedes decir que el contacto no existe porque no se pudo mirar; 'failed' = \
    la libreta falló, tampoco afirmes que no existe; 'missing_fields' = falta 'query'.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "query", type: .string, description: "Nombre, apodo o parentesco a buscar (ej. 'esposa', 'mamá', 'Juan')", required: true)
    ]

    private let manager: any ContactsManaging
    private let aliasStore: ContactAliasStore

    public init(
        manager: any ContactsManaging = AppleContactsManager(),
        aliasStore: ContactAliasStore = .shared
    ) {
        self.manager = manager
        self.aliasStore = aliasStore
    }

    public func run(argsJSON: String) async -> String {
        guard let query = CreateNoteTool.parseString(named: "query", from: argsJSON)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return ToolJSONOutput.object([
                "status": "missing_fields",
                "required": ["query"],
                "message": "Falta 'query' con el nombre, apodo o parentesco a buscar."
            ])
        }

        let resolvedQuery = aliasStore.resolve(aliasOrName: query)
        let aliasUsed = resolvedQuery != query

        let contacts: [GemmaContact]
        do {
            contacts = try await manager.searchContacts(query: resolvedQuery)
        } catch {
            let nsError = error as NSError
            if nsError.code == 403 {
                return ToolJSONOutput.object([
                    "status": "permission_required",
                    "searched_query": query,
                    "resolved_target": aliasUsed ? resolvedQuery : nil,
                    "message": "Falta el permiso de Contactos. No se pudo mirar la libreta, así que no se sabe si '\(query)' está o no: pídele al usuario que lo conceda en Ajustes › Privacidad › Contactos."
                ])
            }
            return ToolJSONOutput.object([
                "status": "failed",
                "searched_query": query,
                "resolved_target": aliasUsed ? resolvedQuery : nil,
                "error": nsError.localizedDescription,
                "message": "La libreta de contactos falló: \(nsError.localizedDescription). No se pudo comprobar nada, no digas que el contacto no existe."
            ])
        }

        guard !contacts.isEmpty else {
            // Que un apodo no encuentre nada no es lo mismo que que no haya contacto: lo
            // más probable es que el apodo apunte a un nombre mal escrito. El consejo
            // que hay que dar al usuario es distinto en cada caso.
            return ToolJSONOutput.object([
                "status": "not_found",
                "searched_query": query,
                "resolved_target": aliasUsed ? resolvedQuery : nil,
                "alias_used": aliasUsed ? true : nil,
                "count": 0,
                "message": aliasUsed
                    ? "No hay ningún contacto que encaje con «\(resolvedQuery)», que es a lo que Gemma traduce «\(query)». Puede que el apodo esté mal guardado: pregúntale al usuario el nombre exacto y corrígelo con remember_contact_alias."
                    : "Se buscó en la libreta y no hay ningún contacto que encaje con «\(query)»."
            ])
        }

        let shown = Array(contacts.prefix(Self.maxReturned))
        return ToolJSONOutput.object([
            "status": "found",
            "searched_query": query,
            "resolved_target": resolvedQuery,
            "alias_used": aliasUsed ? true : nil,
            "count": contacts.count,
            "truncated": contacts.count > shown.count ? true : nil,
            "contacts": shown.map { contact in
                ([
                    "id": contact.id,
                    "givenName": contact.givenName,
                    "familyName": contact.familyName,
                    "fullName": contact.fullName,
                    "nickname": contact.nickname,
                    "phoneNumbers": contact.phoneNumbers,
                    "emailAddresses": contact.emailAddresses
                ] as [String: Any?]).compactMapValues { $0 }
            },
            "message": contacts.count > shown.count
                ? "\(contacts.count) contactos encajan; van los primeros \(shown.count). Si hace falta otro, pídele al usuario que afine el nombre."
                : nil
        ])
    }
}
