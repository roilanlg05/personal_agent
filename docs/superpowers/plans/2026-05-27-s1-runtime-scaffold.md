# S1 Runtime — Plan 1 of 3: Scaffold + Protocol + Dummy Runtime + Bench Framework

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the iOS scaffolding for S1: a SwiftUI harness app, a `ModelRuntime` protocol, a `DummyRuntime` that streams canned tokens, the bench runner, the fixed prompt set, the JSON report writer, and full unit test coverage on everything that isn't UI. End state: the app launches, a "Run Bench" button drives `DummyRuntime` through the prompt set, a JSON report appears in `Documents/`, and all tests pass.

**Architecture:** A protocol-oriented Swift design isolates each runtime behind `ModelRuntime` (async actor-based). `BenchRunner` is runtime-agnostic — it consumes any `ModelRuntime` over a fixed `PromptSet` and emits `BenchReport`. The SwiftUI `HarnessView` lets a human drive single prompts or kick a full bench. `DummyRuntime` satisfies the protocol with deterministic timing so the entire pipeline is testable before any real model lands (Plans 2 and 3).

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Concurrency (actors / async-await), XCTest, Xcode 16+, iPhone 16+ (target device), no third-party dependencies in this plan.

**Position in series:** Plan 1 of 3 for spec `01-s1-runtime.md`. Plans 2 (LiteRT-LM) and 3 (llama.cpp + mmap + report) are not written yet — they will be written after this plan lands.

---

## File structure produced by this plan

```
Gemma/Gemma/                                    (existing app target source root)
├── GemmaApp.swift                              (modified — points to HarnessView)
├── ContentView.swift                           (deleted)
├── Runtime/
│   ├── ModelRuntime.swift                      (new — protocol + supporting types)
│   ├── DummyRuntime.swift                      (new — fake runtime for testing)
│   └── MemoryReporter.swift                    (new — RSS reader)
├── Bench/
│   ├── PromptSet.swift                         (new — fixed bilingual prompts)
│   ├── BenchReport.swift                       (new — Codable report types)
│   └── BenchRunner.swift                       (new — orchestrator)
└── Harness/
    ├── HarnessView.swift                       (new — main UI)
    └── ImagePickerView.swift                   (new — UIImagePicker wrapper)

Gemma/GemmaTests/                               (new test target)
├── GemmaTests.swift                            (new — sanity test)
├── DummyRuntimeTests.swift                     (new)
├── PromptSetTests.swift                        (new)
├── BenchReportTests.swift                      (new)
└── BenchRunnerTests.swift                      (new)
```

**Responsibility split (one purpose per file):**
- `ModelRuntime.swift`: protocol + value types (no logic).
- `DummyRuntime.swift`: only the fake implementation.
- `MemoryReporter.swift`: only the Mach RSS read; isolated so it can be mocked.
- `PromptSet.swift`: immutable prompt data, no logic beyond accessors.
- `BenchReport.swift`: only Codable types and the JSON file writer.
- `BenchRunner.swift`: only orchestration (runtime + prompt set → report).
- `HarnessView.swift`: UI only; delegates to runtime + runner.
- `ImagePickerView.swift`: thin UIKit→SwiftUI bridge, nothing else.

---

## Task 0: Preflight — verify Xcode and create folders on disk

**Files:**
- Modify: filesystem only (no files yet)

- [ ] **Step 1: Verify Xcode version is 16 or later**

Run:
```bash
xcodebuild -version
```
Expected: Xcode 16.0 or higher. If older, stop and update Xcode. Xcode 16+ is required because we rely on synchronized file system groups so files added on disk are auto-picked-up.

- [ ] **Step 2: Verify the existing project opens and builds**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` near the end.

- [ ] **Step 3: Create the empty source folders**

Run:
```bash
mkdir -p /Users/hashdown/Projects/personal_agent/Gemma/Gemma/Runtime \
         /Users/hashdown/Projects/personal_agent/Gemma/Gemma/Bench \
         /Users/hashdown/Projects/personal_agent/Gemma/Gemma/Harness
ls /Users/hashdown/Projects/personal_agent/Gemma/Gemma/
```
Expected output includes: `Assets.xcassets`, `Bench`, `ContentView.swift`, `GemmaApp.swift`, `Harness`, `Runtime`.

- [ ] **Step 4: Ensure the `Gemma` source group is a synchronized folder reference in Xcode**

In Xcode → open `Gemma.xcodeproj` → in the Project navigator, right-click the `Gemma` group (the inner one containing `GemmaApp.swift`) → **"Convert to Synchronized Group"** (Xcode 16+ menu). If the option is greyed out or absent, the group is already synchronized. Save (`⌘S`) and close the project.

Verify:
```bash
grep -c "PBXFileSystemSynchronizedRootGroup" /Users/hashdown/Projects/personal_agent/Gemma/Gemma.xcodeproj/project.pbxproj
```
Expected: ≥ 1.

- [ ] **Step 5: Commit the empty folder scaffold**

```bash
cd /Users/hashdown/Projects/personal_agent
git init  # if not already a repo
git add -A
git commit -m "chore: scaffold Gemma source folders (Runtime, Bench, Harness)"
```

---

## Task 1: Add a Unit Test target to the Xcode project

**Files:**
- Modify: `Gemma/Gemma.xcodeproj/project.pbxproj` (via Xcode UI — do not hand-edit)
- Create: `Gemma/GemmaTests/GemmaTests.swift`

- [ ] **Step 1: Add the test target via Xcode UI**

In Xcode: **File → New → Target… → Unit Testing Bundle**. Set:
- Product Name: `GemmaTests`
- Target to be Tested: `Gemma`
- Language: Swift
- Bundle Identifier: `lambert-dev-group.GemmaTests`

Click **Finish**. Xcode creates `Gemma/GemmaTests/GemmaTests.swift` automatically. Save the project (`⌘S`).

- [ ] **Step 2: Replace the auto-generated test with a sanity test**

Replace the contents of `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/GemmaTests.swift` with:

```swift
import XCTest
@testable import Gemma

