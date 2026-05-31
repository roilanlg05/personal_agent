import Foundation
import GRDB

enum SleepPhase: String, Codable, CaseIterable { case nrem, rem, reflect, curate, shy }
struct SleepCycleState: Equatable { var phase: SleepPhase; var episodeIds: [String]; var startedAt: Double }

nonisolated final class MemoryStore {
    let dbQueue: DatabaseQueue
    let embeddingDim: Int

    init(url: URL? = nil, inMemory: Bool = false, embeddingDim: Int) throws {
        // (sqlite-vec deferred — see Phase 0 decision. Embeddings live in a regular
        //  `node_embedding(node_id, embedding BLOB)` table; nearest() does cosine in Swift.)
        self.embeddingDim = embeddingDim
        if inMemory {
            self.dbQueue = try DatabaseQueue()
        } else {
            self.dbQueue = try DatabaseQueue(path: (url ?? Self.defaultURL()).path)
        }
        try migrator.migrate(dbQueue)
    }

    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Memory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.sqlite")
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1-core") { db in
            try db.create(table: "node") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("label", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("layer", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
                t.column("lastSeenAt", .double).notNull()
                t.column("salience", .double).notNull()
                t.column("decayRate", .double).notNull()
                t.column("confidence", .text).notNull()
                t.column("mentionCount", .integer).notNull().defaults(to: 1)
                t.column("ttlExpiresAt", .double)
                t.column("sourceRef", .text)
                t.column("origin", .text).notNull()
                t.column("serverId", .text)
                t.column("dirty", .boolean).notNull().defaults(to: true)
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("extra", .text)
            }
            try db.create(indexOn: "node", columns: ["kind"])
            try db.create(indexOn: "node", columns: ["layer"])
            try db.create(indexOn: "node", columns: ["ttlExpiresAt"])
            try db.create(indexOn: "node", columns: ["lastSeenAt"])

            try db.create(table: "edge") { t in
                t.primaryKey("id", .text)
                t.column("srcId", .text).notNull().indexed()
                t.column("dstId", .text).notNull().indexed()
                t.column("relation", .text).notNull()
                t.column("weight", .double).notNull().defaults(to: 1)
                t.column("confidence", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
                t.column("dirty", .boolean).notNull().defaults(to: true)
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("extra", .text)
            }

            try db.create(virtualTable: "node_fts", using: FTS5()) { t in
                t.column("node_id")  // unindexed key
                t.column("label")
                t.column("body")
            }

            // Embeddings: regular table (BLOB float32 LE). KNN = cosine in Swift (Task 3.2).
            // (If sqlite-vec is integrated later, swap this for a vec0 virtual table; callers unchanged.)
            try db.create(table: "node_embedding") { t in
                t.primaryKey("node_id", .text)
                t.column("embedding", .blob).notNull()
            }
        }
        m.registerMigration("v2-sleep") { db in
            try db.create(table: "sleep_cycle") { t in
                t.primaryKey("id", .integer)         // always 1
                t.column("phase", .text).notNull()
                t.column("episodeIds", .text).notNull()  // JSON array
                t.column("startedAt", .double).notNull()
            }
        }
        return m
    }

    // MARK: CRUD
    func upsert(_ node: Node) throws {
        try dbQueue.write { db in
            try node.save(db)
            try db.execute(sql: "DELETE FROM node_fts WHERE node_id = ?", arguments: [node.id])
            try db.execute(sql: "INSERT INTO node_fts(node_id, label, body) VALUES (?, ?, ?)",
                           arguments: [node.id, node.label, node.body])
        }
    }
    func upsert(_ edge: Edge) throws { try dbQueue.write { try edge.save($0) } }
    func node(id: String) throws -> Node? { try dbQueue.read { try Node.fetchOne($0, key: id) } }
    func allNodes(includeDeleted: Bool = false) throws -> [Node] {
        try dbQueue.read { db in
            includeDeleted ? try Node.fetchAll(db) : try Node.filter(Column("deleted") == false).fetchAll(db)
        }
    }

    /// Always-relevant "identity core": who the user is and their permanent identity-layer
    /// facts, regardless of the current query. Identity-ONLY (no top-salience union) so the
    /// injected core stays small — query-relevant nodes (from MemoryRetriever) carry the rest.
    func coreMemories(limit: Int = 6) throws -> [Node] {
        try dbQueue.read { db in
            try Node.filter(Column("layer") == MemoryLayer.identity.rawValue && Column("deleted") == false)
                .order(Column("salience").desc).limit(limit).fetchAll(db)
        }
    }
    func edges(from id: String) throws -> [Edge] {
        try dbQueue.read { try Edge.filter(Column("srcId") == id && Column("deleted") == false).fetchAll($0) }
    }
    func allEdges() throws -> [Edge] {
        try dbQueue.read { try Edge.filter(Column("deleted") == false).fetchAll($0) }
    }
    func softDelete(nodeId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE node SET deleted=1, dirty=1, updatedAt=? WHERE id=?",
                           arguments: [Date().timeIntervalSince1970, nodeId])
            try db.execute(sql: "DELETE FROM node_fts WHERE node_id=?", arguments: [nodeId])
        }
    }
    func searchFTS(query: String, limit: Int) throws -> [Node] {
        try dbQueue.read { db in
            let pattern = FTS5Pattern(matchingAnyTokenIn: query)
            guard let p = pattern else { return [] }
            let ids = try String.fetchAll(db, sql: "SELECT node_id FROM node_fts WHERE node_fts MATCH ? LIMIT ?",
                                          arguments: [p.rawPattern, limit])
            return try ids.compactMap { try Node.fetchOne(db, key: $0) }.filter { !$0.deleted }
        }
    }

    static func floatsToBlob(_ v: [Float]) -> Data { v.withUnsafeBytes { Data($0) } }

    // MARK: Sleep / consolidation
    func loadSleepCycle() throws -> SleepCycleState? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT phase, episodeIds, startedAt FROM sleep_cycle WHERE id=1") else { return nil }
            guard let phase = SleepPhase(rawValue: row["phase"]) else { return nil }
            let ids = (try? JSONDecoder().decode([String].self, from: Data((row["episodeIds"] as String).utf8))) ?? []
            return SleepCycleState(phase: phase, episodeIds: ids, startedAt: row["startedAt"])
        }
    }
    func saveSleepCycle(_ s: SleepCycleState) throws {
        let ids = String(data: (try? JSONEncoder().encode(s.episodeIds)) ?? Data(), encoding: .utf8) ?? "[]"
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO sleep_cycle(id, phase, episodeIds, startedAt) VALUES (1, ?, ?, ?)",
                           arguments: [s.phase.rawValue, ids, s.startedAt])
        }
    }
    func clearSleepCycle() throws { try dbQueue.write { try $0.execute(sql: "DELETE FROM sleep_cycle WHERE id=1") } }

    /// Episodic conversation nodes not yet consolidated (per EpisodeRecorder.Meta.status).
    func unconsolidatedEpisodes() throws -> [Node] {
        try allNodes().filter { $0.kind == NodeKind.conversation.rawValue
            && (EpisodeRecorder.meta(from: $0)?.status ?? "closed") != "consolidated" }
    }
    func markEpisodesConsolidated(ids: [String]) throws {
        for id in ids {
            guard var n = try node(id: id), var meta = EpisodeRecorder.meta(from: n) else { continue }
            meta.status = "consolidated"
            n.extra = (try? JSONEncoder().encode(meta)).flatMap { String(data: $0, encoding: .utf8) }
            n.updatedAt = Date().timeIntervalSince1970; n.dirty = true
            try upsert(n)
        }
    }
    func distinctKinds() throws -> [String] {
        try dbQueue.read { try String.fetchAll($0, sql: "SELECT DISTINCT kind FROM node WHERE deleted=0") }
    }
    func reassignKind(from: String, to: String) throws {
        try dbQueue.write { try $0.execute(sql: "UPDATE node SET kind=?, dirty=1, updatedAt=? WHERE kind=? AND deleted=0",
                                           arguments: [to, Date().timeIntervalSince1970, from]) }
    }
    /// Soft-delete edges whose endpoints are deleted/missing.
    func pruneDanglingEdges() throws {
        let live = Set(try allNodes().map { $0.id })
        for e in try allEdges() where !(live.contains(e.srcId) && live.contains(e.dstId)) {
            try dbQueue.write { try $0.execute(sql: "UPDATE edge SET deleted=1, dirty=1, updatedAt=? WHERE id=?",
                                               arguments: [Date().timeIntervalSince1970, e.id]) }
        }
    }
}
