import Foundation

/// Drill-down (N4): given a topic the model already knows from a summary, return the verbatim
/// chat turns behind it. A READ tool — fires only when the user asks for specifics the summary
/// doesn't carry. Delegates to the Memory Service's `/v1/memory/expand` endpoint.
struct ExpandContextTool: AgentTool {
    static let name = "expand_context"
    static let description = """
    Retrieve the exact past messages behind a remembered topic, when the user asks for specific \
    details a summary doesn't contain (e.g. "what exactly did I say about X"). Pass the topic.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "topic", type: .string, description: "The topic/summary to expand into verbatim past messages.", required: true)
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let topic = ((obj["topic"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return "no topic given" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: topic) }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
            do {
                let r = try await mem.expand(topic: topic)
                guard !r.transcript.isEmpty else { return "no detail found for \"\(topic)\"" }
                let lines = r.transcript.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
                return String(lines.joined(separator: "\n").prefix(4000))
            } catch { return "no detail found for \"\(topic)\"" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
