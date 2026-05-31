import Foundation

/// Saves a durable fact the user stated about themselves. Structured (canonical `entity` +
/// optional `detail`) so the model gives a clean anchor; writes synchronously with semantic
/// dedup. Replaces the free-phrase RememberTool.
struct SaveMemoryTool: AgentTool {
    static let name = "save_memory"
    static let description = """
    Save a durable fact the USER stated about THEMSELVES (a preference, a person, a place, or a \
    personal fact). Only call this for things the user affirmed about themselves — NEVER for a \
    question they asked, NEVER for facts about you/the assistant or the current time, and NEVER \
    guess. Use a short canonical `entity` (e.g. "sushi", "Juan", "Madrid"), not a sentence.
    """
    static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "entity", type: .string, description: "Short canonical noun/name to remember, e.g. \"sushi\", \"Juan\". Not a sentence.", required: true),
        AgentToolParam(name: "detail", type: .string, description: "Optional free context, e.g. \"likes it a lot\", \"friend, works with the user\".", required: false),
        AgentToolParam(name: "kind", type: .string, description: "One of: person, place, preference, fact.", required: false),
        AgentToolParam(name: "permanent", type: .boolean, description: "true if this is permanent identity (name, lifelong facts).", required: false),
    ]

    func run(argsJSON: String) async -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        let rawEntity = ((obj["entity"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (obj["detail"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let kind = (obj["kind"] as? String) ?? "fact"
        let permanent = (obj["permanent"] as? Bool) ?? false
        let entity = MemoryText.cleanLabel(rawEntity)
        guard !entity.isEmpty, !MemoryText.isJunkLabel(entity) else { return "nothing to save" }

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: entity) }
        let result: String = await MainActor.run {
            guard let store = MemoryToolbox.shared.store else { return "memory unavailable" }
            let now = Date().timeIntervalSince1970
            let layer: MemoryLayer = permanent ? .identity : .daily
            let k = NodeKind(rawValue: kind) ?? .fact
            let body = (detail?.isEmpty == false) ? detail! : entity
            let node = Node(id: UUID().uuidString, kind: k, label: entity, body: body, layer: layer,
                            createdAt: now, updatedAt: now, lastSeenAt: now, salience: permanent ? 8 : 3,
                            decayRate: Decay.defaultDecayRate(for: layer), confidence: .sure, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil,
                            dirty: true, deleted: false, extra: nil)
            let embedder = MemoryToolbox.shared.embedder
            let embedding = (try? embedder?.embed(entity)) ?? nil
            do {
                _ = try store.upsertMergingSemantic(node, embedding: embedding, embedder: embedder)
                return "Saved: \(entity)"
            } catch { return "memory error: \(error)" }
        }
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
