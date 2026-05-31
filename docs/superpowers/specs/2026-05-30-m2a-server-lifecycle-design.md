# M2a — Server lifecycle management (app launches/keeps-warm the mlx-lm server) — Design

> **Parent:** macOS pivot `[[macos-mlx-pivot]]`; M1 spec `2026-05-30-macos-mlx-m1-design.md` §8 (M2). M2 was decomposed into three independent sub-projects; this is **M2a** (chosen first). M2b = capture-v2 redesign (`2026-05-30-s5a-v2-capture-redesign-design.md`, to be adapted iOS→macOS); M2c = port remaining views + image via `NSImage`.
> **Date:** 2026-05-30. **Platform:** native macOS app (Gemma), branch `main`.

## 1. Problem

After M1 the macOS app talks to a local `mlx-lm` server, but the user must start that server by hand in a terminal (`cd spike-mlx && .venv/bin/mlx_lm.server --model … --port 8080`). Worse, the **first request after the server sits idle is slow (~20-30s)** because macOS pages out the 15GB model weights / the Metal GPU state goes cold; subsequent requests are ~3s. The thinking fix (M1, `enable_thinking=false`) removed the per-reply chain-of-thought cost, but the cold-start remains.

## 2. Goal

Make the app self-contained and snappy:
1. The app **launches and owns** the `mlx-lm` server subprocess on startup (or **attaches** to one already running on the port, to avoid loading 15GB twice).
2. It **keeps the model warm** with a periodic minimal keep-alive inference while the app is open, so the cold-start never bites in normal use.
3. It **shuts the owned server down** cleanly when the app quits (no orphaned 15GB process).
4. It surfaces server **state** in the UI and gates chat input until the model is genuinely ready.

