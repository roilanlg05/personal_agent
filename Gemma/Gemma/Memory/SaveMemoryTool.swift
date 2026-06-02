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
        let entity = Self.cleanLabel(rawEntity)
        guard !entity.isEmpty, !Self.isJunkLabel(entity) else { return "nothing to save" }

        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: entity) }
        let kind = kindRaw.isEmpty ? "fact" : kindRaw
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

    // Light client-side guard so the tool short-circuits before the HTTP roundtrip when the
    // model emits a sentence/filler instead of a canonical entity. The service does its own
    // canonicalization, but this avoids burning a network call on obvious junk.
    private static let likePrefixes = [
        "me gustan ", "me gusta ", "le gusta ", "les gusta ",
        "i like ", "i love ", "likes ", "i prefer ", "my "
    ]
    private static let articlePrefixes = ["el ", "la ", "los ", "las ", "the ", "un ", "una ", "unos ", "unas "]

    static func cleanLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,;:!¡¿?()[]"))
        var changed = true
        while changed {
            changed = false
            let lower = s.lowercased()
            for p in likePrefixes + articlePrefixes where lower.hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return s
    }

    static func isJunkLabel(_ raw: String) -> Bool {
        let k = cleanLabel(raw).lowercased()
        if k.isEmpty { return true }
        let junk: Set<String> = [
            "me gusta", "me gustan", "le gusta", "i like", "like", "likes", "gusta",
            "preferences", "preferencias", "preference", "stuff", "things", "cosas",
            "it", "that", "this", "eso", "esto", "user", "usuario"
        ]
        return junk.contains(k)
    }
}
