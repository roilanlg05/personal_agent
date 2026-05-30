import Foundation
import LiteRTLM

/// Explicit-capture tool: the model calls this to save a durable fact the user shared.
/// Reads the active store/embedder from MemoryToolbox.shared (tools are reconstructed via
/// init() by LiteRT-LM). Emits activity through ToolActivityRelay.shared, like CurrentTimeTool.
/// All @ToolParam values are Optional so the model may omit kind/permanent.
struct RememberTool: Tool {
    static let name = "remember"
    static let description = "Save a durable fact about the user (preference, person, place, routine, etc.) to long-term memory."

    @ToolParam(description: "The fact to remember, as a short canonical phrase.")
    var content: String? = nil
    @ToolParam(description: "Category: one of person, place, fact, preference, topic.")
    var kind: String? = nil
    @ToolParam(description: "Set true to remember permanently (identity).")
    var permanent: Bool? = nil

    init() {}

    func run() async throws -> Any {
        let content = (self.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = self.kind ?? "fact"
        let permanent = self.permanent ?? false
        guard !content.isEmpty else { return "nothing to remember" }
        await MainActor.run { ToolActivityRelay.shared.started(name: Self.name, args: content) }
        let result: String = await MainActor.run {
            guard let store = MemoryToolbox.shared.store else { return "memory unavailable" }
            let now = Date().timeIntervalSince1970
            let layer: MemoryLayer = permanent ? .identity : .daily
            let k = NodeKind(rawValue: kind) ?? .fact
            // Clean the label so explicit memories dedupe with auto-extracted ones (same MemoryText).
            let label = MemoryText.cleanLabel(content)
            let node = Node(id: UUID().uuidString, kind: k, label: label.isEmpty ? content : label, body: content, layer: layer,
                            createdAt: now, updatedAt: now, lastSeenAt: now, salience: permanent ? 8 : 3,
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
