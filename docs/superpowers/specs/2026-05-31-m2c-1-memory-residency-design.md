# M2c-1 — "Mantener el modelo en memoria" toggle + Settings scaffold — Design

> **Parent:** macOS pivot `[[macos-mlx-pivot]]`; M2a server lifecycle (`2026-05-30-m2a-server-lifecycle-design.md`) introduced `ServerManager`/`ServerProcess`/`ServerConfig`; mlx_vlm+MTP migration (`2026-05-31-mlx-vlm-mtp-migration.md`) made `ServerConfig.default` launch `mlx_vlm.server` with a draft model. This is **M2c-1**, the first slice of M2c (Settings UI). Later M2c slices: host/port/model config, keep-warm/idle intervals, image input via `NSImage`.
> **Date:** 2026-05-31. **Platform:** native macOS app (Gemma), branch `main`.

## 1. Problem

The local `mlx_vlm.server` serves the 26B-A4B model from **mmap'd, file-backed** safetensors. When the app sits idle, macOS pages those weights out under memory pressure, so the **first request after idle is slow (cold-start)**. The M2a keep-alive (~75s, 1 token) does not fully prevent this on a MoE (a 1-token gen does not touch every expert), and `mlx_vlm.server` exposes **no mmap/wired flag**.

The user asked (2026-05-31) for a Settings toggle to keep the model resident, **default off**, opt-in.

## 2. Goal

Add a user-facing **"Mantener el modelo en memoria"** toggle (default OFF) that, when ON, launches the server with an MLX **wired-memory limit** so macOS cannot page the weights out — eliminating the cold-start. When OFF, behavior is exactly today's (pageable). Toggling restarts the server. Ship the toggle inside a new macOS **Settings scene** (⌘,), which becomes the scaffold for the rest of M2c.

### Empirical grounding (spike 2026-05-31, M4 24GB, mlx_vlm 0.5.0 — see `[[macos-mlx-pivot]]`)

The launcher `spike-mlx/serve_mlx_vlm.py` (already written and validated) sets `mx.set_wired_limit(N)` before importing `mlx_vlm.server.main()`. Measured:

| Fact | Result |
|---|---|
| Wired cap **without `sudo`** | `max_recommended_working_set_size` = **17.76 GiB (19,069,665,280 B)** — 16 GiB sets clean; 18 GiB raises `ValueError`. **No `sudo` needed.** |
| Boot + generate with wiring | OK, `peak_memory` **16.43 GB** stable, ~29 tok/s. `set_wired_limit` **does pin** the mmap weights (vm_stat wired 3.7→19 GB after warm). |
| Cold-start under memory pressure (hog→exit→timed gen) | **WIRED**: rock-solid ~5–6 s at 4/6/8 GB pressure. **PAGEABLE**: ~5 s at 4 GB but **581 s / 14 s catastrophic thrash at 6 GB**. |

**Conclusion:** wiring's value is *stability under pressure* — it pins the model and forces *other* memory to swap. Chosen resident limit = **16 GiB (17,179,869,184 B)**: covers model+draft (~15.3 GB wired observed), safely under the no-sudo cap, leaves ~1.7 GiB working-set for compute.

