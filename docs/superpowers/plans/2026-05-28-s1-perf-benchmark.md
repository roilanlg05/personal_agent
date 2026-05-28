# S1 Performance Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild "Run Bench" as a performance benchmark on the official LiteRT-LM `benchmark()` API — a dedicated sheet that runs the model N times with synthetic prefill/decode token counts and reports init time, TTFT, and prefill/decode tokens/sec.

**Architecture:** A package-agnostic `BenchmarkConfig`/`BenchmarkResult` value layer; a `PerfBenchmarker` that wraps `LiteRTLM.benchmark()` (creates/tears down its own engine per run — no chat loop, no per-prompt KV-cache churn, so it avoids the OOM that killed the old PromptSet bench); a `BenchmarkModel` (@Observable @MainActor) for sheet state; and a `BenchmarkView` sheet. `HarnessModel` unloads its runtime before benchmarking (avoids two engines / 2× memory) and presents the sheet.

**Tech Stack:** Swift 5, SwiftUI, `@Observable`/`@MainActor`, `LiteRTLM` (`benchmark()` / `BenchmarkInfo`), XCTest, iPhone 17 simulator (unit) + iPhone 16 physical (smoke). Filesystem-synchronized Xcode groups — new files under `Gemma/Gemma/` and `Gemma/GemmaTests/` compile automatically, no project.pbxproj edits.

**Spec:** `docs/superpowers/specs/2026-05-28-s1-perf-benchmark-design.md`.

**Conventions:**
- `xcodebuild` runs from `/Users/hashdown/Projects/personal_agent/Gemma`.
- Sim test shorthand: `xcodebuild test -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17'`
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## File structure produced by this plan

```
Gemma/Gemma/
├── Bench/
│   └── BenchmarkTypes.swift     (NEW — BenchmarkConfig, BenchmarkRun, BenchmarkResult + aggregate)
├── Runtime/
│   └── PerfBenchmarker.swift    (NEW — wraps LiteRTLM.benchmark(); imports LiteRTLM)
└── Harness/
    ├── BenchmarkModel.swift     (NEW — @Observable @MainActor sheet state)
    ├── BenchmarkView.swift      (NEW — benchmark sheet)
    ├── HarnessModel.swift       (MODIFY — presentBenchmark, benchmark state; remove runBench)
    └── HarnessView.swift        (MODIFY — "Benchmark" button + sheet, replaces "Run Bench")

Gemma/GemmaTests/
├── BenchmarkTypesTests.swift    (NEW)
└── HarnessModelTests.swift      (MODIFY — drop runBench test; add presentBenchmark test)
```

---

## Task 1: Benchmark value types

**Files:**
- Create: `Gemma/Gemma/Bench/BenchmarkTypes.swift`
- Test: `Gemma/GemmaTests/BenchmarkTypesTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Gemma/GemmaTests/BenchmarkTypesTests.swift`:

