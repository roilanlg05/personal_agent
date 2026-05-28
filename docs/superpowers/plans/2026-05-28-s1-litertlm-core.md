# S1 Runtime — Plan 3a of 4: LiteRT-LM Core Integration (text + image)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Make `RuntimeFactory.make(.litertlmE4B/.litertlmE2B)` return a **real** `LiteRTLMRuntime` actor that loads a `.litertlm` from `Documents/Models/`, generates text with streaming, and accepts an image via `Content.imageFile(_:)`. Conditional XCTSkip tests run only when the model file is present locally. After this plan: opening the Models sheet, downloading E4B (or sideloading it), then tapping Load + Generate produces real Gemma 4 text on the simulator (CPU path).

**Architecture:** A new actor `LiteRTLMRuntime` wraps `Engine` + `Conversation` from the official `LiteRTLM` SPM package. `ModelLoadOptions` gains three Gemma-4-specific fields (`systemPrompt`, `enableThinking`, `useSpeculativeDecoding`). `GenerationOptions` gains `topK` and updates defaults to the catalog recipe (temp=1.0, topP=0.95, topK=64, maxTokens=4000). `RuntimeFactory.make` switches to the real runtime for the LiteRT-LM kinds, looking up the on-disk model path via `InstalledModels`.

**Tech Stack:** Swift 5.9+, SwiftUI, LiteRTLM SPM package ≥ 0.12.0, XCTest, Xcode 26.2+, iOS 17+ target, iPhone 17 simulator (CPU path) + iPhone 16 physical (later for GPU/Metal).

**Position in series:** Plan 3a of 4. Previous: tag `s1-plan2-model-infra`. Next: Plan 3b (Settings UI + bench + report). Then Plan 4 (llama.cpp + mmap + final S1 report).

---

## File structure produced by this plan

```
Gemma/Gemma/
├── Runtime/
│   ├── ModelRuntime.swift          (modified — GenerationOptions adds topK, defaults bump; ModelLoadOptions adds systemPrompt/enableThinking/useSpeculativeDecoding)
│   ├── RuntimeFactory.swift        (modified — make() returns LiteRTLMRuntime for the two LiteRT-LM kinds via InstalledModels lookup)
│   ├── LiteRTLMRuntime.swift       (NEW — real runtime actor wrapping LiteRTLM.Engine)
│   └── ImageTempFile.swift         (NEW — helper to write UIImage → temp JPEG path for Content.imageFile)
└── Harness/
    └── HarnessModel.swift          (modified — toggleLoad uses RuntimeFactory with installed model path; surfaces missing-model error gracefully)

Gemma/GemmaTests/
├── ModelRuntimeTypesTests.swift    (modified — adapt for new GenerationOptions defaults)
├── LiteRTLMRuntimeTests.swift      (NEW — conditional with XCTSkipIf(modelMissing))
└── ImageTempFileTests.swift        (NEW)
```

---

## Task 0: Preflight + add LiteRT-LM via Xcode UI (HUMAN STEP)

**Files:** none

- [ ] **Step 1: Confirm baseline**

```bash
cd /Users/hashdown/Projects/personal_agent
git describe --tags --abbrev=0   # should be s1-plan2-model-infra
git status                       # clean
```

- [ ] **Step 2: Add LiteRT-LM SPM package via Xcode UI** *(this step requires the human — subagents cannot drive Xcode UI)*

