import Foundation

/// Brain-like consolidation operations over the memory graph, driven by the local model.
/// Phases are independent units (testable with a fake runtime). The resumable cycle driver
/// (`runCycle`) and the awake-light path (`runLight`) compose these phases. A persisted
/// `sleep_cycle` lets a cycle resume from where it was interrupted.
nonisolated final class MemoryConsolidationEngine {
    private let store: MemoryStore
    private let embedder: Embedder?
    private let runtime: ModelRuntime
    private let now: () -> Double
    var onProgress: ((String) -> Void)?   // e.g. "+2 entities", "+1 edge"

    init(store: MemoryStore, embedder: Embedder?, runtime: ModelRuntime,
         now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.store = store; self.embedder = embedder; self.runtime = runtime; self.now = now
    }

    // MARK: shared

    /// Run one plain-text generation and return its full text.
    private func generate(_ prompt: String, maxTokens: Int = 512) async -> String {
        var out = ""
        let stream = await runtime.generate(prompt: prompt,
                                            options: GenerationOptions(maxTokens: maxTokens, temperature: 0.3))
        do { for try await e in stream {
            if case .token(let t) = e { out += t }
            if case .completed(let r) = e, out.isEmpty { out = r.text }
        } } catch { return "" }
        return out
    }

    /// Outermost {...} JSON object from noisy model output.
    static func extractJSON(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        return String(s[a...b])
    }
    private func parse<T: Decodable>(_ raw: String, _ type: T.Type) -> T? {
        guard let j = Self.extractJSON(raw), let d = j.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    // MARK: NREM — Consolidate

    private struct EntitiesOut: Decodable {
        struct E: Decodable { let entity: String; let kind: String?; let detail: String?; let permanent: Bool?
            struct Attr: Decodable { let status: String?; let horizon: String? }
            let attributes: Attr? }
        let entities: [E]
    }

    func consolidate(episodeTexts: [String]) async {
        guard !episodeTexts.isEmpty else { return }
        let convo = episodeTexts.joined(separator: "\n")
        let prompt = """
        Extract durable facts the USER stated about themselves from this conversation. Output JSON only.
        Use a short canonical `entity` (a noun/name, not a sentence). Choose a `kind`: person, place, \
        preference, fact, trait (personality), task (something to do — set attributes.status "pending"), \
        plan (an intention — set attributes.horizon "short" or "long"), or another short lowercase kind if \
        none fit. Put context in `detail`. Never invent; only what the user actually stated.
        Schema: {"entities":[{"entity":"...","kind":"...","detail":"...","permanent":false,"attributes":{"status":"pending|done","horizon":"short|long"}}]}
        Conversation:
        \(convo)
        JSON:
        """
        guard let out = parse(await generate(prompt), EntitiesOut.self) else { return }
        var added = 0
        for e in out.entities {
            let label = MemoryText.cleanLabel(e.entity)
            if MemoryText.isJunkLabel(label) { continue }
            let kind = (e.kind?.isEmpty == false) ? e.kind! : NodeKind.fact.rawValue
            let layer: MemoryLayer = (e.permanent ?? false) ? .identity : .daily
            var attrs = NodeAttributes(); attrs.status = e.attributes?.status; attrs.horizon = e.attributes?.horizon
            let t = now()
            let node = Node(id: UUID().uuidString, kind: kind, label: label, body: e.detail ?? label, layer: layer,
                            createdAt: t, updatedAt: t, lastSeenAt: t, salience: (e.permanent ?? false) ? 8 : 3,
                            decayRate: Decay.defaultDecayRate(for: layer), confidence: .probable, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil,
                            dirty: true, deleted: false, extra: attrs.toJSON())
            let emb = (try? embedder?.embed(label)) ?? nil
            if (try? store.upsertMergingSemantic(node, embedding: emb, embedder: embedder)) != nil { added += 1 }
        }
        onProgress?("+\(added) entities")
    }

    // MARK: REM — Associate

    private struct EdgesOut: Decodable { struct E: Decodable { let from: String; let relation: String; let to: String }; let edges: [E] }

    func associate() async {
        let nodes = (try? store.allNodes().filter { $0.kind != NodeKind.conversation.rawValue }) ?? []
        guard nodes.count >= 2 else { return }
        let labels = nodes.prefix(60).map { "\($0.kind): \($0.label)" }.joined(separator: "\n")
        let relations = Relation.allCases.map { $0.rawValue }.joined(separator: ", ")
        let prompt = """
        Given these memory entities, propose meaningful relationships between them. Output JSON only.
        Use ONLY these relation types: \(relations). Only connect entities that are genuinely related; \
        do not invent entities. Schema: {"edges":[{"from":"<entity label>","relation":"<one of the types>","to":"<entity label>"}]}
        Entities:
        \(labels)
        JSON:
        """
        guard let out = parse(await generate(prompt), EdgesOut.self) else { return }
        func resolve(_ label: String) -> Node? {
            let key = MemoryText.dedupKey(label)
            if let n = nodes.first(where: { MemoryText.dedupKey($0.label) == key }) { return n }
            // 0.25 is intentionally looser than upsertMergingSemantic's 0.2 dedup default: linking
            // an edge endpoint tolerates more drift than merging two nodes into one.
            if let emb = (try? embedder?.embed(label)) ?? nil,
               let hit = (try? store.nearest(to: emb, k: 1))?.first, hit.distance <= 0.25 {
                return try? store.node(id: hit.id)
            }
            return nil
        }
        let existing = Set((try? store.allEdges())?.map { "\($0.srcId)|\($0.relation.rawValue)|\($0.dstId)" } ?? [])
        var added = 0
        for e in out.edges {
            guard let rel = Relation(rawValue: e.relation), let s = resolve(e.from), let d = resolve(e.to), s.id != d.id else { continue }
            let key = "\(s.id)|\(rel.rawValue)|\(d.id)"
            if existing.contains(key) { continue }
            let t = now()
            try? store.upsert(Edge(id: UUID().uuidString, srcId: s.id, dstId: d.id, relation: rel, weight: 1,
                                   confidence: .probable, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
            added += 1
        }
        onProgress?("+\(added) connections")
    }

    // MARK: Reflect — Abstract (grounded insights)
    private struct InsightsOut: Decodable { struct I: Decodable { let text: String; let sourceEntities: [String]; let confidence: String? }; let insights: [I] }

    func reflect() async {
        let nodes = (try? store.allNodes().filter { $0.kind != NodeKind.conversation.rawValue && $0.kind != NodeKind.insight.rawValue }) ?? []
        guard nodes.count >= 2 else { return }
        let labels = nodes.prefix(60).map { "\($0.kind): \($0.label)" }.joined(separator: "\n")
        let prompt = """
        From these memories about the user, infer a few higher-level insights. Output JSON only.
        Each insight MUST be grounded in at least TWO of the listed entities (cite their labels in \
        sourceEntities). Do not speculate beyond the evidence. Schema: \
        {"insights":[{"text":"...","sourceEntities":["label1","label2"],"confidence":"probable|maybe"}]}
        Memories:
        \(labels)
        JSON:
        """
        guard let out = parse(await generate(prompt), InsightsOut.self) else { return }
        // Label-only resolution by design: sources must be among the entities shown to the model
        // (unlike `associate`, which also falls back to semantic nearest-neighbor).
        func resolve(_ label: String) -> Node? {
            let key = MemoryText.dedupKey(label)
            return nodes.first { MemoryText.dedupKey($0.label) == key }
        }
        // Dedup: runLight runs reflect() frequently over stable memory; without this guard,
        // each run would re-mint near-identical insight nodes with fresh UUIDs.
        var existingInsights = Set(((try? store.allNodes()) ?? []).filter { $0.kind == NodeKind.insight.rawValue }.map { MemoryText.dedupKey($0.body) })
        var added = 0
        for ins in out.insights {
            let sources = ins.sourceEntities.compactMap(resolve)
            if Set(sources.map { $0.id }).count < 2 { continue }   // anti-fabrication
            let key = MemoryText.dedupKey(ins.text)
            if existingInsights.contains(key) { continue }         // already have this insight
            existingInsights.insert(key)                            // collapse duplicates within this batch too
            let t = now()
            let conf = Confidence(rawValue: ins.confidence ?? "probable") ?? .probable
            let node = Node(id: UUID().uuidString, kind: NodeKind.insight.rawValue, label: String(ins.text.prefix(60)),
                            body: ins.text, layer: .daily, createdAt: t, updatedAt: t, lastSeenAt: t, salience: 3,
                            decayRate: Decay.defaultDecayRate(for: .daily), confidence: conf, mentionCount: 1,
                            ttlExpiresAt: nil, sourceRef: nil, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil)
            try? store.upsert(node)
            for s in sources {
                try? store.upsert(Edge(id: UUID().uuidString, srcId: node.id, dstId: s.id, relation: .relatedTo, weight: 1,
                                       confidence: conf, createdAt: t, updatedAt: t, dirty: true, deleted: false, extra: nil))
            }
            added += 1
        }
        onProgress?("+\(added) insights")
    }

    // MARK: Curate — fold synonym kinds into a canonical vocabulary
    private struct KindMapOut: Decodable { let map: [String: String] }

    func curateKinds() async {
        let known = NodeKind.allCases.map { $0.rawValue }
        let kinds = (try? store.distinctKinds()) ?? []
        let unknown = kinds.filter { !known.contains($0) }
        guard !unknown.isEmpty else { return }
        let prompt = """
        Map each non-standard memory kind to the closest STANDARD kind, or keep it if it's genuinely distinct. Output JSON only.
        Standard kinds: \(known.joined(separator: ", ")). Schema: {"map":{"<kind>":"<standard-or-same>"}}
        Kinds to map: \(unknown.joined(separator: ", "))
        JSON:
        """
        guard let out = parse(await generate(prompt, maxTokens: 256), KindMapOut.self) else { return }
        for (from, to) in out.map where from != to && !to.isEmpty {
            try? store.reassignKind(from: from, to: to)
        }
    }

    // MARK: SHY — Forget / downscale
    func forget() async {
        try? store.sweep()
        try? store.pruneDanglingEdges()
    }

    // MARK: Cycle driver (resumable). `@escaping` to match the ConsolidationRunning protocol (Task 6).
    func runCycle(isCancelled: @escaping () -> Bool) async {
        // Load or start a cycle.
        var state: SleepCycleState
        if let existing = (try? store.loadSleepCycle()) ?? nil {
            state = existing
        } else {
            let batch = ((try? store.unconsolidatedEpisodes()) ?? []).map { $0.id }
            guard !batch.isEmpty else { return }
            state = SleepCycleState(phase: .nrem, episodeIds: batch, startedAt: now())
            try? store.saveSleepCycle(state)
        }
        let order: [SleepPhase] = [.nrem, .rem, .reflect, .curate, .shy]
        guard let startIdx = order.firstIndex(of: state.phase) else { return }
        for phase in order[startIdx...] {
            if isCancelled() { return }   // leave persisted phase for resume
            switch phase {
            case .nrem:
                let texts = state.episodeIds.compactMap { (try? store.node(id: $0))?.body }
                await consolidate(episodeTexts: texts)
            case .rem: await associate()
            case .reflect: await reflect()
            case .curate: await curateKinds()
            case .shy: await forget()
            }
            // advance persisted phase (so resume skips this one)
            if let next = order.firstIndex(of: phase).map({ $0 + 1 }), next < order.count {
                state.phase = order[next]; try? store.saveSleepCycle(state)
            }
        }
        // Non-atomic by design: if the process dies after .shy advances but before this mark,
        // resume re-enters at .shy, re-runs the idempotent forget(), then marks — so episodes are
        // never lost, only a redundant forget() is paid.
        try? store.markEpisodesConsolidated(ids: state.episodeIds)
        try? store.clearSleepCycle()
        onProgress?("done")
    }

    /// Awake light reflection: associate + reflect over current memory, no replay/curate/forget.
    func runLight(isCancelled: @escaping () -> Bool) async {
        if isCancelled() { return }
        await associate()
        if isCancelled() { return }
        await reflect()
    }
}