```swift
import XCTest
@testable import Gemma

final class BenchmarkTypesTests: XCTestCase {
    func test_config_defaults() {
        let c = BenchmarkConfig()
        XCTAssertEqual(c.backend, .gpu)
        XCTAssertEqual(c.prefillTokens, 256)
        XCTAssertEqual(c.decodeTokens, 256)
        XCTAssertEqual(c.runCount, 5)
    }

    func test_aggregate_emptyRunsIsZero() {
        let r = BenchmarkResult.aggregate([])
        XCTAssertEqual(r.runs.count, 0)
        XCTAssertEqual(r.firstInitSeconds, 0)
        XCTAssertEqual(r.avgWarmInitSeconds, 0)
        XCTAssertEqual(r.avgTTFTSeconds, 0)
        XCTAssertEqual(r.avgPrefillTokPerSec, 0)
        XCTAssertEqual(r.avgDecodeTokPerSec, 0)
    }

    func test_aggregate_separatesFirstInitFromWarm() {
        let runs = [
            BenchmarkRun(initSeconds: 10, ttftSeconds: 1.0, prefillTokPerSec: 100, decodeTokPerSec: 10),
            BenchmarkRun(initSeconds: 2,  ttftSeconds: 0.5, prefillTokPerSec: 200, decodeTokPerSec: 20),
            BenchmarkRun(initSeconds: 4,  ttftSeconds: 0.5, prefillTokPerSec: 300, decodeTokPerSec: 30),
        ]
        let r = BenchmarkResult.aggregate(runs)
        XCTAssertEqual(r.firstInitSeconds, 10, accuracy: 0.0001)
        XCTAssertEqual(r.avgWarmInitSeconds, 3, accuracy: 0.0001)        // (2+4)/2
        XCTAssertEqual(r.avgTTFTSeconds, 2.0/3.0, accuracy: 0.0001)       // (1+0.5+0.5)/3
        XCTAssertEqual(r.avgPrefillTokPerSec, 200, accuracy: 0.0001)      // (100+200+300)/3
        XCTAssertEqual(r.avgDecodeTokPerSec, 20, accuracy: 0.0001)        // (10+20+30)/3
    }

    func test_aggregate_singleRunWarmFallsBackToFirst() {
        let r = BenchmarkResult.aggregate([
            BenchmarkRun(initSeconds: 7, ttftSeconds: 1, prefillTokPerSec: 50, decodeTokPerSec: 5)
        ])
        XCTAssertEqual(r.firstInitSeconds, 7, accuracy: 0.0001)
        XCTAssertEqual(r.avgWarmInitSeconds, 7, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run — verify it fails to compile**

Run: `xcodebuild test ... -only-testing:GemmaTests/BenchmarkTypesTests`
Expected: build failure — `cannot find 'BenchmarkConfig'`/`'BenchmarkResult'`/`'BenchmarkRun'` in scope.

- [ ] **Step 3: Implement the value types**

Create `Gemma/Gemma/Bench/BenchmarkTypes.swift`:

```swift
import Foundation

/// User-tunable benchmark parameters. Package-agnostic (uses ComputeBackend).
public struct BenchmarkConfig: Equatable, Sendable {
    public var backend: ComputeBackend
    public var prefillTokens: Int
    public var decodeTokens: Int
    public var runCount: Int

    public init(
        backend: ComputeBackend = .gpu,
        prefillTokens: Int = 256,
        decodeTokens: Int = 256,
        runCount: Int = 5
    ) {
        self.backend = backend
        self.prefillTokens = prefillTokens
        self.decodeTokens = decodeTokens
        self.runCount = runCount
    }
}

/// One benchmark run's measurements (mapped from LiteRTLM.BenchmarkInfo).
public struct BenchmarkRun: Equatable, Sendable {
    public var initSeconds: Double
    public var ttftSeconds: Double
    public var prefillTokPerSec: Double
    public var decodeTokPerSec: Double

    public init(initSeconds: Double, ttftSeconds: Double, prefillTokPerSec: Double, decodeTokPerSec: Double) {
        self.initSeconds = initSeconds
        self.ttftSeconds = ttftSeconds
        self.prefillTokPerSec = prefillTokPerSec
        self.decodeTokPerSec = decodeTokPerSec
    }
}

/// Aggregated benchmark results. The first run's init time is reported separately
/// because it includes cold compilation; warm runs (2…N) are averaged.
public struct BenchmarkResult: Equatable, Sendable {
    public var runs: [BenchmarkRun]
    public var firstInitSeconds: Double
    public var avgWarmInitSeconds: Double
    public var avgTTFTSeconds: Double
    public var avgPrefillTokPerSec: Double
    public var avgDecodeTokPerSec: Double

