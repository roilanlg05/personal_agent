import XCTest
@testable import Gemma

final class EpisodeRecorderTests: XCTestCase {
    func test_record_writes_user_and_assistant_conversation_nodes() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        EpisodeRecorder.record(store: store, threadId: "T1", turnIndex: 0,
                               userText: "me llamo Roilan", assistantText: "¡Hola Roilan!")
        let convos = try store.allNodes().filter { $0.kind == .conversation }
        XCTAssertEqual(convos.count, 2)
        XCTAssertTrue(convos.allSatisfy { $0.layer == .episodic })
        let roles = Set(convos.compactMap { EpisodeRecorder.meta(from: $0)?.role })
        XCTAssertEqual(roles, ["user", "assistant"])
        let user = convos.first { EpisodeRecorder.meta(from: $0)?.role == "user" }
        XCTAssertEqual(user?.body, "me llamo Roilan")
        XCTAssertEqual(EpisodeRecorder.meta(from: user!)?.threadId, "T1")
        XCTAssertEqual(EpisodeRecorder.meta(from: user!)?.turnIndex, 0)
    }

    func test_record_skips_empty_assistant_text() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        EpisodeRecorder.record(store: store, threadId: "T1", turnIndex: 0, userText: "hola", assistantText: "   ")
        let convos = try store.allNodes().filter { $0.kind == .conversation }
        XCTAssertEqual(convos.count, 1, "empty/whitespace assistant turn is not stored")
        XCTAssertEqual(EpisodeRecorder.meta(from: convos[0])?.role, "user")
    }

    func test_episodes_do_not_count_as_facts() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        EpisodeRecorder.record(store: store, threadId: "T1", turnIndex: 0, userText: "hi", assistantText: "hello")
        XCTAssertTrue(try store.allNodes().filter { $0.kind != .conversation }.isEmpty)
    }
}
