import Foundation

/// HTTP client to the Memory Service (Docker). Reads `baseURL` + bearer token from Settings.
/// Provides graceful degradation: recall returns empty bundle on 5xx/timeout instead of throwing
/// (so the agent keeps chatting if the memory layer is down). Save / forget / etc still throw.
@MainActor
final class MemoryClient {
    struct RecallNode: Decodable, Sendable {
        let kind: String; let label: String; let body: String; let extra: String?; let tags: [String]
        init(kind: String, label: String, body: String, extra: String?, tags: [String] = []) {
            self.kind = kind; self.label = label; self.body = body; self.extra = extra; self.tags = tags
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind  = try c.decode(String.self,    forKey: .kind)
            label = try c.decode(String.self,    forKey: .label)
            body  = try c.decode(String.self,    forKey: .body)
            extra = try c.decodeIfPresent(String.self, forKey: .extra)
            tags  = (try c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        }
        private enum CodingKeys: String, CodingKey { case kind, label, body, extra, tags }
    }
    struct RecentTurn: Decodable, Sendable { let role: String; let text: String }
    struct RecallSummary: Decodable, Sendable {
        let summaryId: String; let chatId: String; let messageRange: [Int]; let text: String
    }
    struct RangeRow: Decodable, Sendable { let seq: Int; let role: String; let text: String }
    struct RangeResult: Decodable, Sendable { let messages: [RangeRow]; let truncated: Bool }
    struct RecallBundle: Decodable, Sendable {
        let core: [RecallNode]; let recall: [RecallNode]; let summaries: [RecallSummary]; let recentTurns: [RecentTurn]
        static let empty = RecallBundle(core: [], recall: [], summaries: [], recentTurns: [])

        /// Render this bundle as a compact injection block (empty string if all lists are empty).
        /// Episodic summaries are rendered after the fact nodes so the model sees them as
        /// drill-down references. `recentTurns` always appears last.
        func injectionBlock() -> String {
            let all = recall + core.filter { c in !recall.contains(where: { $0.label == c.label && $0.kind == c.kind }) }
            let selfNode = all.first { $0.kind == "self" }
            let merged = all.filter { $0.kind != "self" }
            let lines = merged.map { n -> String in
                let base = "- [\(n.kind)] \(n.label): \(n.body.isEmpty ? n.label : n.body)"
                guard n.kind == "event", let extra = n.extra,
                      let data = extra.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = obj["status"] as? String else { return base }
                return base + scheduleStatusSuffix(status)
            }
            var out = ""
            if let s = selfNode, !s.label.isEmpty {
                out = "You are speaking with \(s.label) (the user)." + (s.body.isEmpty ? "" : " \(s.body)\(s.body.hasSuffix(".") ? "" : ".")")
            }
            if !merged.isEmpty {
                out += (out.isEmpty ? "" : "\n") + "What you remember about the user (use if relevant):\n" + lines.joined(separator: "\n")
            }
            if !summaries.isEmpty {
                let sl = summaries.map { s in
                    let r = s.messageRange.count >= 2 ? "\(s.messageRange[0])-\(s.messageRange[1])" : "\(s.messageRange.first ?? 0)"
                    return "- [chat \(s.chatId) · msgs \(r)] \(s.text)"
                }.joined(separator: "\n")
                out += (out.isEmpty ? "" : "\n\n") + "Episodic summaries (load the underlying messages only if a summary doesn't answer):\n" + sl
            }
            if !recentTurns.isEmpty {
                let rt = recentTurns.map { "- \($0.role): \($0.text)" }.joined(separator: "\n")
                out += (out.isEmpty ? "" : "\n\n") + "Recent conversation (other chats):\n" + rt
            }
            return out
        }
    }
    struct SaveResult: Decodable, Sendable { let id: String; let mergedInto: String? }
    struct WindowTurn: Decodable, Sendable { let role: String; let text: String }
    struct StateSnapshot: Decodable, Sendable {
        let nodeCount: Int; let transcriptCount: Int; let isRunning: Bool
        let lastCycle: LastCycle?
        struct LastCycle: Decodable, Sendable { let id: String?; let status: String?; let endedAt: Double? }
    }
    struct ListedNodes: Decodable, Sendable { let nodes: [Node]; let total: Int }
    struct TranscriptRows: Decodable, Sendable { let rows: [TranscriptRow] }
    struct GraphSnapshot: Decodable, Sendable { let nodes: [Node]; let edges: [Edge] }

