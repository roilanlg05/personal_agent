import Foundation
import GRDB

/// Consolidation: dedup/merge on write (human memory consolidates, doesn't accumulate
/// duplicates) + a forgetting sweep. Built on the Phase 1 MemoryStore CRUD + Phase 2 Decay.
extension MemoryStore {
    /// Find an existing non-deleted node to merge into, by (kind, canonical label). Uses
    /// MemoryText.dedupKey so "Sushi", "sushi" and "me gusta el sushi" all collapse together —
    /// the cause of the duplicate "Juan ×3 / sushi ×N" rows seen on device.
    func findDuplicate(kind: NodeKind, label: String) throws -> Node? {
        let key = MemoryText.dedupKey(label)
        return try dbQueue.read { db in
            try Node.filter(Column("kind") == kind.rawValue && Column("deleted") == false)
                .fetchAll(db)
                .first { MemoryText.dedupKey($0.label) == key }
        }
    }

    /// Upsert with dedup: if a duplicate exists, reinforce it (bump salience, mentionCount++,
    /// maybe promote to identity); else insert the candidate. Returns the resulting node id.
    @discardableResult
    func upsertMerging(_ candidate: Node) throws -> String {
        if let existing = try findDuplicate(kind: candidate.kind, label: candidate.label) {
            var merged = existing
            merged.salience = Decay.reinforce(current: existing.salience)
            merged.mentionCount = existing.mentionCount + 1
            merged.lastSeenAt = candidate.lastSeenAt
            merged.updatedAt = candidate.updatedAt
            if merged.body.isEmpty { merged.body = candidate.body }
            if Decay.shouldPromote(mentionCount: merged.mentionCount,
                                   origin: merged.origin,
                                   permanent: merged.layer == .identity) {
                merged.layer = .identity
                merged.ttlExpiresAt = nil
                merged.decayRate = Decay.defaultDecayRate(for: .identity)
            }
            merged.dirty = true
            try upsert(merged)
            return merged.id
        } else {
            try upsert(candidate)
            return candidate.id
        }
    }

    /// Forgetting sweep: soft-delete nodes whose effective salience fell below the floor
    /// or whose TTL expired (identity is never forgotten).
    func sweep(now: Double = Date().timeIntervalSince1970) throws {
        for n in try allNodes() {
            let eff = Decay.effectiveSalience(base: n.salience, decayRate: n.decayRate,
                                              elapsedSeconds: now - n.lastSeenAt)
            if Decay.shouldForget(layer: n.layer, effectiveSalience: eff,
                                  ttlExpiresAt: n.ttlExpiresAt, now: now) {
                try softDelete(nodeId: n.id)
            }
        }
    }
}
