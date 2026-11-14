import BrainContract
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
    static let description = "When explicitly asked, forget an authorized exact source by ID, or use keywords on a legacy memory service."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "query", type: .string, description: "Legacy service keywords.", required: false),
        AgentToolParam(name: "evidence_id", type: .string, description: "Exact authorized source ID.", required: false)
    ]

    static func requestedTarget(in prompt: String) -> String? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return ["olvida ", "olvidate de ", "borra de tu memoria ", "forget ", "please forget ", "delete from memory "]
            .first { normalized.hasPrefix($0) }.map { String(text.dropFirst($0.count)) }
    }

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        if let scope = MemoryToolbox.turnScope, let revision = scope.revision {
            let id = (obj["evidence_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard scope.authorizedForgetID == id, let client = scope.client else {
                return "No memory was erased. Select the exact authorized source to forget."
            }
            let request = BrainForgetRequest(clientOperationID: UUID().uuidString, expectedRevision: revision,
                                             scope: .init(kind: .evidence, id: id), threadID: scope.threadID)
            do {
                let receipt = try await client.forgetEvidence(request)
                guard receipt.state == .committed, receipt.clientOperationID == request.clientOperationID,
                      receipt.scope == request.scope, receipt.revision > revision,
                      receipt.forgottenEvidenceIDs.contains(id) else { return "Erasure was not confirmed." }
                await scope.erasure.confirm()
                return "Forgot the authorized source."
            } catch { return "Erasure was not confirmed." }
        }
        let query = ((obj["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ToolJSONOutput.object([
                "status": "missing_fields",
                "required": ["query"],
                "message": "Falta 'query' con las palabras de lo que hay que olvidar. Pregúntale al usuario qué quiere que olvides; no te lo inventes."
            ])
        }
        if let scope = MemoryToolbox.turnScope,
           scope.legacyForgetTarget?.localizedCaseInsensitiveCompare(query) != .orderedSame {
            return "No memory was erased. Specify the exact memory to forget."
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
                    if MemoryToolbox.turnScope != nil {
                        return $0.label.localizedCaseInsensitiveCompare(query) == .orderedSame
                    }
                    return $0.label.lowercased().contains(needle) ||
                    $0.body.lowercased().contains(needle) ||
                    needle.contains($0.label.lowercased())
                } ?? []

                if !matchingNodes.isEmpty {
                    var total = 0
                    for node in matchingNodes {
                        if try await mem.forget(label: nil, id: node.id) > 0 {
                            await MemoryToolbox.turnScope?.erasure.confirm()
                            total += 1
                        }
                    }
                    if total > 0 { return Self.forgotten(total, query: query) }
                }

                if MemoryToolbox.turnScope != nil { return "No exact memory was found to erase." }
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
