# mlx_vlm + MTP Speculative Decoding Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch the local model server from `mlx_lm.server` to `mlx_vlm.server` with Gemma-4 MTP speculative decoding enabled, for ~1.25–1.33× faster decode (and a multimodal-capable runtime base for M2c).

**Architecture:** The macOS app spawns/keeps-warm a local OpenAI-compatible server (M2a `ServerManager`/`ServerProcess`/`HTTPServerHealth`). The migration is config-only at the process boundary: change the server binary to `.venv-vlm/bin/mlx_vlm.server` and append `--draft-model/--draft-kind/--draft-block-size`. The HTTP surface is unchanged — the spike verified `/v1/models`, `/v1/chat/completions`, OpenAI `tool_calls`, and `chat_template_kwargs.enable_thinking:false` all behave identically on `mlx_vlm.server`. So `ServerRuntime`, `HTTPServerHealth`, the client tool loop, and memory code need **no** changes.

**Tech Stack:** Swift/SwiftUI macOS, `mlx-vlm 0.5.0` (isolated venv `spike-mlx/.venv-vlm`), target `unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit`, drafter `guardiangate1775/gemma-4-26B-A4B-it-assistant-4bit` (MTP, 262 MB, cached), block-size 3.

**Design rationale (de-risked by spike):** see memory `macos-mlx-pivot.md` — measured on this M4 24GB: baseline 29.3 → 4-bit assistant block-3 36.5 tok/s (prose ~1.25×) / 39.1 (code ~1.33×); 4-bit assistant is the sweet spot; mlx_vlm.server tool-calling + thinking-off verified compatible.

---

### Task 1: Wire MTP draft flags + switch to mlx_vlm.server

**Files:**
- Modify: `Gemma/Gemma/Runtime/ServerManager.swift` (`ServerConfig` struct + `.default` + `manualCommand`; doc comment)
- Modify: `Gemma/Gemma/Runtime/ServerProcess.swift` (`serverArguments`; doc comments)
- Modify: `Gemma/GemmaTests/ServerProcessTests.swift` (update/extend tests)
- Test: `Gemma/GemmaTests/ServerProcessTests.swift`

- [ ] **Step 1: Write the failing tests** in `ServerProcessTests.swift`. Replace the body of `test_serverArguments_shape` and add a draft test:

```swift
func test_serverArguments_baseShape_noDraft() {
    let cfg = ServerConfig(venvBinURL: URL(fileURLWithPath: "/x/mlx_vlm.server"),
                           modelId: "some/model", host: "127.0.0.1", port: 8080)
    XCTAssertEqual(serverArguments(for: cfg),
                   ["--model", "some/model", "--host", "127.0.0.1", "--port", "8080"])
}

func test_serverArguments_appendsDraftFlags_whenConfigured() {
    let cfg = ServerConfig(venvBinURL: URL(fileURLWithPath: "/x/mlx_vlm.server"),
                           modelId: "some/model", host: "127.0.0.1", port: 8080,
                           draftModelId: "some/assistant", draftKind: "mtp", draftBlockSize: 3)
    XCTAssertEqual(serverArguments(for: cfg),
                   ["--model", "some/model", "--host", "127.0.0.1", "--port", "8080",
                    "--draft-model", "some/assistant", "--draft-kind", "mtp", "--draft-block-size", "3"])
}

func test_default_config_targets_mlx_vlm_server_with_mtp_draft() {
    let c = ServerConfig.default
    XCTAssertTrue(c.venvBinURL.path.hasSuffix("mlx_vlm.server"), "default must launch mlx_vlm.server, got \(c.venvBinURL.path)")
    XCTAssertEqual(c.draftKind, "mtp")
    XCTAssertNotNil(c.draftModelId)
    XCTAssertEqual(c.draftBlockSize, 3)
}
```

Also update the two `test_watchdogScript_*` constructors' bin path string `"/x/mlx_lm.server"` → `"/x/mlx_vlm.server"` and the assertion `script.contains("/x/mlx_lm.server")` → `"/x/mlx_vlm.server"`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ServerProcessTests 2>&1 | tail -25`
Expected: FAIL — `draftModelId:` is not a member of `ServerConfig`; `serverArguments` doesn't append draft flags; default still points at `mlx_lm.server`.

