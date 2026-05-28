# S1 Plan 3c — MTP Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a one-tap "Compare MTP on/off" to the Benchmark sheet that runs the model with speculative decoding disabled then enabled (GPU), shows a side-by-side table with the decode speedup, and feeds a hand-written S1 runtime report.

**Architecture:** A pure `MTPComparison` value type computes speedups from two `BenchmarkResult`s. `PerfBenchmarker.compareMTP` toggles `ExperimentalFlags.enableSpeculativeDecoding` (read at engine creation; `benchmark()` makes a fresh engine per call) around two N-run blocks, reusing a shared run-loop helper. `BenchmarkModel` exposes the comparison to a new button + table in `BenchmarkView`.

**Tech Stack:** Swift 5, SwiftUI, `@Observable`/`@MainActor`, `LiteRTLM` (`benchmark()`, `ExperimentalFlags`, `BenchmarkInfo`), XCTest, iPhone 17 simulator (unit) + iPhone 16 physical (smoke). Filesystem-synchronized Xcode groups — no project.pbxproj edits.

**Spec:** `docs/superpowers/specs/2026-05-28-s1-mtp-comparison-design.md`.

**Conventions:**
- `xcodebuild` runs from `/Users/hashdown/Projects/personal_agent/Gemma`.
- Sim test shorthand: `xcodebuild test -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17'`
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## File structure produced by this plan

```
Gemma/Gemma/
├── Bench/BenchmarkTypes.swift     (MODIFY — append MTPComparison)
├── Runtime/PerfBenchmarker.swift  (MODIFY — factor runBlock; add compareMTP)
└── Harness/
    ├── BenchmarkModel.swift       (MODIFY — comparison state + compareMTP)
    └── BenchmarkView.swift        (MODIFY — Compare button + comparison table)

Gemma/GemmaTests/
└── BenchmarkTypesTests.swift      (MODIFY — MTPComparison speedup tests)

docs/superpowers/specs/
└── 01-s1-runtime-report.md        (NEW — authored from device numbers, Task 5)
```

---

## Task 1: `MTPComparison` value type

**Files:**
- Modify: `Gemma/Gemma/Bench/BenchmarkTypes.swift`
- Test: `Gemma/GemmaTests/BenchmarkTypesTests.swift`

- [ ] **Step 1: Add failing tests**

Append these test methods inside the existing `BenchmarkTypesTests` class in `Gemma/GemmaTests/BenchmarkTypesTests.swift`:

```swift
    private func result(decode: Double, prefill: Double) -> BenchmarkResult {
        BenchmarkResult(runs: [], firstInitSeconds: 0, avgWarmInitSeconds: 0,
                        avgTTFTSeconds: 0, avgPrefillTokPerSec: prefill, avgDecodeTokPerSec: decode)
    }

    func test_mtpComparison_computesSpeedups() {
        let c = MTPComparison(mtpOff: result(decode: 10, prefill: 100),
                              mtpOn: result(decode: 22, prefill: 120))
        XCTAssertEqual(c.decodeSpeedup, 2.2, accuracy: 0.0001)
        XCTAssertEqual(c.prefillSpeedup, 1.2, accuracy: 0.0001)
    }

    func test_mtpComparison_zeroDenominatorIsZero() {
        let c = MTPComparison(mtpOff: result(decode: 0, prefill: 0),
                              mtpOn: result(decode: 22, prefill: 120))
        XCTAssertEqual(c.decodeSpeedup, 0, accuracy: 0.0001)
        XCTAssertEqual(c.prefillSpeedup, 0, accuracy: 0.0001)
    }

    func test_mtpComparison_equalResultsIsOne() {
        let c = MTPComparison(mtpOff: result(decode: 10, prefill: 100),
                              mtpOn: result(decode: 10, prefill: 100))
        XCTAssertEqual(c.decodeSpeedup, 1.0, accuracy: 0.0001)
        XCTAssertEqual(c.prefillSpeedup, 1.0, accuracy: 0.0001)
    }
```

- [ ] **Step 2: Run — verify it fails to compile**

Run: `xcodebuild test ... -only-testing:GemmaTests/BenchmarkTypesTests`
Expected: build failure — `cannot find 'MTPComparison' in scope`.

- [ ] **Step 3: Append `MTPComparison` to `BenchmarkTypes.swift`**

Add at the end of `Gemma/Gemma/Bench/BenchmarkTypes.swift`:

```swift
/// MTP (speculative decoding) off-vs-on comparison. Speedup = on/off; the decode
/// speedup is the headline number MTP targets.
public struct MTPComparison: Equatable, Sendable {
    public var mtpOff: BenchmarkResult
    public var mtpOn: BenchmarkResult
    public var decodeSpeedup: Double
    public var prefillSpeedup: Double

    public init(mtpOff: BenchmarkResult, mtpOn: BenchmarkResult) {
        self.mtpOff = mtpOff
        self.mtpOn = mtpOn
        self.decodeSpeedup = mtpOff.avgDecodeTokPerSec > 0
            ? mtpOn.avgDecodeTokPerSec / mtpOff.avgDecodeTokPerSec : 0
        self.prefillSpeedup = mtpOff.avgPrefillTokPerSec > 0
            ? mtpOn.avgPrefillTokPerSec / mtpOff.avgPrefillTokPerSec : 0
    }
}
```

- [ ] **Step 4: Run — verify it passes**

Run: `xcodebuild test ... -only-testing:GemmaTests/BenchmarkTypesTests`
Expected: all tests pass (the original 4 + 3 new).

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Bench/BenchmarkTypes.swift Gemma/GemmaTests/BenchmarkTypesTests.swift
git commit -m "feat(bench): MTPComparison value type (decode/prefill speedups)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `PerfBenchmarker.compareMTP` (+ shared run-loop helper)

**Files:**
- Modify: `Gemma/Gemma/Runtime/PerfBenchmarker.swift`

No unit test (native engine); verified by build + on-device smoke (Task 5).

The current `PerfBenchmarker.run` body is:
```swift
        let backend: Backend = config.backend == .gpu ? .gpu : .cpu()
        let cacheDir = ":nocache"
        var runs: [BenchmarkRun] = []
        for i in 0..<max(1, config.runCount) {
            let info = try await benchmark(
                modelPath: modelPath, backend: backend,
                prefillTokens: config.prefillTokens, decodeTokens: config.decodeTokens,
                cacheDir: cacheDir)
            runs.append(BenchmarkRun(
                initSeconds: info.initTimeInSecond, ttftSeconds: info.timeToFirstTokenInSecond,
                prefillTokPerSec: info.lastPrefillTokensPerSecond, decodeTokPerSec: info.lastDecodeTokensPerSecond))
            await onProgress?(i + 1, max(1, config.runCount))
        }
        return BenchmarkResult.aggregate(runs)
```

- [ ] **Step 1: Factor a shared run-loop helper and reimplement `run` on it**

Replace the body of `run(...)` and add a private helper, so the file's `PerfBenchmarker` enum reads:

