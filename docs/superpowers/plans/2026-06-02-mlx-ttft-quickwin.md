# MLX TTFT Quick-Win (APC + Stable Prefix) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut cold-start TTFT from ~3.6–5s to ~0.2–0.5s by enabling `mlx_vlm.server`'s Automatic Prefix Caching (APC, with an SSD tier that survives restarts) and restructuring the prompt so the system prefix is byte-stable across turns.

**Architecture:** Three independent components. (1) The launcher `serve_mlx_vlm.py` turns APC on via env vars when given `--apc-disk-path`, wired through `ServerConfig`/`ServerProcess`. (2) `Agent` emits a stable static system prompt and moves per-turn recall + wakeContext to the tail of the user message, so APC reuses the cached system prefix every turn. (3) A dev script verifies APC is live and measures the TTFT win.

**Tech Stack:** Swift 6 (`@MainActor`, XCTest), Python 3.12 (mlx_vlm), `mlx_vlm.server` OpenAI HTTP API, APC (`mlx_vlm/apc.py`).

**Spec:** `docs/superpowers/specs/2026-06-02-mlx-ttft-quickwin-design.md`

**Branch:** `feat/mlx-ttft-apc` (already created; spec already committed there).

**Test commands:**
- Python: `spike-mlx/.venv-vlm/bin/python spike-mlx/test_serve_mlx_vlm.py` (self-contained asserts, no pytest dependency).
- Swift: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/<Class>` — **note:** the parallel test runner occasionally reports a spurious `** TEST FAILED **` on the first run; re-run once to confirm before treating a failure as real.

---

### Task 1: Launcher enables APC via env vars

**Files:**
- Modify: `spike-mlx/serve_mlx_vlm.py`
- Test: `spike-mlx/test_serve_mlx_vlm.py` (create)

- [ ] **Step 1: Write the failing test**

Create `spike-mlx/test_serve_mlx_vlm.py`:

```python
"""Tests for the serve_mlx_vlm.py launcher arg/env handling. Run with:
    spike-mlx/.venv-vlm/bin/python spike-mlx/test_serve_mlx_vlm.py
Self-contained (no pytest dependency)."""
import importlib.util, os, sys

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "serve_mlx_vlm", os.path.join(_here, "serve_mlx_vlm.py"))
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)


def test_extract_apc_disk_path_space_form():
    path, rest = mod._extract_apc_disk_path(
        ["--apc-disk-path", "/tmp/apc", "--model", "x"])
    assert path == "/tmp/apc", path
    assert rest == ["--model", "x"], rest


def test_extract_apc_disk_path_equals_form():
    path, rest = mod._extract_apc_disk_path(["--apc-disk-path=/tmp/a", "--port", "8080"])
    assert path == "/tmp/a", path
    assert rest == ["--port", "8080"], rest


def test_extract_apc_disk_path_absent():
    path, rest = mod._extract_apc_disk_path(["--model", "x", "--port", "8080"])
    assert path is None, path
    assert rest == ["--model", "x", "--port", "8080"], rest


