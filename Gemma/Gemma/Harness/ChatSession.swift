import Foundation

/// Episode boundary: a conversation idle longer than `gapSeconds` starts a new chat (new chat_id,
/// per-chat message seq restarts), so episodic summaries stay bounded. Same-topic continuity is
/// carried by cross-chat retrieval, not by chat identity. Pure + testable.
enum ChatSession {
    static let defaultGapSeconds: Double = 1800   // 30 minutes

    struct Episode {
        private(set) var id = UUID().uuidString
        private(set) var lastActivity: Double
        private var transcriptIndex = 0

        init(lastActivity: Double) { self.lastActivity = lastActivity }

        mutating func restore(threadID: String, now: Double) {
            id = threadID
            lastActivity = now
            transcriptIndex = 0
        }

        mutating func begin(now: Double) -> (id: String, index: Int) {
            if ChatSession.shouldStartNewChat(lastActivity: lastActivity, now: now) {
                restore(threadID: UUID().uuidString, now: now)
            }
            lastActivity = now
            let index = transcriptIndex
            transcriptIndex += 1
            return (id, index)
        }

        mutating func noteActivity(now: Double) { lastActivity = now }
    }

    /// True when a user message arriving `now` should open a fresh chat because the previous
    /// activity (`lastActivity`, 0 = none yet) is older than `gapSeconds`.
    static func shouldStartNewChat(lastActivity: Double, now: Double, gapSeconds: Double = defaultGapSeconds) -> Bool {
        lastActivity > 0 && (now - lastActivity) > gapSeconds
    }
}
