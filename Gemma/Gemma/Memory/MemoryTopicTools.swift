import Foundation

/// List the thematic topics (tags) the assistant has memories about.
struct ListTopicsTool: AgentTool {
    static let name = "list_topics"
    static let description = "List the topics/themes you have memories about (e.g. when the user asks what you know about them). No arguments."
    static let parameters: [AgentToolParam] = []
    func run(argsJSON: String) async -> String {
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: "") }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
            do {
                let tags = try await mem.memoryTags()
                return tags.isEmpty ? "no topics yet" : String(("Topics: " + tags.joined(separator: ", ")).prefix(2000))
            } catch { return "memory unavailable" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// Complete enumeration of what the assistant remembers about ONE topic (tag-filtered).
struct RecallByTopicTool: AgentTool {
    static let name = "recall_by_topic"
    static let description = """
    Return EVERYTHING you remember about one topic/theme (e.g. "finanzas", "trabajo", "salud"), \
    not just what you already see. Use it when the user asks for all you know about a subject.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "topic", type: .string, description: "The topic/theme to enumerate, e.g. \"finanzas\".", required: true),
    ]
    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let topic = ((obj["topic"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return "need a topic" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: topic) }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
            do {
                let r = try await mem.recallByTopic(topic: topic)
                guard !r.nodes.isEmpty else { return "nothing remembered about \"\(topic)\"" }
                let lines = r.nodes.map { "- [\($0.kind)] \($0.label): \($0.body.isEmpty ? $0.label : $0.body)" }
                return String(("About \(r.tag):\n" + lines.joined(separator: "\n")).prefix(4000))
            } catch { return "memory unavailable" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}

/// Justify a belief: trace an insight back to the source memories it derives from.
struct WhyTool: AgentTool {
    static let name = "why"
    static let description = """
    Explain WHY you believe something about the user, by tracing it to the source memories. \
    Use it when the user asks why you think that or what you're basing it on. Pass the belief/claim. \
    Cite the sources it returns; don't invent a justification.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "claim", type: .string, description: "The belief/claim to justify, e.g. \"the user trades options\".", required: true),
    ]
    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let claim = ((obj["claim"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claim.isEmpty else { return "need a claim" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: claim) }
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
            do {
                let r = try await mem.why(claim: claim)
                guard !r.insight.isEmpty else { return "I can't trace that to a specific memory" }
                guard !r.sources.isEmpty else { return "I believe \"\(r.insight)\" but have no recorded sources" }
                let src = r.sources.map { $0.label }.joined(separator: ", ")
                return String("I believe \"\(r.insight)\" because of: \(src)".prefix(2000))
            } catch { return "memory unavailable" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
