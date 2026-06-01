import Foundation

/// Pure mapping from persisted transcript rows to the chat history (`[ChatMessage]`) the model
/// receives as short-term context. Rows are assumed oldest-first (as `TranscriptStore.recent`
/// returns them). Caps are applied by the store; this is just the role/text mapping.
enum ConversationWindow {
    /// Default short-term window bounds (see spec §2): ~12 turns or ~1500 chars, newest kept.
    static let defaultMaxTurns = 12
    static let defaultMaxChars = 1500

    static func messages(from rows: [TranscriptRow]) -> [ChatMessage] {
        rows.map { row in
            let role: ChatMessage.Role = (row.role == "assistant") ? .assistant : .user
            return ChatMessage(role: role, content: row.text)
        }
    }
}
