import Foundation

/// Drill-down (N4): given a topic the model already knows from a summary, return the verbatim
/// chat turns behind it. A READ tool — fires only when the user asks for specifics the summary
/// doesn't carry. Resolves the topic to a `summary` node, reads its threadId + turnRange, and
/// returns the raw turns from the TranscriptStore (capped).
struct ExpandContextTool: AgentTool {
    static let name = "expand_context"
    static let description = """
    Retrieve the exact past messages behind a remembered topic, when the user asks for specific \
    details a summary doesn't contain (e.g. "what exactly did I say about X"). Pass the topic.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "topic", type: .string, description: "The topic/summary to expand into verbatim past messages.", required: true)
    ]

    private struct Ref: Decodable { let threadId: String?; let turnRange: [Int]? }

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let topic = ((obj["topic"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return "no topic given" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: topic) }
        let result: String = await MainActor.run {
            guard let store = MemoryToolbox.shared.store, let ts = MemoryToolbox.shared.transcriptStore else {
                return "memory unavailable"
            }
            let key = MemoryText.dedupKey(topic)
            let summaries = ((try? store.allNodes()) ?? []).filter { $0.kind == NodeKind.summary.rawValue }
            let match = (try? store.searchFTS(query: topic, limit: 10))?.first { $0.kind == NodeKind.summary.rawValue }
                ?? summaries.first { MemoryText.dedupKey($0.label) == key }
                ?? summaries.first { $0.label.localizedCaseInsensitiveContains(topic) }
            guard let node = match, let raw = node.extra?.data(using: .utf8),
                  let ref = try? JSONDecoder().decode(Ref.self, from: raw),
                  let threadId = ref.threadId, let tr = ref.turnRange, tr.count == 2 else {
                return "no detail found for \"\(topic)\""
            }
            let rows = (try? ts.range(threadId: threadId, fromTurn: tr[0], toTurn: tr[1])) ?? []
            guard !rows.isEmpty else { return "no detail found for \"\(topic)\"" }
            let lines = rows.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
            return String(lines.joined(separator: "\n").prefix(4000))
        }
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
