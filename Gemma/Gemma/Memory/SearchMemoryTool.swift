import Foundation

/// Explicit search tool for long-term memory, past conversations, and recorded facts.
/// The model calls this when the user says "búscalo en tu memoria", "recuerda lo que hablamos",
/// or asks about specific past details.
struct SearchMemoryTool: AgentTool {
    static let name = "search_memory"
    static let description = "Search long-term memory, past conversations, facts, places, and plans by keyword or query. Call this when asked to search or verify details from memory."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "query", type: .string, description: "Keywords or topic to search (e.g. \"banco\", \"Louisville\", \"viaje Cuba\").", required: true),
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let query = ((obj["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "need a search query" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: query) }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
            do {
                let bundle = try await mem.recall(query: query)
                var sections: [String] = []

                if !bundle.summaries.isEmpty {
                    let sumLines = bundle.summaries.map { s in
                        let r = s.messageRange.count >= 2 ? "\(s.messageRange[0])-\(s.messageRange[1])" : "\(s.messageRange.first ?? 0)"
                        return "• [Chat: \(s.chatId) | Turnos: \(r)]: \(s.text)"
                    }
                    sections.append("RESÚMENES ENCONTRADOS (si necesitas el diálogo exacto, llama a load_messages(chat_id, from, to) para ese rango):\n" + sumLines.joined(separator: "\n"))
                }

                let facts = (bundle.recall + bundle.core).filter { $0.kind != "self" && $0.kind != "summary" }
                if !facts.isEmpty {
                    let factLines = facts.map { "- [\($0.kind)] \($0.label): \($0.body.isEmpty ? $0.label : $0.body)" }
                    sections.append("HECHOS Y DATOS RECORDADOS:\n" + factLines.joined(separator: "\n"))
                }

                if !bundle.recentTurns.isEmpty {
                    let turnLines = bundle.recentTurns.prefix(4).map { "- \($0.role): \($0.text)" }
                    sections.append("TURNOS DE CHAT RELACIONADOS:\n" + turnLines.joined(separator: "\n"))
                }

                if sections.isEmpty {
                    return "No specific memories found matching \"\(query)\"."
                }
                return sections.joined(separator: "\n\n")
            } catch {
                return "memory search error: \(error)"
            }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
