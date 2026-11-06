import XCTest
@testable import Gemma

#if os(macOS)

/// Invoca el binario `agent-browser` de verdad, sin mocks. Desactivada por omisión
/// para que la suite normal nunca lance Chrome ni toque la red:
///   GEMMA_LIVE_BROWSER=1 xcodebuild test … -only-testing:GemmaTests/AgentBrowserLiveTests
@MainActor
final class AgentBrowserLiveTests: XCTestCase {

    /// Sesión propia de las pruebas: no choca con `gemma` (producción) ni con otras sesiones.
    private static let liveSession = "gemma-live-test"

    private func requireLive() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GEMMA_LIVE_BROWSER"] == "1",
                          "Prueba en vivo: pon GEMMA_LIVE_BROWSER=1 para ejecutarla contra agent-browser")
    }

    private func parse(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], "got: \(out)")
    }

    func test_read_webpage_reads_example_dot_com() async throws {
        try requireLive()
        let service = AgentBrowserService(sessionName: Self.liveSession)
        let out = await ReadWebpageTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#)
        let json = try parse(out)
        XCTAssertEqual(json["status"] as? String, "success", "got: \(out)")
        XCTAssertTrue((json["content"] as? String ?? "").contains("documentation"), "got: \(out)")
    }

    func test_open_snapshot_and_close_round_trip() async throws {
        try requireLive()
        let service = AgentBrowserService(sessionName: Self.liveSession)
        // Cierra la sesión pase lo que pase, para no dejar un Chrome vivo.
        addTeardownBlock { _ = await BrowserCloseTool(service: service).run(argsJSON: "{}") }

        let opened = try parse(await BrowserOpenTool(service: service).run(argsJSON: #"{"url":"https://example.com"}"#))
        XCTAssertEqual(opened["status"] as? String, "success", "got: \(opened)")

        let snap = try parse(await BrowserSnapshotTool(service: service).run(argsJSON: "{}"))
        XCTAssertEqual(snap["status"] as? String, "success", "got: \(snap)")
        XCTAssertTrue((snap["snapshot"] as? String ?? "").contains("ref=e"), "got: \(snap)")

        let closed = try parse(await BrowserCloseTool(service: service).run(argsJSON: "{}"))
        XCTAssertEqual(closed["status"] as? String, "success", "got: \(closed)")
    }
}

#endif
