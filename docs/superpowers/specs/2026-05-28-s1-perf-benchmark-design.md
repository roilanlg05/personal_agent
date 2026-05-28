# S1 — Performance Benchmark (design spec)

**Date:** 2026-05-28
**Status:** approved (brainstorming)
**Position:** Rebuilds "Run Bench" on the official LiteRT-LM `benchmark()` API. Comes before Plan 3b (Settings UI) at the user's request. Comparative combos + S1 report remain Plan 3c.

## Why

The previous "Run Bench" looped real-prompt chat generations on a shared engine. On iOS that hit a memory ceiling and the app was OOM-killed around the 17th generation regardless of conversation strategy (recreate-per-prompt churned a 4096-token KV cache; reuse accumulated history and slowed/overflowed). There is no official iOS reference for benchmarking via a chat loop. Edge Gallery's `BenchmarkViewModel` and the official `vendor/LiteRT-LM/swift/Benchmark.swift` both benchmark via a dedicated `benchmark()` function that creates and tears down its own engine per run with synthetic token counts — no chat loop, no churn. This spec rebuilds our benchmark on that API.

## What it measures

Performance only, with synthetic token counts (no real prompts, no text output): per the official `BenchmarkInfo` — engine init time, time-to-first-token, prefill tokens/sec, decode tokens/sec. Runs the configured number of times and reports the first init separately from the warm average (matching Gallery).

## Components

### 1. Value types (package-agnostic — no LiteRTLM import)
- `BenchmarkConfig`: `backend: ComputeBackend`, `prefillTokens: Int`, `decodeTokens: Int`, `runCount: Int`. Default = `.gpu`, 256, 256, 5.
- `BenchmarkRun`: one run — `initSeconds`, `ttftSeconds`, `prefillTokPerSec`, `decodeTokPerSec`.
- `BenchmarkResult`: `runs: [BenchmarkRun]` plus aggregates `firstInitSeconds`, `avgWarmInitSeconds` (runs 2…N; falls back to first when runCount == 1), `avgTTFTSeconds`, `avgPrefillTokPerSec`, `avgDecodeTokPerSec`. Pure `static func aggregate(_ runs: [BenchmarkRun]) -> BenchmarkResult`.

New file: `Gemma/Gemma/Bench/BenchmarkTypes.swift`.

### 2. `PerfBenchmarker` (imports LiteRTLM)
`static func run(modelPath: String, config: BenchmarkConfig, onProgress: (@MainActor @Sendable (Int, Int) -> Void)?) async throws -> BenchmarkResult`. Maps `ComputeBackend` → `LiteRTLM.Backend`, calls `LiteRTLM.benchmark(modelPath:backend:prefillTokens:decodeTokens:cacheDir:)` `runCount` times on a background `Task.detached` (the docs recommend a background thread; each call owns its engine lifecycle, so there is no cross-call thread-affinity issue), maps each `BenchmarkInfo` → `BenchmarkRun`, calls `onProgress(i+1, runCount)` after each, and returns `BenchmarkResult.aggregate(...)`. Uses a unique temp `cacheDir` under `NSTemporaryDirectory()` and removes it at the end (like Gallery).

New file: `Gemma/Gemma/Runtime/PerfBenchmarker.swift`.

### 3. `BenchmarkModel` (@Observable @MainActor)
Holds editable `config`, `isRunning`, `progress: (Int, Int)?`, `result: BenchmarkResult?`, `errorMessage: String?`. `func run(modelURL: URL) async` sets `isRunning`, calls `PerfBenchmarker.run` (updating `progress`), stores `result` or `errorMessage`. Guards against re-entry.

New file: `Gemma/Gemma/Harness/BenchmarkModel.swift`.

### 4. `BenchmarkView` (sheet)
Form: `Picker` backend (CPU/GPU bound to `config.backend`), `Stepper`s for prefillTokens / decodeTokens (step 64, range 64…2048) and runCount (1…20), a **Run** button (disabled while running) showing progress "Run i/N", a results section (first init, warm-avg init, TTFT, prefill tok/s, decode tok/s) when `result != nil`, and an error line. "Done" toolbar button.

New file: `Gemma/Gemma/Harness/BenchmarkView.swift`.

### 5. `HarnessModel` / `HarnessView` integration
- `HarnessModel` gains `var showBenchmark: Bool` and `private(set) var benchmark = BenchmarkModel()`, plus `func presentBenchmark() async`: if `runtimeKind.requiredModelId == nil` (Dummy) set a status message and return; resolve the installed model URL (status `.installed`), **unload the runtime if loaded** (avoid two engines / 2× memory), then set `showBenchmark = true`. Stores the resolved URL for the sheet (`benchmarkModelURL: URL?`).
- `HarnessView`: replace the **"Run Bench"** button with **"Benchmark"** that calls `Task { await model.presentBenchmark() }`; add `.sheet(isPresented: $model.showBenchmark) { BenchmarkView(model: model.benchmark, modelURL: model.benchmarkModelURL) }`.
- Remove the old `runBench()` method and its `BenchRunner` invocation from `HarnessModel`. `BenchRunner.swift` and `BenchRunnerTests.swift` stay (unused by UI, retained for potential reuse).

## Data flow

`BenchmarkView` (edits `config`) → `BenchmarkModel.run(modelURL:)` → `PerfBenchmarker.run` → `LiteRTLM.benchmark()` ×N (background) → `BenchmarkResult` → back on MainActor into `BenchmarkModel.result` → rendered in the sheet.

## Error handling
- Dummy / no installed model: `presentBenchmark` sets `statusMessage` and does not open the sheet.
- A failed `benchmark()` call throws; `BenchmarkModel` catches and sets `errorMessage`, shown in the sheet. Temp cacheDir is always cleaned (defer).

## Testing (TDD)
- `BenchmarkResult.aggregate`: correct averages; first init separated from warm runs; runCount == 1 falls back; empty runs returns zeros.
- `BenchmarkConfig` defaults.
- Native `benchmark()` execution verified on the physical iPhone 16 (not unit-tested).

## Out of scope
- Comparative combos (CPU vs GPU, MTP on/off) and the S1 runtime report → Plan 3c.
- Real-prompt quality eval with text output → future (needs a memory solution).
- Persisting benchmark config across launches.
