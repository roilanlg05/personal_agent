import Foundation

/// Optional structured attributes for a memory node, stored as JSON in `Node.extra`.
/// `task` uses `status` (pending|done); `plan` uses `horizon` (short|long). Extensible:
/// unknown keys are ignored. (Episode metadata uses its own `EpisodeRecorder.Meta` JSON; a
/// node is either an episode or a structured fact, so the two never share one `extra`.)
struct NodeAttributes: Codable {
    var status: String?     // task: "pending" | "done"
    var horizon: String?    // plan: "short" | "long"

    func toJSON() -> String? {
        guard status != nil || horizon != nil else { return nil }
        return (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func from(_ extra: String?) -> NodeAttributes {
        guard let s = extra, let d = s.data(using: .utf8),
              let a = try? JSONDecoder().decode(NodeAttributes.self, from: d) else { return NodeAttributes() }
        return a
    }
}
