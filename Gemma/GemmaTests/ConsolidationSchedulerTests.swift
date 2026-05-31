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
        let s = ConsolidationScheduler(runner: spy, isReady: { true },
                                       pauseInterval: .milliseconds(20), idleInterval: .milliseconds(60))
        s.noteUserActivity()
        try await Task.sleep(for: .milliseconds(40))   // past pause, before idle
        XCTAssertGreaterThanOrEqual(spy.light, 1)
        try await Task.sleep(for: .milliseconds(80))   // past idle
        XCTAssertGreaterThanOrEqual(spy.cycle, 1)
    }
    func test_activity_cancels_and_resets() async throws {
        let spy = SpyRunner()
        let s = ConsolidationScheduler(runner: spy, isReady: { true },
                                       pauseInterval: .milliseconds(50), idleInterval: .seconds(60))
        s.noteUserActivity()
        try await Task.sleep(for: .milliseconds(20))
        s.noteUserActivity()                            // reset before pause elapses
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(spy.light, 0, "pause timer was reset by activity")
    }
    func test_not_ready_does_not_fire() async throws {
        let spy = SpyRunner()
        let s = ConsolidationScheduler(runner: spy, isReady: { false },
                                       pauseInterval: .milliseconds(20), idleInterval: .milliseconds(40))
        s.noteUserActivity()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(spy.light + spy.cycle, 0)
    }
}