    public static func aggregate(_ runs: [BenchmarkRun]) -> BenchmarkResult {
        func avg(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        let first = runs.first?.initSeconds ?? 0
        let warm = Array(runs.dropFirst())
        let warmInit = warm.isEmpty ? first : avg(warm.map(\.initSeconds))
        return BenchmarkResult(
            runs: runs,
            firstInitSeconds: first,
            avgWarmInitSeconds: warmInit,
            avgTTFTSeconds: avg(runs.map(\.ttftSeconds)),
            avgPrefillTokPerSec: avg(runs.map(\.prefillTokPerSec)),
            avgDecodeTokPerSec: avg(runs.map(\.decodeTokPerSec))
        )
    }
}
```

- [ ] **Step 4: Run — verify it passes**

Run: `xcodebuild test ... -only-testing:GemmaTests/BenchmarkTypesTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Bench/BenchmarkTypes.swift Gemma/GemmaTests/BenchmarkTypesTests.swift
git commit -m "feat(bench): BenchmarkConfig/Run/Result value types + aggregate

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `PerfBenchmarker` (wraps the official `benchmark()`)

**Files:**
- Create: `Gemma/Gemma/Runtime/PerfBenchmarker.swift`

Wraps `LiteRTLM.benchmark(modelPath:backend:prefillTokens:decodeTokens:cacheDir:) async throws -> BenchmarkInfo`. No unit test (native engine); verified by build here + on-device smoke in Task 6.

- [ ] **Step 1: Implement `PerfBenchmarker`**

Create `Gemma/Gemma/Runtime/PerfBenchmarker.swift`:

```swift
import Foundation
import LiteRTLM

/// Runs the official LiteRTLM `benchmark()` N times and aggregates. Each call
/// creates and tears down its own engine with synthetic prefill/decode tokens, so
/// there is no chat loop or per-prompt KV-cache churn.
public enum PerfBenchmarker {
    public static func run(
        modelPath: String,
        config: BenchmarkConfig,
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> BenchmarkResult {
        let backend: Backend = config.backend == .gpu ? .gpu : .cpu()

        // Dedicated temp cache dir, cleaned up afterwards (matches Edge Gallery).
        let cacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bench-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        var runs: [BenchmarkRun] = []
        for i in 0..<max(1, config.runCount) {
            let info = try await benchmark(
                modelPath: modelPath,
                backend: backend,
                prefillTokens: config.prefillTokens,
                decodeTokens: config.decodeTokens,
                cacheDir: cacheDir.path
            )
            runs.append(BenchmarkRun(
                initSeconds: info.initTimeInSecond,
                ttftSeconds: info.timeToFirstTokenInSecond,
                prefillTokPerSec: info.lastPrefillTokensPerSecond,
                decodeTokPerSec: info.lastDecodeTokensPerSecond
            ))
            await onProgress?(i + 1, max(1, config.runCount))
        }
        return BenchmarkResult.aggregate(runs)
    }
}
```

- [ ] **Step 2: Build — verify it compiles**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild build -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

> If the build fails with a `benchmark` / `BenchmarkInfo` API mismatch, STOP and report the exact compile error — the signature is taken from `vendor/LiteRT-LM/swift/Benchmark.swift` and must match the linked package.

- [ ] **Step 3: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Runtime/PerfBenchmarker.swift
git commit -m "feat(bench): PerfBenchmarker wrapping the official benchmark() API

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `BenchmarkModel` (sheet state)

**Files:**
- Create: `Gemma/Gemma/Harness/BenchmarkModel.swift`

Holds editable config + run state. No unit test (drives the native PerfBenchmarker); verified by build + smoke.

- [ ] **Step 1: Implement `BenchmarkModel`**

Create `Gemma/Gemma/Harness/BenchmarkModel.swift`:

```swift
import Foundation
import Observation

@Observable
@MainActor
public final class BenchmarkModel {
    public var config = BenchmarkConfig()
    public private(set) var isRunning = false
    public private(set) var progress: (completed: Int, total: Int)?
    public private(set) var result: BenchmarkResult?
    public private(set) var errorMessage: String?

    public init() {}

    public func run(modelURL: URL) async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        result = nil
        progress = (0, config.runCount)
        defer { isRunning = false }
        do {
            let r = try await PerfBenchmarker.run(
                modelPath: modelURL.path,
                config: config,
                onProgress: { [weak self] completed, total in
                    self?.progress = (completed, total)
                }
            )
            result = r
        } catch {
            errorMessage = "\(error)"
        }
    }
}
```

- [ ] **Step 2: Build — verify it compiles**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild build -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Harness/BenchmarkModel.swift
git commit -m "feat(bench): BenchmarkModel (sheet state, runs PerfBenchmarker)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `HarnessModel` integration (present benchmark, remove old runBench)

**Files:**
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift`
- Test: `Gemma/GemmaTests/HarnessModelTests.swift`

- [ ] **Step 1: Update tests — drop the old runBench test, add presentBenchmark test**

In `Gemma/GemmaTests/HarnessModelTests.swift`:

a. Delete the entire `test_runBench_writesReportAndSetsPath()` method (it calls the removed `runBench`).

b. Add:
```swift
    func test_presentBenchmark_dummyKind_doesNotOpenSheet() async {
        let m = HarnessModel()  // .dummy
        await m.presentBenchmark()
        XCTAssertFalse(m.showBenchmark)
        XCTAssertTrue(m.statusMessage.contains("Benchmark needs a model"))
    }
```

- [ ] **Step 2: Run — verify the new test fails to compile**

Run: `xcodebuild test ... -only-testing:GemmaTests/HarnessModelTests/test_presentBenchmark_dummyKind_doesNotOpenSheet`
Expected: build failure — `HarnessModel` has no `presentBenchmark` / `showBenchmark`.

- [ ] **Step 3: Add benchmark state + presentBenchmark; remove runBench**

In `Gemma/Gemma/Harness/HarnessModel.swift`:

a. Add observed properties near `showCatalog`:
```swift
    public var showBenchmark: Bool = false
    public private(set) var benchmark = BenchmarkModel()
    public private(set) var benchmarkModelURL: URL?
```

b. Delete the entire `runBench()` method.

c. Add `presentBenchmark()` (e.g. after `runSingle`):
```swift
    public func presentBenchmark() async {
        guard let requiredId = runtimeKind.requiredModelId else {
            statusMessage = "Benchmark needs a model — pick Gemma E2B/E4B."
            return
        }
        guard let descriptor = ModelCatalog.find(requiredId),
              case .installed(let url) = installedStore.status(of: descriptor) else {
            statusMessage = "Benchmark needs the model installed. Open Models to download it."
            return
        }
        // Free our runtime's engine first so the benchmark's own engine isn't a 2nd copy.
        if modelLoaded {
            await runtime.unload()
            modelLoaded = false
            statusMessage = "Runtime: \(runtimeKind.displayName) (unloaded for benchmark)"
        }
        benchmarkModelURL = url
        showBenchmark = true
    }
```

- [ ] **Step 4: Run — verify the suite passes**

Run: `xcodebuild test ... -only-testing:GemmaTests/HarnessModelTests`
Expected: all pass (old runBench test gone, new presentBenchmark test passes).

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/HarnessModelTests.swift
git commit -m "feat(harness): presentBenchmark (resolve model, unload runtime); remove runBench

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `BenchmarkView` sheet + `HarnessView` wiring

**Files:**
- Create: `Gemma/Gemma/Harness/BenchmarkView.swift`
- Modify: `Gemma/Gemma/Harness/HarnessView.swift`

No unit test (SwiftUI); verified by build + smoke.

- [ ] **Step 1: Implement `BenchmarkView`**

Create `Gemma/Gemma/Harness/BenchmarkView.swift`:

```swift
import SwiftUI

struct BenchmarkView: View {
    @Bindable var model: BenchmarkModel
    let modelURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Parameters") {
                    Picker("Backend", selection: $model.config.backend) {
                        Text("GPU").tag(ComputeBackend.gpu)
                        Text("CPU").tag(ComputeBackend.cpu)
                    }
                    Stepper("Prefill tokens: \(model.config.prefillTokens)", value: $model.config.prefillTokens, in: 64...2048, step: 64)
                    Stepper("Decode tokens: \(model.config.decodeTokens)", value: $model.config.decodeTokens, in: 64...2048, step: 64)
                    Stepper("Runs: \(model.config.runCount)", value: $model.config.runCount, in: 1...20)
                }
                Section {
                    Button {
                        if let url = modelURL { Task { await model.run(modelURL: url) } }
                    } label: {
                        if let p = model.progress, model.isRunning {
                            Text("Running… \(p.completed)/\(p.total)")
                        } else {
                            Text("Run benchmark")
                        }
                    }
                    .disabled(model.isRunning || modelURL == nil)
                }
                if let r = model.result {
                    Section("Results (avg of \(r.runs.count) run\(r.runs.count == 1 ? "" : "s"))") {
                        resultRow("First init", String(format: "%.2f s", r.firstInitSeconds))
                        resultRow("Warm init (avg)", String(format: "%.2f s", r.avgWarmInitSeconds))
                        resultRow("TTFT (avg)", String(format: "%.2f s", r.avgTTFTSeconds))
                        resultRow("Prefill (avg)", String(format: "%.1f tok/s", r.avgPrefillTokPerSec))
                        resultRow("Decode (avg)", String(format: "%.1f tok/s", r.avgDecodeTokPerSec))
                    }
                }
                if let err = model.errorMessage {
                    Section { Text("Error: \(err)").font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Benchmark")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.disabled(model.isRunning)
                }
            }
        }
    }

    private func resultRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).monospaced() }
    }
}

