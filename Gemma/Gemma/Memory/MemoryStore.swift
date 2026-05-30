import Foundation
import GRDB

final class MemoryStore {
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

    /// Always-relevant "identity core": who the user is and their strongest facts, regardless
    /// of the current query. Returns identity-layer nodes plus the highest-salience non-deleted
    /// nodes (deduped), so meta-questions like "what do I like?" — which don't keyword/semantic
    /// match any single entity — still see the user's name, preferences and key people.
    func coreMemories(limit: Int = 6) throws -> [Node] {
        try dbQueue.read { db in
            let identity = try Node.filter(Column("layer") == MemoryLayer.identity.rawValue && Column("deleted") == false)
                .order(Column("salience").desc).fetchAll(db)
            let topSalient = try Node.filter(Column("deleted") == false)
                .order(Column("salience").desc).limit(limit).fetchAll(db)
            var seen = Set<String>()
            var out: [Node] = []
            for n in identity + topSalient where seen.insert(n.id).inserted {
                out.append(n)
                if out.count >= limit { break }
            }
            return out
        }
    }
    func edges(from id: String) throws -> [Edge] {
        try dbQueue.read { try Edge.filter(Column("srcId") == id && Column("deleted") == false).fetchAll($0) }
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
}
