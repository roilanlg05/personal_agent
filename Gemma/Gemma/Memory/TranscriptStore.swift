import Foundation
import GRDB

/// One raw conversation turn. Lives in the `transcript` table, SEPARATE from the knowledge
/// graph (`node`). This is Layer 1 (short-term window source) + Layer 4 (drill-down log).
struct TranscriptRow: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "transcript"
    var id: String
    var threadId: String
    var turnIndex: Int
    var role: String
    var text: String
    var createdAt: Double
    var consolidated: Bool
}

/// Persists raw chat turns. Reuses the MemoryStore `DatabaseQueue` (one DB file) but never
/// touches `node`. Replaces `EpisodeRecorder` (which wrote graph nodes per turn).
nonisolated final class TranscriptStore {
    private let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    func append(threadId: String, turnIndex: Int, role: String, text: String,
                now: Double = Date().timeIntervalSince1970) throws {
        let row = TranscriptRow(id: UUID().uuidString, threadId: threadId, turnIndex: turnIndex,
                                role: role, text: text, createdAt: now, consolidated: false)
        try dbQueue.write { try row.insert($0) }
    }

    /// Recent turns for the short-term window, oldest-first, capped by BOTH turn count and a
    /// char budget (newest kept when capping).
    func recent(threadId: String, maxTurns: Int, maxChars: Int) throws -> [TranscriptRow] {
        let newestFirst: [TranscriptRow] = try dbQueue.read { db in
            try TranscriptRow
                .filter(Column("threadId") == threadId)
                // role.asc as the final tiebreaker: in this newest-first fetch (later reversed to
                // oldest-first) "assistant" (a<u) sorts before "user" within an equal-timestamp turn,
                // so after reversed() the user precedes the assistant.
                .order(Column("createdAt").desc, Column("turnIndex").desc, Column("role").asc)
                .limit(maxTurns)
                .fetchAll(db)
        }
        var kept: [TranscriptRow] = []
        var chars = 0
        for r in newestFirst {
            chars += r.text.count
            if chars > maxChars, !kept.isEmpty { break }
            kept.append(r)
        }
        return kept.reversed()
    }

    /// Inclusive slice of a thread by turnIndex — for N4 drill-down (M2d-3).
    func range(threadId: String, fromTurn: Int, toTurn: Int) throws -> [TranscriptRow] {
        try dbQueue.read { db in
            try TranscriptRow
                .filter(Column("threadId") == threadId)
                .filter(Column("turnIndex") >= fromTurn && Column("turnIndex") <= toTurn)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    /// Fetch specific rows by id, oldest-first. Used by consolidation to rebuild episode texts.
    func rows(ids: [String]) throws -> [TranscriptRow] {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { db in
            try TranscriptRow.filter(ids.contains(Column("id")))
                .order(Column("createdAt").asc, Column("role").asc)
                .fetchAll(db)
        }
    }

    /// Turns not yet consolidated, oldest-first — consolidation input source (used in M2d-2).
    func unconsolidated(limit: Int) throws -> [TranscriptRow] {
        try dbQueue.read { db in
            try TranscriptRow
                .filter(Column("consolidated") == false)
                .order(Column("createdAt").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func markConsolidated(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            try TranscriptRow.filter(ids.contains(Column("id")))
                .updateAll(db, Column("consolidated").set(to: true))
        }
    }
}
