import Foundation

/// Abre el marcador del teléfono con un número ya puesto.
///
/// ## Por qué no llama, y por qué no puede
///
/// En iOS, abrir una URL `tel:` desde una app de terceros **no inicia la llamada**. Desde
/// iOS 10.3 el sistema presenta una alerta de confirmación ("¿Llamar a …?") y espera a
/// que el usuario pulse "Llamar". `UIApplication.open(_:)` devuelve `true` en cuanto el
/// sistema acepta mostrar esa alerta, no cuando la llamada empieza.
///
/// No hay forma de evitar ese toque: CallKit (`CXStartCallAction`) solo marca dentro de
/// apps VoIP con su propio proveedor de llamadas, nunca por la red celular, y Apple no
/// expone ninguna otra API de marcación. Es una decisión de plataforma, no una carencia
/// de esta app: una app que pudiera marcar en silencio podría llamar a números de pago
/// sin que el dueño del teléfono se enterara.
///
/// La herramienta antes devolvía `status: "calling"` en cuanto `openURL` decía `true`, así
/// que Gemma anunciaba "estoy llamando a mamá" mientras el teléfono esperaba un dedo.
/// Ahora dice `confirmation_required`, que es lo que de verdad ocurrió.
public final class MakePhoneCallTool: AgentTool, Sendable {
    public static let name = "call_contact"
    public static let description = """
    Abre el marcador del teléfono con el número de un contacto ya puesto (resuelve \
    apodos y parentescos como 'mamá' o 'mi esposa') o con un número directo. OJO: NO \
    inicia la llamada. iOS no permite a ninguna app marcar sin que el usuario pulse; el \
    sistema muestra una alerta de confirmación y es él quien decide. Lee 'status': \
    'confirmation_required' = el marcador se abrió con el número puesto y el usuario \
    tiene que pulsar "Llamar" para que suene, así que díselo; 'ambiguous' = varios \
    contactos encajan, pregúntale a cuál se refiere y no marques a nadie; \
    'permission_required' = falta el permiso de Contactos, que se concede en Ajustes; \
    'not_found' = no hay nadie con ese nombre en la libreta, pídele el número; \
    'no_phone_number' = el contacto existe pero no tiene teléfono guardado; 'failed' = \
    el sistema no pudo ni abrir el marcador. Si viene 'available_numbers', el contacto \
    tiene varios números y se puso el primero: dile cuál y ofrécele los otros. Nunca \
    afirmes que la llamada está en curso ni que el teléfono está sonando: lo único \
    seguro es que el marcador quedó listo.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "contact_or_number", type: .string, description: "Número de teléfono o nombre del contacto a llamar", required: true)
    ]

    private let manager: any ContactsManaging
    private let aliasStore: ContactAliasStore
    private let urlOpener: any AppURLOpening

    /// `urlOpener` es `AppURLOpening` (asíncrono) y no un cierre sincrónico porque
    /// `run(argsJSON:)` corre fuera del actor principal: tocar `UIApplication` desde ahí
    /// dispara el comprobador de hilo principal y puede terminar en caída.
    public init(
        manager: any ContactsManaging = AppleContactsManager(),
        aliasStore: ContactAliasStore = .shared,
        urlOpener: any AppURLOpening = SystemAppURLOpener()
    ) {
        self.manager = manager
        self.aliasStore = aliasStore
        self.urlOpener = urlOpener
    }

    public func run(argsJSON: String) async -> String {
        guard let input = CreateNoteTool.parseString(named: "contact_or_number", from: argsJSON),
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolJSONOutput.error("Se requiere el argumento 'contact_or_number'.")
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        let number: String
        var contactName: String? = nil
        var availableNumbers: Int? = nil

        if SendMessageTool.looksLikePhoneNumber(trimmed) {
            number = SendMessageTool.normalizeNumber(trimmed)
        } else {
            let resolved = aliasStore.resolve(aliasOrName: trimmed)
            let found: [GemmaContact]
            do {
                found = try await manager.searchContacts(query: resolved)
            } catch {
                // "Falta el permiso" y "falló la búsqueda" se cuentan por separado: el
                // primero lo arregla el usuario desde Ajustes, y antes se devolvía
                // "no se encontró un número", que no deja ver la causa.
                if (error as NSError).code == 403 {
                    return ToolJSONOutput.object([
                        "status": "permission_required",
                        "requested": trimmed,
                        "message": "Gemma necesita permiso para acceder a Contactos. Pídele al usuario que lo conceda en Ajustes."
                    ])
                }
                return ToolJSONOutput.error("No se pudo buscar el contacto '\(trimmed)': \(error.localizedDescription)")
            }

            guard !found.isEmpty else {
                return ToolJSONOutput.object([
                    "status": "not_found",
                    "requested": trimmed,
                    "resolved_as": resolved == trimmed ? nil : resolved,
                    "message": "No se encontró ningún contacto llamado '\(resolved)'. Pregúntale al usuario el número."
                ])
            }

            let withPhones = found.filter { !$0.phoneNumbers.isEmpty }
            guard !withPhones.isEmpty else {
                return ToolJSONOutput.object([
                    "status": "no_phone_number",
                    "requested": trimmed,
                    "contact": found[0].fullName,
                    "message": "'\(found[0].fullName)' no tiene ningún número de teléfono guardado."
                ])
            }
            // Varios homónimos: marcar al equivocado hace que el usuario llame a quien no
            // quería, y eso no se deshace. Se pregunta antes de abrir el marcador.
            guard withPhones.count == 1 else {
                return ToolJSONOutput.object([
                    "status": "ambiguous",
                    "requested": trimmed,
                    "candidates": withPhones.prefix(8).map { contact in
                        ["name": contact.fullName, "number": contact.phoneNumbers[0]]
                    },
                    "message": "Hay varios contactos que encajan con '\(trimmed)'. Pregúntale al usuario a cuál se refiere."
                ])
            }

            let contact = withPhones[0]
            contactName = contact.fullName
            number = SendMessageTool.normalizeNumber(contact.phoneNumbers[0])
            // Solo se menciona cuando hay de verdad una elección que el usuario podría
            // querer corregir: con un único número no hay nada que advertir.
            if contact.phoneNumbers.count > 1 { availableNumbers = contact.phoneNumbers.count }
        }

        // `tel:` sin barras: es un esquema sin componente de autoridad, y así lo
        // documenta Apple.
        guard !number.filter(\.isNumber).isEmpty, let callURL = URL(string: "tel:\(number)") else {
            return ToolJSONOutput.object([
                "status": "failed",
                "requested": trimmed,
                "message": "'\(trimmed)' no es un número de teléfono marcable."
            ])
        }

        let opened = await urlOpener.openURL(callURL)
        let target = contactName ?? number
        return ToolJSONOutput.object([
            "status": opened ? "confirmation_required" : "failed",
            "requires_user_tap": opened ? true : nil,
            "contact": contactName,
            "number": number,
            "available_numbers": availableNumbers,
            "message": opened
                ? "El marcador se abrió con el número de \(target). iOS no deja que una app llame sola: dile al usuario que pulse «Llamar» para que empiece la llamada."
                : "El sistema no pudo abrir el marcador telefónico."
        ])
    }
}