final class GemmaTests: XCTestCase {
    func test_sanity_xcTestRuns() {
        XCTAssertEqual(1 + 1, 2)
    }
}
```

- [ ] **Step 3: Run the test target**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30
```
Expected: `Test Suite 'GemmaTests' passed` and `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add -A
git commit -m "test: add GemmaTests unit test target with sanity test"
```

---

## Task 2: Define `ModelRuntime` protocol + value types

**Files:**
- Create: `Gemma/Gemma/Runtime/ModelRuntime.swift`
- Create: `Gemma/GemmaTests/ModelRuntimeTypesTests.swift`

- [ ] **Step 1: Write failing tests for the value types**

Create `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/ModelRuntimeTypesTests.swift`:

```swift
import XCTest
@testable import Gemma

final class ModelRuntimeTypesTests: XCTestCase {
    func test_runtimeMetrics_tokensPerSecond_computesCorrectly() {
        let m = RuntimeMetrics(
            tokensGenerated: 100,
            elapsedSeconds: 5.0,
            timeToFirstTokenSeconds: 0.3,
            peakResidentMemoryBytes: 0,
            draftAcceptanceRate: nil
        )
        XCTAssertEqual(m.tokensPerSecond, 20.0, accuracy: 0.001)
    }

    func test_runtimeMetrics_tokensPerSecond_returnsZeroOnZeroElapsed() {
        let m = RuntimeMetrics(
            tokensGenerated: 100,
            elapsedSeconds: 0,
            timeToFirstTokenSeconds: 0,
            peakResidentMemoryBytes: 0,
            draftAcceptanceRate: nil
        )
        XCTAssertEqual(m.tokensPerSecond, 0)
    }

    func test_modelLoadOptions_defaultsAreSane() {
        let url = URL(fileURLWithPath: "/tmp/model.bin")
        let opts = ModelLoadOptions(modelPath: url)
        XCTAssertEqual(opts.modelPath, url)
        XCTAssertNil(opts.drafterPath)
        XCTAssertTrue(opts.useMmap)
        XCTAssertEqual(opts.contextLength, 4096)
    }

    func test_generationOptions_defaultsAreSane() {
        let opts = GenerationOptions()
        XCTAssertEqual(opts.maxTokens, 256)
        XCTAssertEqual(opts.temperature, 0.7, accuracy: 0.001)
        XCTAssertEqual(opts.topP, 0.9, accuracy: 0.001)
        XCTAssertFalse(opts.useSpeculativeDecoding)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -10
```
Expected: compile errors referring to `RuntimeMetrics`, `ModelLoadOptions`, `GenerationOptions` not found.

- [ ] **Step 3: Implement the protocol and value types**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Runtime/ModelRuntime.swift`:

```swift
import Foundation
import UIKit

// MARK: - Value types

public struct RuntimeMetrics: Sendable, Codable, Equatable {
    public var tokensGenerated: Int
    public var elapsedSeconds: Double
    public var timeToFirstTokenSeconds: Double
    public var peakResidentMemoryBytes: UInt64
    public var draftAcceptanceRate: Double?

    public init(
        tokensGenerated: Int,
        elapsedSeconds: Double,
        timeToFirstTokenSeconds: Double,
        peakResidentMemoryBytes: UInt64,
        draftAcceptanceRate: Double?
    ) {
        self.tokensGenerated = tokensGenerated
        self.elapsedSeconds = elapsedSeconds
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.draftAcceptanceRate = draftAcceptanceRate
    }

    public var tokensPerSecond: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(tokensGenerated) / elapsedSeconds
    }
}

public struct ModelLoadOptions: Sendable {
    public var modelPath: URL
    public var drafterPath: URL?
    public var useMmap: Bool
    public var contextLength: Int

    public init(
        modelPath: URL,
        drafterPath: URL? = nil,
        useMmap: Bool = true,
        contextLength: Int = 4096
    ) {
        self.modelPath = modelPath
        self.drafterPath = drafterPath
        self.useMmap = useMmap
        self.contextLength = contextLength
    }
}

public struct GenerationOptions: Sendable {
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double
    public var useSpeculativeDecoding: Bool

    public init(
        maxTokens: Int = 256,
        temperature: Double = 0.7,
        topP: Double = 0.9,
        useSpeculativeDecoding: Bool = false
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.useSpeculativeDecoding = useSpeculativeDecoding
    }
}

public struct GenerationResult: Sendable {
    public let text: String
    public let metrics: RuntimeMetrics

    public init(text: String, metrics: RuntimeMetrics) {
        self.text = text
        self.metrics = metrics
    }
}

public enum RuntimeError: Error, Sendable, Equatable {
    case modelNotFound(URL)
    case loadFailed(String)
    case notLoaded
    case generationFailed(String)
}

// MARK: - Protocol

public protocol ModelRuntime: Sendable {
    /// Stable identifier used in reports (e.g. "dummy", "litertlm", "llamacpp").
    var identifier: String { get }

