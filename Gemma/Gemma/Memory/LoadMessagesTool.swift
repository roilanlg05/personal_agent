import Foundation

/// Drill-down (CAPA 1): given a summary's refs (chat_id + message range), return the verbatim
/// chat messages behind it. A READ tool — the model calls it ONLY when a summary lacks the
/// detail it needs, reading just that range. Delegates to `/v1/transcript/range`.
struct LoadMessagesTool: AgentTool {
    static let name = "load_messages"
    static let description = """
    Load the exact past messages behind an episodic summary, ONLY when a summary doesn't contain \
    the detail you need. Pass the summary's chat_id and the message range (from/to) shown next to it. \
    Read just that range — never a whole chat.
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
        guard !chatId.isEmpty, from > 0 else { return "need chat_id and from" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "\(chatId):\(from)-\(to ?? from)") }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
            do {
                let r = try await mem.loadMessages(chatId: chatId, from: from, to: to)
                guard !r.messages.isEmpty else { return "no messages found for chat \(chatId) range \(from)-\(to ?? from)" }
                let lines = r.messages.map { "\($0.role == "assistant" ? "Gemma" : "User"): \($0.text)" }
                let body = lines.joined(separator: "\n")
                return String((r.truncated ? body + "\n…(truncated — narrow the range for more)" : body).prefix(4000))
            } catch { return "no messages found for chat \(chatId)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
