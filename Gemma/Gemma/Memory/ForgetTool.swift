import Foundation

/// Forgets previously remembered facts matching a query. Delegates to the Memory Service.
///
/// HABLA EL CONTRATO `status`, Y ANTES NO. Contestaba en prosa («Forgot 3 item(s) matching
/// 'x'.»), que no es un objeto JSON, así que la fila del chat la pintaba con CRUZ ROJA: el
/// usuario pedía olvidar algo, se olvidaba de verdad, y lo que leía era que había fallado. Lo
/// mismo por el otro lado del bucle: su éxito no reiniciaba el presupuesto de fallos, y hubo que
/// parchear `Agent.reiniciaElPresupuesto` para que aceptara la prosa, con el precio de que un
/// FALLO en prosa («memory unavailable») también reiniciara. Los estados son los que ya usan sus
/// hermanas del registro; ninguno es nuevo.
struct ForgetTool: AgentTool {
    static let name = "forget"
    static let description = """
    Forget previously remembered facts that match the given keywords. Read 'status': \
    'success' = forgotten, 'forgotten_count' says how many; 'not_found' = nothing matched, so \
    NOTHING was forgotten — say exactly that, never that you forgot it; 'missing_fields' = no \
    query was given; 'memory_unavailable' or 'failed' = nothing was forgotten, tell the user it \
    is still remembered.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "query", type: .string, description: "Keywords describing what to forget.", required: true)
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let query = ((obj["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ToolJSONOutput.object([
                "status": "missing_fields",
                "required": ["query"],
                "message": "Falta 'query' con las palabras de lo que hay que olvidar. Pregúntale al usuario qué quiere que olvides; no te lo inventes."
            ])
        }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: query) }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else {
                return ToolJSONOutput.object([
                    "status": "memory_unavailable",
                    "query": query,
                    "message": "La memoria de Gemma no está disponible ahora mismo, así que NO se olvidó nada. Dile al usuario que sigue recordándolo."
                ])
            }
            do {
                let list = try? await mem.nodes(limit: 100, offset: 0, kind: nil)
                let needle = query.lowercased()
                let matchingNodes = list?.nodes.filter {
                    $0.label.lowercased().contains(needle) ||
                    $0.body.lowercased().contains(needle) ||
                    needle.contains($0.label.lowercased())
                } ?? []

                if !matchingNodes.isEmpty {
                    var total = 0
                    for node in matchingNodes {
                        _ = try await mem.forget(label: nil, id: node.id)
                        total += 1
                    }
                    return Self.forgotten(total, query: query)
                }

                let removed = try await mem.forget(label: query, id: nil)
                guard removed > 0 else {
                    // NO es un éxito. El usuario pidió olvidar algo que no estaba, así que no se
                    // hizo nada: decirle «listo» es hacerle creer que pasó algo.
                    return ToolJSONOutput.object([
                        "status": "not_found",
                        "query": query,
                        "forgotten_count": 0,
                        "message": "No hay ningún recuerdo que encaje con «\(query)», así que no se olvidó nada. Dilo tal cual."
                    ])
                }
                return Self.forgotten(removed, query: query)
            } catch {
                return ToolJSONOutput.object([
                    "status": "failed",
                    "query": query,
                    "message": "No se pudo olvidar: \(error.localizedDescription). Dile al usuario que sigue recordándolo."
                ])
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }

    /// CUÁNTOS SE OLVIDARON VA EN UNA CLAVE, NO DENTRO DE UNA FRASE. Era la propiedad que la
    /// prueba vieja protegía con un `contains("3")` sobre «Forgot 3 item(s)»: lo que importa es
    /// que el número llegue, y en `forgotten_count` el modelo lo lee sin interpretar prosa.
    private static func forgotten(_ count: Int, query: String) -> String {
        ToolJSONOutput.object([
            "status": "success",
            "query": query,
            "forgotten_count": count,
            "message": "Olvidado(s) \(count) recuerdo(s) que encajaban con «\(query)»."
        ])
    }
}
