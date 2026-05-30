import Foundation
import LiteRTLM

/// Explicit-capture tool: the model calls this to save a durable fact the user shared.
/// Reads the active store/embedder from MemoryToolbox.shared (tools are reconstructed via
/// init() by LiteRT-LM). Emits activity through ToolActivityRelay.shared, like CurrentTimeTool.
struct RememberTool: Tool {
    static let name = "remember"
    static let description = "Save a durable fact about the user (preference, person, place, routine, etc.) to long-term memory."

    @ToolParam(description: "The fact to remember, as a short canonical phrase.")
    var content: String
    @ToolParam(description: "Category: one of person, place, fact, preference, topic.")
    var kind: String
    @ToolParam(description: "Set true to remember permanently (identity).")
    var permanent: Bool

    init() {}

    func run() async throws -> Any {
        // @ToolParam exposes values as optionals (wrappedValue is Value?); unwrap with defaults.
        let content = self.content ?? ""
        let kind = self.kind ?? "fact"
        let permanent = self.permanent ?? false
        guard !content.isEmpty else { return "nothing to remember" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: content) }
        let result: String = await MainActor.run {
            guard let store = MemoryToolbox.shared.store else { return "memory unavailable" }
            let now = Date().timeIntervalSince1970
            let perm = permanent
            let layer: MemoryLayer = perm ? .identity : .daily
            let k = NodeKind(rawValue: kind) ?? .fact
            let node = Node(id: UUID().uuidString, kind: k, label: content, body: content, layer: layer,
                            createdAt: now, updatedAt: now, lastSeenAt: now, salience: perm ? 8 : 3,
                            decayRate: Decay.defaultDecayRate(for: layer), confidence: .sure, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil,
                            dirty: true, deleted: false, extra: nil)
            do {
                let id = try store.upsertMerging(node)
                if let emb = MemoryToolbox.shared.embedder, let v = try? emb.embed(content) {
                    try? store.setEmbedding(nodeId: id, v)
                }
                return "Saved to memory: \(content)"
            } catch {
                return "memory error: \(error)"
            }
        }
        await MainActor.run { ToolActivityRelay.shared.finished(name: Self.name, result: result) }
        return result
    }
}
