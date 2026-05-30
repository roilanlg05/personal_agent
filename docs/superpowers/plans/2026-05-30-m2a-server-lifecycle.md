# M2a — Server lifecycle management — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The macOS Gemma app launches/attaches, keeps warm, and shuts down the local `mlx-lm` server itself, so it's self-contained and the cold-start never bites.

**Architecture:** A new `@MainActor @Observable` `ServerManager` owns the server subprocess via an injected `ServerProcessLauncher` and checks health via an injected `ServerHealth` (both have real impls + test fakes, so the state machine is fully unit-testable without spawning Python or hitting the network). `ServerRuntime` is unchanged. `HarnessModel` owns the `ServerManager`, starts it on launch, exposes `state` to `AgentChatView` (status pill + Send gating + Retry), and stops it on app termination.

**Tech Stack:** Swift, SwiftUI/AppKit, `Foundation.Process`, `URLSession`, XCTest. macOS app (sandbox disabled).

## Spec
`docs/superpowers/specs/2026-05-30-m2a-server-lifecycle-design.md`. Pivot: `[[macos-mlx-pivot]]`.

## Conventions
- Build/test on macOS: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS'`. Success = "Test Suite … passed" / "BUILD SUCCEEDED". Build-time SourceKit "No such module"/"Cannot find type" diagnostics are spurious if xcodebuild succeeds.
- New `.swift` files under `Gemma/Gemma/` and `Gemma/GemmaTests/` auto-add to the target (synchronized groups). No pbxproj edits for Swift files.
- Commit after each task. End commit messages with a blank line then:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- After code changes: `graphify update .` (ignore if it errors).
- A live mlx-lm server may already be running on :8080 from earlier work (warm). Tasks 2–4 use fakes and don't need it; Task 7 (manual) controls it explicitly.

## Current state (verified)
- `Runtime/ServerRuntime.swift`: `final class ServerRuntime: ModelRuntime, ToolCallingRuntime` with `init(baseURL: URL = http://localhost:8080, model: String = "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit", session: .shared, enableThinking: Bool = false)`. Unchanged by this plan.
- `Harness/HarnessModel.swift`: `@Observable @MainActor public final class HarnessModel`. `init()` sets `self.runtime = ServerRuntime()`. Has `agentLog`, `agentRunning`, `showMemory`, `runAgentTurn`, `inspectorStore()`.
- `Harness/AgentChatView.swift`: `@Bindable var model: HarnessModel`; `inputBar` Send button `.disabled(model.agentRunning || input empty)`.
- `Harness/HarnessView.swift`: owns `@State private var model = HarnessModel()` and renders `AgentChatView(model: model)`. (Verify its exact contents in Task 5 before editing.)
- `GemmaApp.swift`: `WindowGroup { HarnessView() }`.
- `Gemma/Gemma/Gemma.entitlements`: has `com.apple.security.app-sandbox`=true, `network.client`=true, `files.user-selected.read-only`=true. `project.pbxproj` references it via `CODE_SIGN_ENTITLEMENTS`.
- The mlx-lm server is started by: `<repo>/spike-mlx/.venv/bin/mlx_lm.server --model unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit --port 8080`. Repo abs path: `/Users/hashdown/Projects/personal_agent`.

## File structure (after M2a)
**New:** `Runtime/ServerManager.swift` (ServerState, ServerConfig, ServerProcessLauncher/ServerProcessHandle protocols, ServerHealth protocol, ServerManager state machine + keep-alive), `Runtime/ServerProcess.swift` (real `RealServerProcessLauncher` + `RealServerProcessHandle` + pure `serverArguments`), `Runtime/HTTPServerHealth.swift` (real URLSession health). Tests: `GemmaTests/ServerManagerTests.swift`, `GemmaTests/ServerProcessTests.swift`.
**Modified:** `Gemma/Gemma/Gemma.entitlements` (remove sandbox), `Harness/HarnessModel.swift` (own/start/stop ServerManager), `Harness/AgentChatView.swift` (status pill, Send gating, Retry), `Harness/HarnessView.swift` (kick off start), possibly `GemmaApp.swift`.

