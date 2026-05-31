import Foundation

/// Persists each chat turn as two `conversation` nodes (user + assistant) in the `episodic`
/// layer — the replayable substrate the sleep-consolidation pass (M2b-2) reads. Thread metadata
/// (session id, role, turn index, status) is packed into `Node.extra` as JSON (no schema change).
enum EpisodeRecorder {
    struct Meta: Codable {
        var threadId: String
        var role: String       // "user" | "assistant"
        var turnIndex: Int
        var status: String     // "open" | "closed"
    }

    static func meta(from node: Node) -> Meta? {
        guard let s = node.extra, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: d)
    }

    /// Record one finished turn. Best-effort: storage errors are swallowed (never break a reply).
    static func record(store: MemoryStore, threadId: String, turnIndex: Int,
                       userText: String, assistantText: String,
                       now: Double = Date().timeIntervalSince1970) {
        write(store: store, threadId: threadId, turnIndex: turnIndex, role: "user", text: userText, now: now)
        write(store: store, threadId: threadId, turnIndex: turnIndex, role: "assistant", text: assistantText, now: now)
    }

    private static func write(store: MemoryStore, threadId: String, turnIndex: Int,
                              role: String, text: String, now: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let meta = Meta(threadId: threadId, role: role, turnIndex: turnIndex, status: "closed")
        let extra = (try? JSONEncoder().encode(meta)).flatMap { String(data: $0, encoding: .utf8) }
        let preview = String(trimmed.prefix(60))
        let node = Node(id: UUID().uuidString, kind: NodeKind.conversation.rawValue, label: "\(role): \(preview)",
                        body: trimmed, layer: .episodic, createdAt: now, updatedAt: now, lastSeenAt: now,
                        salience: 2, decayRate: Decay.defaultDecayRate(for: .episodic), confidence: .sure,
                        mentionCount: 1, ttlExpiresAt: nil, sourceRef: threadId, origin: .extracted,
                        serverId: nil, dirty: true, deleted: false, extra: extra)
        try? store.upsert(node)   // distinct per turn — NOT deduped
    }
}