    struct Node: Decodable, Sendable, Identifiable {
        let id: String
        let kind: String
        let label: String
        let body: String
        let extra: String?
        // The service returns the full GRDB row; these are decoded when present (graph view
        // needs them for sizing/coloring), absent otherwise (recall path uses only label/body).
        let layer: String?
        let salience: Double?
        let mentionCount: Int?
        let confidence: String?
    }
    struct Edge: Decodable, Sendable, Identifiable {
        let id: String
        let srcId: String
        let dstId: String
        let relation: String
        let weight: Double
    }
    struct TranscriptRow: Decodable, Sendable, Identifiable {
        let id: String; let threadId: String; let role: String; let text: String
        let turnIndex: Int; let createdAt: Double
    }

    struct ScheduleEvent: Decodable, Sendable, Identifiable {
        let id: String
        let title: String
        let start: Double
        let end: Double
        let allDay: Bool
        let location: String?
        let status: String
    }
    struct CreateEventResult: Sendable { let created: Bool; let id: String?; let conflicts: [ScheduleEvent] }
    struct UpdateEventResult: Sendable {
        let updated: Bool
        let event: ScheduleEvent?
        let conflicts: [ScheduleEvent]
        let notFound: Bool
        let ambiguous: [ScheduleEvent]
    }

    enum ClientError: Error {
        case http(status: Int, message: String)
        case decode(Error)
        case invalidResponse
    }

    let baseURL: URL
    let bearerToken: String
    private let session: URLSession

    init(baseURL: URL, bearerToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.session = session
    }

    // MARK: transcript
    func appendTranscript(threadId: String, role: String, text: String, turnIndex: Int) async throws {
        struct Body: Encodable { let threadId: String; let role: String; let text: String; let turnIndex: Int }
        let _: EmptyOK = try await post("/v1/transcript/append",
                                        Body(threadId: threadId, role: role, text: text, turnIndex: turnIndex))
    }
    func conversationWindow(threadId: String, maxTurns: Int = 12, maxChars: Int = 1500) async throws -> [WindowTurn] {
        struct W: Decodable { let turns: [WindowTurn] }
        let w: W = try await get("/v1/conversation/window?threadId=\(escape(threadId))&maxTurns=\(maxTurns)&maxChars=\(maxChars)")
        return w.turns
    }

    // MARK: memory
    func save(kind: String, label: String, body: String?, extra: String?, sourceRef: String?) async throws -> SaveResult {
        struct B: Encodable { let kind: String; let label: String; let body: String?; let extra: String?; let sourceRef: String? }
        return try await post("/v1/memory/save", B(kind: kind, label: label, body: body, extra: extra, sourceRef: sourceRef))
    }
    func forget(label: String? = nil, id: String? = nil) async throws -> Int {
        struct B: Encodable { let label: String?; let id: String? }
        struct R: Decodable { let removed: Int }
        let r: R = try await post("/v1/memory/forget", B(label: label, id: id))
        return r.removed
    }
    /// Returns empty bundle on 5xx/timeout — never throws.
    /// Note: the server also accepts an optional `tag` filter on recall (SP-B1); the app decodes
    /// the per-node `tags` but does not yet send a filter — a tag-scoped recall consumer comes later.
    func recall(query: String, scope: String? = nil, limit: Int? = nil, threadId: String? = nil) async throws -> RecallBundle {
        struct B: Encodable { let query: String; let scope: String?; let limit: Int?; let threadId: String? }
        do {
            return try await post("/v1/memory/recall", B(query: query, scope: scope, limit: limit, threadId: threadId))
        } catch ClientError.http(let status, _) where (500...599).contains(status) {
            return .empty
        } catch is URLError {
            return .empty
        }
    }
    func loadMessages(chatId: String, from: Int, to: Int?) async throws -> RangeResult {
        let toq = to.map { "&to=\($0)" } ?? ""
        return try await get("/v1/transcript/range?chat_id=\(escape(chatId))&from=\(from)\(toq)")
    }