---

## Task 1: Remove the App Sandbox

**Files:** Modify `Gemma/Gemma/Gemma.entitlements`.

- [ ] **Step 1: Empty the entitlements (drop sandbox + the now-inert sandbox-only keys).** Replace the whole file with:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
</dict></plist>
```
> Without the sandbox, `Process` can spawn the Python server and network access is unrestricted; `network.client`/`files.user-selected.read-only` are sandbox-only and inert here, so we drop them.

- [ ] **Step 2: Build for macOS**
```bash
cd /Users/hashdown/Projects/personal_agent
xcodebuild build -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**
```bash
git add -A && git commit -m "build(m2a): disable App Sandbox so the app can launch the mlx-lm server"
```

---

## Task 2: `ServerManager` core state machine (TDD, fakes)

**Files:** Create `Runtime/ServerManager.swift`, Test `GemmaTests/ServerManagerTests.swift`.

- [ ] **Step 1: Write the failing test** `GemmaTests/ServerManagerTests.swift`:
```swift
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
}
```

- [ ] **Step 2: Run → fail** (`-only-testing:GemmaTests/ServerManagerTests`) with "cannot find type 'ServerManager'".

- [ ] **Step 3: Implement** `Runtime/ServerManager.swift`:
```swift
import Foundation
import Observation

/// Lifecycle state of the local mlx-lm server. `.ready` means the model has actually
/// served a pre-warm inference (not merely that the port is open).
enum ServerState: Equatable {
    case idle
    case starting       // process spawned, waiting for HTTP to come up
    case loadingModel   // HTTP up, running pre-warm (model loads)
    case ready          // pre-warm done → model hot, accepting chat
    case stopped        // owned process terminated
    case failed(String)
}

/// Where/how to run the server. Hardcoded defaults for M2a; a Settings UI is M2c.
struct ServerConfig: Sendable {
    var venvBinURL: URL
    var modelId: String
    var host: String
    var port: Int
    var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    static let `default` = ServerConfig(
        venvBinURL: URL(fileURLWithPath: "/Users/hashdown/Projects/personal_agent/spike-mlx/.venv/bin/mlx_lm.server"),
        modelId: "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
        host: "127.0.0.1",
        port: 8080)
}

/// A running server process we can terminate; notifies via `onExit` if it dies on its own.
protocol ServerProcessHandle: AnyObject {
    func terminate()
    var onExit: (@Sendable () -> Void)? { get set }
    var stderrTail: String { get }
}

/// Spawns the server process. Real impl uses `Process`; tests use a fake.
protocol ServerProcessLauncher {
    func launch(_ config: ServerConfig) throws -> ServerProcessHandle
}

/// Probes server readiness and runs a minimal warm-up/keep-alive inference.
protocol ServerHealth {
    func probe(_ config: ServerConfig) async -> Bool
    func warm(_ config: ServerConfig) async throws
}

@MainActor
@Observable
final class ServerManager {
    private(set) var state: ServerState = .idle

    @ObservationIgnored private let config: ServerConfig
    @ObservationIgnored private let launcher: ServerProcessLauncher
    @ObservationIgnored private let health: ServerHealth
    @ObservationIgnored private let pollAttempts: Int
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored let keepAliveInterval: Duration

    @ObservationIgnored private var handle: ServerProcessHandle?
    @ObservationIgnored private var owned = false
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?

    init(config: ServerConfig = .default,
         launcher: ServerProcessLauncher = RealServerProcessLauncher(),
         health: ServerHealth = HTTPServerHealth(),
         pollAttempts: Int = 180,
         pollInterval: Duration = .seconds(1),
         keepAliveInterval: Duration = .seconds(75)) {
        self.config = config
        self.launcher = launcher
        self.health = health
        self.pollAttempts = pollAttempts
        self.pollInterval = pollInterval
        self.keepAliveInterval = keepAliveInterval
    }

    /// Idempotent-ish entry point; also used by the Retry button. Cancels any prior keep-alive.
    func start() async {
        keepAliveTask?.cancel(); keepAliveTask = nil

        // Attach path: a server is already serving on the port → don't spawn.
        if await health.probe(config) {
            owned = false
            await warmToReady()
            return
        }

        // Spawn path.
        state = .starting
        do {
            let h = try launcher.launch(config)
            h.onExit = { [weak self] in Task { @MainActor in self?.handleUnexpectedExit() } }
            handle = h
            owned = true
        } catch {
            state = .failed("No pude lanzar el server (\(error)). Binario: \(config.venvBinURL.path)")
            return
        }

        var up = false
        for _ in 0..<pollAttempts {
            if await health.probe(config) { up = true; break }
            try? await Task.sleep(for: pollInterval)
        }
        guard up else {
            state = .failed("El server no respondió a tiempo.\n\(handle?.stderrTail ?? "")")
            return
        }
        await warmToReady()
    }

    func stop() {
        keepAliveTask?.cancel(); keepAliveTask = nil
        if owned { handle?.terminate() }
        handle = nil
        state = .stopped
    }

    /// Manual fallback command shown in the UI on failure.
    var manualCommand: String {
        "\(config.venvBinURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path) && \(config.venvBinURL.path) --model \(config.modelId) --port \(config.port)"
    }

    // MARK: - internals

    private func warmToReady() async {
        state = .loadingModel
        do {
            try await health.warm(config)
            state = .ready
            startKeepAlive()
        } catch {
            state = .failed("El warm-up falló: \(error)")
        }
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        let health = self.health
        let config = self.config
        let interval = self.keepAliveInterval
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                do {
                    try await health.warm(config)
                } catch {
                    await MainActor.run { self?.state = .failed("El server dejó de responder: \(error)") }
                    break
                }
            }
        }
    }

    private func handleUnexpectedExit() {
        // Only meaningful if we still thought it was alive.
        switch state {
        case .ready, .loadingModel, .starting:
            keepAliveTask?.cancel(); keepAliveTask = nil
            handle = nil
            state = .failed("El server se cerró inesperadamente.")
        default:
            break
        }
    }
}
```
> Note: `RealServerProcessLauncher` and `HTTPServerHealth` are referenced as init defaults but defined in Task 4. **This task will not compile until Task 4 exists.** To keep Task 2 green in isolation, temporarily stub them at the bottom of `ServerManager.swift` (delete the stubs in Task 4):
```swift
// TEMP stubs — replaced by real impls in Task 4.
final class RealServerProcessLauncher: ServerProcessLauncher {
    func launch(_ config: ServerConfig) throws -> ServerProcessHandle { fatalError("Task 4") }
}
final class HTTPServerHealth: ServerHealth {
    func probe(_ config: ServerConfig) async -> Bool { false }
    func warm(_ config: ServerConfig) async throws {}
}
```

