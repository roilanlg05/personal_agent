# M2c-1 — "Mantener el modelo en memoria" toggle + Settings scaffold — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings (⌘,) toggle "Mantener el modelo en memoria" (default OFF) that launches the local `mlx_vlm.server` with an MLX wired-memory limit (16 GiB) to eliminate the cold-start; OFF = today's pageable behavior. Toggling restarts the server.

**Architecture:** The validated launcher `spike-mlx/serve_mlx_vlm.py` (sets `mx.set_wired_limit(N)` then runs `mlx_vlm.server.main()`) becomes the spawn target. `ServerConfig` gains `pythonBinURL`/`launcherScriptURL`/`wiredLimitBytes`; `ServerManager` gains `setWiredLimit`; `HarnessModel` maps an `@AppStorage("keepModelResident")` flag → bytes and restarts. A new macOS `Settings` scene hosts the toggle and is the scaffold for the rest of M2c. `ServerRuntime`/`HTTPServerHealth`/`Agent`/memory untouched (identical HTTP contract).

**Tech Stack:** Swift 6 / SwiftUI / AppKit, `@MainActor @Observable`, XCTest, MLX `mx.set_wired_limit` (Python launcher), Xcode 26.2 (filesystem-synchronized groups → new files auto-included, **no `project.pbxproj` edits needed**).

**Spec:** `docs/superpowers/specs/2026-05-31-m2c-1-memory-residency-design.md`. **Empirical grounding for the design:** spike in `[[macos-mlx-pivot]]` (no sudo; cap 17.76 GiB; 16 GiB stable, peak 16.43 GB; wired ~5-6s vs pageable up to 581s under pressure).

**Build/test command (success = "Test Suite … passed"):**
```bash
xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS'
```
**Pre-req:** no live server needed for the unit suite (the host app no-ops `startServer`/`applyKeepModelResident` under XCTest). Live tests are gated by `TEST_RUNNER_GEMMA_LIVE_SERVER=1`.

---

### Task 1: `ServerConfig` fields + `wiringArguments`/`launchArguments`

**Files:**
- Modify: `Gemma/Gemma/Runtime/ServerManager.swift` (`ServerConfig` struct + `.default`)
- Modify: `Gemma/Gemma/Runtime/ServerProcess.swift` (add the two pure functions next to `serverArguments`)
- Test: `Gemma/GemmaTests/ServerProcessTests.swift`

- [ ] **Step 1: Write the failing tests** — replace the body of `ServerProcessTests` with the updated construction (new fields) + new wiring/launch tests:

