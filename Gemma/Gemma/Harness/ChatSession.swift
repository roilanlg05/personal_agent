import Foundation

/// Episode boundary: a conversation idle longer than `gapSeconds` starts a new chat (new chat_id,
/// per-chat message seq restarts), so episodic summaries stay bounded. Same-topic continuity is
/// carried by cross-chat retrieval, not by chat identity. Pure + testable.
enum ChatSession {
    static let defaultGapSeconds: Double = 1800   // 30 minutes

    /// True when a user message arriving `now` should open a fresh chat because the previous
    /// activity (`lastActivity`, 0 = none yet) is older than `gapSeconds`.
    static func shouldStartNewChat(lastActivity: Double, now: Double, gapSeconds: Double = defaultGapSeconds) -> Bool {
        lastActivity > 0 && (now - lastActivity) > gapSeconds
    }
}
