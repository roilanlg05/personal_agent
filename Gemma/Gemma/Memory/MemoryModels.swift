import Foundation
import GRDB

enum NodeKind: String, Codable, CaseIterable { case person, place, fact, preference, topic, trait, task, plan, summary, insight, day, episode, conversation, followUp = "follow_up", clarification }
enum MemoryLayer: String, Codable, CaseIterable { case live, daily, identity, episodic } // episodic reservado (S11)
enum Confidence: String, Codable, CaseIterable { case sure, probable, maybe }
enum Origin: String, Codable, CaseIterable { case explicit, extracted }
enum Relation: String, Codable, CaseIterable {
    case knows, worksWith, family, likes, dislikes, locatedAt, visited, happenedOn, mentionedIn, partOfEpisode, relatedTo
}

struct Node: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: String
    var kind: String
    var label: String
    var body: String
    var layer: MemoryLayer
    var createdAt: Double
    var updatedAt: Double
    var lastSeenAt: Double
    var salience: Double
    var decayRate: Double
    var confidence: Confidence
    var mentionCount: Int
    var ttlExpiresAt: Double?
    var sourceRef: String?
    var origin: Origin
    var serverId: String?
    var dirty: Bool
    var deleted: Bool
    var extra: String?
    static let databaseTableName = "node"
}

struct Edge: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: String
    var srcId: String
    var dstId: String
    var relation: Relation
    var weight: Double
    var confidence: Confidence
    var createdAt: Double
    var updatedAt: Double
    var dirty: Bool
    var deleted: Bool
    var extra: String?
    static let databaseTableName = "edge"
}
