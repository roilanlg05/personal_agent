import Foundation

public final class SendMessageTool: AgentTool, Sendable {
    public static let name = "send_message"
    public static let description = """
    Envía un mensaje de texto a un contacto o a un número. Acepta el nombre del \
    contacto, un parentesco ('mamá', 'mi esposa') o el número directo; resuelve el \
    contacto en la libreta del usuario. Lee 'status': 'sent' = el mensaje salió; \
    'compose_presented' = quedó preparado en la app y el usuario debe pulsar enviar, así \
    que pídeselo; 'cancelled' = lo descartó y NO se envió; 'ambiguous' = varios \
    contactos encajan, pregunta cuál; 'permission_required' = falta permiso de \
    Contactos; 'not_found', 'no_phone_number', 'unavailable' o 'failed'. Nunca afirmes \
    que el mensaje se envió si el estado no es 'sent'.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "to", type: .string, description: "Nombre del contacto, parentesco ('mamá') o número de teléfono", required: true),
        AgentToolParam(name: "message", type: .string, description: "Texto del mensaje a enviar", required: true),
        AgentToolParam(name: "channel", type: .string, description: "'messages' para iMessage/SMS (por defecto) o 'whatsapp'", required: false)
    ]

    private let sender: (any MessageSending)?
    private let contacts: any ContactsManaging
    private let aliases: ContactAliasStore

    public init(
        sender: (any MessageSending)? = MessageSenderFactory.make(),
        contacts: any ContactsManaging = AppleContactsManager(),
        aliases: ContactAliasStore = .shared
    ) {
        self.sender = sender
        self.contacts = contacts
        self.aliases = aliases
    }

    public func run(argsJSON: String) async -> String {
        guard let recipient = CreateNoteTool.parseString(named: "to", from: argsJSON), !recipient.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'to' con el contacto o número de destino.")
        }
        guard let body = CreateNoteTool.parseString(named: "message", from: argsJSON), !body.isEmpty else {
            return ToolJSONOutput.error("Se requiere 'message' con el texto a enviar.")
        }
        let channel = MessageChannel.parse(CreateNoteTool.parseString(named: "channel", from: argsJSON))

        guard let sender else {
            return ToolJSONOutput.object([
                "status": "unavailable",
                "message": "Enviar mensajes no está disponible en este dispositivo."
            ])
        }

        // Resolver el destinatario: número directo o contacto de la libreta.
        let number: String
        var contactName: String? = nil

        if Self.looksLikePhoneNumber(recipient) {
            number = Self.normalizeNumber(recipient)
        } else {
            let resolved = aliases.resolve(aliasOrName: recipient)
            let found: [GemmaContact]
            do {
                found = try await contacts.searchContacts(query: resolved)
            } catch {
                // El acceso denegado y el fallo técnico se cuentan distinto: en el
                // primero el usuario puede arreglarlo desde Ajustes.
                let nsError = error as NSError
                if nsError.code == 403 {
                    return ToolJSONOutput.object([
                        "status": "permission_required",
                        "requested": recipient,
                        "message": "Gemma necesita permiso para acceder a Contactos. Pídele al usuario que lo conceda en Ajustes."
                    ])
                }
                return ToolJSONOutput.error("No se pudo buscar el contacto '\(recipient)': \(error.localizedDescription)")
            }

            let withPhones = found.filter { !$0.phoneNumbers.isEmpty }

            guard !found.isEmpty else {
                return ToolJSONOutput.object([
                    "status": "not_found",
                    "requested": recipient,
                    "resolved_as": resolved,
                    "message": "No se encontró ningún contacto llamado '\(resolved)'. Pregúntale al usuario el número."
                ])
            }
            guard !withPhones.isEmpty else {
                return ToolJSONOutput.object([
                    "status": "no_phone_number",
                    "requested": recipient,
                    "contact": found[0].fullName,
                    "message": "'\(found[0].fullName)' no tiene ningún número de teléfono guardado."
                ])
            }
            // Varios contactos encajan: mandar el mensaje a la persona equivocada no se
            // puede deshacer, así que se pregunta.
            guard withPhones.count == 1 else {
                return ToolJSONOutput.object([
                    "status": "ambiguous",
                    "requested": recipient,
                    "candidates": withPhones.prefix(8).map {
                        ["name": $0.fullName, "number": $0.phoneNumbers.first ?? ""]
                    },
                    "message": "Hay varios contactos que encajan con '\(recipient)'. Pregúntale al usuario a cuál se refiere."
                ])
            }

            let contact = withPhones[0]
            contactName = contact.fullName
            number = Self.normalizeNumber(contact.phoneNumbers[0])
        }

        let result = await sender.send(to: number, body: body, channel: channel)

        return ToolJSONOutput.object([
            "status": result.outcome.rawValue,
            "channel": channel.rawValue,
            "contact": contactName,
            "number": number,
            "error_message": result.errorMessage,
            "message": Self.message(for: result.outcome, channel: channel, recipient: contactName ?? number)
        ])
    }

    static func message(for outcome: MessageSendOutcome, channel: MessageChannel, recipient: String) -> String {
        switch outcome {
        case .sent:
            return "Mensaje enviado a \(recipient)."
        case .composePresented:
            return "El mensaje para \(recipient) está preparado en \(channel.displayName). Dile al usuario que pulse enviar; todavía no ha salido."
        case .cancelled:
            return "El usuario descartó el mensaje para \(recipient). No se envió nada."
        case .unavailable:
            return "\(channel.displayName) no está disponible en este dispositivo."
        case .failed:
            return "No se pudo enviar el mensaje a \(recipient)."
        }
    }

    /// ¿Es lo que escribió el usuario un número y no un nombre?
    static func looksLikePhoneNumber(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber)
        guard digits.count >= 6 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789+()-. ")
        return text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Deja solo dígitos y el prefijo internacional.
    static func normalizeNumber(_ text: String) -> String {
        let hasPlus = text.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        let digits = text.filter(\.isNumber)
        return hasPlus ? "+\(digits)" : digits
    }
}
