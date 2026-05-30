import Foundation

/// Post-turn consolidation: runs a plain-text extraction pass over the finished exchange
/// (same E4B, text path) and upserts structured memories + relations. Async, non-blocking.
@MainActor
final class MemoryConsolidator {
    private let runtime: ModelRuntime
    private let store: MemoryStore
    private let embedder: Embedder?

    init(runtime: ModelRuntime, store: MemoryStore, embedder: Embedder?) {
        self.runtime = runtime
        self.store = store
        self.embedder = embedder
    }

    struct Extracted: Codable {
        struct Item: Codable { let kind: String; let label: String; let body: String?; let confidence: String?; let ttlHours: Double? }
        struct Rel: Codable { let from: String; let relation: String; let to: String }
        let memories: [Item]
        let relations: [Rel]?
    }

    private func prompt(user: String, assistant: String) -> String {
        """
        Extract durable facts the USER stated about themselves from the message. Output JSON only.
        Rules:
        - "label" MUST be a short canonical entity: a name or a noun (e.g. "sushi", "Juan", "Messi"). NEVER a sentence or a verb phrase. Strip "I like"/"me gusta".
        - "kind": person (a human) | place (a location) | preference (something they like/dislike) | topic (an interest/subject) | fact (anything else, e.g. their name).
        - If the user says they like X, that is kind "preference" with label X.
        - Put detail/context in "body". If there are no real durable facts, use empty arrays.
        Examples:
        Message: "Me llamo Roilan y me gusta el sushi"
        JSON: {"memories":[{"kind":"fact","label":"name","body":"the user's name is Roilan","confidence":"sure","ttlHours":null},{"kind":"preference","label":"sushi","body":"likes sushi","confidence":"sure","ttlHours":null}],"relations":[]}
        Message: "Me gusta Messi y mi amigo Juan trabaja conmigo"
        JSON: {"memories":[{"kind":"preference","label":"Messi","body":"likes Messi","confidence":"sure","ttlHours":null},{"kind":"person","label":"Juan","body":"the user's friend; works with the user","confidence":"sure","ttlHours":null}],"relations":[]}
        Schema: {"memories":[{"kind":"person|place|fact|preference|topic","label":"short entity","body":"detail","confidence":"sure|probable|maybe","ttlHours":null}],"relations":[{"from":"label","relation":"knows|worksWith|family|likes|locatedAt","to":"label"}]}
        Message: \(user)
        JSON:
        """
    }

    func consolidate(user: String, assistant: String) async {
        let p = prompt(user: user, assistant: assistant)
        var raw = ""
        let stream = await runtime.generate(prompt: p,
                                            options: GenerationOptions(maxTokens: 256, temperature: 0.2))
        do {
            for try await e in stream { if case .token(let t) = e { raw += t } }
        } catch {
            return
        }
        guard let json = Self.extractJSON(raw), let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Extracted.self, from: data) else { return }

        let now = Date().timeIntervalSince1970
        var labelToId: [String: String] = [:]   // keyed by dedupKey so relations resolve regardless of casing
        for item in parsed.memories {
            // RC1: clean the label and drop fillers/sentences the small model emits as labels.
            let label = MemoryText.cleanLabel(item.label)
            if MemoryText.isJunkLabel(label) { continue }
            let k = NodeKind(rawValue: item.kind) ?? .fact
            let ttl = item.ttlHours.map { now + $0 * 3600 }
            let layer: MemoryLayer = ttl != nil ? .live : .daily
            let node = Node(id: UUID().uuidString, kind: k, label: label, body: item.body ?? label, layer: layer,
                            createdAt: now, updatedAt: now, lastSeenAt: now, salience: 3,
                            decayRate: Decay.defaultDecayRate(for: layer),
                            confidence: Confidence(rawValue: item.confidence ?? "probable") ?? .probable,
                            mentionCount: 1, ttlExpiresAt: ttl, sourceRef: nil, origin: .extracted,
                            serverId: nil, dirty: true, deleted: false, extra: nil)
            if let id = try? store.upsertMerging(node) {
                labelToId[MemoryText.dedupKey(item.label)] = id
                // Index the canonical label (the entity), not the body — a clean anchor for
                // semantic dedup and retrieval ("sushi", "Juan" vs the free-text body).
                if let embedder, let v = try? embedder.embed(node.label) { try? store.setEmbedding(nodeId: id, v) }
            }
        }
        for rel in parsed.relations ?? [] {
            guard let s = labelToId[MemoryText.dedupKey(rel.from)], let d = labelToId[MemoryText.dedupKey(rel.to)],
                  let r = Relation(rawValue: rel.relation) else { continue }
            let edge = Edge(id: UUID().uuidString, srcId: s, dstId: d, relation: r, weight: 1, confidence: .probable,
                            createdAt: now, updatedAt: now, dirty: true, deleted: false, extra: nil)
            try? store.upsert(edge)
        }
        try? store.sweep()
    }

    /// Extract the outermost {...} JSON object from possibly-noisy model output.
    static func extractJSON(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return nil }
        return String(s[start...end])
    }
}