**Decisions locked:**
| Decision | Choice |
|---|---|
| Mechanism | MLX `mx.set_wired_limit(N)` via the existing `spike-mlx/serve_mlx_vlm.py` launcher. mmap itself is not disableable; wiring is the real lever. |
| Default | **OFF / pageable** (today's behavior). Wiring is opt-in. |
| Resident limit value | **16 GiB** (`17_179_869_184`). No `sudo`. |
| Persistence | `@AppStorage("keepModelResident")` (UserDefaults), default `false` — per the user's explicit choice. Shared key constant to avoid drift. |
| Launch path | **Always** launch via `python serve_mlx_vlm.py` (the launcher handles N≤0 = pageable). Replaces launching the `mlx_vlm.server` console script directly. |
| Toggle effect | Restart the server (stop → start) with the new wired limit. |
| UI placement | New macOS **`Settings` scene** (⌘,), not a loose window. Becomes the M2c scaffold. |

## 3. Architecture

```
GemmaApp (@main)
├─ @State model = HarnessModel()                 // lifted from HarnessView so both scenes share it
├─ WindowGroup  → HarnessView(model:)            // .task { model.startServer() }
└─ Settings     → SettingsView(model:)           // ⌘, — the toggle lives here
                       │ @AppStorage("keepModelResident") → on change → model.applyKeepModelResident(_:)
HarnessModel
├─ reads UserDefaults[keepModelResident] at init → builds ServerConfig.wiredLimitBytes
├─ serverManager = ServerManager(config:)
└─ applyKeepModelResident(_ on:) → serverManager.setWiredLimit( on ? 16GiB : 0 )   // no-op under XCTest
ServerManager (@MainActor @Observable)
└─ setWiredLimit(_:) → if changed: config.wiredLimitBytes = N; stop(); await start()
ServerConfig (value type)
├─ pythonBinURL, launcherScriptURL   (replace venvBinURL)
├─ wiredLimitBytes: UInt64 = 0
└─ launchArguments = [launcherScriptURL.path] + wiringArguments + serverArguments
ServerProcess
└─ RealServerProcessLauncher launches  pythonBinURL  with  launchArguments  (under the watchdog)
```

`ServerRuntime` / `HTTPServerHealth` / `Agent` / memory are **untouched** — the HTTP contract is identical (the spike confirmed `tool_calls`, thinking-off, and `/v1/chat/completions` all work through the wrapper).

### 3.1 `ServerConfig` (`Runtime/ServerManager.swift`)

Replace `venvBinURL` (pointed at the `mlx_vlm.server` console script) with:
- `var pythonBinURL: URL` — `.venv-vlm/bin/python3.12`
- `var launcherScriptURL: URL` — `spike-mlx/serve_mlx_vlm.py`

Add `var wiredLimitBytes: UInt64 = 0` (0 = pageable; >0 = wire). `serverArguments(for:)` (the `mlx_vlm.server` flags: model/host/port/draft) is **unchanged**.

New pure functions (next to `serverArguments`):
```swift
nonisolated func wiringArguments(for config: ServerConfig) -> [String] {
    config.wiredLimitBytes > 0 ? ["--wired-limit-bytes", String(config.wiredLimitBytes)] : []
}
nonisolated func launchArguments(for config: ServerConfig) -> [String] {
    [config.launcherScriptURL.path] + wiringArguments(for: config) + serverArguments(for: config)
}
```
`ServerConfig.default`: `pythonBinURL` = `…/spike-mlx/.venv-vlm/bin/python3.12`, `launcherScriptURL` = `…/spike-mlx/serve_mlx_vlm.py`, `wiredLimitBytes` = 0 (host/port/model/draft unchanged).

### 3.2 `ServerProcess` (`Runtime/ServerProcess.swift`)

`RealServerProcessLauncher.launch` builds the watchdog with `binPath: config.pythonBinURL.path` and `args: launchArguments(for: config)` (was `config.venvBinURL.path` + `serverArguments`). `manualCommand` (in `ServerManager`): `cd <launcherScriptURL parent> && <pythonBinURL.path> <launchArguments joined>`. The failure message in `ServerManager.start()` reports `config.pythonBinURL.path`.

### 3.3 `ServerManager` (`Runtime/ServerManager.swift`)

- `private let config` → `private var config`.
- New: `func setWiredLimit(_ bytes: UInt64) async { guard bytes != config.wiredLimitBytes else { return }; config.wiredLimitBytes = bytes; stop(); await start() }` — same-value call is a no-op (no needless 20s restart).

### 3.4 `HarnessModel` (`Harness/HarnessModel.swift`)

- `static let residentWiredLimitBytes: UInt64 = 17_179_869_184  // 16 GiB`
- Pure mapping (testable): `static func wiredLimitBytes(keepResident: Bool) -> UInt64 { keepResident ? residentWiredLimitBytes : 0 }`
- Build `serverManager` in `init()` (not inline) so the initial `ServerConfig` reflects the stored toggle:
  `var cfg = ServerConfig.default; cfg.wiredLimitBytes = Self.wiredLimitBytes(keepResident: UserDefaults.standard.bool(forKey: SettingsKeys.keepModelResident)); serverManager = ServerManager(config: cfg)`
- `func applyKeepModelResident(_ on: Bool)` — guarded no-op under XCTest (same guard as `startServer`); else `Task { await serverManager.setWiredLimit(Self.wiredLimitBytes(keepResident: on)) }`.

### 3.5 Settings scene + view

- `SettingsKeys` (small enum, `Settings/SettingsKeys.swift`): `static let keepModelResident = "keepModelResident"`.
- `Settings/SettingsView.swift`: a `Form` with a section "Servidor". `@AppStorage(SettingsKeys.keepModelResident) private var keepResident = false`. `Toggle("Mantener el modelo en memoria", isOn: $keepResident)` with `.onChange(of: keepResident) { _, new in model.applyKeepModelResident(new) }`. Footnote text: explains it keeps the model always ready (no cold-start) at the cost of ~16 GB wired RAM — under memory pressure other apps will slow down — and that toggling restarts the server (~20 s). Takes `let model: HarnessModel` via init.
- `GemmaApp`: lift `@State private var model = HarnessModel()`; `WindowGroup { HarnessView(model: model) }`; add `Settings { SettingsView(model: model) }`.
- `HarnessView`: accept `let model: HarnessModel` (was `@State private var model = HarnessModel()`); keep `.task { model.startServer() }`.

## 4. Data flow

1. App launch → `HarnessModel.init` reads `keepModelResident` from UserDefaults → builds `ServerConfig` with the right `wiredLimitBytes` → `ServerManager(config:)`.
2. `HarnessView.task` → `model.startServer()` → spawns `python serve_mlx_vlm.py [--wired-limit-bytes N] --model … --draft-model …`.
3. User opens Settings (⌘,), flips the toggle → `@AppStorage` persists → `.onChange` → `model.applyKeepModelResident(on)` → `serverManager.setWiredLimit(N)` → stop → start with new limit. Status pill (existing M2a UI) shows starting → ready (~20 s).

## 5. Error handling / edge cases

- **Same value:** `setWiredLimit` early-returns → no restart if the toggle ends on its current value.
- **Resident limit > system cap:** mitigated by choosing 16 GiB (< 17.76 GiB no-sudo cap). If a future device's cap is lower, `mx.set_wired_limit` raises `ValueError` and the server exits during load → existing M2a `.failed(stderrTail)` surfaces it + Retry. (Out of scope: adaptive limit.)
- **XCTest:** `applyKeepModelResident` is a no-op under XCTest (same guard as `startServer`) so the test host never spawns the 15 GB server.
- **Launcher missing:** existing `.failed("No pude lanzar el server…")` path already reports the bad binary path (now `pythonBinURL`).

## 6. Testing

Unit (no server, fakes — extend existing `ServerProcessTests`/`ServerManagerTests`):
- `wiringArguments`: 0 → `[]`; N → `["--wired-limit-bytes","N"]`.
- `launchArguments`: pageable → `[script, …serverArgs]` (no wiring flag, script first); wired → `[script, "--wired-limit-bytes","N", …serverArgs]`.
- `serverArguments` existing tests: update `ServerConfig(...)` construction to the new fields; assertions unchanged.
- `ServerConfig.default`: `pythonBinURL` ends `python3.12`; `launcherScriptURL` ends `serve_mlx_vlm.py`; `wiredLimitBytes == 0`.
- `ServerManager.setWiredLimit`: with fakes, changing the value triggers one stop+start and updates `config.wiredLimitBytes`; same value = no restart (assert launch count unchanged).
- `HarnessModel.wiredLimitBytes(keepResident:)`: false → 0; true → `residentWiredLimitBytes`.
- `manualCommand`: contains `pythonBinURL.path`, the script path, and (when wired) the wiring flag; is shell-runnable shape.

Live (gated `TEST_RUNNER_GEMMA_LIVE_SERVER=1`, extend `ServerManagerLiveTests`): update `ServerConfig.default.venvBinURL` → `.pythonBinURL`. Optional resident-mode live check: start with `wiredLimitBytes = 16 GiB`, assert `.ready`, stop clean (no orphan). (Spike already proved this manually.)

GUI (human, owed): ⌘, opens Settings; toggle ON restarts server to ready; OFF restarts; footnote readable.

## 7. Out of scope (later M2c slices)

Host/port/model selection UI; keep-warm/idle interval settings; image input (`NSImage`, multimodal); adaptive wired limit / `sudo sysctl` raise; exposing draft-model/spec-decode toggles; `draftKind` enum (deferred from migration review).

## 8. File structure

- Modify: `Runtime/ServerManager.swift` (ServerConfig fields + `wiringArguments`/`launchArguments` + `var config` + `setWiredLimit`), `Runtime/ServerProcess.swift` (launch via python+launcher), `Harness/HarnessModel.swift` (init from UserDefaults + `applyKeepModelResident` + mapping), `Harness/HarnessView.swift` (accept model), `GemmaApp.swift` (lift model + Settings scene).
- Create: `Settings/SettingsKeys.swift`, `Settings/SettingsView.swift`.
- Tests: extend `GemmaTests/ServerProcessTests.swift`, `GemmaTests/ServerManagerTests.swift`, `GemmaTests/ServerManagerLiveTests.swift`; new `GemmaTests/HarnessResidencyTests.swift` (pure mapping).
- Runtime dep (already present): `spike-mlx/serve_mlx_vlm.py`, `.venv-vlm` (mlx-vlm 0.5.0).

## 9. Resultado M2c-1 (a completar al verificar)

_(pending implementation)_