#Preview {
    BenchmarkView(model: BenchmarkModel(), modelURL: nil)
}
```

- [ ] **Step 2: Replace the "Run Bench" button + add the sheet in `HarnessView`**

In `Gemma/Gemma/Harness/HarnessView.swift`, in `promptArea`, replace the existing "Run Bench" button:
```swift
                Button("Run Bench") {
                    Task { await model.runBench() }
                }
                .disabled(!model.modelLoaded || model.isGenerating)
```
with:
```swift
                Button("Benchmark") {
                    Task { await model.presentBenchmark() }
                }
                .disabled(model.isGenerating)
```

Add the sheet after the existing `.sheet(...)` modifiers (next to the CatalogView sheet):
```swift
            .sheet(isPresented: $model.showBenchmark) {
                BenchmarkView(model: model.benchmark, modelURL: model.benchmarkModelURL)
            }
```

- [ ] **Step 3: Build — verify it compiles**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild build -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Harness/BenchmarkView.swift Gemma/Gemma/Harness/HarnessView.swift
git commit -m "feat(bench): Benchmark sheet + replace Run Bench button

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Full suite + on-device smoke + tag

**Files:** none.

- [ ] **Step 1: Full simulator suite (minus device-only runtime tests)**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' -skip-testing:GemmaTests/LiteRTLMRuntimeTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: On-device smoke (HUMAN STEP — physical iPhone 16)**

```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild -project Gemma.xcodeproj -scheme Gemma -destination 'platform=iOS,id=00008140-000A6216110A801C' -allowProvisioningUpdates -derivedDataPath /tmp/gemma_dd build 2>&1 | tail -2
APP=$(find /tmp/gemma_dd/Build/Products/Debug-iphoneos -maxdepth 1 -name "Gemma.app" | head -1)
xcrun devicectl device install app --device 00008140-000A6216110A801C "$APP"
```
On the unlocked device: pick Gemma E4B → tap **Benchmark** → in the sheet keep defaults (GPU, 256/256, 5 runs) → **Run benchmark**. Confirm it completes all runs without the app closing and shows non-zero prefill/decode tok/s. Run it 2–3 more times to confirm it stays stable (no OOM, since each run owns its engine).

- [ ] **Step 3: Update the knowledge graph**

Run: `cd /Users/hashdown/Projects/personal_agent && graphify update .`

- [ ] **Step 4: Final commit + tag**

```bash
cd /Users/hashdown/Projects/personal_agent
git commit --allow-empty -m "chore(s1): perf benchmark complete — official benchmark() API, tests green, device smoke clean

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git tag -a s1-perf-benchmark -m "S1: performance benchmark on official benchmark() API (no chat-loop OOM)"
git tag -l
```

---

## Out of scope (Plan 3c / later)
- Comparative combos (CPU vs GPU, MTP on/off) + the S1 runtime report.
- Real-prompt quality eval with text output.
- Persisting benchmark config across launches.

## Risks
| # | Risk | Mitigation |
|---|------|-----------|
| R1 | `benchmark()` on GPU from a background context could SIGSEGV if it shares the runtime's engine. | `presentBenchmark` unloads the runtime first; `benchmark()` owns a separate engine in a temp cacheDir. Task 6 device smoke verifies. |
| R2 | Device build needs `-allowProvisioningUpdates` (increased-memory-limit entitlement). | Task 6 includes the flag. |
| R3 | A very large `decodeTokens` (e.g. 2048) may still pressure memory on the 8 GB device. | Default is 256; the stepper caps at 2048 and a failed run surfaces as `errorMessage`, not a crash. |
```