- [ ] **Step 4: Run → pass** (`-only-testing:GemmaTests/ServerManagerTests`). All 6 cases green.

- [ ] **Step 5: Commit**
```bash
git add -A && git commit -m "feat(m2a): ServerManager state machine (attach/spawn/ready/failed/stop) with fakes"
```

---

## Task 3: keep-alive + unexpected-exit (TDD)

**Files:** Modify `GemmaTests/ServerManagerTests.swift` (add cases). The behavior already exists in `ServerManager` (Task 2 implemented `startKeepAlive`/`handleUnexpectedExit`); this task verifies it.

- [ ] **Step 1: Add the failing tests** to `ServerManagerTests`:
```swift
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
```

- [ ] **Step 2: Run → pass** (the implementation from Task 2 already covers these): `-only-testing:GemmaTests/ServerManagerTests`. If `test_keepAlive…` is flaky, the implementation is fine — keep intervals as written; do not loosen the assertion below `> 1`.

- [ ] **Step 3: Commit**
```bash
git add -A && git commit -m "test(m2a): keep-alive fires while ready + unexpected-exit → failed"
```

---

## Task 4: Real `Process` launcher + HTTP health

**Files:** Create `Runtime/ServerProcess.swift`, `Runtime/HTTPServerHealth.swift`, Test `GemmaTests/ServerProcessTests.swift`. Remove the TEMP stubs from `ServerManager.swift`.

