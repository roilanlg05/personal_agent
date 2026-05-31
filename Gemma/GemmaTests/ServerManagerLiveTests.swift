import XCTest
@testable import Gemma

/// GATED live integration test for the REAL M2a server plumbing:
/// `RealServerProcessLauncher` (spawns `mlx_vlm.server` via `Process`) +
/// `HTTPServerHealth` (probe `/v1/models`, warm with a 1-token completion) +
/// `ServerManager.start()/stop()` driving them against the actual local mlx_vlm server.
///
/// Skipped unless `GEMMA_LIVE_SERVER=1` AND the server binary exists. Run with:
///   GEMMA_LIVE_SERVER=1 xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj \
///     -destination 'platform=macOS' -only-testing:GemmaTests/ServerManagerLiveTests
///
/// NOTE: every method is `async` on purpose — synchronous @MainActor XCTest methods
/// crash on deinit in this project.
@MainActor
final class ServerManagerLiveTests: XCTestCase {

    func test_live_spawn_ready_then_stop() async throws {
        let env = ProcessInfo.processInfo.environment
        print("[live-diag] GEMMA_LIVE_SERVER=\(env["GEMMA_LIVE_SERVER"] ?? "<nil>") TEST_RUNNER_GEMMA_LIVE_SERVER=\(env["TEST_RUNNER_GEMMA_LIVE_SERVER"] ?? "<nil>") envCount=\(env.count)")
        let enabled = (env["GEMMA_LIVE_SERVER"] == "1") || (env["TEST_RUNNER_GEMMA_LIVE_SERVER"] == "1")
        try XCTSkipUnless(enabled, "set GEMMA_LIVE_SERVER=1 to run the live server test")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: ServerConfig.default.pythonBinURL.path),
            "venv python not found")

        let config = ServerConfig.default
        let health = HTTPServerHealth()

        // Precondition: this test exercises the spawn+own+terminate path, which only
        // happens when nothing is already serving on :8080. If a server is already up,
        // start() would attach (owned=false) and stop() wouldn't kill it → skip.
        let portFreeAtStart = !(await health.probe(config))
        try XCTSkipUnless(portFreeAtStart,
            "port \(config.port) already in use — can't exercise the self-spawn path")
        print("[live] precondition OK: port \(config.port) is free")

        // REAL deps (no fakes): RealServerProcessLauncher() + HTTPServerHealth() defaults,
        // generous 180/1s poll for the 15GB model load.
        let m = ServerManager(config: config)

        // --- start() → .ready against the REAL server ---
        let t0 = Date()
        print("[live] calling start() — spawning real mlx_vlm.server + loading model + pre-warm...")
        await m.start()
        let startElapsed = Date().timeIntervalSince(t0)
        print(String(format: "[live] start() returned after %.1fs, state=%@", startElapsed, String(describing: m.state)))
        XCTAssertEqual(m.state, .ready, "real server should reach .ready; state=\(m.state)")

        // --- independent confirmation it's actually serving ---
        let serving = await HTTPServerHealth().probe(config)
        print("[live] direct probe after ready: \(serving)")
        XCTAssertTrue(serving, "direct probe should confirm the server is serving")

        // --- stop() must terminate the owned process ---
        print("[live] calling stop()...")
        m.stop()
        XCTAssertEqual(m.state, .stopped)

        // Poll for the port to go down within ~5s (SIGTERM → process exit → port closes).
        let t1 = Date()
        var down = false
        for _ in 0..<10 {
            if !(await HTTPServerHealth().probe(config)) { down = true; break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let stopElapsed = Date().timeIntervalSince(t1)
        print(String(format: "[live] server down=%@ after %.1fs from stop()", down ? "true" : "false", stopElapsed))
        XCTAssertTrue(down, "stop() should terminate the owned process so the port goes down within ~5s")
    }
}
