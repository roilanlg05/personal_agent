import XCTest
@testable import Gemma

// MARK: Test doubles

final class FakeServerHandle: ServerProcessHandle, @unchecked Sendable {
    var terminated = false
    var onExit: (@Sendable () -> Void)?
    var stderrTail: String = ""
    func terminate() { terminated = true }
    /// Simulate the process dying on its own.
    func simulateExit() { onExit?() }
}

final class FakeLauncher: ServerProcessLauncher, @unchecked Sendable {
    var launchCount = 0
    var throwOnLaunch: Error?
    /// A NEW handle is produced per successful launch and recorded here.
    private(set) var handles: [FakeServerHandle] = []
    /// Convenience: the most recently spawned handle.
    var handle: FakeServerHandle { handles.last ?? FakeServerHandle() }
    func launch(_ config: ServerConfig) throws -> ServerProcessHandle {
        launchCount += 1
        if let e = throwOnLaunch { throw e }
        let h = FakeServerHandle()
        handles.append(h)
        return h
    }
}

/// `probeResults` is consumed one-per-probe; when exhausted the last value repeats.
final class FakeHealth: ServerHealth, @unchecked Sendable {
    var probeResults: [Bool]
    private var probeIdx = 0
    var probeCount = 0
    var warmCount = 0
    var throwOnWarm: Error?
    /// If set, `warm` throws only on the FIRST call, then succeeds (warm-up fails once, recovers).
    var throwOnFirstWarm: Error?
    init(probeResults: [Bool]) { self.probeResults = probeResults }
    func probe(_ config: ServerConfig) async -> Bool {
        probeCount += 1
        let v = probeIdx < probeResults.count ? probeResults[probeIdx] : (probeResults.last ?? false)
        probeIdx += 1
        return v
    }
    func warm(_ config: ServerConfig) async throws {
        warmCount += 1
        if warmCount == 1, let e = throwOnFirstWarm { throw e }
        if let e = throwOnWarm { throw e }
    }
}

enum TestError: Error { case boom }

@MainActor
final class ServerManagerTests: XCTestCase {
    private func makeManager(launcher: FakeLauncher, health: FakeHealth) -> ServerManager {
        ServerManager(config: .default, launcher: launcher, health: health,
                      pollAttempts: 5, pollInterval: .milliseconds(1),
                      keepAliveInterval: .seconds(3600)) // long: keep-alive tested in Task 3
    }

    func test_attaches_when_server_already_up() async {
        let launcher = FakeLauncher()
        let health = FakeHealth(probeResults: [true])      // already serving
        let m = makeManager(launcher: launcher, health: health)
        await m.start()
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(launcher.launchCount, 0, "must NOT spawn when one is already up")
        XCTAssertEqual(health.warmCount, 1, "still pre-warms the attached server")
    }

    func test_spawns_when_server_down_then_ready() async {
        let launcher = FakeLauncher()
        let health = FakeHealth(probeResults: [false, false, true]) // down, then comes up
        let m = makeManager(launcher: launcher, health: health)
        await m.start()
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(health.warmCount, 1)
    }

    func test_failed_when_launch_throws() async {
        let launcher = FakeLauncher(); launcher.throwOnLaunch = TestError.boom
        let health = FakeHealth(probeResults: [false])
        let m = makeManager(launcher: launcher, health: health)
        await m.start()
        if case .failed = m.state {} else { XCTFail("expected .failed, got \(m.state)") }
    }

    func test_failed_when_probe_never_succeeds() async {
        let launcher = FakeLauncher()
        let health = FakeHealth(probeResults: [false])     // never comes up
        let m = makeManager(launcher: launcher, health: health)
        await m.start()
        if case .failed = m.state {} else { XCTFail("expected .failed timeout, got \(m.state)") }
    }

    func test_stop_terminates_owned_process() async {
        let launcher = FakeLauncher()
        let health = FakeHealth(probeResults: [false, true])
        let m = makeManager(launcher: launcher, health: health)
        await m.start()
        m.stop()
        XCTAssertEqual(m.state, .stopped)
        XCTAssertTrue(launcher.handle.terminated, "owned process must be terminated")
    }

    func test_stop_does_not_terminate_attached_process() async {
        let launcher = FakeLauncher()
        let health = FakeHealth(probeResults: [true])      // attached, not spawned
        let m = makeManager(launcher: launcher, health: health)
        await m.start()
        m.stop()
        XCTAssertEqual(m.state, .stopped)
        XCTAssertFalse(launcher.handle.terminated, "attached external server must be left running")
    }

    func test_keepAlive_fires_while_ready_and_stops_on_stop() async throws {
        let launcher = FakeLauncher()
        let health = FakeHealth(probeResults: [true])      // attach → ready fast
        let m = ServerManager(config: .default, launcher: launcher, health: health,
                              pollAttempts: 5, pollInterval: .milliseconds(1),
                              keepAliveInterval: .milliseconds(20))
        await m.start()
        XCTAssertEqual(m.state, .ready)
        // pre-warm = 1; let a few keep-alive ticks fire
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertGreaterThan(health.warmCount, 1, "keep-alive should have warmed at least once more")
        m.stop()
        let countAtStop = health.warmCount
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(health.warmCount, countAtStop, "keep-alive must stop after stop()")
    }