- [ ] **Step 3: Add the draft fields to `ServerConfig`** in `ServerManager.swift`. Add three optional stored properties (default `nil` preserves the memberwise initializer for existing 4-arg callers) and point `.default` at `mlx_vlm.server` + the cached 4-bit MTP assistant:

```swift
nonisolated struct ServerConfig: Sendable {
    var venvBinURL: URL
    var modelId: String
    var host: String
    var port: Int
    /// MTP speculative-decoding drafter (HF id or path). nil = no speculative decoding.
    var draftModelId: String? = nil
    /// Drafter family for mlx_vlm: "mtp" (Gemma 4 assistant) or "dflash". nil = omit flag.
    var draftKind: String? = nil
    /// Tokens drafted per verification round. nil = use the drafter's configured default.
    var draftBlockSize: Int? = nil
    var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    static let `default` = ServerConfig(
        venvBinURL: URL(fileURLWithPath: "/Users/hashdown/Projects/personal_agent/spike-mlx/.venv-vlm/bin/mlx_vlm.server"),
        modelId: "unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
        host: "127.0.0.1",
        port: 8080,
        draftModelId: "guardiangate1775/gemma-4-26B-A4B-it-assistant-4bit",
        draftKind: "mtp",
        draftBlockSize: 3)
}
```

Update the struct's doc comment line above it from "mlx-lm server" to "mlx_vlm server".

- [ ] **Step 4: Append the draft flags in `serverArguments`** in `ServerProcess.swift` (and update the doc comment `mlx_lm.server` → `mlx_vlm.server`):

```swift
/// The argv (after the executable) for `mlx_vlm.server`. Pure → unit-testable.
nonisolated func serverArguments(for config: ServerConfig) -> [String] {
    var args = ["--model", config.modelId, "--host", config.host, "--port", String(config.port)]
    if let draft = config.draftModelId {
        args += ["--draft-model", draft]
        if let kind = config.draftKind { args += ["--draft-kind", kind] }
        if let block = config.draftBlockSize { args += ["--draft-block-size", String(block)] }
    }
    return args
}
```

- [ ] **Step 5: Make `manualCommand` use `serverArguments`** so the draft flags appear in the UI fallback command. In `ServerManager.swift` replace the `manualCommand` body:

```swift
/// Manual fallback command shown in the UI on failure.
var manualCommand: String {
    let dir = config.venvBinURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let argv = ([config.venvBinURL.path] + serverArguments(for: config)).joined(separator: " ")
    return "cd \(dir.path) && \(argv)"
}
```

- [ ] **Step 6: Update remaining `mlx_lm.server` comments** to `mlx_vlm.server` in `ServerProcess.swift` (the `RealServerProcessHandle` and `RealServerProcessLauncher` doc comments at lines ~27 and ~60) and the `ServerManager.swift` top-of-file comment. (Comments only — no behavior change.)

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' -only-testing:GemmaTests/ServerProcessTests 2>&1 | tail -25`
Expected: PASS (all ServerProcessTests).

- [ ] **Step 8: Run the full suite to confirm no regression**

Run: `xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' 2>&1 | tail -15`
Expected: "Test Suite 'All tests' passed". (Live/E2E server tests are gated off without `GEMMA_LIVE_SERVER=1`/running server and will skip.)

- [ ] **Step 9: Commit**

```bash
git add Gemma/Gemma/Runtime/ServerManager.swift Gemma/Gemma/Runtime/ServerProcess.swift Gemma/GemmaTests/ServerProcessTests.swift
git commit -m "feat(server): migrate to mlx_vlm.server with Gemma-4 MTP speculative decoding"
```

---

### Task 2: Live E2E verification against the real mlx_vlm.server

**Files:**
- Modify (comments only, if needed): `Gemma/GemmaTests/ServerManagerLiveTests.swift` (update `mlx_lm.server` strings in comments/asserts to `mlx_vlm.server`)
- No production code changes expected.

