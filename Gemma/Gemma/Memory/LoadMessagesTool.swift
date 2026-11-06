import Foundation

/// Drill-down (CAPA 1): dado el `chat_id` y el rango de un resumen episódico, devuelve
/// los mensajes textuales que hay detrás. Es una herramienta de LECTURA: el modelo la
/// llama solo cuando un resumen no trae el detalle que necesita, y lee únicamente ese
/// rango. Delega en `/v1/transcript/range`.
///
/// ## El defecto que tenía
///
/// Su `catch` devolvía literalmente `"no messages found for chat \(chatId)"`. Es decir:
/// si el servicio de memoria estaba caído, el endpoint fallaba o la respuesta no se
/// podía decodificar, la herramienta informaba de que **no había mensajes**. El modelo le
/// decía al usuario que esa conversación no existía o que no quedaba nada de ella, cuando
/// la verdad era «no se pudo consultar». Es «no se pudo saber» disfrazado de «no hay
/// nada», que es justo lo que el contrato de honestidad prohíbe: el usuario tomaba por
/// perdido un trozo de su propio historial.
///
/// Además recortaba la salida con `.prefix(4000)` sin decirlo, así que el modelo creía
/// haber leído el rango completo cuando podía faltarle el final.
struct LoadMessagesTool: AgentTool {
    static let name = "load_messages"
    static let description = """
    Carga los mensajes exactos que hay detrás de un resumen episódico, SOLO cuando el \
    resumen no contiene el detalle que necesitas. Pásale el 'chat_id' y el rango \
    ('from'/'to') que aparecen junto al resumen. Lee solo ese rango, nunca un chat \
    entero. Lee 'status': 'ok' = los mensajes vienen en 'messages'; 'empty' = ese rango \
    de ese chat no tiene mensajes (el rango está mal o se borraron), pide el rango \
    correcto; 'memory_unavailable' o 'failed' = NO se pudo consultar el historial, que no \
    es lo mismo que no haber mensajes — dile al usuario que no pudiste leer esa parte de \
    la conversación, nunca que no existe; 'missing_fields' = falta 'chat_id' o 'from'. Si \
    viene 'truncated': true, el rango no cabía entero: pide un rango más estrecho.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "chat_id", type: .string, description: "The chat id shown with the summary, e.g. \"g7y\".", required: true),
        AgentToolParam(name: "from", type: .integer, description: "First message number (seq) of the range.", required: true),
        AgentToolParam(name: "to", type: .integer, description: "Last message number (seq); omit for a single message.", required: false),
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let chatId = ((obj["chat_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let from = (obj["from"] as? Int) ?? (obj["from"] as? Double).map(Int.init) ?? (obj["from"] as? String).flatMap { Int($0) } ?? 0
        let to = (obj["to"] as? Int) ?? (obj["to"] as? Double).map(Int.init) ?? (obj["to"] as? String).flatMap { Int($0) }

        // Los mensajes se numeran desde 1 (la columna `seq` del servidor), así que un
        // `from` de 0 o negativo es un argumento mal puesto, no el principio del chat.
        var missing: [String] = []
        if chatId.isEmpty { missing.append("chat_id") }
        if from <= 0 { missing.append("from") }
        guard missing.isEmpty else {
            return ToolJSONOutput.object([
                "status": "missing_fields",
                "required": missing,
                "received": ["chat_id": chatId, "from": from],
                "message": "Faltan estos argumentos: \(missing.joined(separator: ", ")). Son el 'chat_id' y el número del primer mensaje que vienen junto al resumen; los mensajes se numeran desde 1."
            ])
        }

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "\(chatId):\(from)-\(to ?? from)") }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else {
                return MemoryQuerySupport.memoryUnavailable("leer los mensajes del chat \(chatId)")
            }
            do {
                let r = try await mem.loadMessages(chatId: chatId, from: from, to: to)
                let (shown, capWarning) = MemoryQuerySupport.cap(
                    r.messages, to: MemoryQuerySupport.Caps.messages, noun: "mensajes"
                )
                var warnings: [String] = []
                if let capWarning { warnings.append(capWarning) }
                if r.truncated {
                    warnings.append("El servidor recortó el rango: hay más mensajes de los que se devolvieron. Pide un rango más estrecho si necesitas el resto.")
                }
                return ToolJSONOutput.object([
                    "status": r.messages.isEmpty ? "empty" : "ok",
                    "chat_id": chatId,
                    "from": from,
                    "to": to ?? from,
                    "count": shown.count,
                    "messages": shown.map { ["seq": $0.seq, "role": $0.role, "text": $0.text] },
                    "truncated": (r.truncated || capWarning != nil) ? true : nil,
                    "warnings": warnings.isEmpty ? nil : warnings,
                    "message": r.messages.isEmpty
                        ? "El chat \(chatId) no tiene mensajes entre \(from) y \(to ?? from). Comprueba el rango que venía con el resumen; no supongas que la conversación se perdió."
                        : "\(shown.count) mensaje(s) del chat \(chatId)."
                ])
            } catch {
                // Antes esto devolvía "no messages found for chat X": un fallo de red o de
                // servidor se le contaba al usuario como un trozo de su historial que no
                // existía.
                return ToolJSONOutput.object([
                    "status": "failed",
                    "chat_id": chatId,
                    "from": from,
                    "to": to ?? from,
                    "message": "No se pudo leer el historial del chat \(chatId): \(error.localizedDescription). Dile al usuario que no pudiste consultar esa parte de la conversación; NO le digas que no hay mensajes ni que se perdió."
                ])
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
