# MLX TTFT Quick-Win (APC + Stable Prefix) — Design

**Date:** 2026-06-02
**Status:** Approved (brainstorming → spec)

## Goal

Cut cold-start time-to-first-token from ~3.6–5s to ~0.2–0.5s by reusing the KV cache of a stable system-prompt prefix — both in memory (within a session) and persisted to SSD (across server restarts) — without switching off MLX.

## Background

The llama.cpp-fork spike (`docs/spikes/2026-06-02-llamacpp-fork-vs-mlx.md`) proved the TTFT fix is **prompt-prefix caching, not the backend**: a cold 569-token prefill (3.58s) collapsed to 0.14s when the prefix was cached. MLX wins on speed/memory, so we stay on it.

`mlx_vlm.server` already ships **Automatic Prefix Caching (APC)** (`mlx_vlm/apc.py`): block-level (16 tokens/block) chained-hash KV reuse across requests, an optional SSD tier that survives restarts, and a `/apc/stats` endpoint. It is **off by default** and enabled via env vars read by `apc.from_env()`:

- `APC_ENABLED=1` — master switch.
- `APC_HASH=sha256` — stable cross-process hash (the default "fast" `hash()` is only deterministic within one process; the SSD tier needs sha256 to match blocks after a restart).
- `APC_DISK_PATH=<dir>` — enables the SSD tier (namespaced per model).
- `APC_DISK_MAX_GB`, `APC_NUM_BLOCKS`, `APC_BLOCK_SIZE` — capacity knobs.

APC matches on the **token prefix**, block by block, with a chained hash: once a block differs, every later block misses. Today the per-turn-variable recall (`memoryBlock`) is injected at the **front** of the system prompt, so only the tiny static `base` (~80 tokens) is cacheable and everything after the recall re-prefills every turn.

## Architecture

Three independent components.

### Component 1 — Enable APC in the server

**Files:** `spike-mlx/serve_mlx_vlm.py`, `Gemma/Gemma/Runtime/ServerProcess.swift`, `Gemma/Gemma/Runtime/ServerManager.swift`

- `serve_mlx_vlm.py` gains a `--apc-disk-path PATH` flag, extracted from `argv` exactly like the existing `--wired-limit-bytes` (an `_extract_apc_disk_path(argv) -> (path_or_None, remaining_argv)` helper). When a non-empty path is present, **before** `from mlx_vlm.server import main`, the launcher sets:
  - `os.environ["APC_ENABLED"] = "1"`
  - `os.environ["APC_HASH"] = "sha256"`
  - `os.environ["APC_DISK_PATH"] = path`
  - `os.environ.setdefault("APC_DISK_MAX_GB", "2")`
  - `os.environ.setdefault("APC_NUM_BLOCKS", "1024")`  (~16k tokens of cache; bounds the in-memory block pool)
  When the flag is absent or empty, no env vars are set (APC stays off — current behavior).
- `ServerConfig` gains `var apcDiskPath: String? = nil`. `ServerConfig.default` sets it to `NSHomeDirectory() + "/Library/Caches/Gemma/apc"`.
- `ServerProcess.swift` gains a pure `apcArguments(for config:) -> [String]` returning `["--apc-disk-path", path]` when `apcDiskPath` is a non-empty string, else `[]`. `launchArguments(for:)` becomes `[launcher] + wiringArguments + apcArguments + serverArguments`. APC flags sit with the launcher flags (consumed by `serve_mlx_vlm.py`, never forwarded to `mlx_vlm.server`).

The launcher creates the disk directory if missing (`Path(path).expanduser().mkdir(parents=True, exist_ok=True)`) so a fresh machine doesn't fail the disk-tier init.

### Component 2 — Stable system prefix + recall at the tail

**Files:** `Gemma/Gemma/Agent/Agent.swift`