```swift
import XCTest
@testable import Gemma

final class ServerProcessTests: XCTestCase {
    private func cfg(wired: UInt64 = 0, draft: Bool = false) -> ServerConfig {
        ServerConfig(pythonBinURL: URL(fileURLWithPath: "/x/.venv-vlm/bin/python3.12"),
                     launcherScriptURL: URL(fileURLWithPath: "/x/spike-mlx/serve_mlx_vlm.py"),
                     modelId: "some/model", host: "127.0.0.1", port: 8080,
                     draftModelId: draft ? "some/assistant" : nil,
                     draftKind: draft ? "mtp" : nil,
                     draftBlockSize: draft ? 3 : nil,
                     wiredLimitBytes: wired)
    }

    func test_serverArguments_baseShape_noDraft() {
        XCTAssertEqual(serverArguments(for: cfg()),
                       ["--model", "some/model", "--host", "127.0.0.1", "--port", "8080"])
    }

    func test_serverArguments_appendsDraftFlags_whenConfigured() {
        XCTAssertEqual(serverArguments(for: cfg(draft: true)),
                       ["--model", "some/model", "--host", "127.0.0.1", "--port", "8080",
                        "--draft-model", "some/assistant", "--draft-kind", "mtp", "--draft-block-size", "3"])
    }

    func test_wiringArguments_emptyWhenPageable() {
        XCTAssertEqual(wiringArguments(for: cfg(wired: 0)), [])
    }

    func test_wiringArguments_setsFlagWhenWired() {
        XCTAssertEqual(wiringArguments(for: cfg(wired: 17_179_869_184)),
                       ["--wired-limit-bytes", "17179869184"])
    }

    func test_launchArguments_pageable_scriptFirst_noWiringFlag() {
        let a = launchArguments(for: cfg(wired: 0, draft: true))
        XCTAssertEqual(a.first, "/x/spike-mlx/serve_mlx_vlm.py", "launcher script must be argv[0] for python")
        XCTAssertFalse(a.contains("--wired-limit-bytes"))
        XCTAssertEqual(Array(a.suffix(10)),
                       ["--model", "some/model", "--host", "127.0.0.1", "--port", "8080",
                        "--draft-model", "some/assistant", "--draft-kind", "mtp", "--draft-block-size", "3"])
    }

    func test_launchArguments_wired_insertsFlagBetweenScriptAndServerArgs() {
        let a = launchArguments(for: cfg(wired: 17_179_869_184))
        XCTAssertEqual(Array(a.prefix(3)),
                       ["/x/spike-mlx/serve_mlx_vlm.py", "--wired-limit-bytes", "17179869184"])
        XCTAssertEqual(a[3], "--model")
    }

    func test_default_config_targets_launcher_and_python_pageable() {
        let c = ServerConfig.default
        XCTAssertTrue(c.pythonBinURL.path.hasSuffix("python3.12"), "default must run the venv python, got \(c.pythonBinURL.path)")
        XCTAssertTrue(c.launcherScriptURL.path.hasSuffix("serve_mlx_vlm.py"), "default must use the wiring launcher, got \(c.launcherScriptURL.path)")
        XCTAssertEqual(c.wiredLimitBytes, 0, "default must be pageable (toggle off)")
        XCTAssertEqual(c.draftKind, "mtp")
        XCTAssertNotNil(c.draftModelId)
        XCTAssertEqual(c.draftBlockSize, 3)
    }

    func test_watchdogScript_contains_guardrails() {
        let c = cfg()
        let script = watchdogScript(binPath: c.pythonBinURL.path,
                                    args: launchArguments(for: c),
                                    parentPID: 4242)
        XCTAssertTrue(script.contains("/x/.venv-vlm/bin/python3.12"), "missing python path:\n\(script)")
        XCTAssertTrue(script.contains("serve_mlx_vlm.py"), "missing launcher:\n\(script)")
        XCTAssertTrue(script.contains("some/model"), "missing model id:\n\(script)")
        XCTAssertTrue(script.contains("trap"), "missing trap:\n\(script)")
        XCTAssertTrue(script.contains("kill -0 4242"), "missing parent-pid guard:\n\(script)")
        XCTAssertTrue(script.contains("sleep"), "missing sleep poll:\n\(script)")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -30`
Expected: COMPILE FAIL — `ServerConfig` has no `pythonBinURL`/`launcherScriptURL`/`wiredLimitBytes`; `wiringArguments`/`launchArguments` undefined.

- [ ] **Step 3: Update `ServerConfig`** in `Runtime/ServerManager.swift` — replace `var venvBinURL: URL` and the `.default` initializer:

```swift
nonisolated struct ServerConfig: Sendable {
    /// The venv Python that runs the wiring launcher (.venv-vlm/bin/python3.12).
    var pythonBinURL: URL
    /// The wiring launcher script (spike-mlx/serve_mlx_vlm.py): sets mx.set_wired_limit then runs mlx_vlm.server.
    var launcherScriptURL: URL
    var modelId: String
    var host: String
    var port: Int
    /// MTP speculative-decoding drafter (HF id or path). nil = no speculative decoding.
    var draftModelId: String? = nil
    /// Drafter family for mlx_vlm: "mtp" (Gemma 4 assistant) or "dflash". nil = omit flag.
    var draftKind: String? = nil
    /// Tokens drafted per verification round. nil = use the drafter's configured default.
    var draftBlockSize: Int? = nil
    /// MLX wired-memory limit in bytes. 0 = pageable (mmap, may cold-start);
    /// >0 = wire the model resident so macOS won't page it out (anti-cold-start). See spec §2.
    var wiredLimitBytes: UInt64 = 0
    var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    static let `default` = ServerConfig(
        pythonBinURL: URL(fileURLWithPath: "/Users/hashdown/Projects/personal_agent/spike-mlx/.venv-vlm/bin/python3.12"),
        launcherScriptURL: URL(fileURLWithPath: "/Users/hashdown/Projects/personal_agent/spike-mlx/serve_mlx_vlm.py"),
        modelId: "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
        host: "127.0.0.1",
        port: 8080,
        draftModelId: "guardiangate1775/gemma-4-26B-A4B-it-assistant-4bit",
        draftKind: "mtp",
        draftBlockSize: 3,
        wiredLimitBytes: 0)
}
```

