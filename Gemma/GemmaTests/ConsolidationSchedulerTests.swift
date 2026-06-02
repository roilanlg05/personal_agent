import XCTest
@testable import Gemma

@MainActor
final class ConsolidationSchedulerTests: XCTestCase {
    final class SpyRunner: ConsolidationRunning {
        var light = 0, cycle = 0
        func runLight(isCancelled: @escaping () -> Bool) async { light += 1 }
        func runCycle(isCancelled: @escaping () -> Bool) async { cycle += 1 }
    }
    func test_idle_fires_cycle_and_pause_fires_light() async throws {
        let spy = SpyRunner()
        let s = ConsolidationScheduler(runner: spy, isReady: { true }, hasPendingCycle: { false },
                                       pauseInterval: .milliseconds(20), idleInterval: .milliseconds(60))
        s.noteTurnEnded()
        try await Task.sleep(for: .milliseconds(40))   // past pause, before idle
        XCTAssertGreaterThanOrEqual(spy.light, 1)
        try await Task.sleep(for: .milliseconds(80))   // past idle
        XCTAssertGreaterThanOrEqual(spy.cycle, 1)
    }
    func test_activity_cancels_and_resets() async throws {
        let spy = SpyRunner()
        let s = ConsolidationScheduler(runner: spy, isReady: { true }, hasPendingCycle: { false },
                                       pauseInterval: .milliseconds(50), idleInterval: .seconds(60))
        s.noteTurnEnded()                               // arm timers at first turn end
        try await Task.sleep(for: .milliseconds(20))
        s.noteUserActivity()                            // new turn starts: cancel timers before pause elapses
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(spy.light, 0, "pause timer was reset by activity")
    }
    func test_requested_reflection_runs_when_not_interrupted() async throws {
        // The agentic `reflect` tool calls requestLightReflection() mid-turn. As long as no
        // user activity is noted afterwards (turn-end no longer cancels), the requested
        // reflection must actually run.
        let spy = SpyRunner()
        let s = ConsolidationScheduler(runner: spy, isReady: { true }, hasPendingCycle: { false },
                                       pauseInterval: .seconds(60), idleInterval: .seconds(60))
        s.requestLightReflection()
        try await Task.sleep(for: .milliseconds(40))   // no noteUserActivity() in between
        XCTAssertGreaterThanOrEqual(spy.light, 1, "requested reflection should run when not interrupted")
    }
    func test_not_ready_does_not_fire() async throws {
        let spy = SpyRunner()
        let s = ConsolidationScheduler(runner: spy, isReady: { false }, hasPendingCycle: { false },
                                       pauseInterval: .milliseconds(20), idleInterval: .milliseconds(40))
        s.noteTurnEnded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(spy.light + spy.cycle, 0)
    }
    func test_pause_resumes_pending_cycle_instead_of_light() async throws {
        let spy = SpyRunner()
        let s = ConsolidationScheduler(runner: spy, isReady: { true }, hasPendingCycle: { true },
                                       pauseInterval: .milliseconds(20), idleInterval: .seconds(60))
        s.noteTurnEnded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThanOrEqual(spy.cycle, 1, "a pending cycle resumes on the pause timer")
        XCTAssertEqual(spy.light, 0, "light reflection is NOT run while a cycle is pending")
    }

    func test_does_not_launch_while_user_busy() async {
        let runner = SpyRunner()
        var busy = true
        let s = ConsolidationScheduler(runner: runner, isReady: { true }, hasPendingCycle: { false },
                                       isUserBusy: { busy }, pauseInterval: .milliseconds(5), idleInterval: .seconds(3600))
        s.noteTurnEnded()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(runner.light, 0, "must NOT consolidate while a user turn is in progress")
        busy = false
        s.noteTurnEnded()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertGreaterThan(runner.light, 0, "should consolidate once the user is idle")
    }

    func test_noteUserActivity_cancels_without_arming() async {
        let runner = SpyRunner()
        let s = ConsolidationScheduler(runner: runner, isReady: { true }, hasPendingCycle: { false },
                                       isUserBusy: { false }, pauseInterval: .milliseconds(5), idleInterval: .seconds(3600))
        s.noteUserActivity()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(runner.light, 0, "turn start must not schedule consolidation")
    }
}