- [ ] **Step 1: Write the failing test** `GemmaTests/ServerProcessTests.swift` (pure argv builder — no spawning):
```swift
import XCTest
@testable import Gemma

final class ServerProcessTests: XCTestCase {
    func test_serverArguments_shape() {
        let cfg = ServerConfig(venvBinURL: URL(fileURLWithPath: "/x/mlx_lm.server"),
                               modelId: "some/model", host: "127.0.0.1", port: 8080)
        XCTAssertEqual(serverArguments(for: cfg),
                       ["--model", "some/model", "--host", "127.0.0.1", "--port", "8080"])
    }
}
```

- [ ] **Step 2: Run → fail** ("cannot find 'serverArguments'").

- [ ] **Step 3: Implement** `Runtime/ServerProcess.swift`:
```swift
import Foundation

/// The argv (after the executable) for `mlx_lm.server`. Pure → unit-testable.
func serverArguments(for config: ServerConfig) -> [String] {
    ["--model", config.modelId, "--host", config.host, "--port", String(config.port)]
}

/// Owns a spawned `mlx_lm.server` process. Captures a tail of stderr for diagnostics and
/// fires `onExit` if the process dies on its own.
final class RealServerProcessHandle: ServerProcessHandle, @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var _stderrTail = ""
    var onExit: (@Sendable () -> Void)?

    var stderrTail: String { lock.lock(); defer { lock.unlock() }; return _stderrTail }

    /// `stderrPipe` is the SAME pipe wired to `process.standardError` by the launcher.
    init(process: Process, stderrPipe: Pipe) {
        self.process = process
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8), let self else { return }
            self.lock.lock()
            self._stderrTail = String((self._stderrTail + s).suffix(4000))
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in self?.onExit?() }
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminationHandler = nil   // expected shutdown — don't fire onExit
        process.terminate()                // SIGTERM
    }
}

/// Spawns `mlx_lm.server` via `Process`. Requires the App Sandbox to be OFF (Task 1).
final class RealServerProcessLauncher: ServerProcessLauncher {
    func launch(_ config: ServerConfig) throws -> ServerProcessHandle {
        let process = Process()
        process.executableURL = config.venvBinURL
        process.arguments = serverArguments(for: config)
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()   // drain stdout so the pipe buffer never blocks the child
        let handle = RealServerProcessHandle(process: process, stderrPipe: stderrPipe)
        try process.run()
        return handle
    }
}
```
> `RealServerProcessHandle.init` attaches the stderr readability handler to the SAME `stderrPipe` the launcher wired to `process.standardError` (no duplicate pipe). The launcher also drains `standardOutput` so the child never blocks on a full stdout pipe.

- [ ] **Step 4: Implement** `Runtime/HTTPServerHealth.swift`:
```swift
import Foundation

/// Real health client: probes `/v1/models` and runs a 1-token warm-up/keep-alive completion.
final class HTTPServerHealth: ServerHealth, @unchecked Sendable {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func probe(_ config: ServerConfig) async -> Bool {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/models"))
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse { return (200..<300).contains(http.statusCode) }
            return false
        } catch { return false }
    }

    func warm(_ config: ServerConfig) async throws {
        let body: [String: Any] = [
            "model": config.modelId,
            "messages": [["role": "user", "content": "."]],
            "max_tokens": 1,
            "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 180   // first warm-up loads the 15GB model
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RuntimeError.generationFailed("warm-up HTTP \( (resp as? HTTPURLResponse)?.statusCode ?? -1): \(String(data: data.prefix(256), encoding: .utf8) ?? "")")
        }
    }
}
```

- [ ] **Step 5: Remove the TEMP stubs** at the bottom of `Runtime/ServerManager.swift` (the placeholder `RealServerProcessLauncher`/`HTTPServerHealth` added in Task 2).