- [ ] **Step 4: Add the pure functions** in `Runtime/ServerProcess.swift`, right after `serverArguments(for:)` (keep `serverArguments` unchanged):

```swift
/// The `--wired-limit-bytes` flag for the launcher, or empty when pageable. Pure → testable.
nonisolated func wiringArguments(for config: ServerConfig) -> [String] {
    config.wiredLimitBytes > 0 ? ["--wired-limit-bytes", String(config.wiredLimitBytes)] : []
}

/// Full argv for the venv python: the launcher script, optional wiring flag, then the mlx_vlm.server flags.
nonisolated func launchArguments(for config: ServerConfig) -> [String] {
    [config.launcherScriptURL.path] + wiringArguments(for: config) + serverArguments(for: config)
}
```

- [ ] **Step 5: Run tests to verify Task-1 tests pass**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ServerProcessTests 2>&1 | tail -20`
Expected: ServerProcessTests PASS. (The wider suite will still fail to build — `ServerProcess.swift`/`ServerManager.swift` `manualCommand` still reference `venvBinURL`; fixed in Task 2.)

- [ ] **Step 6: Commit**

```bash
git add Gemma/Gemma/Runtime/ServerManager.swift Gemma/Gemma/Runtime/ServerProcess.swift Gemma/GemmaTests/ServerProcessTests.swift
git commit -m "feat(m2c-1): ServerConfig wiring fields + wiringArguments/launchArguments"
```

---

### Task 2: Launch via python + launcher; fix `manualCommand` and failure message

**Files:**
- Modify: `Gemma/Gemma/Runtime/ServerProcess.swift:68-84` (`RealServerProcessLauncher.launch`)
- Modify: `Gemma/Gemma/Runtime/ServerManager.swift` (`manualCommand`, and the `.failed(...)` message in `start()`)
- Test: `Gemma/GemmaTests/ServerManagerTests.swift` (`test_manualCommand_is_runnable`)

- [ ] **Step 1: Update the `manualCommand` test** in `ServerManagerTests.swift` — replace `test_manualCommand_is_runnable` with one that also asserts the python + launcher shape:

```swift
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
```

- [ ] **Step 2: Run to verify it fails to compile**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -30`
Expected: COMPILE FAIL — `ServerProcess.swift`/`ServerManager.swift` still reference `config.venvBinURL` (removed in Task 1).

- [ ] **Step 3: Update `RealServerProcessLauncher.launch`** in `ServerProcess.swift` — replace the `process.arguments = [...]` block:

```swift
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", watchdogScript(
            binPath: config.pythonBinURL.path,
            args: launchArguments(for: config),
            parentPID: ProcessInfo.processInfo.processIdentifier)]
```

- [ ] **Step 4: Update `manualCommand` and the failure message** in `ServerManager.swift`:

```swift
    /// Manual fallback command shown in the UI on failure.
    var manualCommand: String {
        let dir = config.launcherScriptURL.deletingLastPathComponent()   // …/spike-mlx
        let argv = ([config.pythonBinURL.path] + launchArguments(for: config)).joined(separator: " ")
        return "cd \(dir.path) && \(argv)"
    }
```

And in `start()`, change the launch-failure message:

```swift
            state = .failed("No pude lanzar el server (\(error)). Binario: \(config.pythonBinURL.path)")
```

