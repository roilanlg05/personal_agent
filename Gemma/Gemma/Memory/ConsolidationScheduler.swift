import Foundation
import Observation

/// Abstraction over the engine so the scheduler is testable with a spy.
protocol ConsolidationRunning: AnyObject {
    func runLight(isCancelled: @escaping () -> Bool) async
    func runCycle(isCancelled: @escaping () -> Bool) async
}

@MainActor
@Observable
final class ConsolidationScheduler {
    enum State: Equatable { case idle, reflecting, sleeping(String), done(String) }
    private(set) var state: State = .idle
    var lastSummary: String = ""

    @ObservationIgnored private let runner: ConsolidationRunning
    @ObservationIgnored private let isReady: () -> Bool
    @ObservationIgnored private let hasPendingCycle: () -> Bool
    @ObservationIgnored private let pauseInterval: Duration
    @ObservationIgnored private let idleInterval: Duration
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var cancelFlag = false

    init(runner: ConsolidationRunning, isReady: @escaping () -> Bool, hasPendingCycle: @escaping () -> Bool,
         pauseInterval: Duration = .seconds(15), idleInterval: Duration = .seconds(180)) {
        self.runner = runner; self.isReady = isReady; self.hasPendingCycle = hasPendingCycle
        self.pauseInterval = pauseInterval; self.idleInterval = idleInterval
    }

    /// Called at the START of every user turn: cancel any running consolidation + reset timers.
    func noteUserActivity() {
        cancelFlag = true
        running?.cancel(); running = nil
        pauseTask?.cancel(); idleTask?.cancel()
        state = .idle
        scheduleTimers()
    }

    func consolidateNow() { launch(light: false) }
    func requestLightReflection() { launch(light: true) }

    private func scheduleTimers() {
        pauseTask = Task { [weak self, pauseInterval] in
            try? await Task.sleep(for: pauseInterval)
            guard let self, !Task.isCancelled else { return }
            if self.hasPendingCycle() { self.launch(light: false) }  // resume the interrupted cycle promptly
            else { self.launch(light: true) }                        // otherwise a light awake reflection
        }
        idleTask = Task { [weak self, idleInterval] in
            try? await Task.sleep(for: idleInterval)
            guard let self, !Task.isCancelled else { return }
            self.launch(light: false)
        }
    }

    private func launch(light: Bool) {
        guard isReady(), running == nil else { return }
        cancelFlag = false
        let isCancelled: () -> Bool = { [weak self] in self?.cancelFlag ?? true }
        state = light ? .reflecting : .sleeping("nrem")
        running = Task { [weak self, runner] in
            if light { await runner.runLight(isCancelled: isCancelled) }
            else { await runner.runCycle(isCancelled: isCancelled) }
            await MainActor.run {
                guard let self else { return }
                self.running = nil
                if self.state != .idle { self.state = .done(light ? "💭" : "🌙") }
            }
        }
    }
}
