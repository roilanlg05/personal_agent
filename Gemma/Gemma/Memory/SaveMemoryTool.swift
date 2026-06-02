import Foundation

/// Saves a durable fact the user stated about themselves. Structured (canonical `entity` +
/// optional `detail`) so the model gives a clean anchor; writes through the Memory Service
/// (HTTP). Replaces the free-phrase RememberTool.
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
        let kindRaw = (obj["kind"] as? String) ?? "fact"
        let permanent = (obj["permanent"] as? Bool) ?? false
        let entity = MemoryText.cleanLabel(rawEntity)
        guard !entity.isEmpty, !MemoryText.isJunkLabel(entity) else { return "nothing to save" }

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: entity) }
        let kind = kindRaw.isEmpty ? NodeKind.fact.rawValue : kindRaw
        let body = (detail?.isEmpty == false) ? detail! : entity
        // Pass permanence as an `extra` JSON hint so the service can decide identity vs daily layer.
        let extra: String? = permanent ? #"{"permanent":true}"# : nil
        let result: String = await {
            guard let mem = await MemoryToolbox.shared.memory else { return "memory unavailable" }
            do {
                let r = try await mem.save(kind: kind, label: entity, body: body, extra: extra, sourceRef: nil)
                return r.mergedInto != nil ? "Saved: \(entity)" : "Saved: \(entity)"
            } catch { return "memory error: \(error)" }
        }()
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