In Xcode:
1. **File → Add Package Dependencies…**
2. Paste URL: `https://github.com/google-ai-edge/LiteRT-LM`
3. **Dependency Rule:** "Up to Next Major Version" from `0.12.0`
4. Click **Add Package**
5. When prompted with library selection, add **`LiteRTLM`** to the **`Gemma`** app target (NOT to `GemmaTests`)
6. Save (`⌘S`); close Xcode (so subsequent `xcodebuild` doesn't fight the project lock).

Verify the package landed:
```bash
grep -c "LiteRT-LM\|LiteRTLM" /Users/hashdown/Projects/personal_agent/Gemma/Gemma.xcodeproj/project.pbxproj
```
Expected: ≥ 1.

- [ ] **Step 3: Add `-all_load` linker flag for the Gemma target** *(human Xcode step)*

In Xcode: select the project → **Gemma** target → **Build Settings** → search "Other Linker Flags" → add `-all_load` for both Debug and Release. (Required because LiteRT-LM's static libraries register CPU/GPU backends via C++ static initializers.)

Verify:
```bash
grep -A1 "OTHER_LDFLAGS" /Users/hashdown/Projects/personal_agent/Gemma/Gemma.xcodeproj/project.pbxproj | head -10
```
Expected: includes `-all_load`.

- [ ] **Step 4: Build with the new dependency**

```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild build -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. (LiteRT-LM resolves and links cleanly even before any `import LiteRTLM`.)

- [ ] **Step 5: Commit project file change**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma.xcodeproj/project.pbxproj Gemma/Gemma.xcodeproj/project.xcworkspace
git commit -m "build(deps): add LiteRT-LM SPM dependency + -all_load linker flag

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 1: Update `ModelRuntime.swift` value types (GenerationOptions + ModelLoadOptions)

**Files:**
- Modify: `Gemma/Gemma/Runtime/ModelRuntime.swift`
- Modify: `Gemma/GemmaTests/ModelRuntimeTypesTests.swift`

- [ ] **Step 1: Update the existing tests for new defaults**

Replace `test_generationOptions_defaultsAreSane` in `ModelRuntimeTypesTests.swift` with:

```swift
    func test_generationOptions_defaultsAreSane() {
        let opts = GenerationOptions()
        XCTAssertEqual(opts.maxTokens, 4000)
        XCTAssertEqual(opts.temperature, 1.0, accuracy: 0.001)
        XCTAssertEqual(opts.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(opts.topK, 64)
        XCTAssertFalse(opts.useSpeculativeDecoding)  // legacy field; load-time MTP supersedes
    }

    func test_modelLoadOptions_defaultsAreSane() {
        let url = URL(fileURLWithPath: "/tmp/model.bin")
        let opts = ModelLoadOptions(modelPath: url)
        XCTAssertEqual(opts.modelPath, url)
        XCTAssertTrue(opts.useMmap)
        XCTAssertEqual(opts.contextLength, 32_000)
        XCTAssertFalse(opts.useSpeculativeDecoding)
        XCTAssertFalse(opts.enableThinking)
        XCTAssertNil(opts.systemPrompt)
    }
```

- [ ] **Step 2: Update `ModelRuntime.swift`**

In `Gemma/Gemma/Runtime/ModelRuntime.swift`:

a. Replace `GenerationOptions` with:

```swift
public struct GenerationOptions: Sendable {
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    /// Legacy per-call MTP request. Plan 3a moves the authoritative MTP toggle to ModelLoadOptions.
    /// Kept for backward source compatibility; runtimes may ignore it.
    public var useSpeculativeDecoding: Bool

    public init(
        maxTokens: Int = 4000,
        temperature: Double = 1.0,
        topP: Double = 0.95,
        topK: Int = 64,
        useSpeculativeDecoding: Bool = false
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.useSpeculativeDecoding = useSpeculativeDecoding
    }
}
```

b. Replace `ModelLoadOptions` with:

```swift
public struct ModelLoadOptions: Sendable {
    public var modelPath: URL
    public var drafterPath: URL?
    public var useMmap: Bool
    public var contextLength: Int
    public var systemPrompt: String?
    public var enableThinking: Bool
    public var useSpeculativeDecoding: Bool

    public init(
        modelPath: URL,
        drafterPath: URL? = nil,
        useMmap: Bool = true,
        contextLength: Int = 32_000,
        systemPrompt: String? = nil,
        enableThinking: Bool = false,
        useSpeculativeDecoding: Bool = false
    ) {
        self.modelPath = modelPath
        self.drafterPath = drafterPath
        self.useMmap = useMmap
        self.contextLength = contextLength
        self.systemPrompt = systemPrompt
        self.enableThinking = enableThinking
        self.useSpeculativeDecoding = useSpeculativeDecoding
    }
}
```

- [ ] **Step 3: Run tests**

```bash
xcodebuild test ... -only-testing:GemmaTests/ModelRuntimeTypesTests
```
Expected: 4 tests pass.

Some of the existing 62-test full suite may break because callers of `GenerationOptions(maxTokens: 64)` etc. still compile, but tests that asserted the old 256 default will need updates. Specifically `BenchRunner` test that builds `GenerationOptions(maxTokens: 64)` keeps working — explicit init unchanged.

Run the full suite:
```bash
xcodebuild test ... 2>&1 | tail -10
```
Expected: all pass. If any fail, fix the assertion to the new defaults.

- [ ] **Step 4: Commit**

```bash
git add Gemma/Gemma/Runtime/ModelRuntime.swift Gemma/GemmaTests/ModelRuntimeTypesTests.swift
git commit -m "feat(runtime): align GenerationOptions/ModelLoadOptions with Gemma 4 catalog

- topK added; defaults updated (temp=1.0, topP=0.95, topK=64, maxTokens=4000)
- ModelLoadOptions adds systemPrompt, enableThinking, useSpeculativeDecoding
- contextLength default raised to 32_000

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Implement `ImageTempFile` helper

**Files:**
- Create: `Gemma/Gemma/Runtime/ImageTempFile.swift`
- Create: `Gemma/GemmaTests/ImageTempFileTests.swift`

LiteRT-LM's multimodal API takes a file path (`Content.imageFile(_:)`), not a UIImage buffer. This helper writes a UIImage to a temp JPEG and returns the URL.

- [ ] **Step 1: Failing tests**

Create `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/ImageTempFileTests.swift`:

```swift
import XCTest
import UIKit
@testable import Gemma

final class ImageTempFileTests: XCTestCase {
    func test_write_producesReadableJPEG() throws {
        let img = UIImage(named: "bench-image-1")!
        let url = try ImageTempFile.writeJPEG(img)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "jpg")
        // file is a valid JPEG: starts with FFD8
        let head = try FileHandle(forReadingFrom: url).read(upToCount: 2)!
        XCTAssertEqual(head[0], 0xFF)
        XCTAssertEqual(head[1], 0xD8)
    }

    func test_write_nilDataThrows() {
        // Build a UIImage with no underlying data — using a 0x0 size produces nil jpegData.
        let blank = UIGraphicsImageRenderer(size: .zero).image { _ in }
        XCTAssertThrowsError(try ImageTempFile.writeJPEG(blank))
    }
}
```

- [ ] **Step 2: Implement**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Runtime/ImageTempFile.swift`:

```swift
import Foundation
import UIKit

public enum ImageTempFile {
    public enum WriteError: Error, Equatable {
        case encodingFailed
    }

    /// Writes a UIImage to a unique temp .jpg path and returns the URL. Caller deletes when done.
    public static func writeJPEG(_ image: UIImage, quality: CGFloat = 0.9) throws -> URL {
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw WriteError.encodingFailed
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gemma-img-\(UUID().uuidString).jpg")
        try data.write(to: url, options: .atomic)
        return url
    }
}
```

- [ ] **Step 3: Tests pass**

Expected: 2 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Gemma/Gemma/Runtime/ImageTempFile.swift Gemma/GemmaTests/ImageTempFileTests.swift
git commit -m "feat(runtime): add ImageTempFile helper (UIImage → temp JPEG path)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Implement `LiteRTLMRuntime` actor (text + image)

**Files:**
- Create: `Gemma/Gemma/Runtime/LiteRTLMRuntime.swift`
- Create: `Gemma/GemmaTests/LiteRTLMRuntimeTests.swift`

> **IMPORTANT:** The exact LiteRTLM Swift API is documented at https://ai.google.dev/edge/litert-lm/swift. The skeleton below is correct as of LiteRTLM 0.12.x. **If the build fails because of an API mismatch (renamed type, different initializer signature), report BLOCKED with the exact compile error and the controller will adjust this task.** Do NOT guess at API shapes.

- [ ] **Step 1: Conditional failing tests**

Create `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/LiteRTLMRuntimeTests.swift`:

```swift
import XCTest
import UIKit
@testable import Gemma

final class LiteRTLMRuntimeTests: XCTestCase {

    /// Returns the path of an installed Gemma 4 .litertlm, or throws XCTSkip if not present.
    private func installedModelURL() throws -> (descriptor: ModelDescriptor, url: URL) {
        let store = InstalledModels.defaultInDocuments()
        if let desc = ModelCatalog.find("gemma-4-e2b-it"),
           case .installed(let url) = store.status(of: desc) {
            return (desc, url)
        }
        if let desc = ModelCatalog.find("gemma-4-e4b-it"),
           case .installed(let url) = store.status(of: desc) {
            return (desc, url)
        }
        throw XCTSkip("No Gemma 4 .litertlm installed in Documents/Models/. Sideload one to run this test.")
    }

    func test_load_and_isLoaded_returnsTrue() async throws {
        let (_, url) = try installedModelURL()
        let runtime = LiteRTLMRuntime()
        try await runtime.load(options: ModelLoadOptions(modelPath: url))
        let loaded = await runtime.isLoaded()
        XCTAssertTrue(loaded)
        await runtime.unload()
    }

    func test_generate_textOnly_producesNonEmptyOutput() async throws {
        let (_, url) = try installedModelURL()
        let runtime = LiteRTLMRuntime()
        try await runtime.load(options: ModelLoadOptions(modelPath: url, useSpeculativeDecoding: false))
        let stream = await runtime.generate(
            prompt: "Say hi in three words.",
            image: nil,
            options: GenerationOptions(maxTokens: 32)
        )
        var text = ""
        var got: GenerationResult?
        for try await event in stream {
            switch event {
            case .token(let t): text += t
            case .completed(let r): got = r
            }
        }
        await runtime.unload()
        XCTAssertNotNil(got)
        XCTAssertFalse(text.isEmpty || got!.text.isEmpty)
        XCTAssertGreaterThan(got!.metrics.tokensGenerated, 0)
    }

    func test_generate_image_producesNonEmptyOutput() async throws {
        let (_, url) = try installedModelURL()
        let runtime = LiteRTLMRuntime()
        try await runtime.load(options: ModelLoadOptions(modelPath: url))
        let img = UIImage(named: "bench-image-1")!
        let stream = await runtime.generate(
            prompt: "Describe this image briefly.",
            image: img,
            options: GenerationOptions(maxTokens: 64)
        )
        var got: GenerationResult?
        for try await event in stream {
            if case .completed(let r) = event { got = r }
        }
        await runtime.unload()
        XCTAssertNotNil(got)
        XCTAssertGreaterThan(got!.metrics.tokensGenerated, 0)
    }
}
```

- [ ] **Step 2: Implement `LiteRTLMRuntime`**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Runtime/LiteRTLMRuntime.swift`:

```swift
import Foundation
import UIKit
import LiteRTLM

public actor LiteRTLMRuntime: ModelRuntime {
    public nonisolated let identifier: String = "litertlm"

    private var engine: Engine?
    private var conversation: Conversation?
    private var loaded: Bool = false
    private var lastMetrics: RuntimeMetrics?
    private var loadOptions: ModelLoadOptions?

    public init() {}

    public func isLoaded() -> Bool { loaded }

    public func load(options: ModelLoadOptions) async throws {
        // Global toggle must be set BEFORE engine.initialize().
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = options.useSpeculativeDecoding

        let cfg = try EngineConfig(
            modelPath: options.modelPath.path,
            backend: .gpu,                       // GPU on device; falls back to CPU on simulator automatically.
            maxNumTokens: options.contextLength,
            cacheDir: NSTemporaryDirectory(),
            visionBackend: .cpu(),
            audioBackend: .cpu()
        )
        let engine = Engine(engineConfig: cfg)
        try await engine.initialize()

        let sampler = try SamplerConfig(
            topK: 64,
            topP: 0.95,
            temperature: 1.0
        )
        let convCfg = ConversationConfig(
            systemMessage: options.systemPrompt.map { Message($0) },
            samplerConfig: sampler,
            tools: nil
        )
        let conv = try await engine.createConversation(with: convCfg)

        self.engine = engine
        self.conversation = conv
        self.loaded = true
        self.loadOptions = options
    }

    public func unload() {
        conversation = nil
        engine = nil
        loaded = false
        lastMetrics = nil
        loadOptions = nil
    }

    public func generate(
        prompt: String,
        image: UIImage?,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<GenerationEvent, Error> {
        let conv = self.conversation
        let loadedNow = self.loaded
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard loadedNow, let conv else {
                    continuation.finish(throwing: RuntimeError.notLoaded)
                    return
                }
                // Build the user Message, with optional image attachment.
                var tempImageURL: URL?
                let userMessage: Message
                if let image {
                    do {
                        let url = try ImageTempFile.writeJPEG(image)
                        tempImageURL = url
                        userMessage = Message(contents: [
                            Content.imageFile(url.path),
                            Content.text(prompt)
                        ])
                    } catch {
                        continuation.finish(throwing: RuntimeError.generationFailed("image encoding failed: \(error)"))
                        return
                    }
                } else {
                    userMessage = Message(prompt)
                }
                defer { tempImageURL.flatMap { try? FileManager.default.removeItem(at: $0) } }

                let start = Date()
                var firstTokenAt: Date?
                var accumulated = ""
                var tokenCount = 0
                do {
                    for try await chunk in conv.sendMessageStream(userMessage) {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        let piece = chunk.toString
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        accumulated += piece
                        tokenCount += 1
                        continuation.yield(.token(piece))
                    }
                } catch {
                    continuation.finish(throwing: RuntimeError.generationFailed("\(error)"))
                    return
                }
                let elapsed = Date().timeIntervalSince(start)
                let ttft = firstTokenAt?.timeIntervalSince(start) ?? 0
                let metrics = RuntimeMetrics(
                    tokensGenerated: tokenCount,
                    elapsedSeconds: elapsed,
                    timeToFirstTokenSeconds: ttft,
                    peakResidentMemoryBytes: MemoryReporter.currentResidentBytes(),
                    draftAcceptanceRate: nil
                )
                await self.setLastMetrics(metrics)
                continuation.yield(.completed(GenerationResult(text: accumulated, metrics: metrics)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func currentMetrics() -> RuntimeMetrics? { lastMetrics }

    private func setLastMetrics(_ m: RuntimeMetrics) { lastMetrics = m }
}
```

- [ ] **Step 3: Build**

```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild build -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -10
```

**If build fails with LiteRTLM API mismatch (renamed/missing types), STOP and report BLOCKED.** The fix has to come from the docs at https://ai.google.dev/edge/litert-lm/swift, not from guessing.

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run tests**

```bash
xcodebuild test ... -only-testing:GemmaTests/LiteRTLMRuntimeTests
```
Expected: 3 tests skipped (no model installed) OR pass (if a Gemma 4 model was sideloaded). Either result is acceptable for Plan 3a.

- [ ] **Step 5: Commit**

```bash
git add Gemma/Gemma/Runtime/LiteRTLMRuntime.swift Gemma/GemmaTests/LiteRTLMRuntimeTests.swift
git commit -m "feat(runtime): add LiteRTLMRuntime actor (text + image multimodal)

Conformance to ModelRuntime via LiteRTLM.Engine + Conversation.
Image multimodality via Content.imageFile(_:) over a temp JPEG.
MTP controlled by ModelLoadOptions.useSpeculativeDecoding (set before
engine.initialize()). Tests skip when no .litertlm is installed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Wire `RuntimeFactory` to instantiate `LiteRTLMRuntime`

**Files:**
- Modify: `Gemma/Gemma/Runtime/RuntimeFactory.swift`
- Modify: `Gemma/GemmaTests/RuntimeFactoryTests.swift`

`RuntimeKind` already has `.litertlmE4B` and `.litertlmE2B` (Plan 2 Task 7). `RuntimeFactory.make` currently returns `DummyRuntime` for both — swap to `LiteRTLMRuntime()`.

- [ ] **Step 1: Update factory**

Replace `RuntimeFactory.make` in `Gemma/Gemma/Runtime/RuntimeFactory.swift`:

```swift
public enum RuntimeFactory {
    /// Returns a fresh runtime instance for the given kind. Caller owns the lifecycle
    /// and must call `load(options:)` with the correct model path themselves.
    public static func make(_ kind: RuntimeKind) -> ModelRuntime {
        switch kind {
        case .dummy:
            return DummyRuntime()
        case .litertlmE4B, .litertlmE2B:
            return LiteRTLMRuntime()
        }
    }
}
```

- [ ] **Step 2: Adapt the existing test**

Replace `test_make_dummy_returnsDummyRuntime` and add a new test for LiteRT-LM kind selection:

```swift
    func test_make_dummy_returnsDummyRuntime() async {
        let r = RuntimeFactory.make(.dummy)
        XCTAssertEqual(r.identifier, "dummy")
    }

    func test_make_litertlmE4B_returnsLiteRTLMRuntime() async {
        let r = RuntimeFactory.make(.litertlmE4B)
        XCTAssertEqual(r.identifier, "litertlm")
    }

    func test_make_litertlmE2B_returnsLiteRTLMRuntime() async {
        let r = RuntimeFactory.make(.litertlmE2B)
        XCTAssertEqual(r.identifier, "litertlm")
    }
```

- [ ] **Step 3: Tests pass**

```bash
xcodebuild test ... -only-testing:GemmaTests/RuntimeFactoryTests
```
Expected: 8 tests pass (7 prior + 1 new; the dummy test stays as 1 and 2 new tests are added net +2 → 9? — depends on prior shape; report actual count).

- [ ] **Step 4: Commit**

```bash
git add Gemma/Gemma/Runtime/RuntimeFactory.swift Gemma/GemmaTests/RuntimeFactoryTests.swift
git commit -m "feat(runtime): RuntimeFactory returns LiteRTLMRuntime for .litertlm* kinds

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Make `HarnessModel.toggleLoad` use the installed model path

**Files:**
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift`
- Modify: `Gemma/GemmaTests/HarnessModelTests.swift`

`HarnessModel.toggleLoad` currently calls `runtime.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))` because `DummyRuntime` ignores the path. With real LiteRT-LM, the path must point to an installed `.litertlm`. When the user picks `.litertlmE4B`, `toggleLoad` must look up the model path via `InstalledModels` and refuse-with-message if it isn't installed.

- [ ] **Step 1: Update `toggleLoad`**

Replace the `toggleLoad` method in `HarnessModel.swift` with:

```swift
    public func toggleLoad() async {
        if modelLoaded {
            await runtime.unload()
            modelLoaded = false
            statusMessage = "Runtime: \(runtimeKind.displayName) (unloaded)"
            return
        }
        // Resolve the model file (dummy needs none).
        var modelURL: URL = URL(fileURLWithPath: "/dev/null")
        if let requiredId = runtimeKind.requiredModelId {
            guard let descriptor = ModelCatalog.find(requiredId) else {
                statusMessage = "Model descriptor missing for \(requiredId)"
                return
            }
            switch installedStore.status(of: descriptor) {
            case .installed(let url):
                modelURL = url
            case .notInstalled:
                statusMessage = "Model not installed. Open Models to download \(descriptor.displayName)."
                return
            case .corrupted(let actual, let expected):
                statusMessage = "Model file corrupted (\(actual) / \(expected) bytes). Remove and re-download."
                return
            }
        }
        isLoadingModel = true
        statusMessage = "Loading…"
        do {
            try await runtime.load(options: ModelLoadOptions(modelPath: modelURL))
            modelLoaded = true
            statusMessage = "Runtime: \(runtimeKind.displayName) (loaded)"
        } catch {
            statusMessage = "Load failed: \(error)"
        }
        isLoadingModel = false
    }
```

- [ ] **Step 2: Update / add HarnessModel tests**

The existing `test_toggleLoad_setsModelLoaded` and `test_toggleLoad_secondCallUnloads` still use `.dummy` (the default `runtimeKind`), so they still work. Add a new test:

```swift
    func test_toggleLoad_litertlmKind_withoutInstall_setsStatusMessage() async {
        let m = HarnessModel(initialKind: .litertlmE4B)
        await m.toggleLoad()
        await Task.yield()
        XCTAssertFalse(m.modelLoaded)
        XCTAssertTrue(m.statusMessage.contains("not installed") || m.statusMessage.contains("Open Models"))
    }
```

- [ ] **Step 3: Tests pass**

Run the full suite (`xcodebuild test ...`). Expected: all previously-green tests still pass + new test pass.

- [ ] **Step 4: Commit**

```bash
git add Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/HarnessModelTests.swift
git commit -m "feat(harness): toggleLoad resolves installed-model path or shows guidance

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Full test suite + launch smoke + tag

**Files:** none.

- [ ] **Step 1: Full test suite**

```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -50
```
Expected: `** TEST SUCCEEDED **`. New tests:
- `test_modelLoadOptions_defaultsAreSane` (modified) — 1
- `ImageTempFileTests` — 2
- `LiteRTLMRuntimeTests` — 3 (skipped without model)
- `test_make_litertlmE4B_returnsLiteRTLMRuntime`, `_E2B_` — 2
- `test_toggleLoad_litertlmKind_withoutInstall_setsStatusMessage` — 1

Estimated total: **70 tests** (62 prior + 8 new — 3 of which may report as `skipped`).

- [ ] **Step 2: Launch smoke**

Same script as Plan 2 Task 11 — install, launch, verify pid alive 4s, terminate, clean derivedData.

- [ ] **Step 3: Final commit + tag**

```bash
cd /Users/hashdown/Projects/personal_agent
git commit --allow-empty -m "chore(s1): plan 3a complete — LiteRTLMRuntime real, tests green, smoke clean

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
git tag -a s1-plan3a-litertlm-core -m "S1 Plan 3a: LiteRT-LM real runtime (text + image), runtime kinds wired"
git tag -l
```

---

## Out of scope (Plan 3b or later)

- Settings UI (system prompt textarea, MTP toggle, enable thinking toggle, sampler params) → Plan 3b.
- Bench combos a (MTP on) vs b (MTP off) over the fixed PromptSet → Plan 3b.
- `docs/superpowers/specs/01-s1-runtime-report.md` writeup → Plan 3b.
- Audio on-device (`Content.audioFile`) → Plan 3.5 (separate small plan when needed).
- llama.cpp + uncensored GGUF combo (c) → Plan 4.
- mmap vs no-mmap sub-evaluation → Plan 4.
- Background download integration with UIBackgroundTask → future.

## Risks (heads-up for Plan 3b)

| # | Risk | Mitigation suggestion for Plan 3b |
|---|---|---|
| R1 | LiteRT-LM API names in this plan are taken from the public docs and may differ slightly from the actual 0.12.x SPM artifact (e.g. `Content` cases, `Message` initializers). | Plan 3a Task 3 explicitly says STOP-and-report if the build fails with an API mismatch; controller adjusts. |
| R2 | `ExperimentalFlags.enableSpeculativeDecoding` is a global, set-once-per-process flag. Reloading with a different value may not actually toggle the engine's behavior. | Plan 3b bench tasks should kill+relaunch the app between combos a and b, or accept that the toggle requires a restart. |
| R3 | iPhone 17 simulator runs LiteRT-LM on CPU (not Metal). Tokens/s will be far below real device. | Plan 3b report should flag every simulator number as "CPU baseline only" and reserve the actual conclusion for iPhone 16 physical (later phase). |
| R4 | Multimodal image on simulator may fail if the LiteRTLM build doesn't ship the vision backend for simulator slices. | Plan 3a Task 3 image test will surface this as a generation failure; that's a known limitation, not a blocker. |
