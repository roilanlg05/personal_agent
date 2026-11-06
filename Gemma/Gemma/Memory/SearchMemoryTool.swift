import Foundation

/// Búsqueda explícita en la memoria a largo plazo: conversaciones pasadas, hechos,
/// lugares y planes. El modelo la llama cuando el usuario dice «búscalo en tu memoria»,
/// «recuerda lo que hablamos» o pregunta por un detalle concreto del pasado.
///
/// ## El agujero que tenía
///
/// `MemoryClient.recall` se traga los 5xx y los `URLError` y devuelve un paquete
/// **vacío** a propósito: así el agente sigue conversando aunque la memoria se haya
/// caído, simplemente sin inyectar nada. Para la inyección automática eso está bien,
/// pero esta herramienta heredaba ese silencio: con el servicio caído recibía un paquete
/// vacío, indistinguible de «no hay nada», y contestaba
/// `No specific memories found matching "banco"`. El usuario oía que Gemma no recordaba
/// nada de él cuando lo único que pasaba era que el servidor no respondía.
///
/// Por eso usa `recallStrict`, que sí propaga el fallo: quien pregunta a propósito tiene
/// derecho a saber que no se pudo mirar. Y por eso devuelve JSON con `status` en vez de
/// prosa, y declara los recortes en vez de aplicarlos en silencio.
struct SearchMemoryTool: AgentTool {
    static let name = "search_memory"
    static let description = """
    Busca en la memoria a largo plazo: conversaciones pasadas, hechos, lugares y planes. \
    Llámala cuando te pidan buscar o verificar un detalle de la memoria. Lee 'status': \
    'ok' = hay resultados en 'facts' (hechos recordados), 'summaries' (resúmenes de \
    conversaciones; si necesitas el diálogo exacto de uno, llama a load_messages con su \
    'chat_id', 'from' y 'to') y 'recent_turns'; 'empty' = se buscó y NO hay nada que \
    encaje, dilo tal cual; 'memory_unavailable' o 'failed' = la memoria no se pudo \
    consultar, que NO es lo mismo que estar vacía — dile al usuario que no pudiste \
    buscar, nunca que no recuerdas nada de eso; 'missing_fields' = falta la consulta. Si \
    viene 'truncated': true, hay más de lo que ves.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "query", type: .string, description: "Keywords or topic to search (e.g. \"banco\", \"Louisville\", \"viaje Cuba\").", required: true),
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let query = ((obj["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return MemoryQuerySupport.missingField("query", "qué hay que buscar en la memoria")
        }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: query) }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else {
                return MemoryQuerySupport.memoryUnavailable("buscar «\(query)» en la memoria")
            }
            let bundle: MemoryClient.RecallBundle
            do {
                bundle = try await mem.recallStrict(query: query)
            } catch {
                // Deliberadamente `memory_unavailable` y no `empty`: el caso que rompió la
                // confianza del usuario es justo este, un fallo contado como ausencia.
                return ToolJSONOutput.object([
                    "status": "memory_unavailable",
                    "query": query,
                    "message": "No se pudo buscar en la memoria: \(error.localizedDescription). Dile al usuario que no pudiste consultar tu memoria; NO le digas que no recuerdas nada de eso."
                ])
            }

            var warnings: [String] = []

            let allFacts = (bundle.recall + bundle.core).filter { $0.kind != "self" && $0.kind != "summary" }
            let (facts, factsWarning) = MemoryQuerySupport.cap(
                allFacts, to: MemoryQuerySupport.Caps.facts, noun: "hechos"
            )
            if let factsWarning { warnings.append(factsWarning) }

            let (summaries, summariesWarning) = MemoryQuerySupport.cap(
                bundle.summaries, to: MemoryQuerySupport.Caps.summaries, noun: "resúmenes"
            )
            if let summariesWarning { warnings.append(summariesWarning) }

            // Antes se quedaba con `.prefix(4)` sin decirlo.
            let (turns, turnsWarning) = MemoryQuerySupport.cap(
                bundle.recentTurns, to: MemoryQuerySupport.Caps.recentTurns, noun: "turnos de chat"
            )
            if let turnsWarning { warnings.append(turnsWarning) }

            let isEmpty = allFacts.isEmpty && bundle.summaries.isEmpty && bundle.recentTurns.isEmpty
            return ToolJSONOutput.object([
                "status": isEmpty ? "empty" : "ok",
                "query": query,
                "facts": facts.map {
                    ([
                        "kind": $0.kind,
                        "label": $0.label,
                        "detail": $0.body.isEmpty || $0.body == $0.label ? nil : $0.body,
                        "tags": $0.tags.isEmpty ? nil : $0.tags
                    ] as [String: Any?]).compactMapValues { $0 }
                },
                "summaries": summaries.map { s in
                    ([
                        "summary_id": s.summaryId,
                        "chat_id": s.chatId,
                        "from": s.messageRange.first,
                        "to": s.messageRange.count >= 2 ? s.messageRange[1] : s.messageRange.first,
                        "text": s.text
                    ] as [String: Any?]).compactMapValues { $0 }
                },
                "recent_turns": turns.map { ["role": $0.role, "text": $0.text] },
                "truncated": warnings.isEmpty ? nil : true,
                "warnings": warnings.isEmpty ? nil : warnings,
                "message": isEmpty
                    ? "Se buscó «\(query)» en la memoria y no hay nada que encaje. Dilo tal cual: se buscó y no hay, no que no se pudiera mirar."
                    : "\(allFacts.count) hecho(s), \(bundle.summaries.count) resumen(es) y \(bundle.recentTurns.count) turno(s) relacionados con «\(query)»."
            ])
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
