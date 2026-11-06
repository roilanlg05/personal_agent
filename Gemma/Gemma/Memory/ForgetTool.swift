import Foundation

/// Forgets previously remembered facts matching a query. Delegates to the Memory Service.
struct ForgetTool: AgentTool {
    static let name = "forget"
    static let description = "Forget previously remembered facts that match the given keywords."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "query", type: .string, description: "Keywords describing what to forget.", required: true)
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let query = ((obj["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "nothing to forget" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: query) }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
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
                    return "Forgot \(total) item(s) matching '\(query)'."
                }

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