def test_apply_apc_env_sets_vars(tmp_path="/tmp/gemma-apc-test"):
    for k in ("APC_ENABLED", "APC_HASH", "APC_DISK_PATH", "APC_DISK_MAX_GB", "APC_NUM_BLOCKS"):
        os.environ.pop(k, None)
    mod._apply_apc_env(tmp_path)
    assert os.environ["APC_ENABLED"] == "1"
    assert os.environ["APC_HASH"] == "sha256"
    assert os.environ["APC_DISK_PATH"] == tmp_path
    assert os.environ["APC_DISK_MAX_GB"] == "2"
    assert os.environ["APC_NUM_BLOCKS"] == "1024"
    assert os.path.isdir(tmp_path), "disk dir must be created"


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"PASS {name}")
            except Exception as e:
                fails += 1
                print(f"FAIL {name}: {e}")
    sys.exit(1 if fails else 0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `spike-mlx/.venv-vlm/bin/python spike-mlx/test_serve_mlx_vlm.py`
Expected: FAIL — `AttributeError: module 'serve_mlx_vlm' has no attribute '_extract_apc_disk_path'`.

- [ ] **Step 3: Add the extractor + env helper, wire into main()**

In `spike-mlx/serve_mlx_vlm.py`, add these two functions after `_extract_wired_limit`:

```python
def _extract_apc_disk_path(argv):
    """Pull --apc-disk-path PATH (or --apc-disk-path=PATH) out of argv.

    Returns (path_or_None, remaining_argv). Leaves every other flag intact so
    mlx_vlm.server's own parser sees exactly what it expects.
    """
    out = []
    path = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--apc-disk-path":
            path = argv[i + 1]
            i += 2
            continue
        if a.startswith("--apc-disk-path="):
            path = a.split("=", 1)[1]
            i += 1
            continue
        out.append(a)
        i += 1
    return path, out


def _apply_apc_env(disk_path):
    """Turn on Automatic Prefix Caching for mlx_vlm.server (read by apc.from_env).

    sha256 hashing makes block hashes stable across processes so the SSD tier
    can be reused after a server restart (the default 'fast' hash is only
    deterministic within one process). APC_NUM_BLOCKS bounds the in-memory
    block pool (~16k tokens at the default 16-token block size).
    """
    import os
    from pathlib import Path
    Path(disk_path).expanduser().mkdir(parents=True, exist_ok=True)
    os.environ["APC_ENABLED"] = "1"
    os.environ["APC_HASH"] = "sha256"
    os.environ["APC_DISK_PATH"] = disk_path
    os.environ.setdefault("APC_DISK_MAX_GB", "2")
    os.environ.setdefault("APC_NUM_BLOCKS", "1024")
```

Then change `main()` (the body before the `from mlx_vlm.server import main` line) to:

```python
def main():
    wired, rest = _extract_wired_limit(sys.argv[1:])
    apc_path, rest = _extract_apc_disk_path(rest)
    if wired > 0:
        import mlx.core as mx
        prev = mx.set_wired_limit(wired)
        print(
            f"[serve_mlx_vlm] wired limit set to {wired} bytes "
            f"({wired / 1024**3:.2f} GiB), previous={prev}",
            flush=True,
        )
    else:
        print("[serve_mlx_vlm] no wiring (pageable)", flush=True)

    if apc_path:
        _apply_apc_env(apc_path)
        import os
        print(
            f"[serve_mlx_vlm] APC enabled (disk={apc_path}, hash=sha256, "
            f"num_blocks={os.environ['APC_NUM_BLOCKS']})",
            flush=True,
        )
    else:
        print("[serve_mlx_vlm] APC disabled", flush=True)

    from mlx_vlm.server import main as server_main
    sys.argv = ["mlx_vlm.server"] + rest
    return server_main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `spike-mlx/.venv-vlm/bin/python spike-mlx/test_serve_mlx_vlm.py`
Expected: `PASS` for all four tests, exit 0.

- [ ] **Step 5: Commit**

```bash
git add spike-mlx/serve_mlx_vlm.py spike-mlx/test_serve_mlx_vlm.py
git commit -m "feat(server): launcher enables APC prefix cache via --apc-disk-path"
```

---

### Task 2: Wire APC disk path through ServerConfig + ServerProcess

**Files:**
- Modify: `Gemma/Gemma/Runtime/ServerManager.swift` (ServerConfig struct + `.default`)
- Modify: `Gemma/Gemma/Runtime/ServerProcess.swift` (add `apcArguments`, extend `launchArguments`)
- Test: `Gemma/GemmaTests/ServerProcessTests.swift`

- [ ] **Step 1: Write the failing tests**

In `Gemma/GemmaTests/ServerProcessTests.swift`, change the `cfg` helper to accept an `apc` argument (add the parameter and pass it to the initializer):

```swift
    private func cfg(wired: UInt64 = 0, draft: Bool = false, apc: String? = nil) -> ServerConfig {
        ServerConfig(pythonBinURL: URL(fileURLWithPath: "/x/.venv-vlm/bin/python3.12"),
                     launcherScriptURL: URL(fileURLWithPath: "/x/spike-mlx/serve_mlx_vlm.py"),
                     modelId: "some/model", host: "127.0.0.1", port: 8080,
                     draftModelId: draft ? "some/assistant" : nil,
                     draftKind: draft ? "mtp" : nil,
                     draftBlockSize: draft ? 3 : nil,
                     wiredLimitBytes: wired,
                     apcDiskPath: apc)
    }
```

Then add these test methods to the class:

```swift
    func test_apcArguments_emptyWhenNil() {
        XCTAssertEqual(apcArguments(for: cfg(apc: nil)), [])
    }

    func test_apcArguments_emptyWhenBlank() {
        XCTAssertEqual(apcArguments(for: cfg(apc: "")), [])
    }

    func test_apcArguments_setsFlagWhenPathGiven() {
        XCTAssertEqual(apcArguments(for: cfg(apc: "/tmp/apc")),
                       ["--apc-disk-path", "/tmp/apc"])
    }

    func test_launchArguments_apcFlagSitsBeforeServerArgs() {
        let a = launchArguments(for: cfg(wired: Self.sixteenGiB, apc: "/tmp/apc"))
        XCTAssertEqual(Array(a.prefix(5)),
                       ["/x/spike-mlx/serve_mlx_vlm.py", "--wired-limit-bytes", "17179869184",
                        "--apc-disk-path", "/tmp/apc"])
        XCTAssertEqual(a[5], "--model")
    }

    func test_default_config_has_apc_disk_path() {
        XCTAssertTrue(ServerConfig.default.apcDiskPath?.hasSuffix("Library/Caches/Gemma/apc") ?? false,
                      "default must enable APC at the caches path, got \(ServerConfig.default.apcDiskPath ?? "nil")")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/ServerProcessTests`
Expected: COMPILE FAILURE — `extra argument 'apcDiskPath'`, `cannot find 'apcArguments'`.

- [ ] **Step 3: Add the ServerConfig field + default**

In `Gemma/Gemma/Runtime/ServerManager.swift`, inside `struct ServerConfig`, add after `wiredLimitBytes`:

```swift
    /// When non-nil/non-empty, the launcher turns on Automatic Prefix Caching with an SSD tier
    /// at this path (cold-start TTFT win — the stable system-prompt prefix is restored from disk).
    /// nil = APC off.
    var apcDiskPath: String? = nil
```

In `ServerConfig.default`, add this argument (after `wiredLimitBytes: 0`):

```swift
        wiredLimitBytes: 0,
        apcDiskPath: NSHomeDirectory() + "/Library/Caches/Gemma/apc")
```

- [ ] **Step 4: Add apcArguments + extend launchArguments**

In `Gemma/Gemma/Runtime/ServerProcess.swift`, add after `wiringArguments`:

```swift
/// The `--apc-disk-path` flag for the launcher (turns on prefix caching), or empty when unset. Pure → testable.
nonisolated func apcArguments(for config: ServerConfig) -> [String] {
    if let p = config.apcDiskPath, !p.isEmpty { return ["--apc-disk-path", p] }
    return []
}
```

And change `launchArguments` to insert APC flags between wiring and server args:

```swift
nonisolated func launchArguments(for config: ServerConfig) -> [String] {
    [config.launcherScriptURL.path] + wiringArguments(for: config) + apcArguments(for: config) + serverArguments(for: config)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/ServerProcessTests`
Expected: all `ServerProcessTests` PASS (including the pre-existing `test_launchArguments_wired_insertsFlagBetweenScriptAndServerArgs`, which still holds because `cfg()` defaults `apc` to nil → `apcArguments == []`). Re-run once if the first run reports a spurious failure.

- [ ] **Step 6: Commit**

```bash
git add Gemma/Gemma/Runtime/ServerManager.swift Gemma/Gemma/Runtime/ServerProcess.swift Gemma/GemmaTests/ServerProcessTests.swift
git commit -m "feat(server): wire APC disk path through ServerConfig/ServerProcess"
```

---

### Task 3: Stable system prefix + recall at the tail

**Files:**
- Modify: `Gemma/Gemma/Agent/Agent.swift` (`systemPrompt`, `run`)
- Test: `Gemma/GemmaTests/AgentMemoryTests.swift` (update existing assertions + add new), `Gemma/GemmaTests/AgentSystemPromptTests.swift` (unchanged, must stay green)

**Context:** Today `Agent.run` builds `memoryBlock` from recall and `systemPrompt(memoryBlock:)` appends it (plus `wakeContext`) into the system prompt. We move recall + wakeContext to the tail of the **user** message so the system prefix is byte-stable. Two existing tests assert recall/wakeContext land in the *system* prompt — they must be updated to assert the *user* message instead.

- [ ] **Step 1: Update the capturing runtime + failing tests**

In `Gemma/GemmaTests/AgentMemoryTests.swift`, replace the `CapturingRuntime` so it also captures the user prompt:

```swift
    /// Captures the system prompt AND the user prompt the runtime receives, then completes.
    final class CapturingRuntime: ToolCallingRuntime {
        var capturedSystemPrompt: String?
        var capturedUserPrompt: String?
        func generate(prompt: String, tools: [AgentTool], options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
            capturedSystemPrompt = options.systemPrompt
            capturedUserPrompt = prompt
            return AsyncThrowingStream { c in
                c.yield(.completed(GenerationResult(text: "ok", metrics: RuntimeMetrics(tokensGenerated: 0, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
                c.finish()
            }
        }
    }
```

Replace `testInjectsMemoryIntoSystemPrompt` with a version asserting recall rides the **user** prompt and is **absent** from the system prompt (rename for clarity):

```swift
    func testInjectsMemoryIntoUserPromptTail() async throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 4)
        let now = Date().timeIntervalSince1970
        try store.upsert(Node(id: "1", kind: NodeKind.preference.rawValue, label: "sushi", body: "likes sushi", layer: .daily,
                              createdAt: now, updatedAt: now, lastSeenAt: now, salience: 5, decayRate: 0.0001,
                              confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                              origin: .extracted, serverId: nil, dirty: true, deleted: false, extra: nil))
        let retriever = MemoryRetriever(store: store, embedder: nil)
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry(),
                          memory: MemoryServices(retriever: retriever))
        for try await _ in agent.run(prompt: "sushi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedUserPrompt?.contains("sushi") ?? false,
                      "recall must be prepended to the user prompt; got: \(rt.capturedUserPrompt ?? "nil")")
        XCTAssertEqual(rt.capturedSystemPrompt?.contains("What you remember"), false,
                       "recall must NOT be in the system prompt (it would bust the prefix cache)")
        // The original user text is still present after the recall tail.
        XCTAssertTrue(rt.capturedUserPrompt?.hasSuffix("sushi") ?? false)
    }
```

Replace `test_wakeContext_is_injected_into_system_prompt` with:

```swift
    func test_wakeContext_rides_user_prompt_tail() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry(), memory: nil,
                          wakeContext: "You were reflecting on: sushi.")
        for try await _ in agent.run(prompt: "hi", options: GenerationOptions()) {}
        XCTAssertTrue(rt.capturedUserPrompt?.contains("You were reflecting on: sushi.") ?? false,
                      "wakeContext must ride the user prompt; got: \(rt.capturedUserPrompt ?? "nil")")
        XCTAssertEqual(rt.capturedSystemPrompt?.contains("You were reflecting on") ?? false, false,
                       "wakeContext must NOT be in the system prompt")
    }
```

Add a new test confirming the no-memory case leaves the user prompt unchanged:

```swift
    func test_noMemory_noWake_leaves_user_prompt_unchanged() async throws {
        let rt = CapturingRuntime()
        let agent = Agent(runtime: rt, registry: ToolRegistry())  // memory = nil, wakeContext = ""
        for try await _ in agent.run(prompt: "hola", options: GenerationOptions()) {}
        XCTAssertEqual(rt.capturedUserPrompt, "hola")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/AgentMemoryTests`
Expected: FAIL — `testInjectsMemoryIntoUserPromptTail` fails because recall is still in the system prompt (and `capturedUserPrompt` is just `"sushi"` without the recall tail), `test_wakeContext_rides_user_prompt_tail` fails similarly.

- [ ] **Step 3: Implement stable prefix + tail injection in Agent**

In `Gemma/Gemma/Agent/Agent.swift`, replace `systemPrompt(memoryBlock:)` with a no-argument, static-only version:

```swift
    private func systemPrompt() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd (EEEE)"
        let today = df.string(from: Date())
        // Static instructions only — kept byte-stable across turns so the mlx_vlm.server APC
        // prefix cache reuses its KV (cold start restored from the SSD tier). Per-turn recall and
        // wakeContext are NOT here; they ride the tail of the user message (see run()).
        // The date is intentionally kept in the prefix: stable within a day (≤1 cache rebuild/day)
        // and preserves temporal grounding.
        return """
        You are Gemma, a helpful on-device assistant. Today is \(today). You can call tools to get real information. \
        When a tool is relevant (e.g. the user asks the time), call it instead of guessing. \
        Answer only what the user asked; do not list unrelated things you remember. \
        But when several remembered facts match the question (e.g. multiple meetings or events), \
        mention ALL of them with their dates — never answer with only the most recent. \
        IMPORTANT: after any tool runs, ALWAYS reply to the user in a short, natural sentence — \
        confirm what you did or answer their question. Never end your turn with only a tool call.
        """
    }
```

In `run(prompt:options:)`, replace the recall/system-prompt setup (the block that builds `memoryBlock` and sets `opts.systemPrompt`, and the `var currentPrompt = prompt` line) with:

```swift
                // Recall + wakeContext ride the TAIL of the user message so the system prefix
                // stays byte-identical across turns → APC prefix-cache hit (disk on cold start,
                // memory when warm). See docs/superpowers/specs/2026-06-02-mlx-ttft-quickwin-design.md.
                var recallTail = ""
                if let memory, let nodes = try? memory.retriever.retrieve(query: prompt) {
                    recallTail = memory.retriever.injectionBlock(for: nodes)
                }
                if !wakeContext.isEmpty {
                    recallTail = recallTail.isEmpty ? wakeContext : recallTail + "\n\n" + wakeContext
                }
                var opts = options
                opts.systemPrompt = systemPrompt()

                do {
                    let maxIterations = 5
                    // Iteration 0 carries the recall tail; tool-loop iterations reuse their own prompt.
                    var currentPrompt = recallTail.isEmpty ? prompt : recallTail + "\n\n" + prompt
```

Note: keep the existing `do {` / `let maxIterations = 5` / loop body; only the lines that previously set `memoryBlock`, `opts.systemPrompt`, and `var currentPrompt = prompt` change. The rest of the tool loop (which reassigns `currentPrompt` on tool results) is unchanged.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/AgentMemoryTests`
Then: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/AgentSystemPromptTests`
Expected: both classes PASS. `AgentSystemPromptTests` still passes because the date, "Answer only what the user asked", and "all of them" text remain in `systemPrompt()`. Re-run once on a spurious failure.

- [ ] **Step 5: Run the full Agent + ServerRuntime suites for regressions**

Run: `xcodebuild test -project Gemma/Gemma.xcodeproj -scheme Gemma -destination 'platform=macOS' -only-testing:GemmaTests/AgentTests -only-testing:GemmaTests/AgentToolTests -only-testing:GemmaTests/ServerRuntimeTests`
Expected: all PASS (these don't assert recall placement).

- [ ] **Step 6: Commit**

```bash
git add Gemma/Gemma/Agent/Agent.swift Gemma/GemmaTests/AgentMemoryTests.swift
git commit -m "feat(agent): stable system prefix + recall/wake at user-prompt tail for APC"
```

---

### Task 4: Verify APC is live (with MTP draft) — dev script

**Files:**
- Create: `spike-mlx/apc_check.py`

**Context:** Live validation (no unit-test gate — needs a running server). Confirms APC is enabled and hits rise on a repeated prefix, **with the MTP draft model active** (Risk 1 in the spec). Run after Tasks 1–2 are merged into the launcher path.

- [ ] **Step 1: Write the verification script**

Create `spike-mlx/apc_check.py`:

```python
"""Verify Automatic Prefix Caching is live on a running mlx_vlm.server.
Usage: spike-mlx/.venv-vlm/bin/python spike-mlx/apc_check.py [http://localhost:8080]
Sends two requests sharing a long identical prefix; asserts apc_enabled and a rising hit count."""
import json, sys, time, urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=10) as r:
        return json.loads(r.read())


def chat(prefix, tail):
    body = json.dumps({"model": "x", "stream": False, "max_tokens": 8, "temperature": 0.0,
                       "messages": [{"role": "system", "content": prefix},
                                    {"role": "user", "content": tail}]}).encode()
    req = urllib.request.Request(BASE + "/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=120) as r:
        r.read()
    return time.time() - t0


def main():
    stats0 = get("/apc/stats")
    print("apc/stats:", stats0)
    assert stats0.get("apc_enabled") is True, "APC is NOT enabled — check --apc-disk-path wiring"
    prefix = "You are Gemma. " + " ".join(f"stable-prefix-token-{i}" for i in range(120))
    t1 = chat(prefix, "first question about the weather")
    s1 = get("/apc/stats")
    t2 = chat(prefix, "second different question")   # same prefix → should hit cache
    s2 = get("/apc/stats")
    print(f"req1 {t1:.2f}s  req2 {t2:.2f}s")
    print("stats after req1:", s1)
    print("stats after req2:", s2)
    # The hit counter key name may vary; print the snapshot and check any 'hit'-like counter rose.
    hits1 = sum(v for k, v in s1.items() if "hit" in k.lower() and isinstance(v, (int, float)))
    hits2 = sum(v for k, v in s2.items() if "hit" in k.lower() and isinstance(v, (int, float)))
    print(f"hit-counter sum: after1={hits1} after2={hits2}")
    assert hits2 > hits1, "expected APC hits to rise on the repeated prefix"
    print("OK: APC live and reusing the shared prefix.")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Start the server with APC, with the MTP draft active**

Run (frees RAM first; uses the default app config flags + APC):
```bash
lsof -ti tcp:8080 | xargs -r kill 2>/dev/null; sleep 3
spike-mlx/.venv-vlm/bin/python spike-mlx/serve_mlx_vlm.py \
  --apc-disk-path "$HOME/Library/Caches/Gemma/apc" \
  --model unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit --host 127.0.0.1 --port 8080 \
  --draft-model guardiangate1775/gemma-4-26B-A4B-it-assistant-4bit --draft-kind mtp --draft-block-size 3 \
  > /tmp/mlx_apc.log 2>&1 &
```
Wait for readiness:
```bash
for i in $(seq 1 60); do curl -s -m2 http://localhost:8080/health >/dev/null 2>&1 && { echo READY; break; }; sleep 2; done
grep -iE "APC enabled|apc" /tmp/mlx_apc.log | head
```
Expected: `[serve_mlx_vlm] APC enabled (disk=..., hash=sha256, num_blocks=1024)` in the log.

- [ ] **Step 3: Run the verification script**

Run: `spike-mlx/.venv-vlm/bin/python spike-mlx/apc_check.py http://localhost:8080`
Expected: `apc_enabled: True`, the hit-counter sum rises from req1→req2, and `OK: APC live...`. If the script errors because the stats key names differ, read the printed snapshot, adjust the `"hit"` substring match to the actual counter name, and re-run. If output is wrong/garbled with the draft active, that is Risk 1 — record it and proceed to decide (APC without draft vs report); do not silently continue.

- [ ] **Step 4: Commit**

```bash
git add spike-mlx/apc_check.py
git commit -m "test(server): apc_check.py — verify APC live with MTP draft"
```

---

### Task 5: Measure the TTFT win + memory (live)

**Files:** none (measurement only; results recorded in the spike doc).

**Context:** Live measurement on the M4 24GB. Confirms the success criteria: cold-start TTFT after a restart (prefix restored from the SSD tier) ≤ ~1s, warm ~0.2–0.3s, and total memory fits 24GB with model + MTP draft + APC pool (Risk 2).

- [ ] **Step 1: Warm the cache + populate the disk tier**

With the server from Task 4 running, send one request with the real app system prefix (so its blocks get cached + written to the SSD tier):
```bash
spike-mlx/.venv-vlm/bin/python - <<'PY'
import json, urllib.request, time
P = "You are Gemma, a helpful on-device assistant. Today is 2026-06-02 (Tuesday). You can call tools to get real information. When a tool is relevant, call it instead of guessing. Answer only what the user asked. IMPORTANT: after any tool runs, ALWAYS reply in a short natural sentence."
b = json.dumps({"model":"x","stream":False,"max_tokens":8,"temperature":0.0,
    "messages":[{"role":"system","content":P},{"role":"user","content":"hola"}]}).encode()
t0=time.time(); urllib.request.urlopen(urllib.request.Request("http://localhost:8080/v1/chat/completions",data=b,headers={"Content-Type":"application/json"}),timeout=120).read()
print(f"warm-up populate: {time.time()-t0:.2f}s")
PY
ls -lh "$HOME/Library/Caches/Gemma/apc" 2>/dev/null | head   # disk tier should now have shards
```
Expected: shard files present under the APC disk dir.

- [ ] **Step 2: Restart the server, measure COLD TTFT (disk-restored prefix)**

```bash
lsof -ti tcp:8080 | xargs -r kill 2>/dev/null; sleep 4
spike-mlx/.venv-vlm/bin/python spike-mlx/serve_mlx_vlm.py \
  --apc-disk-path "$HOME/Library/Caches/Gemma/apc" \
  --model unsloth/gemma-4-26b-a4b-it-UD-MLX-4bit --host 127.0.0.1 --port 8080 \
  --draft-model guardiangate1775/gemma-4-26B-A4B-it-assistant-4bit --draft-kind mtp --draft-block-size 3 \
  > /tmp/mlx_apc.log 2>&1 &
for i in $(seq 1 60); do curl -s -m2 http://localhost:8080/health >/dev/null 2>&1 && break; sleep 2; done
```
Then send the SAME system prefix as Step 1 and time the first token (this is the cold-start path; the prefix KV should restore from disk):
```bash
spike-mlx/.venv-vlm/bin/python - <<'PY'
import json, urllib.request, time
P = "You are Gemma, a helpful on-device assistant. Today is 2026-06-02 (Tuesday). You can call tools to get real information. When a tool is relevant, call it instead of guessing. Answer only what the user asked. IMPORTANT: after any tool runs, ALWAYS reply in a short natural sentence."
def ttft(tail):
    b=json.dumps({"model":"x","stream":True,"max_tokens":40,"temperature":0.0,
        "messages":[{"role":"system","content":P},{"role":"user","content":tail}]}).encode()
    r=urllib.request.urlopen(urllib.request.Request("http://localhost:8080/v1/chat/completions",data=b,headers={"Content-Type":"application/json"}),timeout=120)
    t0=time.time()
    for raw in r:
        s=raw.decode("utf-8","replace").strip()
        if s.startswith("data:") and s[5:].strip() not in ("","[DONE]"):
            d=json.loads(s[5:].strip())["choices"][0].get("delta",{})
            if d.get("content"): return time.time()-t0
    return None
print("COLD TTFT:", f"{ttft('que hora es?'):.2f}s")
print("WARM TTFT:", f"{ttft('y manana?'):.2f}s")
PY
grep -iE "APC|disk|restore" /tmp/mlx_apc.log | head
```
Expected: COLD TTFT ≤ ~1s (vs ~3.6–5s baseline), WARM TTFT ~0.2–0.3s. Record both numbers.

- [ ] **Step 3: Record peak memory (Risk 2)**

```bash
PID=$(lsof -ti tcp:8080 | head -1)
ps -o rss= -p $PID | awk '{printf "server RSS=%.2fGB\n",$1/1048576}'
vm_stat | awk -v pg=16384 '/Pages free/{gsub(/\./,"",$NF);printf "free=%.1fGB\n",$NF*pg/1e9} /Swapouts/{gsub(/\./,"",$NF);printf "swapouts=%s\n",$NF}'
```
Expected: total resident (model ~15GB + draft + APC pool) fits 24GB with no runaway swap during generation. If memory is tight, lower `APC_NUM_BLOCKS` (e.g. 512) via the launcher default in Task 1 and re-measure.

- [ ] **Step 4: Append results to the spike doc + update memory**

Append a "## MLX APC quick-win — measured" section to `docs/spikes/2026-06-02-llamacpp-fork-vs-mlx.md` with the cold/warm TTFT, decode t/s, peak memory, and the APC+MTP coexistence verdict.

```bash
git add docs/spikes/2026-06-02-llamacpp-fork-vs-mlx.md
git commit -m "docs(ttft): record measured MLX APC quick-win (cold/warm TTFT, memory)"
```

- [ ] **Step 5: Kill the server to free RAM**

```bash
lsof -ti tcp:8080 | xargs -r kill 2>/dev/null; echo done
```

---

## Notes for the implementer

- **No silent fallbacks.** If APC + MTP produce wrong output (Task 4 Step 3) or memory doesn't fit (Task 5 Step 3), STOP and report with the evidence — do not quietly disable a feature and continue.
- **App default now enables APC.** After Task 2, `ServerConfig.default.apcDiskPath` is set, so the macOS app launches the server with APC on automatically. The keep-warm wiring (already shipped in M2c-1) keeps the in-memory APC pool hot within a session.
- **The `Today is <date>` in the prefix** rebuilds the cache once per day; that's intended and bounded by the SSD tier.