- [ ] **Step 6: Run tests + build**
```bash
xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ServerProcessTests -only-testing:GemmaTests/ServerManagerTests 2>&1 | tail -10
xcodebuild build -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -3
```
Expected: tests pass; BUILD SUCCEEDED.

- [ ] **Step 7: Commit**
```bash
git add -A && git commit -m "feat(m2a): real Process launcher + HTTP health (probe + warm)"
```

---

## Task 5: Wire `ServerManager` into `HarnessModel` + app lifecycle

**Files:** Modify `Harness/HarnessModel.swift`, `Harness/HarnessView.swift`. Read `Harness/HarnessView.swift` first to match its exact structure.

- [ ] **Step 1: Add the ServerManager to `HarnessModel`.** In `Harness/HarnessModel.swift`, add a property + start/stop + a termination observer. Insert after the existing properties (keep everything else unchanged):
```swift
    /// Owns the local mlx-lm server process lifecycle (M2a).
    let serverManager = ServerManager()
```
And add these methods to the class:
```swift
    /// Launch/attach the server and start keeping it warm. Safe to call again (Retry).
    public func startServer() {
        Task { await serverManager.start() }
    }

    /// Terminate the owned server (called on app quit).
    public func stopServer() { serverManager.stop() }
```
And in `init()`, after `self.runtime = ServerRuntime()`, register a terminate observer so the owned 15GB process never orphans:
```swift
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.serverManager.stop() }
        }
```
> Add `import AppKit` at the top of `HarnessModel.swift` (for `NSApplication`).
> `MainActor.assumeIsolated` is valid here because the observer runs on `.main`. If the compiler rejects it, use `Task { @MainActor in self?.serverManager.stop() }` (slightly less reliable during teardown, acceptable fallback).

- [ ] **Step 2: Kick off start from the view.** In `Harness/HarnessView.swift`, add a `.task` to the top-level view that starts the server once. Read the file, then add to the root view (the one holding `model`):
```swift
        .task { model.startServer() }
```
(If `HarnessView` renders `AgentChatView(model: model)`, attach `.task` to that or to the enclosing container — anywhere it runs once when the window appears.)

