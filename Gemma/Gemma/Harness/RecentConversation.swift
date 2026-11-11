import Foundation

/// An in-process window of messages actually exchanged on the current connection.
struct RecentConversation {
    private static let messageLimit = 8
    private static let messageByteLimit = 768
    private var threadID: String?
    private var messages: [ChatMessage] = []

    mutating func start(threadID: String) {
        guard self.threadID != threadID else { return }
        self.threadID = threadID
        messages.removeAll()
    }

    mutating func append(_ message: ChatMessage, threadID: String) {
        guard self.threadID == threadID, let bounded = Self.bounded(message) else { return }
        messages.append(bounded)
        if messages.count > Self.messageLimit { messages.removeFirst() }
    }

    @MainActor
    func history(threadID: String, client: MemoryClient?) async -> [ChatMessage] {
        guard self.threadID == threadID else { return [] }
        guard let client, let rows = try? await client.conversationWindow(threadId: threadID) else { return messages }
        let remote = rows.suffix(Self.messageLimit).compactMap { row -> ChatMessage? in
            guard let role = ChatMessage.Role(rawValue: row.role) else { return nil }
            return Self.bounded(ChatMessage(role: role, content: row.text))
        }
        // Legacy windows have no message identifiers. Only extend the local window if the
        // server contains its entire suffix in order, avoiding both gaps and duplicates.
        return remote.suffix(messages.count).elementsEqual(messages) ? remote : messages
    }

    private static func bounded(_ message: ChatMessage) -> ChatMessage? {
        guard message.role != .system,
              !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let bytes = message.content.utf8
        guard bytes.count > messageByteLimit else { return message }

        // Attachment previews precede the user's actual question in the submitted text.
        let omission = "\n[…]\n"
        let segmentLimit = (messageByteLimit - omission.utf8.count) / 2
        var head = bytes.prefix(segmentLimit)
        var tail = bytes.suffix(segmentLimit)
        while String(bytes: head, encoding: .utf8) == nil { head = head.dropLast() }
        while String(bytes: tail, encoding: .utf8) == nil { tail = tail.dropFirst() }
        let text = String(decoding: head, as: UTF8.self) + omission + String(decoding: tail, as: UTF8.self)
        return ChatMessage(role: message.role, content: text)
    }
}