- [ ] **Step 5: Run the full suite to verify it builds and passes**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -20`
Expected: BUILD OK; all non-live tests PASS (live tests skip without `TEST_RUNNER_GEMMA_LIVE_SERVER`).

- [ ] **Step 6: Commit**

```bash
git add Gemma/Gemma/Runtime/ServerProcess.swift Gemma/Gemma/Runtime/ServerManager.swift Gemma/GemmaTests/ServerManagerTests.swift
git commit -m "feat(m2c-1): launch server via python + serve_mlx_vlm.py wrapper"
```

---

### Task 3: `ServerManager.setWiredLimit` (restart on change)

**Files:**
- Modify: `Gemma/Gemma/Runtime/ServerManager.swift` (`config` → `var`; add `setWiredLimit`)
- Test: `Gemma/GemmaTests/ServerManagerTests.swift`

- [ ] **Step 1: Write the failing tests** — append to `ServerManagerTests`:

```swift
    func test_setWiredLimit_change_restarts_with_new_limit() async {
        let launcher = FakeLauncher()
        // start: spawn→ready ; setWiredLimit: stop()+start() → probe false then true → spawn again
        let health = FakeHealth(probeResults: [false, true, false, true])
        let m = makeManager(launcher: launcher, health: health)
        await m.start()
        XCTAssertEqual(launcher.launchCount, 1)
        await m.setWiredLimit(17_179_869_184)
        XCTAssertEqual(m.state, .ready)
        XCTAssertEqual(launcher.launchCount, 2, "changing the wired limit must restart (stop+start)")
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ServerManagerTests 2>&1 | tail -20`
Expected: COMPILE FAIL — `setWiredLimit` undefined.

- [ ] **Step 3: Implement** in `ServerManager.swift` — change the stored `config` to `var` and add the method:

Change the property declaration:
```swift
    @ObservationIgnored private var config: ServerConfig
```

Add after `stop()`:
```swift
    /// Change the MLX wired-memory limit and restart the server so it takes effect.
    /// No-op if the limit is unchanged (avoids a needless ~20s reload).
    func setWiredLimit(_ bytes: UInt64) async {
        guard bytes != config.wiredLimitBytes else { return }
        config.wiredLimitBytes = bytes
        stop()
        await start()
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ServerManagerTests 2>&1 | tail -20`
Expected: ServerManagerTests PASS.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Runtime/ServerManager.swift Gemma/GemmaTests/ServerManagerTests.swift
git commit -m "feat(m2c-1): ServerManager.setWiredLimit restarts on change"
```

---

### Task 4: `HarnessModel` mapping + init-from-UserDefaults + `applyKeepModelResident`

**Files:**
- Create: `Gemma/Gemma/Settings/SettingsKeys.swift`
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift`
- Test: `Gemma/GemmaTests/HarnessResidencyTests.swift` (new)

- [ ] **Step 1: Create the shared key** `Gemma/Gemma/Settings/SettingsKeys.swift`:

```swift
import Foundation

/// UserDefaults keys shared between the Settings UI (@AppStorage) and non-View readers (HarnessModel).
enum SettingsKeys {
    /// Bool. When true the server is launched with a wired-memory limit (anti-cold-start). Default false.
    static let keepModelResident = "keepModelResident"
}
```

- [ ] **Step 2: Write the failing test** `Gemma/GemmaTests/HarnessResidencyTests.swift`:

```swift
import XCTest
@testable import Gemma

final class HarnessResidencyTests: XCTestCase {
    func test_wiredLimitBytes_pageableWhenOff() {
        XCTAssertEqual(HarnessModel.wiredLimitBytes(keepResident: false), 0)
    }

    func test_wiredLimitBytes_residentValueWhenOn() {
        XCTAssertEqual(HarnessModel.wiredLimitBytes(keepResident: true), HarnessModel.residentWiredLimitBytes)
    }

    func test_residentLimit_is_16GiB_underNoSudoCap() {
        // 16 GiB exactly; must stay under the measured no-sudo cap (17.76 GiB ≈ 19_069_665_280 B).
        XCTAssertEqual(HarnessModel.residentWiredLimitBytes, 17_179_869_184)
        XCTAssertLessThan(HarnessModel.residentWiredLimitBytes, 19_069_665_280)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/HarnessResidencyTests 2>&1 | tail -20`
Expected: COMPILE FAIL — `HarnessModel.wiredLimitBytes`/`residentWiredLimitBytes` undefined.

- [ ] **Step 4: Implement in `HarnessModel.swift`.** Add the constant + mapping near the top of the class; build `serverManager` in `init`; add `applyKeepModelResident`.

Replace the property `let serverManager = ServerManager()` with:
```swift
    /// Owns the local mlx_vlm server process lifecycle (M2a). Built in init() so its initial
    /// ServerConfig reflects the persisted "keep model resident" toggle (M2c-1).
    let serverManager: ServerManager

    /// MLX wired-memory limit when "keep model resident" is ON. 16 GiB — covers model+draft
    /// (~15.3 GB) under the no-sudo cap (~17.76 GiB), leaving working-set for compute. See spec §2.
    static let residentWiredLimitBytes: UInt64 = 17_179_869_184

    /// Pure mapping toggle → wired bytes. 0 = pageable.
    static func wiredLimitBytes(keepResident: Bool) -> UInt64 {
        keepResident ? residentWiredLimitBytes : 0
    }
```

In `init()`, before the existing body, build the manager from the stored toggle:
```swift
    public init() {
        var cfg = ServerConfig.default
        cfg.wiredLimitBytes = Self.wiredLimitBytes(
            keepResident: UserDefaults.standard.bool(forKey: SettingsKeys.keepModelResident))
        self.serverManager = ServerManager(config: cfg)
        self.settings = settingsStore.load()
        self.runtime = ServerRuntime()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopServer() }
        }
    }
```

Add after `stopServer()`:
```swift
    /// Apply the "keep model resident" toggle: restart the server with/without a wired limit.
    /// No-op under XCTest (same guard as startServer — must not spawn the 15GB server in tests).
    public func applyKeepModelResident(_ on: Bool) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { await serverManager.setWiredLimit(Self.wiredLimitBytes(keepResident: on)) }
    }
```

- [ ] **Step 5: Run to verify pass**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/HarnessResidencyTests 2>&1 | tail -20`
Expected: HarnessResidencyTests PASS.

- [ ] **Step 6: Commit**

```bash
git add Gemma/Gemma/Settings/SettingsKeys.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/HarnessResidencyTests.swift
git commit -m "feat(m2c-1): HarnessModel maps keepModelResident toggle to wired limit"
```

---

### Task 5: Settings scene + view; share `HarnessModel` across scenes

**Files:**
- Create: `Gemma/Gemma/Settings/SettingsView.swift`
- Modify: `Gemma/Gemma/GemmaApp.swift`
- Modify: `Gemma/Gemma/Harness/HarnessView.swift:4` (accept `model` instead of creating it)

> No unit test — SwiftUI scene wiring. Verification = build green + the human GUI check at the end. Keep the view tiny.

- [ ] **Step 1: Create `Gemma/Gemma/Settings/SettingsView.swift`:**

```swift
import SwiftUI

/// macOS Settings (⌘,). M2c-1 hosts the "keep model resident" toggle; later M2c slices add
/// host/port/model and image options here.
struct SettingsView: View {
    let model: HarnessModel
    @AppStorage(SettingsKeys.keepModelResident) private var keepResident = false

    var body: some View {
        Form {
            Section("Servidor") {
                Toggle("Mantener el modelo en memoria", isOn: $keepResident)
                    .onChange(of: keepResident) { _, new in model.applyKeepModelResident(new) }
                Text("Cablea el modelo en RAM (~16 GB) para que nunca tenga arranque en frío. "
                     + "Bajo presión de memoria, otras apps irán más lento. "
                     + "Cambiarlo reinicia el servidor (~20 s).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
```

- [ ] **Step 2: Lift the model in `GemmaApp.swift` and add the Settings scene:**

```swift
import SwiftUI

@main
struct GemmaApp: App {
    @State private var model = HarnessModel()

    var body: some Scene {
        WindowGroup {
            HarnessView(model: model)
        }
        Settings {
            SettingsView(model: model)
        }
    }
}
```

- [ ] **Step 3: Make `HarnessView` accept the model.** Change line 4 of `Harness/HarnessView.swift` from `@State private var model = HarnessModel()` to:

```swift
    let model: HarnessModel
```

(Leave the `.task { model.startServer() }` and the rest of the view unchanged.)

- [ ] **Step 4: Build + run the full suite**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -20`
Expected: BUILD OK; full suite PASS. (If `HarnessView` is referenced anywhere else without a `model:` argument — e.g. a preview — update those call sites to pass `model: HarnessModel()`.)

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Settings/SettingsView.swift Gemma/Gemma/GemmaApp.swift Gemma/Gemma/Harness/HarnessView.swift
git commit -m "feat(m2c-1): Settings scene with keep-model-resident toggle"
```

---

### Task 6: Update live test for the new launch path

**Files:**
- Modify: `Gemma/GemmaTests/ServerManagerLiveTests.swift:24` (`venvBinURL` → `pythonBinURL`)

- [ ] **Step 1: Update the executable-file guard.** Change `ServerConfig.default.venvBinURL.path` to `ServerConfig.default.pythonBinURL.path`:

```swift
            FileManager.default.isExecutableFile(atPath: ServerConfig.default.pythonBinURL.path),
```

- [ ] **Step 2: Build the test target (compile check only; live test stays gated)**

Run: `xcodebuild build-for-testing -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -10`
Expected: BUILD OK (no `venvBinURL` references remain).

- [ ] **Step 3: (Optional, manual) run the live test** to confirm the python+launcher path spawns and reaches `.ready`. Requires the venv + cached model; kill anything on port 8080 first.

Run:
```bash
lsof -ti tcp:8080 | xargs -r kill
xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' \
  -only-testing:GemmaTests/ServerManagerLiveTests \
  TEST_RUNNER_GEMMA_LIVE_SERVER=1 2>&1 | tail -20
```
Expected: PASS — spawn → `.ready` (~20s) → stop, no orphan on 8080. (Already proven manually in the spike; this is confirmation.)

- [ ] **Step 4: Commit**

```bash
git add Gemma/GemmaTests/ServerManagerLiveTests.swift
git commit -m "test(m2c-1): live test uses pythonBinURL launch path"
```

---

### Task 7: Final verification + graph update

- [ ] **Step 1: Run the complete suite**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -25`
Expected: "Test Suite 'All tests' passed", 0 failures.

- [ ] **Step 2: Update the knowledge graph** (per CLAUDE.md, AST-only, no API cost)

Run: `graphify update .`

- [ ] **Step 3: Commit any graph changes**

```bash
git add graphify-out
git commit -m "chore(m2c-1): graphify update"
```

- [ ] **Step 4: GUI check (human, owed — not blocking).** `⌘R` in Xcode; ⌘, opens Settings; flip the toggle ON → the M2a status pill cycles starting → ready (~20s) with the model wired (`vm_stat | grep "wired"` rises to ~19 GB); flip OFF → restarts pageable. Footnote text reads correctly.

---

## Self-Review

**Spec coverage:**
- §3.1 ServerConfig fields + wiring/launch fns → Task 1. ✓
- §3.2 ServerProcess launch + manualCommand + failure msg → Task 2. ✓
- §3.3 ServerManager `var config` + `setWiredLimit` → Task 3. ✓
- §3.4 HarnessModel mapping + init-from-UserDefaults + applyKeepModelResident → Task 4. ✓
- §3.5 SettingsKeys + SettingsView + GemmaApp lift + HarnessView accept model → Tasks 4 (keys) + 5. ✓
- §6 Testing: unit (Tasks 1,3,4), live update (Task 6), GUI owed (Task 7). ✓

**Placeholder scan:** none — all steps carry concrete code/commands.

**Type consistency:** `pythonBinURL`/`launcherScriptURL`/`wiredLimitBytes` used identically across Tasks 1-4; `wiringArguments`/`launchArguments`/`setWiredLimit`/`wiredLimitBytes(keepResident:)`/`residentWiredLimitBytes`/`applyKeepModelResident`/`SettingsKeys.keepModelResident` names consistent throughout. Resident value `17_179_869_184` matches in spec, plan, and tests.

**Note for the implementer:** Xcode 26.2 filesystem-synchronized groups mean new files under `Gemma/Gemma/Settings/` and `Gemma/GemmaTests/` are auto-included — **no `project.pbxproj` edits**. If a build surprisingly can't find a new type, that assumption broke: open the project and confirm the file's target membership.
