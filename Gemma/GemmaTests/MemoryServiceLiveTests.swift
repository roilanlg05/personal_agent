import XCTest
@testable import Gemma

/// Real E2E against the docker-compose stack. The live-roundtrip test is gated to avoid
/// CI breakage when Docker isn't up. The degrade-gracefully test runs unconditionally
/// (it intentionally points at a closed port, so it does not require Docker).
///
/// Run with: `GEMMA_LIVE_DOCKER=1 xcodebuild test ...`
/// or via `scripts/m3a-e2e.sh`.
@MainActor
final class MemoryServiceLiveTests: XCTestCase {

    func test_save_recall_expand_forget_roundtrip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GEMMA_LIVE_DOCKER"] == "1",
                          "set GEMMA_LIVE_DOCKER=1 + docker compose up to run")

        let token = ProcessInfo.processInfo.environment["MEMORY_BEARER_TOKEN"] ?? "test-token"
        let client = MemoryClient(baseURL: URL(string: "http://localhost:8081")!, bearerToken: token)

        // save
        let save = try await client.save(kind: "preference", label: "sushi",
                                         body: "al user le gusta el sushi", extra: nil, sourceRef: nil)
        XCTAssertFalse(save.id.isEmpty)

        // recall — should mention sushi
        let bundle = try await client.recall(query: "qué comida me gusta")
        XCTAssertTrue(bundle.recall.contains { $0.label.localizedCaseInsensitiveContains("sushi") },
                      "recall must surface 'sushi'; got: \(bundle.recall.map(\.label))")

        // append a turn + ask state to advance counts
        try await client.appendTranscript(threadId: "T-live", role: "user", text: "hola", turnIndex: 0)
        let state = try await client.state()
        XCTAssertGreaterThanOrEqual(state.transcriptCount, 1)
        XCTAssertGreaterThanOrEqual(state.nodeCount, 1)

        // forget
        let removed = try await client.forget(label: "sushi")
        XCTAssertGreaterThanOrEqual(removed, 1)
    }

    func test_recall_degrades_gracefully_when_service_unreachable() async throws {
        // Point at a closed port; recall MUST NOT throw.
        let client = MemoryClient(baseURL: URL(string: "http://127.0.0.1:65534")!,
                                  bearerToken: "anything")
        let bundle = try await client.recall(query: "x")
        XCTAssertTrue(bundle.core.isEmpty && bundle.recall.isEmpty)
    }
}