    func isLoaded() async -> Bool
    func load(options: ModelLoadOptions) async throws
    func unload() async

    /// Streams tokens via `onToken` as they are produced; returns the final result on completion.
    func generate(
        prompt: String,
        image: UIImage?,
        options: GenerationOptions,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> GenerationResult

    func currentMetrics() async -> RuntimeMetrics?
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GemmaTests/ModelRuntimeTypesTests 2>&1 | tail -10
```
Expected: 4 tests passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add -A
git commit -m "feat(runtime): add ModelRuntime protocol and value types"
```

---

## Task 3: Implement `MemoryReporter` (Mach RSS reader)

**Files:**
- Create: `Gemma/Gemma/Runtime/MemoryReporter.swift`
- Create: `Gemma/GemmaTests/MemoryReporterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/MemoryReporterTests.swift`:

```swift
import XCTest
@testable import Gemma

final class MemoryReporterTests: XCTestCase {
    func test_currentRSS_returnsNonZero() {
        let rss = MemoryReporter.currentResidentBytes()
        XCTAssertGreaterThan(rss, 0, "Process must report non-zero RSS")
    }

    func test_currentRSS_isReasonable() {
        // A bare iOS test process should be well under 2 GB.
        let rss = MemoryReporter.currentResidentBytes()
        XCTAssertLessThan(rss, UInt64(2) * 1024 * 1024 * 1024)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GemmaTests/MemoryReporterTests 2>&1 | tail -10
```
Expected: compile error — `MemoryReporter` not found.

- [ ] **Step 3: Implement**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Runtime/MemoryReporter.swift`:

```swift
import Foundation
import Darwin

public enum MemoryReporter {
    /// Returns the current process's resident set size in bytes, or 0 on failure.
    public static func currentResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPtr,
                    &count
                )
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GemmaTests/MemoryReporterTests 2>&1 | tail -10
```
Expected: 2 tests passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add -A
git commit -m "feat(runtime): add MemoryReporter for current RSS"
```

---

## Task 4: Implement `DummyRuntime`

**Files:**
- Create: `Gemma/Gemma/Runtime/DummyRuntime.swift`
- Create: `Gemma/GemmaTests/DummyRuntimeTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/DummyRuntimeTests.swift`:

```swift
import XCTest
@testable import Gemma

final class DummyRuntimeTests: XCTestCase {
    func test_isLoaded_falseInitially() async {
        let r = DummyRuntime()
        let loaded = await r.isLoaded()
        XCTAssertFalse(loaded)
    }

    func test_load_setsLoadedToTrue() async throws {
        let r = DummyRuntime()
        try await r.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))
        let loaded = await r.isLoaded()
        XCTAssertTrue(loaded)
    }

    func test_generate_throwsWhenNotLoaded() async {
        let r = DummyRuntime()
        do {
            _ = try await r.generate(
                prompt: "hola",
                image: nil,
                options: GenerationOptions(),
                onToken: { _ in }
            )
            XCTFail("Expected RuntimeError.notLoaded")
        } catch RuntimeError.notLoaded {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_generate_streamsAllTokens() async throws {
        let r = DummyRuntime(
            cannedResponse: "uno dos tres",
            tokensPerSecondTarget: 200.0
        )
        try await r.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))

        let received = Mutex<[String]>([])
        let result = try await r.generate(
            prompt: "hola",
            image: nil,
            options: GenerationOptions(maxTokens: 10),
            onToken: { token in received.write { $0.append(token) } }
        )

        let tokens = received.read { $0 }
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(result.metrics.tokensGenerated, 3)
        XCTAssertGreaterThan(result.metrics.elapsedSeconds, 0)
        XCTAssertGreaterThan(result.metrics.timeToFirstTokenSeconds, 0)
        XCTAssertEqual(result.text, "uno dos tres")
    }

    func test_generate_respectsMaxTokens() async throws {
        let r = DummyRuntime(
            cannedResponse: "a b c d e f",
            tokensPerSecondTarget: 200.0
        )
        try await r.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))

        let received = Mutex<[String]>([])
        let result = try await r.generate(
            prompt: "p",
            image: nil,
            options: GenerationOptions(maxTokens: 3),
            onToken: { token in received.write { $0.append(token) } }
        )
        XCTAssertEqual(received.read { $0.count }, 3)
        XCTAssertEqual(result.metrics.tokensGenerated, 3)
    }

    func test_currentMetrics_isNilBeforeGenerate() async {
        let r = DummyRuntime()
        let m = await r.currentMetrics()
        XCTAssertNil(m)
    }
}

/// Minimal thread-safe box for collecting from a Sendable closure in tests.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ initial: Value) { self.value = initial }
    func write(_ f: (inout Value) -> Void) { lock.lock(); f(&value); lock.unlock() }
    func read<T>(_ f: (Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(value) }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GemmaTests/DummyRuntimeTests 2>&1 | tail -10
```
Expected: compile error — `DummyRuntime` not found.

- [ ] **Step 3: Implement `DummyRuntime`**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Runtime/DummyRuntime.swift`:

```swift
import Foundation
import UIKit

public actor DummyRuntime: ModelRuntime {
    public nonisolated let identifier: String = "dummy"

    private var loaded: Bool = false
    private let cannedResponse: String
    private let tokensPerSecondTarget: Double
    private var lastMetrics: RuntimeMetrics?

    public init(
        cannedResponse: String = "Hola, soy un dummy. This is a bilingual test response.",
        tokensPerSecondTarget: Double = 20.0
    ) {
        self.cannedResponse = cannedResponse
        self.tokensPerSecondTarget = tokensPerSecondTarget
    }

    public func isLoaded() -> Bool { loaded }

    public func load(options: ModelLoadOptions) async throws {
        // Simulate a small load delay so tests exercise the async path.
        try await Task.sleep(nanoseconds: 50_000_000)
        loaded = true
    }

    public func unload() {
        loaded = false
        lastMetrics = nil
    }

    public func generate(
        prompt: String,
        image: UIImage?,
        options: GenerationOptions,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> GenerationResult {
        guard loaded else { throw RuntimeError.notLoaded }

        let tokens = cannedResponse.split(separator: " ").map(String.init)
        let limit = min(tokens.count, max(0, options.maxTokens))
        let intervalNs = UInt64(1_000_000_000 / max(tokensPerSecondTarget, 1))

        let start = Date()
        var firstTokenAt: Date?
        var emitted: [String] = []
        for i in 0..<limit {
            try await Task.sleep(nanoseconds: intervalNs)
            if firstTokenAt == nil { firstTokenAt = Date() }
            let piece = i == 0 ? tokens[i] : " " + tokens[i]
            onToken(piece)
            emitted.append(piece)
        }
        let elapsed = Date().timeIntervalSince(start)
        let ttft = firstTokenAt?.timeIntervalSince(start) ?? 0

        let metrics = RuntimeMetrics(
            tokensGenerated: limit,
            elapsedSeconds: elapsed,
            timeToFirstTokenSeconds: ttft,
            peakResidentMemoryBytes: MemoryReporter.currentResidentBytes(),
            draftAcceptanceRate: nil
        )
        lastMetrics = metrics
        return GenerationResult(text: emitted.joined(), metrics: metrics)
    }

    public func currentMetrics() -> RuntimeMetrics? { lastMetrics }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GemmaTests/DummyRuntimeTests 2>&1 | tail -15
```
Expected: 6 tests passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add -A
git commit -m "feat(runtime): add DummyRuntime with deterministic streaming"
```

---

## Task 5: Define the fixed `PromptSet`

**Files:**
- Create: `Gemma/Gemma/Bench/PromptSet.swift`
- Create: `Gemma/GemmaTests/PromptSetTests.swift`

- [ ] **Step 1: Write failing tests**

Create `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/PromptSetTests.swift`:

```swift
import XCTest
@testable import Gemma

final class PromptSetTests: XCTestCase {
    func test_promptSet_hasExpectedTotalCount() {
        XCTAssertEqual(PromptSet.all.count, 20)
    }

    func test_promptSet_categoryCountsMatchSpec() {
        let by = Dictionary(grouping: PromptSet.all, by: { $0.category })
        XCTAssertEqual(by[.factual]?.count, 8)
        XCTAssertEqual(by[.conversational]?.count, 6)
        XCTAssertEqual(by[.long]?.count, 4)
        XCTAssertEqual(by[.image]?.count, 2)
    }

    func test_promptSet_languageCounts_balanced() {
        let by = Dictionary(grouping: PromptSet.all, by: { $0.language })
        // 4 ES + 4 EN factual, 3+3 conversational, 2+2 long, 1+1 image  → 10 each
        XCTAssertEqual(by[.es]?.count, 10)
        XCTAssertEqual(by[.en]?.count, 10)
    }

    func test_promptSet_idsAreUnique() {
        let ids = PromptSet.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func test_promptSet_isDeterministic() {
        let a = PromptSet.all.map(\.id)
        let b = PromptSet.all.map(\.id)
        XCTAssertEqual(a, b)
    }

    func test_imagePrompts_haveImageNames() {
        let imgs = PromptSet.all.filter { $0.category == .image }
        for p in imgs {
            XCTAssertNotNil(p.imageAssetName)
            XCTAssertFalse(p.imageAssetName!.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GemmaTests/PromptSetTests 2>&1 | tail -10
```
Expected: compile error — `PromptSet` not found.

- [ ] **Step 3: Implement the `PromptSet`**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Bench/PromptSet.swift`:

```swift
import Foundation

public enum PromptCategory: String, Sendable, Codable, Hashable {
    case factual
    case conversational
    case long
    case image
}

public enum PromptLanguage: String, Sendable, Codable, Hashable {
    case es
    case en
}

public struct BenchPrompt: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let category: PromptCategory
    public let language: PromptLanguage
    public let text: String
    /// For .image prompts: the name of an image bundled in Assets.xcassets (added later by image task).
    public let imageAssetName: String?

    public init(
        id: String,
        category: PromptCategory,
        language: PromptLanguage,
        text: String,
        imageAssetName: String? = nil
    ) {
        self.id = id
        self.category = category
        self.language = language
        self.text = text
        self.imageAssetName = imageAssetName
    }
}

public enum PromptSet {
    /// Fixed set of 20 prompts used by every bench run. DO NOT mutate during S1.
    /// Distribution: 8 factual (4 ES + 4 EN), 6 conversational (3 ES + 3 EN), 4 long (2 ES + 2 EN), 2 image (1 ES + 1 EN).
    public static let all: [BenchPrompt] = [
        // Factual ES
        .init(id: "fact-es-1", category: .factual, language: .es,
              text: "¿Cuál es la capital de Australia?"),
        .init(id: "fact-es-2", category: .factual, language: .es,
              text: "¿En qué año cayó el Muro de Berlín?"),
        .init(id: "fact-es-3", category: .factual, language: .es,
              text: "Nombra tres planetas del sistema solar."),
        .init(id: "fact-es-4", category: .factual, language: .es,
              text: "¿Quién escribió Cien años de soledad?"),

        // Factual EN
        .init(id: "fact-en-1", category: .factual, language: .en,
              text: "What is the boiling point of water at sea level in Celsius?"),
        .init(id: "fact-en-2", category: .factual, language: .en,
              text: "Who painted the Mona Lisa?"),
        .init(id: "fact-en-3", category: .factual, language: .en,
              text: "Name three programming languages used for iOS development."),
        .init(id: "fact-en-4", category: .factual, language: .en,
              text: "What does HTTP stand for?"),

        // Conversational ES
        .init(id: "conv-es-1", category: .conversational, language: .es,
              text: "Hola, ¿cómo estás hoy?"),
        .init(id: "conv-es-2", category: .conversational, language: .es,
              text: "Tengo hambre, ¿qué me recomiendas para cenar?"),
        .init(id: "conv-es-3", category: .conversational, language: .es,
              text: "Cuéntame un chiste corto."),

        // Conversational EN
        .init(id: "conv-en-1", category: .conversational, language: .en,
              text: "Hi, can you help me plan a weekend trip?"),
        .init(id: "conv-en-2", category: .conversational, language: .en,
              text: "I am tired. Give me a quick tip to relax."),
        .init(id: "conv-en-3", category: .conversational, language: .en,
              text: "Tell me a fun fact about octopuses."),

        // Long ES (500-1000 tokens context + question)
        .init(id: "long-es-1", category: .long, language: .es,
              text: String(repeating:
                "La inteligencia artificial generativa ha transformado múltiples industrias en los últimos años. "
              , count: 25) + "Resume el texto anterior en tres puntos."),
        .init(id: "long-es-2", category: .long, language: .es,
              text: String(repeating:
                "El cambio climático afecta a los ecosistemas marinos de formas cada vez más visibles. "
              , count: 25) + "¿Cuál es la idea principal del texto?"),

        // Long EN
        .init(id: "long-en-1", category: .long, language: .en,
              text: String(repeating:
                "Distributed systems must balance consistency, availability, and partition tolerance. "
              , count: 25) + "Summarize the trade-off in two sentences."),
        .init(id: "long-en-2", category: .long, language: .en,
              text: String(repeating:
                "On-device machine learning has matured rapidly thanks to hardware acceleration. "
              , count: 25) + "What is the main argument of the passage?"),

        // Image (1 ES + 1 EN); image assets are added in Task 9.
        .init(id: "img-es-1", category: .image, language: .es,
              text: "¿Qué hay en esta imagen?", imageAssetName: "bench-image-1"),
        .init(id: "img-en-1", category: .image, language: .en,
              text: "What do you see in this image?", imageAssetName: "bench-image-1"),
    ]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GemmaTests/PromptSetTests 2>&1 | tail -15
```
Expected: 6 tests passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add -A
git commit -m "feat(bench): add fixed bilingual PromptSet (20 prompts)"
```

---

## Task 6: Define `BenchReport` (Codable + file writer)

**Files:**
- Create: `Gemma/Gemma/Bench/BenchReport.swift`
- Create: `Gemma/GemmaTests/BenchReportTests.swift`

- [ ] **Step 1: Write failing tests**

Create `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/BenchReportTests.swift`:

```swift
import XCTest
@testable import Gemma

final class BenchReportTests: XCTestCase {
    private func sampleReport() -> BenchReport {
        BenchReport(
            runtimeIdentifier: "dummy",
            modelDescription: "n/a",
            useSpeculativeDecoding: false,
            useMmap: true,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_010),
            results: [
                .init(
                    promptId: "fact-es-1",
                    outputText: "Canberra.",
                    metrics: RuntimeMetrics(
                        tokensGenerated: 3,
                        elapsedSeconds: 0.5,
                        timeToFirstTokenSeconds: 0.1,
                        peakResidentMemoryBytes: 123,
                        draftAcceptanceRate: nil
                    )
                )
            ]
        )
    }

    func test_benchReport_codable_roundTrip() throws {
        let original = sampleReport()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BenchReport.self, from: data)
        XCTAssertEqual(decoded.runtimeIdentifier, original.runtimeIdentifier)
        XCTAssertEqual(decoded.results.count, 1)
        XCTAssertEqual(decoded.results[0].promptId, "fact-es-1")
        XCTAssertEqual(decoded.results[0].metrics.tokensGenerated, 3)
    }

    func test_benchReport_writeToDocuments_createsFile() throws {
        let report = sampleReport()
        let url = try report.writeToDocuments(filename: "test-report.json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(BenchReport.self, from: data)
        XCTAssertEqual(decoded.runtimeIdentifier, "dummy")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GemmaTests/BenchReportTests 2>&1 | tail -10
```
Expected: compile error — `BenchReport` not found.

- [ ] **Step 3: Implement `BenchReport`**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Bench/BenchReport.swift`:

```swift
import Foundation

public struct BenchPromptResult: Sendable, Codable, Equatable {
    public let promptId: String
    public let outputText: String
    public let metrics: RuntimeMetrics

    public init(promptId: String, outputText: String, metrics: RuntimeMetrics) {
        self.promptId = promptId
        self.outputText = outputText
        self.metrics = metrics
    }
}

public struct BenchReport: Sendable, Codable, Equatable {
    public let runtimeIdentifier: String
    public let modelDescription: String
    public let useSpeculativeDecoding: Bool
    public let useMmap: Bool
    public let startedAt: Date
    public let completedAt: Date
    public let results: [BenchPromptResult]

    public init(
        runtimeIdentifier: String,
        modelDescription: String,
        useSpeculativeDecoding: Bool,
        useMmap: Bool,
        startedAt: Date,
        completedAt: Date,
        results: [BenchPromptResult]
    ) {
        self.runtimeIdentifier = runtimeIdentifier
        self.modelDescription = modelDescription
        self.useSpeculativeDecoding = useSpeculativeDecoding
        self.useMmap = useMmap
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.results = results
    }

    /// Writes JSON to `Documents/<filename>` and returns the file URL.
    @discardableResult
    public func writeToDocuments(filename: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)

        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = docs.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}
```

The `JSONEncoder` here uses `.iso8601` for dates; `JSONDecoder` in the test uses the default (`.deferredToDate`). To make the round-trip test pass, update the decoder in the test:

Modify `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/BenchReportTests.swift` — replace the two `JSONDecoder()` instances with:

```swift
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
```

So that the round-trip test reads:

```swift
func test_benchReport_codable_roundTrip() throws {
    let original = sampleReport()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(original)
    let decoded = try decoder.decode(BenchReport.self, from: data)
    XCTAssertEqual(decoded.runtimeIdentifier, original.runtimeIdentifier)
    XCTAssertEqual(decoded.results.count, 1)
    XCTAssertEqual(decoded.results[0].promptId, "fact-es-1")
    XCTAssertEqual(decoded.results[0].metrics.tokensGenerated, 3)
}
```

And in `test_benchReport_writeToDocuments_createsFile`:

```swift
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let decoded = try decoder.decode(BenchReport.self, from: data)
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GemmaTests/BenchReportTests 2>&1 | tail -10
```
Expected: 2 tests passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add -A
git commit -m "feat(bench): add BenchReport Codable + writeToDocuments"
```

---

## Task 7: Implement `BenchRunner`

**Files:**
- Create: `Gemma/Gemma/Bench/BenchRunner.swift`
- Create: `Gemma/GemmaTests/BenchRunnerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/BenchRunnerTests.swift`:

```swift
import XCTest
@testable import Gemma

final class BenchRunnerTests: XCTestCase {
    func test_run_executesAllNonImagePromptsAgainstRuntime() async throws {
        let runtime = DummyRuntime(
            cannedResponse: "ok ok ok",
            tokensPerSecondTarget: 200.0
        )
        try await runtime.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))

        let runner = BenchRunner()
        let report = try await runner.run(
            runtime: runtime,
            modelDescription: "dummy",
            useSpeculativeDecoding: false,
            useMmap: true,
            prompts: PromptSet.all.filter { $0.category != .image }
        )
        // 8 + 6 + 4 = 18 non-image prompts
        XCTAssertEqual(report.results.count, 18)
        XCTAssertEqual(report.runtimeIdentifier, "dummy")
        XCTAssertFalse(report.useSpeculativeDecoding)
        XCTAssertTrue(report.useMmap)
        for r in report.results {
            XCTAssertEqual(r.metrics.tokensGenerated, 3)
            XCTAssertFalse(r.outputText.isEmpty)
        }
    }

    func test_run_propagatesRuntimeError() async {
        let runtime = DummyRuntime()  // never loaded
        let runner = BenchRunner()
        do {
            _ = try await runner.run(
                runtime: runtime,
                modelDescription: "dummy",
                useSpeculativeDecoding: false,
                useMmap: true,
                prompts: [PromptSet.all[0]]
            )
            XCTFail("Expected error")
        } catch RuntimeError.notLoaded {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_run_completedAtIsAfterStartedAt() async throws {
        let runtime = DummyRuntime(cannedResponse: "a", tokensPerSecondTarget: 200)
        try await runtime.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))
        let runner = BenchRunner()
        let report = try await runner.run(
            runtime: runtime,
            modelDescription: "dummy",
            useSpeculativeDecoding: false,
            useMmap: true,
            prompts: [PromptSet.all[0]]
        )
        XCTAssertGreaterThanOrEqual(report.completedAt, report.startedAt)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GemmaTests/BenchRunnerTests 2>&1 | tail -10
```
Expected: compile error — `BenchRunner` not found.

- [ ] **Step 3: Implement `BenchRunner`**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Bench/BenchRunner.swift`:

```swift
import Foundation
import UIKit

public struct BenchRunner: Sendable {
    public init() {}

    /// Runs every prompt against the runtime sequentially and assembles a report.
    /// Image prompts are passed with `image == nil` here — Plan 2/3 will wire actual images.
    public func run(
        runtime: ModelRuntime,
        modelDescription: String,
        useSpeculativeDecoding: Bool,
        useMmap: Bool,
        prompts: [BenchPrompt],
        generationOptions: GenerationOptions = GenerationOptions(maxTokens: 64)
    ) async throws -> BenchReport {
        let started = Date()
        var results: [BenchPromptResult] = []
        results.reserveCapacity(prompts.count)

        for prompt in prompts {
            let collector = TokenCollector()
            let result = try await runtime.generate(
                prompt: prompt.text,
                image: nil,  // Plan 2/3 attaches images via asset name lookup
                options: generationOptions,
                onToken: { token in collector.append(token) }
            )
            results.append(BenchPromptResult(
                promptId: prompt.id,
                outputText: result.text.isEmpty ? collector.joined() : result.text,
                metrics: result.metrics
            ))
        }

        return BenchReport(
            runtimeIdentifier: runtime.identifier,
            modelDescription: modelDescription,
            useSpeculativeDecoding: useSpeculativeDecoding,
            useMmap: useMmap,
            startedAt: started,
            completedAt: Date(),
            results: results
        )
    }
}

/// Thread-safe accumulator used inside the @Sendable token closure.
final class TokenCollector: @unchecked Sendable {
    private var parts: [String] = []
    private let lock = NSLock()

    func append(_ s: String) {
        lock.lock(); parts.append(s); lock.unlock()
    }
    func joined() -> String {
        lock.lock(); defer { lock.unlock() }
        return parts.joined()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GemmaTests/BenchRunnerTests 2>&1 | tail -10
```
Expected: 3 tests passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add -A
git commit -m "feat(bench): add BenchRunner orchestrator"
```

---

## Task 8: Implement `ImagePickerView` (UIKit bridge)

**Files:**
- Create: `Gemma/Gemma/Harness/ImagePickerView.swift`

> No unit tests in this task — `UIImagePickerController` cannot be exercised in XCTest reliably. Validated by manual smoke (Task 11).

- [ ] **Step 1: Implement**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Harness/ImagePickerView.swift`:

```swift
import SwiftUI
import UIKit

struct ImagePickerView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .photoLibrary
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePickerView
        init(_ parent: ImagePickerView) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild build -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add -A
git commit -m "feat(harness): add ImagePickerView SwiftUI bridge"
```

---

## Task 9: Implement `HarnessView` (main UI)

**Files:**
- Create: `Gemma/Gemma/Harness/HarnessView.swift`

> No unit tests for SwiftUI views in this plan. Validated by manual smoke (Task 11).

- [ ] **Step 1: Implement**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Harness/HarnessView.swift`:

```swift
import SwiftUI
import UIKit

@MainActor
struct HarnessView: View {
    @State private var prompt: String = "Hola, ¿cómo estás?"
    @State private var streamedOutput: String = ""
    @State private var isGenerating: Bool = false
    @State private var isLoadingModel: Bool = false
    @State private var modelLoaded: Bool = false
    @State private var lastMetrics: RuntimeMetrics?
    @State private var benchReportPath: String?
    @State private var pickedImage: UIImage?
    @State private var showImagePicker: Bool = false
    @State private var statusMessage: String = "Runtime: dummy (not loaded)"

    private let runtime: ModelRuntime = DummyRuntime()
    private let runner = BenchRunner()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                statusBar
                Divider()
                promptArea
                Divider()
                outputArea
                Divider()
                metricsBar
                if let path = benchReportPath {
                    Text("Bench report: \(path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .padding()
            .navigationTitle("Gemma Harness")
            .sheet(isPresented: $showImagePicker) {
                ImagePickerView(image: $pickedImage)
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(modelLoaded ? "Unload" : "Load") {
                Task { await toggleLoad() }
            }
            .disabled(isLoadingModel || isGenerating)
        }
    }

    private var promptArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt").font(.headline)
            TextEditor(text: $prompt).frame(minHeight: 80).border(.quaternary)
            HStack {
                Button(pickedImage == nil ? "Attach image" : "Replace image") {
                    showImagePicker = true
                }
                if let img = pickedImage {
                    Image(uiImage: img).resizable().scaledToFit().frame(height: 32)
                    Button("Clear") { pickedImage = nil }
                }
                Spacer()
                Button("Generate") {
                    Task { await runSingle() }
                }
                .disabled(!modelLoaded || isGenerating)

                Button("Run Bench") {
                    Task { await runBench() }
                }
                .disabled(!modelLoaded || isGenerating)
            }
        }
    }

    private var outputArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output").font(.headline)
            ScrollView {
                Text(streamedOutput.isEmpty ? "—" : streamedOutput)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120)
            .background(Color.secondary.opacity(0.08))
        }
    }

    private var metricsBar: some View {
        HStack(spacing: 16) {
            if let m = lastMetrics {
                Text(String(format: "tok/s: %.1f", m.tokensPerSecond))
                Text(String(format: "TTFT: %.2fs", m.timeToFirstTokenSeconds))
                Text("RAM: \(byteString(m.peakResidentMemoryBytes))")
            } else {
                Text("No metrics yet.").foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospaced())
    }

    private func byteString(_ b: UInt64) -> String {
        let mb = Double(b) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }

    // MARK: - Actions

    private func toggleLoad() async {
        if modelLoaded {
            await runtime.unload()
            modelLoaded = false
            statusMessage = "Runtime: dummy (unloaded)"
            return
        }
        isLoadingModel = true
        statusMessage = "Loading…"
        do {
            try await runtime.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))
            modelLoaded = true
            statusMessage = "Runtime: dummy (loaded)"
        } catch {
            statusMessage = "Load failed: \(error)"
        }
        isLoadingModel = false
    }

    private func runSingle() async {
        isGenerating = true
        streamedOutput = ""
        defer { isGenerating = false }
        do {
            let result = try await runtime.generate(
                prompt: prompt,
                image: pickedImage,
                options: GenerationOptions(maxTokens: 128),
                onToken: { piece in
                    Task { @MainActor in streamedOutput += piece }
                }
            )
            lastMetrics = result.metrics
        } catch {
            streamedOutput += "\n[error: \(error)]"
        }
    }

    private func runBench() async {
        isGenerating = true
        streamedOutput = "Running bench…"
        defer { isGenerating = false }
        do {
            let report = try await runner.run(
                runtime: runtime,
                modelDescription: "DummyRuntime (Plan 1 scaffold)",
                useSpeculativeDecoding: false,
                useMmap: true,
                prompts: PromptSet.all.filter { $0.category != .image }
            )
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = try report.writeToDocuments(filename: "bench-\(stamp).json")
            benchReportPath = url.path
            streamedOutput = "Bench done: \(report.results.count) prompts. Report at \(url.lastPathComponent)."
            lastMetrics = report.results.last?.metrics
        } catch {
            streamedOutput = "Bench failed: \(error)"
        }
    }
}

#Preview {
    HarnessView()
}
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild build -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add -A
git commit -m "feat(harness): add HarnessView with load/generate/bench buttons"
```

---

## Task 10: Wire `HarnessView` into `GemmaApp` and delete `ContentView`

**Files:**
- Modify: `Gemma/Gemma/GemmaApp.swift`
- Delete: `Gemma/Gemma/ContentView.swift`

- [ ] **Step 1: Replace `GemmaApp.swift`**

Replace the entire contents of `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/GemmaApp.swift` with:

```swift
import SwiftUI

@main
struct GemmaApp: App {
    var body: some Scene {
        WindowGroup {
            HarnessView()
        }
    }
}
```

- [ ] **Step 2: Delete `ContentView.swift`**

Run:
```bash
rm /Users/hashdown/Projects/personal_agent/Gemma/Gemma/ContentView.swift
```

- [ ] **Step 3: Verify build**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild build -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add -A
git commit -m "refactor(app): swap ContentView for HarnessView entry point"
```

---

## Task 11: Run all tests + manual smoke on simulator

**Files:** none

- [ ] **Step 1: Run the full test suite**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30
```
Expected: all tests pass (`** TEST SUCCEEDED **`). Approximate counts:
- GemmaTests (sanity): 1
- ModelRuntimeTypesTests: 4
- MemoryReporterTests: 2
- DummyRuntimeTests: 6
- PromptSetTests: 6
- BenchReportTests: 2
- BenchRunnerTests: 3
- Total: 24 tests.

- [ ] **Step 2: Launch in simulator and smoke-test the harness**

In Xcode: select **iPhone 16** simulator → Run (⌘R). When the app opens:
1. Tap **Load**. Status should switch to "Runtime: dummy (loaded)" within ~0.1 s.
2. Type a prompt (or leave default). Tap **Generate**. Tokens should stream into the Output area; metrics row should populate (tok/s, TTFT, RAM).
3. Tap **Run Bench**. Output should change to "Bench done: 18 prompts. Report at bench-YYYY-MM-DDT…json".
4. Tap **Unload**. Status should switch to "Runtime: dummy (unloaded)" and Generate/Run Bench should disable.

Expected: every step above behaves as described. No crashes.

- [ ] **Step 3: Confirm the bench report file exists**

In Xcode's bottom bar, open the simulator's app container (Devices and Simulators → simulator → Gemma → Show Container) or via Bash:
```bash
xcrun simctl get_app_container booted lambert-dev-group.Gemma data 2>/dev/null
```
Inside that path, `Documents/bench-*.json` should exist and contain a valid JSON report with 18 results.

- [ ] **Step 4: Final commit and tag**

```bash
cd /Users/hashdown/Projects/personal_agent
git add -A
git commit --allow-empty -m "chore(s1): scaffold plan 1 complete — tests green, smoke clean"
git tag s1-plan1-scaffold
```

---

## Out of scope for this plan (handled by Plans 2 and 3)

- Real LiteRT-LM integration and the official MTP drafter (Plan 2).
- Real llama.cpp integration with GGUF uncensored variants (Plan 3).
- Image attachment plumbing through to a real multimodal runtime (Plan 2/3).
- mmap vs no-mmap sub-evaluation (Plan 3 — meaningful only with a real runtime).
- Xcode Instruments Energy Log measurement (Plan 3 — meaningful only with sustained real inference).
- Model file download/management flow (deferred: human places model files manually in Documents for now).
- Asset image for `bench-image-1` referenced by image prompts: added in Plan 2 alongside the first multimodal runtime that can actually use it.

---

## Self-review summary

- **Spec coverage (from `01-s1-runtime.md`):**
  - §6 metrics & prompt set → Tasks 4, 5 (PromptSet), 6, 7 (BenchReport, BenchRunner). Tokens/s, TTFT, RAM peak captured in `RuntimeMetrics`. Drafter acceptance rate field present but null until Plans 2/3.
  - §8 file structure → Tasks 2–10 produce exactly the structure declared in the spec.
  - §9 reporter file → JSON report writer in Task 6 lays groundwork; the markdown report comes in Plan 3.
  - §10 risks → out-of-scope here; addressed in Plan 2/3 setup.
  - §11 done-criteria — Plan 1 fulfills bullet "harness Swift carga el ganador y hace streaming end-to-end" with `DummyRuntime`; the rest of §11 is for Plans 2/3.

- **Placeholder scan:** No "TBD", "add error handling later", or vague references; every code step has full code.
- **Type consistency:** `ModelRuntime` (protocol), `RuntimeMetrics`, `ModelLoadOptions`, `GenerationOptions`, `GenerationResult`, `RuntimeError`, `BenchPrompt`, `PromptCategory`, `PromptLanguage`, `BenchPromptResult`, `BenchReport`, `BenchRunner`, `DummyRuntime`, `MemoryReporter`, `HarnessView`, `ImagePickerView` — checked consistent across all tasks.