    // MARK: consolidation
    func consolidationTurnEnd(threadId: String) async throws {
        struct B: Encodable { let threadId: String; let timezone: String }
        let _: EmptyOK = try await post("/v1/consolidation/turn-end",
                                        B(threadId: threadId, timezone: TimeZone.current.identifier))
    }
    func reflect() async throws -> String? {
        struct B: Encodable { let timezone: String }
        struct R: Decodable { let cycleId: String }
        let r: R = try await post("/v1/consolidation/reflect", B(timezone: TimeZone.current.identifier))
        return r.cycleId.isEmpty ? nil : r.cycleId
    }
    func state() async throws -> StateSnapshot { try await get("/v1/consolidation/state") }

    // MARK: inspector
    func nodes(limit: Int = 100, offset: Int = 0, kind: String? = nil) async throws -> ListedNodes {
        var path = "/v1/nodes?limit=\(limit)&offset=\(offset)"
        if let kind { path += "&kind=\(escape(kind))" }
        return try await get(path)
    }
    func transcriptRecent(limit: Int = 200) async throws -> [TranscriptRow] {
        let r: TranscriptRows = try await get("/v1/transcript/recent?limit=\(limit)")
        return r.rows
    }
    /// Newest `nodeLimit` live nodes + every live edge between them. Backs the Grafo tab.
    func graph(nodeLimit: Int = 300) async throws -> GraphSnapshot {
        try await get("/v1/graph?nodeLimit=\(nodeLimit)")
    }

    // MARK: hub navigation (Phase 2)
    struct ByHubResult: Decodable, Sendable { let nodes: [Node]; let kind: String; let total: Int }
    struct ByEntityResult: Decodable, Sendable { let nodes: [Node]; let entity: String; let total: Int }
    struct TopicNode: Decodable, Sendable { let kind: String; let label: String; let body: String }
    struct TopicResult: Decodable, Sendable { let tag: String; let nodes: [TopicNode] }
    struct WhyResult: Decodable, Sendable { let insight: String; let sources: [TopicNode] }

    /// All members of the `<kind>` hub. `status` filters `extra.status`; `sortByDate`
    /// orders by `extra.date` ascending. Used for "list my pending tasks ordered by date"
    /// without scanning every node.
    func byHub(kind: String, status: String? = nil, sortByDate: Bool = false,
               limit: Int = 100) async throws -> ByHubResult {
        var path = "/v1/memory/byHub?kind=\(escape(kind))&limit=\(limit)"
        if let status { path += "&status=\(escape(status))" }
        if sortByDate { path += "&sort=date" }
        return try await get(path)
    }

    /// Every node connected to the named entity (either direction, any relation).
    /// Used for "tell me everything you know about <person>".
    func byEntity(label: String, limit: Int = 100) async throws -> ByEntityResult {
        try await get("/v1/memory/byEntity?label=\(escape(label))&limit=\(limit)")
    }

    /// All tag strings known to the memory service.
    func memoryTags() async throws -> [String] {
        struct R: Decodable { let tags: [String] }
        let r: R = try await get("/v1/memory/tags")
        return r.tags
    }

    /// All nodes tagged with `topic`.
    func recallByTopic(topic: String, limit: Int = 100) async throws -> TopicResult {
        try await get("/v1/memory/by_topic?topic=\(escape(topic))&limit=\(limit)")
    }

    /// Evidence behind a claim — the nodes that support or refute it.
    func why(claim: String) async throws -> WhyResult {
        try await get("/v1/memory/why?claim=\(escape(claim))")
    }

    // MARK: schedule (SP1)
    func checkSchedule(start: Double, end: Double) async throws -> [ScheduleEvent] {
        struct B: Encodable { let start: Double; let end: Double }
        struct R: Decodable { let conflicts: [ScheduleEvent] }
        let r: R = try await post("/v1/schedule/check", B(start: start, end: end))
        return r.conflicts
    }

