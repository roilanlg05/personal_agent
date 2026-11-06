import Foundation

public enum MessageTone: String, Codable, Sendable, CaseIterable {
    case friend
    case business
    case family

    /// Traduce lo que escriba el modelo al tono correspondiente, o devuelve `nil`.
    ///
    /// Devolver `nil` en vez de caer a `.friend` es deliberado. Antes, cualquier palabra
    /// que no fuera exactamente 'friend', 'business' o 'family' se convertía en silencio
    /// en amistosa: el usuario pedía un mensaje formal para su abogado, recibía un saludo
    /// de colegas, y el modelo no tenía forma de saber que su tono se había descartado.
    public static func parse(_ raw: String?) -> MessageTone? {
        guard let raw else { return nil }
        let key = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !key.isEmpty else { return nil }

        switch key {
        case "friend", "amigo", "amiga", "amistoso", "informal", "colega", "casual":
            return .friend
        case "business", "formal", "trabajo", "negocios", "profesional", "laboral", "serio", "usted":
            return .business
        case "family", "familia", "familiar", "carinoso", "calido":
            return .family
        default:
            return nil
        }
    }

    /// Nombre del tono en español, para explicárselo al usuario.
    public var spanishName: String {
        switch self {
        case .friend: return "informal"
        case .business: return "formal"
        case .family: return "familiar"
        }
    }
}

public struct SmartMessageDrafter: Sendable {

    /// Rellena una plantilla con el nombre y la idea.
    ///
    /// Es un relleno mecánico, no una redacción: quien decide las palabras finales es el
    /// modelo que conduce a Gemma. La plantilla amistosa evita a propósito jerga de
    /// ninguna región (traía "¡Qué onda!", mexicano, para un usuario cubano): una
    /// plantilla no puede elegirle el registro al usuario.
    public static func draft(recipientName: String, rawIdea: String, tone: MessageTone = .friend) -> String {
        let trimmedName = recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? "Hola" : trimmedName
        let cleanIdea = rawIdea.trimmingCharacters(in: .whitespacesAndNewlines)

        switch tone {
        case .friend:
            return "¡Hola \(name)! Oye, \(cleanIdea). Avísame qué tal para alistar todo."
        case .business:
            return "Estimado/a \(name), espero se encuentre muy bien. Le escribo respecto a lo siguiente: \(cleanIdea). Quedo atento a su confirmación y comentarios. Saludos cordiales."
        case .family:
            return "¡Hola \(name)! ¿Cómo estás? Te escribía para lo siguiente: \(cleanIdea). ¡Te mando un fuerte abrazo!"
        }
    }
}