    func test_unexpected_exit_marks_failed() async {
        let launcher = FakeLauncher()
        let health = FakeHealth(probeResults: [false, true])  // spawn → ready
        let m = ServerManager(config: .default, launcher: launcher, health: health,
                              pollAttempts: 5, pollInterval: .milliseconds(1),
                              keepAliveInterval: .seconds(3600))
        await m.start()
        XCTAssertEqual(m.state, .ready)
        launcher.handle.simulateExit()         // process dies on its own
        // onExit hops to MainActor via a Task; yield so it runs.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        if case .failed = m.state {} else { XCTFail("expected .failed after unexpected exit, got \(m.state)") }
    }

    func test_retry_after_spawn_terminates_old_owned_process() async {
        let launcher = FakeLauncher()
        // First start(): probe false then true → spawn + comes up; warm fails once → .failed.
        // Second start() (Retry): probe false then true → spawn again; warm now succeeds → .ready.
        let health = FakeHealth(probeResults: [false, true, false, true])
        health.throwOnFirstWarm = TestError.boom
        let m = makeManager(launcher: launcher, health: health)

        await m.start()
        if case .failed = m.state {} else { XCTFail("expected .failed after warm-up failure, got \(m.state)") }
        XCTAssertEqual(launcher.handles.count, 1, "first start() should have spawned one handle")
        XCTAssertFalse(launcher.handles[0].terminated, "spawned child must still be alive after .failed (orphan)")

        await m.start()   // Retry
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(launcher.handles.count, 2, "Retry should spawn a fresh handle")
        XCTAssertTrue(launcher.handles[0].terminated, "Retry must terminate the prior owned child (no orphan)")
    }

    func test_concurrent_start_spawns_once() async {
        let launcher = FakeLauncher()
        let health = FakeHealth(probeResults: [false, true])
        let m = ServerManager(config: .default, launcher: launcher, health: health,
                              pollAttempts: 5, pollInterval: .milliseconds(1),
                              keepAliveInterval: .seconds(3600))
        async let a: Void = m.start()
        async let b: Void = m.start()
        _ = await (a, b)
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(launcher.handles.count, 1, "re-entrant start() must spawn only once")
    }

    func test_manualCommand_is_runnable() async {
        let launcher = FakeLauncher()
        let health = FakeHealth(probeResults: [true])
        let m = makeManager(launcher: launcher, health: health)
        let cmd = m.manualCommand
        XCTAssertTrue(cmd.contains("cd "), "expected a cd prefix, got: \(cmd)")
        XCTAssertTrue(cmd.contains("python3.12"), "expected the venv python, got: \(cmd)")
        XCTAssertTrue(cmd.contains("serve_mlx_vlm.py"), "expected the wiring launcher, got: \(cmd)")
        XCTAssertTrue(cmd.contains("--model"), "expected --model, got: \(cmd)")
        XCTAssertTrue(cmd.contains("--port"), "expected --port, got: \(cmd)")
    }

    func test_setWiredLimit_change_restarts_with_new_limit() async {
        let launcher = FakeLauncher()
        // probes: start→ [#1 false=spawn, #2 true=up]; restart→ [#3 false=already-down (waitForDown returns),
        //         #4 false=spawn path, #5 true=up].
        let health = FakeHealth(probeResults: [false, true, false, false, true])
        let m = makeManager(launcher: launcher, health: health)
        await m.start()
        XCTAssertEqual(launcher.launchCount, 1)
        await m.setWiredLimit(17_179_869_184)
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(launcher.launchCount, 2, "changing the wired limit must restart (stop+start)")
        XCTAssertTrue(launcher.handles[0].terminated, "old process must be terminated on restart")
    }

    /// Regression for the restart race: stop() only SIGTERMs the old server and returns; if start()
    /// probes while the old (owned) server is still shutting down (~40-250ms), it would wrongly ATTACH
    /// to the dying server instead of spawning the new one — leaving NO server once the old one exits.
    /// The fix waits for the owned server to go down before starting, so a fresh spawn always happens.
    func test_setWiredLimit_waitsForOldServerDown_thenSpawns_notAttach() async {
        let launcher = FakeLauncher()
        // probes: start→ [#1 false=spawn, #2 true=up]; restart→ [#3 true=old server STILL lingering,
        //         #4 false=now down (waitForDown returns), #5 false=spawn path, #6 true=up].
        let health = FakeHealth(probeResults: [false, true, true, false, false, true])
        let m = makeManager(launcher: launcher, health: health)
        await m.start()
        XCTAssertEqual(launcher.launchCount, 1)
        await m.setWiredLimit(17_179_869_184)
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(launcher.launchCount, 2,
                       "restart must SPAWN the new (wired) server, not attach to the dying old one")
        XCTAssertTrue(launcher.handles[0].terminated, "old process must be terminated on restart")
    }

    func test_setWiredLimit_sameValue_isNoop() async {
        let launcher = FakeLauncher()
        let health = FakeHealth(probeResults: [false, true])
        let m = makeManager(launcher: launcher, health: health)
        await m.start()
        XCTAssertEqual(launcher.launchCount, 1)
        await m.setWiredLimit(0)   // already 0 (default)
        XCTAssertEqual(launcher.launchCount, 1, "same value must NOT restart the server")
        XCTAssertEqual(m.state, .ready)
    }
}
