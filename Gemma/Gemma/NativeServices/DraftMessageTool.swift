import Foundation

/// Rellena una plantilla de mensaje con el nombre del destinatario y la idea.
///
/// Tiene dos arreglos de honestidad respecto a la versión anterior. Uno: un tono que no
/// se entiende ya no se sustituye en silencio por el amistoso, porque eso convertía
/// "escríbele formal a mi abogado" en un saludo de colegas sin que nadie se enterara.
/// Dos: declara que lo que devuelve es una plantilla, no una redacción, para que el
/// modelo la use como punto de partida y no la mande tal cual.
public final class DraftMessageTool: AgentTool, Sendable {
    public static let name = "draft_message"
    public static let description = """
    Rellena una PLANTILLA de mensaje con el nombre del destinatario y la idea, en tono \
    informal, formal o familiar. No es una redacción: es un andamio mecánico, así que \
    puedes y debes reescribirlo con tus propias palabras antes de proponerlo. Pásale \
    'recipient', 'raw_idea' y opcionalmente 'tone' ('formal', 'amigo', 'familia'). Lee \
    'status': 'drafted' = plantilla lista en 'drafted_message'; si 'tone_defaulted' es \
    true el tono lo eligió la herramienta, no el usuario, así que no digas que es el que \
    pidió; 'invalid_tone' = no entendí el tono, no hay borrador, mira 'valid_tones' y \
    vuelve a llamar; 'missing_fields' = falta 'recipient' o 'raw_idea'. Esta herramienta \
    NO envía nada: para enviar, send_message.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "recipient", type: .string, description: "Nombre del destinatario (ej. 'Marcos', 'Lic. Pérez')", required: true),
        AgentToolParam(name: "raw_idea", type: .string, description: "Idea o mensaje bruto a transmitir (ej. 'mañana vamos a pescar')", required: true),
        AgentToolParam(name: "tone", type: .string, description: "Tono: 'amigo'/'friend', 'formal'/'business' o 'familia'/'family'. Si falta se usa el informal", required: false)
    ]

    public init() {}

    public func run(argsJSON: String) async -> String {
        let recipient = CreateNoteTool.parseString(named: "recipient", from: argsJSON)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawIdea = CreateNoteTool.parseString(named: "raw_idea", from: argsJSON)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var missing: [String] = []
        if recipient?.isEmpty != false { missing.append("recipient") }
        if rawIdea?.isEmpty != false { missing.append("raw_idea") }
        guard missing.isEmpty, let recipient, let rawIdea else {
            return ToolJSONOutput.object([
                "status": "missing_fields",
                "required": missing,
                "message": "Faltan datos: \(missing.joined(separator: ", "))."
            ])
        }

        // El tono se valida antes de redactar. Un tono ilegible no produce borrador:
        // devolver uno con otro registro es peor que no devolver nada, porque el modelo
        // no tiene cómo notar la diferencia.
        let rawTone = CreateNoteTool.parseString(named: "tone", from: argsJSON)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let toneDefaulted = (rawTone?.isEmpty ?? true)
        var tone = MessageTone.friend
        if !toneDefaulted {
            guard let parsed = MessageTone.parse(rawTone) else {
                return ToolJSONOutput.object([
                    "status": "invalid_tone",
                    "received": rawTone,
                    "valid_tones": ["amigo", "formal", "familia"],
                    "message": "No entendí el tono «\(rawTone ?? "")». Usa 'amigo', 'formal' o 'familia'. No se redactó nada."
                ])
            }
            tone = parsed
        }

        let drafted = SmartMessageDrafter.draft(
            recipientName: recipient,
            rawIdea: rawIdea,
            tone: tone
        )

        return ToolJSONOutput.object([
            "status": "drafted",
            "recipient": recipient,
            "tone": tone.rawValue,
            "tone_label": tone.spanishName,
            "tone_defaulted": toneDefaulted ? true : nil,
            "is_template": true,
            "drafted_message": drafted,
            "message": toneDefaulted
                ? "Plantilla en tono informal (lo eligió la herramienta, el usuario no pidió tono). Reescríbela con tus palabras antes de proponerla; todavía no se ha enviado nada."
                : "Plantilla en tono \(tone.spanishName). Reescríbela con tus palabras antes de proponerla; todavía no se ha enviado nada."
        ])
    }
}