- [ ] **Step 1: Update the live-test comments** in `ServerManagerLiveTests.swift`: `mlx_lm.server` → `mlx_vlm.server` (lines ~5, ~25, ~44). The executable-exists precondition (`ServerConfig.default.venvBinURL`) now checks the mlx_vlm binary automatically.

- [ ] **Step 2: Kill any stray server, then run the live server-lifecycle test** (spawns the real server via the app's own `RealServerProcessLauncher`, proving the new binary + draft flags spawn → ready → stop with no orphan):

```bash
pkill -f "mlx_lm.server|mlx_vlm.server" 2>/dev/null; sleep 1
cd /Users/hashdown/Projects/personal_agent
GEMMA_LIVE_SERVER=1 xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj \
  -destination 'platform=macOS' -only-testing:GemmaTests/ServerManagerLiveTests \
  2>&1 | tail -30
```
Expected: the live test passes (spawn → pre-warm → `.ready` → stop → no orphan). If `GEMMA_LIVE_SERVER` is consumed via a `TEST_RUNNER_` prefix in this project, use `TEST_RUNNER_GEMMA_LIVE_SERVER=1` instead (check the test's env-var read).

- [ ] **Step 3: Independently confirm the drafter actually engaged.** Spawn the server exactly as the app does and check the stderr banner + tool-calling in one shot:

```bash
cd /Users/hashdown/Projects/personal_agent/spike-mlx
pkill -f mlx_vlm.server 2>/dev/null; sleep 1
nohup .venv-vlm/bin/mlx_vlm.server --model unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit \
  --draft-model guardiangate1775/gemma-4-26B-A4B-it-assistant-4bit --draft-kind mtp --draft-block-size 3 \
  --host 127.0.0.1 --port 8080 > /tmp/vlm-verify.log 2>&1 &
curl -s --retry-connrefused --retry 40 --retry-delay 2 http://127.0.0.1:8080/v1/models -o /dev/null -w "models HTTP %{http_code}\n"
grep -i "Drafter ready\|speculative decoding enabled" /tmp/vlm-verify.log || echo "WARN: no drafter banner"
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model":"unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit",
  "messages":[{"role":"user","content":"What time is it?"}],
  "tools":[{"type":"function","function":{"name":"get_current_time","description":"Get the current time","parameters":{"type":"object","properties":{}}}}],
  "chat_template_kwargs":{"enable_thinking":false},"max_tokens":64,"temperature":0.0}' \
  | python3 -c "import sys,json;m=json.load(sys.stdin)['choices'][0]['message'];print('tool_calls:',json.dumps(m.get('tool_calls')));print('reasoning:',repr(m.get('reasoning')))"
pkill -f mlx_vlm.server 2>/dev/null
```
Expected: `models HTTP 200`; the "Drafter ready — speculative decoding enabled." banner present; `tool_calls` contains `get_current_time`; `reasoning: None`.

- [ ] **Step 4: Commit any comment updates**

```bash
git add Gemma/GemmaTests/ServerManagerLiveTests.swift
git commit -m "test(server): point live tests at mlx_vlm.server"
```

---

## Notes / Out of scope (do NOT do here)

- **No changes to `ServerRuntime`, `HTTPServerHealth`, `Agent`, memory, or the client tool loop** — the HTTP contract is unchanged (spike-verified).
- **Do not** touch the legacy `ModelLoadOptions.drafterPath/useSpeculativeDecoding` / `GenerationOptions.useSpeculativeDecoding` fields — those are LiteRT-era in-process scaffolding, unrelated to the server-flag approach. Leave them.
- **Settings UI** for host/port/model/draft toggle is M2c — not here. The drafter is hardcoded in `ServerConfig.default` like the rest of M2a config.
- The isolated `.venv-vlm` (mlx-vlm 0.5.0) and the cached 4-bit assistant are the runtime dependency; keep them. (Consolidating venvs / pinning is a separate ops task.)
</content>
</invoke>
