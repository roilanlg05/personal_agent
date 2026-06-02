import Foundation

/// HTTP client to the Memory Service (Docker). Reads `baseURL` + bearer token from Settings.
/// Provides graceful degradation: recall returns empty bundle on 5xx/timeout instead of throwing
/// (so the agent keeps chatting if the memory layer is down). Save / forget / etc still throw.
@MainActor
final class MemoryClient {
    struct RecallNode: Decodable, Sendable {
        let kind: String; let label: String; let body: String; let extra: String?
    }
    struct RecallBundle: Decodable, Sendable {
        let core: [RecallNode]; let recall: [RecallNode]
        static let empty = RecallBundle(core: [], recall: [])
    }
    struct SaveResult: Decodable, Sendable { let id: String; let mergedInto: String? }
    struct WindowTurn: Decodable, Sendable { let role: String; let text: String }
    struct ExpandResult: Decodable, Sendable { let transcript: [WindowTurn]; let summaryLabel: String? }
    struct StateSnapshot: Decodable, Sendable {
        let nodeCount: Int; let transcriptCount: Int; let isRunning: Bool
        let lastCycle: LastCycle?
        struct LastCycle: Decodable, Sendable { let id: String?; let status: String?; let endedAt: Double? }
    }
    struct ListedNodes: Decodable, Sendable { let nodes: [Node]; let total: Int }
    struct TranscriptRows: Decodable, Sendable { let rows: [TranscriptRow] }

    struct Node: Decodable, Sendable, Identifiable {
        let id: String; let kind: String; let label: String; let body: String; let extra: String?
    }
    struct TranscriptRow: Decodable, Sendable, Identifiable {
        let id: String; let threadId: String; let role: String; let text: String
        let turnIndex: Int; let createdAt: Double
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
    func recall(query: String, scope: String? = nil, limit: Int? = nil) async throws -> RecallBundle {
        struct B: Encodable { let query: String; let scope: String?; let limit: Int? }
        do {
            return try await post("/v1/memory/recall", B(query: query, scope: scope, limit: limit))
        } catch ClientError.http(let status, _) where (500...599).contains(status) {
            return .empty
        } catch is URLError {
            return .empty
        }
    }
    func expand(topic: String) async throws -> ExpandResult {
        try await get("/v1/memory/expand?topic=\(escape(topic))")
    }

    // MARK: consolidation
    func consolidationTurnEnd(threadId: String) async throws {
        struct B: Encodable { let threadId: String }
        let _: EmptyOK = try await post("/v1/consolidation/turn-end", B(threadId: threadId))
    }
    func reflect() async throws -> String? {
        struct R: Decodable { let cycleId: String }
        let r: R = try await post("/v1/consolidation/reflect", EmptyBody())
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

    private func get<R: Decodable>(_ path: String) async throws -> R {
        var req = URLRequest(url: makeURL(path))
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        return try await execute(req)
    }
    private func post<B: Encodable, R: Decodable>(_ path: String, _ body: B) async throws -> R {
        var req = URLRequest(url: makeURL(path))
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
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