- [ ] **Step 3: Build**
```bash
xcodebuild build -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**
```bash
git add -A && git commit -m "feat(m2a): HarnessModel owns ServerManager; start on launch, stop on terminate"
```

---

## Task 6: UI — status pill, gate Send, failure + Retry

**Files:** Modify `Harness/AgentChatView.swift`.

- [ ] **Step 1: Add a status helper.** In `AgentChatView.swift`, add a computed view + a derived "ready" flag. Insert inside the struct:
```swift
    private var serverReady: Bool {
        if case .ready = model.serverManager.state { return true }
        return false
    }

    @ViewBuilder private var serverBanner: some View {
        switch model.serverManager.state {
        case .idle, .starting:
            Label("Iniciando server…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .loadingModel:
            Label("Cargando modelo…", systemImage: "shippingbox").foregroundStyle(.secondary)
        case .ready:
            Label("Listo", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .stopped:
            Label("Detenido", systemImage: "stop.circle").foregroundStyle(.secondary)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("Error del server", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(model.serverManager.manualCommand).font(.caption.monospaced())
                    .textSelection(.enabled).foregroundStyle(.secondary)
                Button("Reintentar") { model.startServer() }
            }
        }
    }
```

- [ ] **Step 2: Show the banner + gate Send.** Put the banner at the top of the `body` VStack and gate Send on `serverReady`. Change the `body`'s VStack to start with the banner:
```swift
        VStack(spacing: 0) {
            serverBanner
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.top, 8)
            transcript
            Divider()
            inputBar
        }
```
And in `inputBar`, add `|| !serverReady` to BOTH the TextField and Send `.disabled(...)`:
```swift
            TextField("Message Gemma…", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
                .disabled(model.agentRunning || !serverReady)
            Button("Send", action: send)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.agentRunning || !serverReady || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
```
And in `send()`, add the ready guard:
```swift
    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.agentRunning, serverReady else { return }
        input = ""
        Task { await model.runAgentTurn(text) }
    }
```

- [ ] **Step 3: Build**
```bash
xcodebuild build -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: `graphify update .`; Commit**
```bash
graphify update . || true
git add -A && git commit -m "feat(m2a): server status pill, gate Send on ready, failure + Retry UI"
```

---

## Task 7: Manual end-to-end on macOS + record

- [ ] **Step 1: Ensure no server is running**
```bash
pkill -f mlx_lm.server; sleep 1; lsof -nP -iTCP:8080 -sTCP:LISTEN || echo "port free"
```
- [ ] **Step 2: Run the app from Xcode (⌘R) or build+open.** Observe: status goes "Iniciando server…" → "Cargando modelo…" → "Listo" (first model load ~30-60s). Send is disabled until "Listo".
- [ ] **Step 3: Cold-start gone.** Ask "What time is it?" → fast (~3s), runs `get_current_time`, replies. Leave the app idle ~5 minutes, ask again → still fast (keep-alive kept it warm).
- [ ] **Step 4: Clean shutdown.** Quit the app (⌘Q). Then:
```bash
pgrep -fl mlx_lm.server || echo "server terminated (good)"
```
Expected: nothing — the owned process was killed.
- [ ] **Step 5: Attach path.** Start a server by hand (`cd /Users/hashdown/Projects/personal_agent/spike-mlx && .venv/bin/mlx_lm.server --model unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit --port 8080`), then launch the app → it should reach "Listo" WITHOUT a second 15GB load (check RAM in Activity Monitor; `launchCount`-equivalent: only one python process). Quit the app → the hand-started server should KEEP running (attached, not owned).
- [ ] **Step 6: Record** results in `[[macos-mlx-pivot]]` (M2a done: app self-launches + keeps warm + clean shutdown + attach) and a short §9 note in `docs/superpowers/specs/2026-05-30-m2a-server-lifecycle-design.md`. Commit docs.

**M2a DONE:** the app launches/attaches, keeps warm, and shuts down the mlx-lm server itself; the cold-start is gone in normal use.

---

## Testing Strategy
- **Unit (macOS, no Python/network):** `ServerManagerTests` drives the full state machine with `FakeLauncher`+`FakeHealth` (attach/spawn/ready/failed/stop-owned-only/keep-alive/unexpected-exit); `ServerProcessTests` checks the pure `serverArguments` argv. Run: `xcodebuild test … -destination 'platform=macOS'`.
- **Manual (macOS, real server):** Task 7 — self-launch, cold-start-gone, clean shutdown, attach-to-existing.

## Self-Review (spec coverage)
- Launch/attach + own → Tasks 2,4,5 (start()/attach/spawn). Keep-warm → Tasks 2,3 (keep-alive). Shutdown on quit → Task 5 (willTerminate → stop). Sandbox off → Task 1. State in UI + gate Send + Retry/manual-cmd → Task 6. Pre-warm = readiness gate → Task 2 (warmToReady). Testability via injected launcher/health → Tasks 2,3,4. Manual E2E (cold-start gone, attach) → Task 7. ✅
- Crash-orphan (app crashes, not quits) is explicitly out of scope (manual `pkill` fallback); only graceful quit is handled.
- The `ServerManager` init references `RealServerProcessLauncher`/`HTTPServerHealth` as defaults (Task 2) but they're defined in Task 4 — Task 2 adds TEMP stubs to stay green, Task 4 removes them. Execute in order.

## References
- Spec: `docs/superpowers/specs/2026-05-30-m2a-server-lifecycle-design.md`; pivot `[[macos-mlx-pivot]]`.
- Server cmd: `/Users/hashdown/Projects/personal_agent/spike-mlx/.venv/bin/mlx_lm.server --model unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit --port 8080`.
- `ServerRuntime` (unchanged) is the HTTP client; `ServerManager` is the new lifecycle owner.