    func createEvent(title: String, start: Double, end: Double, allDay: Bool,
                     location: String?, force: Bool) async throws -> CreateEventResult {
        struct B: Encodable { let title: String; let start: Double; let end: Double
                              let allDay: Bool; let location: String?; let origin: String; let force: Bool }
        struct R: Decodable { let created: Bool; let id: String?; let conflicts: [ScheduleEvent] }
        let r: R = try await post("/v1/schedule/create",
            B(title: title, start: start, end: end, allDay: allDay, location: location, origin: "user", force: force))
        return CreateEventResult(created: r.created, id: r.id, conflicts: r.conflicts)
    }

    func scheduleWindow(from: Double, to: Double, includeCancelled: Bool = false) async throws -> [ScheduleEvent] {
        struct R: Decodable { let events: [ScheduleEvent] }
        let r: R = try await get("/v1/schedule/window?from=\(Int(from))&to=\(Int(to))&includeCancelled=\(includeCancelled)")
        return r.events
    }

    func cancelEvents(ids: [String]?, from: Double?, to: Double?) async throws -> Int {
        struct B: Encodable { let ids: [String]?; let from: Double?; let to: Double? }
        struct R: Decodable { let cancelled: Int }
        let r: R = try await post("/v1/schedule/cancel", B(ids: ids, from: from, to: to))
        return r.cancelled
    }

    func updateEvent(start: Double, title: String?, newStart: Double?, newEnd: Double?,
                     newTitle: String?, location: String?, allDay: Bool?, force: Bool) async throws -> UpdateEventResult {
        struct B: Encodable { let start: Double; let title: String?; let newStart: Double?; let newEnd: Double?
                              let newTitle: String?; let location: String?; let allDay: Bool?; let force: Bool }
        struct R: Decodable { let updated: Bool; let event: ScheduleEvent?; let conflicts: [ScheduleEvent]?
                              let notFound: Bool?; let ambiguous: [ScheduleEvent]? }
        let r: R = try await post("/v1/schedule/update",
            B(start: start, title: title, newStart: newStart, newEnd: newEnd, newTitle: newTitle,
              location: location, allDay: allDay, force: force))
        return UpdateEventResult(updated: r.updated, event: r.event, conflicts: r.conflicts ?? [],
                                 notFound: r.notFound ?? false, ambiguous: r.ambiguous ?? [])
    }

    // MARK: model config (consolidation provider, pushed to the i3)
    func setModelConfig(provider: String, baseURL: String, model: String, apiKey: String?) async throws {
        struct B: Encodable { let provider: String; let baseURL: String; let model: String; let apiKey: String? }
        let _: EmptyOK = try await post("/v1/config/model",
                                        B(provider: provider, baseURL: baseURL, model: model, apiKey: apiKey))
    }
    struct ModelConfigInfo: Decodable, Sendable { let provider: String; let baseURL: String; let model: String; let hasKey: Bool }
    func modelConfig() async throws -> ModelConfigInfo { try await get("/v1/config/model") }

    // MARK: HTTP helpers
    private struct EmptyOK: Decodable {}
    private struct EmptyBody: Encodable {}

    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    /// Build URL by joining path+query to baseURL while preserving the query string.
    private func makeURL(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL) ?? baseURL.appendingPathComponent(path)
    }

    private var effectiveToken: String {
        let t = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "replace-me-with-a-long-random-string" : t
    }

    private func get<R: Decodable>(_ path: String) async throws -> R {
        var req = URLRequest(url: makeURL(path))
        req.setValue("Bearer \(effectiveToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        return try await execute(req)
    }
    private func post<B: Encodable, R: Decodable>(_ path: String, _ body: B) async throws -> R {
        var req = URLRequest(url: makeURL(path))
        req.httpMethod = "POST"
        req.setValue("Bearer \(effectiveToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 8
        return try await execute(req)
    }
    private func execute<R: Decodable>(_ req: URLRequest) async throws -> R {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.http(status: http.statusCode, message: msg)
        }
        if R.self == EmptyOK.self { return EmptyOK() as! R }
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw ClientError.decode(error)
        }
    }
}
