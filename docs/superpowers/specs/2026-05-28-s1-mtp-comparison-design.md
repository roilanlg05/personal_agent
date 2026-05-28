# S1 Plan 3c — MTP comparison + runtime report (design spec)

**Date:** 2026-05-28
**Status:** approved (brainstorming)
**Position:** S1 Plan 3c. Builds on the perf benchmark (`s1-perf-benchmark`) and Settings UI (`s1-plan3b-settings-ui`). Produces the S1 runtime report's MTP decision.

## Why

`01-s1-runtime.md` requires a measured decision on whether to use Multi-Token Prediction (speculative decoding / MTP). The other S1 comparisons it envisioned (LiteRT-LM vs llama.cpp, official vs uncensored model, mmap vs full-load) are not buildable yet — llama.cpp, the GGUF/uncensored model, and an mmap toggle don't exist (they are Plan 4). So Plan 3c answers the one comparison that IS feasible today: **MTP off vs on, on GPU**, using the official `benchmark()` API, and writes the report for that decision.

## What it does

A one-tap comparison in the existing Benchmark sheet that runs the model with MTP off and then with MTP on (GPU, same prefill/decode/run counts), shows a side-by-side table with the decode speedup, and feeds a written report.

MTP is toggled via `ExperimentalFlags.enableSpeculativeDecoding`, which is read when an Engine is created. `benchmark()` creates a fresh engine per call, so setting the flag before each block takes effect.

## Components

### 1. `MTPComparison` (value type — append to `Gemma/Gemma/Bench/BenchmarkTypes.swift`)
```
public struct MTPComparison: Equatable, Sendable {
    public var mtpOff: BenchmarkResult
    public var mtpOn: BenchmarkResult
    public var decodeSpeedup: Double   // mtpOn.avgDecodeTokPerSec / mtpOff.avgDecodeTokPerSec, 0 if denom 0
    public var prefillSpeedup: Double   // same for prefill
}
```
`decodeSpeedup`/`prefillSpeedup` are computed in the initializer (or a factory) from the two results; division by zero yields 0. Public init.

### 2. `PerfBenchmarker.compareMTP(...)` (in `PerfBenchmarker.swift`, imports LiteRTLM)
`static func compareMTP(modelPath: String, config: BenchmarkConfig, onProgress: (@MainActor @Sendable (Int, Int) -> Void)?) async throws -> MTPComparison`.
- `ExperimentalFlags.optIntoExperimentalAPIs()`.
- Captures the previous `enableSpeculativeDecoding`; `defer` restores it.
- Block A (MTP off): set `enableSpeculativeDecoding = false`; run `benchmark()` `runCount` times (GPU per config, `cacheDir: ":nocache"`), aggregate → `mtpOff`.
- Block B (MTP on): set `enableSpeculativeDecoding = true`; run `runCount` times, aggregate → `mtpOn`.
- `onProgress(completed, 2*runCount)` after each run.
- Returns `MTPComparison(mtpOff:mtpOn:)`.
- Reuses the same per-run mapping (`BenchmarkInfo` → `BenchmarkRun`) already in `PerfBenchmarker.run`; factor the single-config N-run loop into a private helper so `run` and `compareMTP` share it (DRY).

### 3. `BenchmarkModel`
Add `public private(set) var comparison: MTPComparison?`, `public private(set) var isComparing: Bool`, and `func compareMTP(modelURL: URL) async` — same guard/progress/error pattern as `run`, storing `comparison` or `errorMessage`.

### 4. `BenchmarkView`
Add a **"Compare MTP on/off"** button (alongside the existing "Run benchmark"), disabled while running. When `comparison != nil`, show a section with a 2-column table (MTP off | MTP on) for rows: prefill tok/s, decode tok/s, TTFT, first init; plus a **"Decode speedup: ×N.NN"** line. Progress shows "Comparing… i/2N".

### 5. Report (authored after the device run, not code)
`docs/superpowers/specs/01-s1-runtime-report.md`: the comparison table with real iPhone 16 numbers, the decode/prefill speedup, the **MTP decision (use it or not)**, and caveats — GPU only, E4B, physical device (simulator excluded), and the deferred comparisons (llama.cpp / uncensored / mmap) flagged as Plan 4.

## Data flow
`BenchmarkView` (Compare button) → `BenchmarkModel.compareMTP(modelURL:)` → `PerfBenchmarker.compareMTP` → `benchmark()` ×2N (MTP off then on, via ExperimentalFlags) → `MTPComparison` → rendered table. Numbers → human-written report.

## Error handling
- If the model doesn't support MTP, `enableSpeculativeDecoding = true` makes `benchmark()` throw at engine creation → caught in `BenchmarkModel` → `errorMessage`.
- `:nocache` (already proven) avoids the weight-cache-write crash.
- The previous `enableSpeculativeDecoding` value is always restored (defer).

## Testing (TDD)
- `MTPComparison` speedups: correct ratio; denom 0 → 0; equal results → 1.0.
- Native `compareMTP` verified on the physical iPhone 16.

## Out of scope (Plan 4 / later)
- llama.cpp runtime, uncensored GGUF model, mmap-vs-full comparison, energy measurement.
- CPU-vs-GPU and E2B-vs-E4B matrices (this plan fixes GPU + the installed model).
- In-app report export (the report is authored in markdown from the on-screen numbers).