- `systemPrompt(...)` no longer takes a memory block. It returns only the **static instructions + `Today is <yyyy-MM-dd (EEEE)>`**. The date is kept in the prefix on purpose: it is stable within a day (busts the cache at most once per day, which the SSD tier then rebuilds once) and preserves the temporal grounding fixed in earlier work.
- In `run(prompt:options:)`, the retrieved `memoryBlock` and `wakeContext` are concatenated into a **tail block** and **prepended to the user prompt** (`currentPrompt`) on the **first iteration only** (iteration 0). Tool-loop iterations ≥1 keep their existing prompt-augmentation behavior and do not re-inject recall.
- Resulting message order sent by `ServerRuntime`: `[system = stable]` + `[history]` + `[user = recallTail + "\n\n" + prompt]`. The stable system prefix is byte-identical across turns → APC hit (disk on cold start, memory when warm); only `recallTail + prompt` re-prefills.

Format of the tail block (unchanged recall wording, just relocated):
```
<injectionBlock output>      // "What you remember about the user (use if relevant):\n- [kind] label: body" ...
<wakeContext if non-empty>
<original user prompt>
```
Joined with blank lines; empty pieces are omitted. When there is no recall and no wakeContext, the user prompt is sent unchanged.

**Out of scope (YAGNI):** caching the full conversation history across turns. That requires recall delivered as a tool result (so it becomes immutable replayed history), which is a larger redesign. Per-turn-variable recall and history prefix-caching are mutually exclusive without it. Documented as future work. This spec still guarantees the system-prefix hit every turn, which is the cold-start win the user asked for.

### Component 3 — Verification & measurement

**Files:** `spike-mlx/apc_check.py` (new, dev-only script)

- `apc_check.py` hits `GET /apc/stats`, asserts `apc_enabled == true`, fires two identical-prefix requests, and confirms the hit counter increases on the second. Prints stats.
- A measurement run records: cold TTFT (kill + relaunch the server so the prefix is restored from the SSD tier, then one request), warm TTFT (immediate second request), decode t/s, and peak memory (model + MTP draft + APC pool must fit 24GB).

## Risks (validate early in the plan)

1. **APC + MTP speculative decoding coexistence.** The server runs a draft model (MTP). Confirm APC produces correct output and real hits with the draft active. If they conflict: fall back to APC without the draft, or report. Validated in the verification task before the prompt restructure ships.
2. **Memory footprint.** The APC block pool adds to resident memory. `APC_NUM_BLOCKS=1024` (~16k tokens) bounds it; the measurement task confirms the total fits 24GB alongside the ~15GB model + MTP draft + wired residency.

## Testing

- **Pure functions:** `apcArguments(for:)` returns the flag when `apcDiskPath` is set and `[]` when nil/empty; `launchArguments` places APC flags between wiring and server args. (`ServerProcessTests`)
- **Launcher:** a Python test imports `_extract_apc_disk_path` and asserts it pulls the path out and leaves the rest of argv intact; and that the env-setting branch sets `APC_ENABLED`/`APC_HASH`/`APC_DISK_PATH`. (`spike-mlx/test_serve_mlx_vlm.py`)
- **Agent:** the system message no longer contains recall text; the recall block is prepended to the user message; with no recall/wakeContext the user message is unchanged. Asserted via the existing `ServerRuntimeMockProtocol.capturedBody`. (`AgentTests` / `ServerRuntimeTests` style)
- **Regression:** existing `ServerRuntimeTests` stay green.
- **Live (manual, dev script):** `apc_check.py` confirms `apc_enabled` + rising hit rate; measurement confirms cold-TTFT win.

## Success criteria

- `/apc/stats` reports `apc_enabled: true` and a rising hit rate on repeated identical prefixes.
- Cold-start TTFT (after a server restart, prefix restored from SSD) drops to roughly ≤1s for a typical app prompt (from ~3.6–5s), with warm TTFT ~0.2–0.3s.
- Output quality unchanged; total memory fits 24GB with the model + MTP draft.
- All unit tests green.
