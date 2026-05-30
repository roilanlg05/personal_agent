import Foundation

/// Saves a durable fact the user shared. Parses args from the model's JSON object.
struct RememberTool: AgentTool {
    static let name = "remember"
    static let description = "Save a durable fact about the user (preference, person, place, routine, etc.) to long-term memory."
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "content", type: .string, description: "The fact to remember, as a short canonical phrase.", required: true),
        AgentToolParam(name: "kind", type: .string, description: "Category: one of person, place, fact, preference, topic.", required: false),
        AgentToolParam(name: "permanent", type: .boolean, description: "Set true to remember permanently (identity).", required: false),
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let content = ((obj["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = (obj["kind"] as? String) ?? "fact"
        let permanent = (obj["permanent"] as? Bool) ?? false
        guard !content.isEmpty else { return "nothing to remember" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: content) }
        let result: String = await MainActor.run {
            guard let store = MemoryToolbox.shared.store else { return "memory unavailable" }
            let now = Date().timeIntervalSince1970
            let layer: MemoryLayer = permanent ? .identity : .daily
            let k = NodeKind(rawValue: kind) ?? .fact
            let label = MemoryText.cleanLabel(content)
            let canonicalLabel = label.isEmpty ? content : label
            let node = Node(id: UUID().uuidString, kind: k, label: canonicalLabel, body: content, layer: layer,
                            createdAt: now, updatedAt: now, lastSeenAt: now, salience: permanent ? 8 : 3,
                            decayRate: Decay.defaultDecayRate(for: layer), confidence: .sure, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil,
                            dirty: true, deleted: false, extra: nil)
            do {
                let id = try store.upsertMerging(node)
                if let emb = MemoryToolbox.shared.embedder, let v = try? emb.embed(canonicalLabel) {
                    try? store.setEmbedding(nodeId: id, v)
                }
                return "Saved to memory: \(content)"
            } catch { return "memory error: \(error)" }
        }
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
