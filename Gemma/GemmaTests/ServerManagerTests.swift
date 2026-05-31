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
    let handle = FakeServerHandle()
    func launch(_ config: ServerConfig) throws -> ServerProcessHandle {
        launchCount += 1
        if let e = throwOnLaunch { throw e }
        return handle
    }
}

/// `probeResults` is consumed one-per-probe; when exhausted the last value repeats.
final class FakeHealth: ServerHealth, @unchecked Sendable {
    var probeResults: [Bool]
    private var probeIdx = 0
    var probeCount = 0
    var warmCount = 0
    var throwOnWarm: Error?
    init(probeResults: [Bool]) { self.probeResults = probeResults }
    func probe(_ config: ServerConfig) async -> Bool {
        probeCount += 1
        let v = probeIdx < probeResults.count ? probeResults[probeIdx] : (probeResults.last ?? false)
        probeIdx += 1
        return v
    }
    func warm(_ config: ServerConfig) async throws {
        warmCount += 1
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
}
