import XCTest
@testable import Gemma

/// GATED live integration test for the REAL M2a server plumbing:
/// `RealServerProcessLauncher` (spawns the venv python on `serve_mlx_vlm.py`, which optionally
/// wires memory then runs `mlx_vlm.server`, via `Process`) +
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

    /// Regression for the "Mantener el modelo en memoria" bug: toggling resident ON restarts the
    /// server with a wired limit. The restart must wait for the old (owned) server to go down before
    /// spawning, or start() attaches to the dying server and leaves nothing once it exits.
    /// This exercises the REAL stop→wait→spawn timing race with two real 15GB loads.
    func test_live_setWiredLimit_restarts_into_wired_server() async throws {
        let env = ProcessInfo.processInfo.environment
        let enabled = (env["GEMMA_LIVE_SERVER"] == "1") || (env["TEST_RUNNER_GEMMA_LIVE_SERVER"] == "1")
        try XCTSkipUnless(enabled, "set GEMMA_LIVE_SERVER=1 to run the live server test")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: ServerConfig.default.pythonBinURL.path),
            "venv python not found")

        var config = ServerConfig.default
        config.wiredLimitBytes = 0   // start pageable, like the app default
        let health = HTTPServerHealth()
        let portFree = !(await health.probe(config))
        try XCTSkipUnless(portFree,
            "port \(config.port) already in use — can't exercise the self-spawn path")

        let m = ServerManager(config: config)
        print("[live] start() pageable…")
        await m.start()
        XCTAssertEqual(m.state, .ready, "pageable server should reach .ready; state=\(m.state)")

        // Flip to resident: restart with the 16 GiB wired limit. The bug was: this attached to the
        // dying pageable server and the model went away → next request failed to connect.
        print("[live] setWiredLimit(16 GiB) — restarting into wired…")
        let t0 = Date()
        await m.setWiredLimit(HarnessModel.residentWiredLimitBytes)
        print(String(format: "[live] restart returned after %.1fs, state=%@",
                     Date().timeIntervalSince(t0), String(describing: m.state)))
        XCTAssertEqual(m.state, .ready, "wired server should reach .ready after restart; state=\(m.state)")

        // The key regression assertion: the server is ACTUALLY serving (not a dead corpse we attached to).
        let serving = await HTTPServerHealth().probe(config)
        XCTAssertTrue(serving, "after restart the wired server must actually be serving on the port")

        m.stop()
        XCTAssertEqual(m.state, .stopped)
        var down = false
        for _ in 0..<10 {
            if !(await HTTPServerHealth().probe(config)) { down = true; break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertTrue(down, "stop() should terminate the owned wired server")
    }
}
