import BrainContract
import Foundation

/// Forgets previously remembered facts matching a query. Delegates to the Memory Service.
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
        guard !query.isEmpty else { return "nothing to forget" }
        if let scope = MemoryToolbox.turnScope,
           scope.legacyForgetTarget?.localizedCaseInsensitiveCompare(query) != .orderedSame {
            return "No memory was erased. Specify the exact memory to forget."
        }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: query) }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
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
                    return "Forgot \(total) item(s) matching '\(query)'."
                }

                if MemoryToolbox.turnScope != nil { return "No exact memory was found to erase." }
                let removed = try await mem.forget(label: query, id: nil)
                if removed == 0 {
                    return "No memories found matching '\(query)' to forget."
                }
                return "Forgot \(removed) item(s)."
            } catch { return "memory error: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