**Decisions locked (brainstorm 2026-05-30):**
| Decision | Choice |
|---|---|
| Architecture | Dedicated `ServerManager` (`Process`-based). `ServerRuntime` unchanged (HTTP client). Approach 1 of 3 (rejected: LaunchAgent — overkill; supervise-external-only — doesn't manage the process). |
| App Sandbox | **Disabled** (`com.apple.security.app-sandbox` removed). Personal, non-App-Store app on the user's own Mac → `Process` may spawn the Python server freely. |
| Keep-warm policy | **Periodic keep-alive while the app is open** (~75s interval, `max_tokens:1`). Chosen over foreground-only / pre-warm-only for max responsiveness (Jarvis-like). |
| Crash recovery | **Manual Retry** in the UI (no automatic auto-restart loop in M2a). |
| Venv/model provisioning | **Out of scope** — assume the spike already created `spike-mlx/.venv` + cached the model. |

## 3. Architecture

App = SwiftUI/AppKit UI + `Agent`/`ToolRegistry`/`Memory` + `ServerRuntime` (HTTP) — all unchanged — **plus a new `ServerManager`** that owns the server process lifecycle. `HarnessModel` creates the `ServerManager`, starts it on launch, exposes its state to the UI, and stops it on quit. Clean separation: `ServerManager` = process/health/warmth, `ServerRuntime` = requests, `HarnessModel` = chat orchestration.

```
macOS app (sandbox OFF)
├─ ServerManager (Process owner) ──spawn/attach/keep-warm/stop──► mlx_lm.server (localhost:8080, Gemma 4 26B)
├─ ServerRuntime (HTTP client, unchanged) ──────────────────────►  ▲
├─ Agent + ToolRegistry + Memory (unchanged)
└─ AgentChatView (status pill + Send gated on .ready)
```

### 3.1 `ServerManager` (`Runtime/ServerManager.swift`, `@MainActor @Observable`)

**State:**
```
enum ServerState: Equatable {
    case idle            // not started
    case starting        // process spawned, waiting for HTTP to come up
    case loadingModel    // HTTP up, running pre-warm inference (model loads)
    case ready           // pre-warm done → model hot, accepting chat
    case failed(String)  // with a human-readable reason
    case stopped         // owned process terminated
}
```
The **pre-warm doubles as the readiness gate**: `ready` means the model has actually served one inference, not merely that the port is open (the port responds before the model is loaded).

**Config** (`ServerConfig` value type): `venvBinURL` (default `…/spike-mlx/.venv/bin/mlx_lm.server`), `modelId` (default `unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit`), `host` (`127.0.0.1`), `port` (`8080`). Hardcoded defaults for M2a; a Settings UI hook is M2c.

**Dependencies (injected for testability — unit tests must NOT spawn real Python):**
- `ProcessLauncher` protocol: `func launch(_ config: ServerConfig) throws -> ServerProcessHandle` (real impl builds + runs an `NSTask`/`Process`; captures stdout/stderr to a log; exposes a termination callback + `terminate()`). A `FakeLauncher` is used in tests.
- A probe/warm seam: `func probeReady() async -> Bool` (HTTP GET `/v1/models`) and `func preWarm() async throws` (a tiny completion). In tests these are injected closures/fakes so no network is needed.

**Behavior:**
- `start()`:
  1. **Attach path:** if `probeReady()` already succeeds (a server is up on the port), do NOT spawn. Mark `owned = false`, run `preWarm()`, → `ready`.
  2. **Spawn path:** else `launcher.launch(config)` → `starting`; poll `probeReady()` until true or timeout (~120s) → `loadingModel`; `preWarm()` → `ready`, `owned = true`.
  3. Any throw / timeout → `failed(reason)` (include the binary path or the captured stderr tail).
- **keep-alive:** while `state == .ready`, a repeating task every ~75s sends a minimal completion (`max_tokens:1`, prompt "."). Success → stay ready; failure (server died) → `failed` (offer Retry). Cancelled when leaving `.ready` / on `stop()`.
- `stop()`: if `owned`, `handle.terminate()` (SIGTERM; SIGKILL fallback after a short grace) and cancel keep-alive → `stopped`. If not owned (attached), just cancel keep-alive (leave the external server running).
- Unexpected process exit (termination callback fires while we expected it alive) → `failed` (offer Retry).

### 3.2 Wiring
- `HarnessModel` gains `serverManager: ServerManager` (created with default config; `ServerRuntime` points at the same host:port). `HarnessModel` calls `serverManager.start()` on first appear / init.
- `GemmaApp` observes `NSApplication.willTerminateNotification` (or `scenePhase` → `.background`/termination) and calls `serverManager.stop()` so the owned 15GB process never orphans.

### 3.3 UI (`AgentChatView`)
- A **status pill** bound to `serverManager.state`: e.g. "⏳ Iniciando…", "📦 Cargando modelo…", "🟢 Listo", "🔴 Error", "⏹ Detenido".
- **Send is disabled unless `.ready`** (and while a turn is running, as today).
- On `.failed(reason)`: show the reason + the **manual fallback command** (`cd spike-mlx && .venv/bin/mlx_lm.server --model … --port 8080`) as selectable text + a **Retry** button calling `serverManager.start()`.

## 4. Data flow
`app launch → ServerManager.start() (async) → spawn-or-attach → poll /v1/models → loadingModel → preWarm → ready → UI enables Send`. Chat turns go through `ServerRuntime` (unchanged) against the now-warm server. Idle → keep-alive every ~75s keeps weights resident. `app quit → ServerManager.stop() → SIGTERM owned process`.

## 5. Error handling
- venv binary missing → `failed("No encontré mlx_lm.server en <path> — corre el setup del spike")` + manual command.
- HTTP never comes up within the timeout → `failed("el server no respondió en Ns")` + last stderr lines from the captured log.
- Port occupied by a non-mlx process (probe/health shape unexpected) → `failed`.
- Owned process exits unexpectedly → `failed` + Retry.
- Spawn throws → `failed(error)`.
- All server stdout/stderr captured to a log file (e.g. `~/Library/Application Support/Gemma/mlx-server.log` or a temp path) for diagnostics + the failure tail.

## 6. Testing
- **Unit (no real Python; inject `FakeLauncher` + fake probe/warm):**
  - attach-when-already-up: probe succeeds → no spawn, `owned=false`, → `ready`.
  - spawn-when-down: probe fails then succeeds → spawn, `starting`→`loadingModel`→`ready`, `owned=true`.
  - failed-on-missing-binary / launch-throws → `failed`.
  - failed-on-probe-timeout → `failed`.
  - keep-alive fires while `ready` (and stops on `stop()`).
  - `stop()` terminates ONLY an owned process (attached → process left running).
  - unexpected process exit → `failed`.
- **Manual (macOS, real server):**
  - Launch app with NO server running → status `starting`→`loadingModel`→`ready`; first query is fast (no cold-start).
  - Leave idle ~5 min → next query still fast (keep-warm worked).
  - Quit app → `pgrep -f mlx_lm.server` returns nothing (owned process killed).
  - Relaunch while a server is already up on :8080 → app attaches (no second 15GB load; check Activity Monitor / RAM).

## 7. Out of scope (later milestones)
- Managing the Python venv / downloading the model (assume the spike provisioned them).
- Settings UI for server config (host/port/model/keep-warm interval) — hardcoded defaults here; **M2c** adds the Settings UI.
- Automatic crash auto-restart beyond the manual Retry.
- Capture-v2 (M2b) and image/`NSImage` + remaining-view port (M2c).

## 8. File structure
**New:** `Runtime/ServerManager.swift` (ServerManager + ServerState + ServerConfig + ProcessLauncher protocol + real launcher + ServerProcessHandle), tests `GemmaTests/ServerManagerTests.swift`.
**Modified:** `Harness/HarnessModel.swift` (own + start/stop ServerManager, expose state), `Harness/AgentChatView.swift` (status pill, gate Send, failure UI + Retry), `GemmaApp.swift` (stop on terminate), `Gemma/Gemma.entitlements` + `project.pbxproj` (remove app-sandbox).

## 9. Resultado M2a (VERIFICADO 2026-05-31)

Plan `docs/superpowers/plans/2026-05-30-m2a-server-lifecycle.md` ejecutado completo (subagent-driven, doble review spec+calidad por tarea). Commits en `main` `cb893b7`…`057b7b9`.

- **Sandbox** quitado (entitlements vacíos) → la app puede lanzar `Process`.
- **`ServerManager`** (`@MainActor @Observable`): attach-si-ya-corre / spawn-si-no → poll `/v1/models` → pre-warm (= gate de `.ready`) → keep-alive cada ~75s; `stop()` mata solo el proceso propio; observer `willTerminate`→stop. Deps inyectadas (launcher/health) → 12 unit tests con fakes (sin Python/red).
- **Bugs reales encontrados+arreglados en review:** orphan-on-retry (mata el proceso propio antes de re-probar), generation-guard contra callbacks de exit rezagados, drain de stdout (evita colgar al hijo), `manualCommand` funcional, **guard de re-entrancia en `start()`** (un Retry durante el arranque ya no mata su propio proceso), y **guard de XCTest** (el host de tests ya no spawnea el server de 15GB → cero huérfanos tras la suite). Tipos de datos/IO marcados `nonisolated` → cero warnings de concurrencia.
- **UI** (`AgentChatView`): status pill (Iniciando/Cargando modelo/Listo/Detenido/Error), Send bloqueado hasta `.ready`, fallo muestra razón + comando manual + Retry.
- **E2E real verificado (`ServerManagerLiveTests`, gated `GEMMA_LIVE_SERVER=1`, vía `TEST_RUNNER_` prefix):** spawn real del `mlx_lm.server` → `.ready` en **~21s** (caché caliente) → probe confirma serving → `stop()` → proceso muerto, **sin huérfano**. Suite completa verde con los tests live/E2E en skip.
- **Pendiente (humano):** check visual de la GUI (`⌘R` en Xcode) — el plumbing está verificado por el test live.
- **Limitaciones conocidas (fuera de M2a):** un crash/SIGKILL de la app (no quit limpio) puede dejar huérfano el server (solo `willTerminate` lo limpia); `.task` envuelve un `Task` detached (benigno para app de una ventana). M2b = captura v2; M2c = Settings UI (host/port/modelo/intervalo keep-warm) + imagen NSImage.
