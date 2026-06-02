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
                let removed = try await mem.forget(label: query, id: nil)
                return "Forgot \(removed) item(s)."
            } catch { return "memory error: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