```swift
public enum PerfBenchmarker {
    /// Runs `config.runCount` benchmark() calls (GPU/CPU per config, no on-disk
    /// cache — see :nocache rationale) and returns the per-run measurements.
    /// `progressBase`/`progressTotal` let callers report progress across multiple blocks.
    private static func runBlock(
        modelPath: String,
        backend: Backend,
        config: BenchmarkConfig,
        progressBase: Int,
        progressTotal: Int,
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) async throws -> [BenchmarkRun] {
        var runs: [BenchmarkRun] = []
        for i in 0..<max(1, config.runCount) {
            let info = try await benchmark(
                modelPath: modelPath,
                backend: backend,
                prefillTokens: config.prefillTokens,
                decodeTokens: config.decodeTokens,
                cacheDir: ":nocache"
            )
            runs.append(BenchmarkRun(
                initSeconds: info.initTimeInSecond,
                ttftSeconds: info.timeToFirstTokenInSecond,
                prefillTokPerSec: info.lastPrefillTokensPerSecond,
                decodeTokPerSec: info.lastDecodeTokensPerSecond
            ))
            await onProgress?(progressBase + i + 1, progressTotal)
        }
        return runs
    }

    public static func run(
        modelPath: String,
        config: BenchmarkConfig,
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> BenchmarkResult {
        let backend: Backend = config.backend == .gpu ? .gpu : .cpu()
        let total = max(1, config.runCount)
        let runs = try await runBlock(modelPath: modelPath, backend: backend, config: config,
                                      progressBase: 0, progressTotal: total, onProgress: onProgress)
        return BenchmarkResult.aggregate(runs)
    }

    /// Runs the model with MTP (speculative decoding) off, then on, and returns the
    /// comparison. MTP is toggled via ExperimentalFlags (read when each fresh engine
    /// is created inside benchmark()).
    public static func compareMTP(
        modelPath: String,
        config: BenchmarkConfig,
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> MTPComparison {
        ExperimentalFlags.optIntoExperimentalAPIs()
        let previous = ExperimentalFlags.enableSpeculativeDecoding
        defer { ExperimentalFlags.enableSpeculativeDecoding = previous }

        let backend: Backend = config.backend == .gpu ? .gpu : .cpu()
        let n = max(1, config.runCount)
        let total = n * 2

        ExperimentalFlags.enableSpeculativeDecoding = false
        let offRuns = try await runBlock(modelPath: modelPath, backend: backend, config: config,
                                         progressBase: 0, progressTotal: total, onProgress: onProgress)

        ExperimentalFlags.enableSpeculativeDecoding = true
        let onRuns = try await runBlock(modelPath: modelPath, backend: backend, config: config,
                                        progressBase: n, progressTotal: total, onProgress: onProgress)

        return MTPComparison(mtpOff: BenchmarkResult.aggregate(offRuns),
                             mtpOn: BenchmarkResult.aggregate(onRuns))
    }
}
```
(Keep the file's existing `import Foundation` / `import LiteRTLM` header.)

- [ ] **Step 2: Build**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild build -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -4`
Expected `** BUILD SUCCEEDED **`.

> `ExperimentalFlags.enableSpeculativeDecoding` is `Bool?`; assigning `false`/`true` is fine. If the build fails on `ExperimentalFlags` API, STOP and report the exact error (it lives in `vendor/LiteRT-LM/swift/ExperimentalFlags.swift`).

- [ ] **Step 3: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Runtime/PerfBenchmarker.swift
git commit -m "feat(bench): PerfBenchmarker.compareMTP (off vs on) + shared runBlock

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `BenchmarkModel` comparison state

**Files:**
- Modify: `Gemma/Gemma/Harness/BenchmarkModel.swift`

No unit test (drives native); verified by build + smoke.

- [ ] **Step 1: Add comparison state + `compareMTP`**

In `Gemma/Gemma/Harness/BenchmarkModel.swift`, add these properties alongside the existing ones (after `public private(set) var result: BenchmarkResult?`):
```swift
    public private(set) var comparison: MTPComparison?
    public private(set) var isComparing = false
```

And add this method after the existing `run(modelURL:)`:
```swift
    public func compareMTP(modelURL: URL) async {
        guard !isRunning && !isComparing else { return }
        isComparing = true
        errorMessage = nil
        comparison = nil
        progress = (0, config.runCount * 2)
        defer { isComparing = false }
        do {
            let c = try await PerfBenchmarker.compareMTP(
                modelPath: modelURL.path,
                config: config,
                onProgress: { [weak self] completed, total in
                    self?.progress = (completed, total)
                }
            )
            comparison = c
        } catch {
            errorMessage = "\(error)"
        }
    }
```

- [ ] **Step 2: Build**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild build -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -4`
Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Harness/BenchmarkModel.swift
git commit -m "feat(bench): BenchmarkModel comparison state + compareMTP

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `BenchmarkView` — Compare button + comparison table

**Files:**
- Modify: `Gemma/Gemma/Harness/BenchmarkView.swift`

No unit test (SwiftUI); verified by build + smoke.

The current `BenchmarkView` has a "Parameters" Section, a Section with the "Run benchmark" button (disabled `model.isRunning || modelURL == nil`, label shows progress when `model.isRunning`), an optional results Section (`if let r = model.result`), and an error Section. It has a `private func resultRow(_:_:) -> some View`.

- [ ] **Step 1: Add the Compare button to the run Section**

In the Section that currently holds the "Run benchmark" button, add a second button right after it:
```swift
                    Button {
                        if let url = modelURL { Task { await model.compareMTP(modelURL: url) } }
                    } label: {
                        if let p = model.progress, model.isComparing {
                            Text("Comparing MTP… \(p.completed)/\(p.total)")
                        } else {
                            Text("Compare MTP on/off")
                        }
                    }
                    .disabled(model.isRunning || model.isComparing || modelURL == nil)
```
Also update the existing "Run benchmark" button's `.disabled(...)` to also disable while comparing: change it to `.disabled(model.isRunning || model.isComparing || modelURL == nil)`.

- [ ] **Step 2: Add the comparison table section**

Add this right after the existing `if let r = model.result { ... }` results Section (and before the error Section):
```swift
                if let c = model.comparison {
                    Section("MTP off vs on (avg of \(c.mtpOff.runs.count) run\(c.mtpOff.runs.count == 1 ? "" : "s"))") {
                        comparisonRow("", "MTP off", "MTP on")
                        comparisonRow("Prefill tok/s",
                                      String(format: "%.1f", c.mtpOff.avgPrefillTokPerSec),
                                      String(format: "%.1f", c.mtpOn.avgPrefillTokPerSec))
                        comparisonRow("Decode tok/s",
                                      String(format: "%.1f", c.mtpOff.avgDecodeTokPerSec),
                                      String(format: "%.1f", c.mtpOn.avgDecodeTokPerSec))
                        comparisonRow("TTFT s",
                                      String(format: "%.2f", c.mtpOff.avgTTFTSeconds),
                                      String(format: "%.2f", c.mtpOn.avgTTFTSeconds))
                        comparisonRow("First init s",
                                      String(format: "%.2f", c.mtpOff.firstInitSeconds),
                                      String(format: "%.2f", c.mtpOn.firstInitSeconds))
                        HStack {
                            Text("Decode speedup").bold()
                            Spacer()
                            Text(String(format: "×%.2f", c.decodeSpeedup)).monospaced().bold()
                        }
                    }
                }
```

- [ ] **Step 3: Add the `comparisonRow` helper**

Add this method next to the existing `resultRow`:
```swift
    private func comparisonRow(_ label: String, _ off: String, _ on: String) -> some View {
        HStack {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Text(off).monospaced().frame(maxWidth: .infinity, alignment: .trailing)
            Text(on).monospaced().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
```

- [ ] **Step 4: Build**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild build -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -4`
Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Harness/BenchmarkView.swift
git commit -m "feat(bench): Compare MTP button + off/on comparison table

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Full suite + device smoke + report + tag

**Files:**
- Create: `docs/superpowers/specs/01-s1-runtime-report.md` (authored from device numbers)

- [ ] **Step 1: Full simulator suite (minus device-only runtime tests)**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' -skip-testing:GemmaTests/LiteRTLMRuntimeTests 2>&1 | tail -5`
Expected `** TEST SUCCEEDED **`.

- [ ] **Step 2: On-device smoke (HUMAN STEP — physical iPhone 16)**

```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild -project Gemma.xcodeproj -scheme Gemma -destination 'platform=iOS,id=00008140-000A6216110A801C' -allowProvisioningUpdates -derivedDataPath /tmp/gemma_dd build 2>&1 | tail -2
APP=$(find /tmp/gemma_dd/Build/Products/Debug-iphoneos -maxdepth 1 -name "Gemma.app" | head -1)
xcrun devicectl device install app --device 00008140-000A6216110A801C "$APP"
```
On the unlocked device: Gemma E4B → **Benchmark** → **Compare MTP on/off** (defaults GPU, 256/256, 5 runs). Confirm it completes both blocks (10 runs) without crashing and the table shows non-zero numbers for both columns. Record the table + decode speedup (read it out or screenshot).

- [ ] **Step 3: Author the S1 runtime report**

Using the recorded numbers, create `docs/superpowers/specs/01-s1-runtime-report.md` with: a one-line summary; the MTP off/on table (prefill tok/s, decode tok/s, TTFT, first init); the decode and prefill speedups; the **MTP decision** ("use MTP" if decode speedup is clearly > 1, e.g. ≥ ~1.2×; "don't" otherwise; "inconclusive — flag toggling suspect" if off ≈ on); and caveats: GPU only, Gemma E4B, physical iPhone 16 (8 GB), simulator excluded, `:nocache` cold builds; and the deferred S1 comparisons (llama.cpp, uncensored GGUF, mmap-vs-full, energy) flagged as Plan 4. Link it from `01-s1-runtime.md` if that file has a report pointer.

- [ ] **Step 4: Update the knowledge graph**

Run: `cd /Users/hashdown/Projects/personal_agent && graphify update .`

- [ ] **Step 5: Commit report + tag**

```bash
cd /Users/hashdown/Projects/personal_agent
git add docs/superpowers/specs/01-s1-runtime-report.md
git commit -m "docs(s1): runtime report — MTP off/on comparison + decision (device numbers)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git tag -a s1-plan3c-mtp-report -m "S1 Plan 3c: MTP off/on comparison + runtime report"
git tag -l | grep s1- | sort
```

---

## Out of scope (Plan 4 / later)
- llama.cpp runtime, uncensored GGUF, mmap-vs-full, energy measurement.
- CPU-vs-GPU and E2B-vs-E4B matrices (this plan fixes GPU + the installed model).
- In-app report export.

## Risks
| # | Risk | Mitigation |
|---|------|-----------|
| R1 | `enableSpeculativeDecoding` may not re-toggle per fresh engine (set-once-per-process). | Each `benchmark()` builds a new engine that re-reads the flag; if off ≈ on on device, the report records the comparison as inconclusive and notes the suspected cause. |
| R2 | Model lacks MTP support → enabling throws. | E4B ships an `mtp_drafter` section; if it throws, `BenchmarkModel.errorMessage` surfaces it (no crash). |
| R3 | Device build needs `-allowProvisioningUpdates` (increased-memory-limit entitlement). | Task 5 includes the flag. |
