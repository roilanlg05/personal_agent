import XCTest
@testable import Gemma

@MainActor
final class RecentConversationTests: XCTestCase {
    private let question = ChatMessage(role: .user, content: "La misión pasa por un puente.")
    private let reply = ChatMessage(role: .assistant, content: "Me acuerdo de ese puente.")

    func test_recent_messages_survive_missing_client_401_and_stale_server() async {
        var conversation = RecentConversation()
        conversation.start(threadID: "episode")
        conversation.append(question, threadID: "episode")
        conversation.append(reply, threadID: "episode")

        let unconfigured = await conversation.history(threadID: "episode", client: nil)
        XCTAssertEqual(unconfigured, [question, reply])

        let unauthorized = makeStubMemoryClient { _ in (401, Data()) }
        let rejected = await conversation.history(threadID: "episode", client: unauthorized)
        XCTAssertEqual(rejected, [question, reply])

        let stale = makeStubMemoryClient { _ in
            (200, Data(#"{"turns":[{"role":"user","text":"Una misión anterior"}]}"#.utf8))
        }
        let outdated = await conversation.history(threadID: "episode", client: stale)
        XCTAssertEqual(outdated, [question, reply])
    }

    func test_new_episode_ignores_late_reply_and_can_load_its_own_remote_history() async {
        var conversation = RecentConversation()
        conversation.start(threadID: "old")
        conversation.append(question, threadID: "old")
        conversation.start(threadID: "new")
        conversation.append(reply, threadID: "old")
        let local = await conversation.history(threadID: "new", client: nil)
        XCTAssertEqual(local, [])

        let client = makeStubMemoryClient { request in
            guard request.url?.query?.contains("threadId=new") == true else { return (400, Data()) }
            return (200, Data(#"{"turns":[{"role":"user","text":"Continuidad de esta conexión"}]}"#.utf8))
        }
        let remote = await conversation.history(threadID: "new", client: client)
        XCTAssertEqual(remote, [.init(role: .user, content: "Continuidad de esta conexión")])
    }

    func test_large_reply_does_not_evict_the_preceding_user_message() async {
        var conversation = RecentConversation()
        conversation.start(threadID: "episode")
        conversation.append(question, threadID: "episode")
        let longReply = String(repeating: "á🎮", count: 2_000)
        conversation.append(.init(role: .assistant, content: longReply), threadID: "episode")
        let history = await conversation.history(threadID: "episode", client: nil)
        XCTAssertEqual(history.first, question)
        XCTAssertEqual(history.last?.role, .assistant)
        XCTAssertLessThan(history.last?.content.utf8.count ?? .max, longReply.utf8.count)
        XCTAssertFalse(history.last?.content.contains("�") ?? true)
    }

    func test_attachment_preview_cannot_hide_the_trailing_user_question() async {
        var conversation = RecentConversation()
        conversation.start(threadID: "episode")
        let prompt = String(repeating: "página del archivo 🎮\n", count: 200) + "¿Cuánto costó la consola?"
        conversation.append(.init(role: .user, content: prompt), threadID: "episode")
        let history = await conversation.history(threadID: "episode", client: nil)
        XCTAssertTrue(history.last?.content.hasSuffix("¿Cuánto costó la consola?") ?? false)
        XCTAssertLessThanOrEqual(history.last?.content.utf8.count ?? .max, 768)
    }
}
