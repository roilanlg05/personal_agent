import XCTest
@testable import Gemma

final class SummaryMergeExtraTests: XCTestCase {
    func test_summary_merge_adopts_latest_extra() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        func summary(_ thread: String, _ lo: Int, _ hi: Int) -> Node {
            let extra = #"{"concepts":["x"],"threadId":"\#(thread)","turnRange":[\#(lo),\#(hi)]}"#
            return Node(id: UUID().uuidString, kind: NodeKind.summary.rawValue, label: "viaje a Japón",
                        body: "trip", layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 4,
                        decayRate: 0.1, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil,
                        sourceRef: thread, origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: extra)
        }
        // First summary (thread A, turns 0..0), then a same-topic summary (thread B, turns 5..5).
        _ = try store.upsertMergingSemantic(summary("A", 0, 0), embedding: nil, embedder: nil)
        _ = try store.upsertMergingSemantic(summary("B", 5, 5), embedding: nil, embedder: nil)
        let summaries = try store.allNodes().filter { $0.kind == NodeKind.summary.rawValue && !$0.deleted }
        XCTAssertEqual(summaries.count, 1, "same-topic summaries should merge into one")
        let extra = try XCTUnwrap(summaries.first?.extra?.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: extra) as? [String: Any])
        XCTAssertEqual(obj["threadId"] as? String, "B", "merged summary must adopt the latest thread")
        XCTAssertEqual(obj["turnRange"] as? [Int], [5, 5], "merged summary must adopt the latest turnRange")
    }
}
