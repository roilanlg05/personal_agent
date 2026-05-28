# S1 Plan 3b — Settings UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings sheet that lets the user tune all generation/engine parameters (backend, context, MTP, sampler, system prompt, max output tokens), persist them, and apply them — auto-reloading the model when an Engine-level parameter changed.

**Architecture:** A `GenerationSettings` Codable value type holds the eight tunables, persisted via a `SettingsStore` (UserDefaults). `HarnessModel` owns the current settings, builds `ModelLoadOptions`/`GenerationOptions` from them, and on `saveSettings` reloads only when an Engine-level field changed. `GenerationOptions` gains `systemPrompt` so the per-generation conversation (recreated each call) applies the live sampler + system prompt. `SettingsView` (a tabbed sheet) edits a draft and commits on Save.

**Tech Stack:** Swift 5, SwiftUI, `@Observable`/`@MainActor`, UserDefaults + Codable, XCTest, Xcode 26.2, iPhone 17 simulator (unit tests) + iPhone 16 physical (manual smoke). The project uses filesystem-synchronized Xcode groups, so new files under `Gemma/Gemma/` and `Gemma/GemmaTests/` compile automatically — no project.pbxproj edits.

**Position in series:** S1 Plan 3b. Previous: Plan 3a (LiteRT-LM core, on-device GPU working). Spec: `docs/superpowers/specs/2026-05-28-s1-settings-ui-design.md`. Next: Plan 3c (bench combos + report).

**Conventions:**
- All `xcodebuild` commands run from `/Users/hashdown/Projects/personal_agent/Gemma`.
- Simulator test command shorthand used below:
  `xcodebuild test -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17'`
- Commit messages end with the project's Co-Authored-By trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## File structure produced by this plan

```
Gemma/Gemma/
├── Settings/
│   ├── GenerationSettings.swift   (NEW — Codable settings value type + engineLevelDiffers)
│   └── SettingsStore.swift        (NEW — UserDefaults persistence, injectable)
├── Runtime/
│   ├── ModelRuntime.swift         (MODIFY — ComputeBackend: Codable; GenerationOptions gains systemPrompt)
│   └── LiteRTLMRuntime.swift      (MODIFY — conversation uses per-generation sampler + systemPrompt)
└── Harness/
    ├── HarnessModel.swift         (MODIFY — settings, saveSettings, build options from settings)
    ├── SettingsView.swift         (NEW — tabbed Settings sheet)
    └── HarnessView.swift          (MODIFY — ⚙️ button + Settings sheet)

Gemma/GemmaTests/
├── GenerationSettingsTests.swift  (NEW)
├── SettingsStoreTests.swift       (NEW)
├── ModelRuntimeTypesTests.swift   (MODIFY — assert GenerationOptions.systemPrompt default)
└── HarnessModelTests.swift        (MODIFY — saveSettings behavior)
```

---

## Task 1: `GenerationSettings` value type

**Files:**
- Modify: `Gemma/Gemma/Runtime/ModelRuntime.swift` (make `ComputeBackend` Codable)
- Create: `Gemma/Gemma/Settings/GenerationSettings.swift`
- Test: `Gemma/GemmaTests/GenerationSettingsTests.swift`

- [ ] **Step 1: Make `ComputeBackend` Codable**

In `Gemma/Gemma/Runtime/ModelRuntime.swift`, change the enum declaration:

```swift
public enum ComputeBackend: Sendable, Equatable, Codable {
    case cpu
    case gpu
}
```
(Only the conformance list changes — add `Codable`. Enums with no associated values get Codable synthesized.)

- [ ] **Step 2: Write the failing tests**

Create `Gemma/GemmaTests/GenerationSettingsTests.swift`:

```swift
import XCTest
@testable import Gemma

final class GenerationSettingsTests: XCTestCase {
    func test_default_matchesGalleryRecipe() {
        let s = GenerationSettings.default
        XCTAssertEqual(s.backend, .gpu)
        XCTAssertEqual(s.contextLength, 4096)
        XCTAssertFalse(s.useSpeculativeDecoding)
        XCTAssertEqual(s.systemPrompt, "")
        XCTAssertEqual(s.temperature, 1.0, accuracy: 0.0001)
        XCTAssertEqual(s.topP, 0.95, accuracy: 0.0001)
        XCTAssertEqual(s.topK, 64)
        XCTAssertEqual(s.maxOutputTokens, 256)
    }

    func test_codable_roundTrip() throws {
        let s = GenerationSettings(backend: .cpu, contextLength: 2048, useSpeculativeDecoding: true,
                                   systemPrompt: "be brief", temperature: 0.7, topP: 0.9, topK: 40, maxOutputTokens: 128)
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(GenerationSettings.self, from: data)
        XCTAssertEqual(decoded, s)
    }

    func test_engineLevelDiffers_trueForEngineFields() {
        let base = GenerationSettings.default
        XCTAssertTrue(base.engineLevelDiffers(from: GenerationSettings(backend: .cpu)))
        XCTAssertTrue(base.engineLevelDiffers(from: GenerationSettings(contextLength: 2048)))
        XCTAssertTrue(base.engineLevelDiffers(from: GenerationSettings(useSpeculativeDecoding: true)))
    }

    func test_engineLevelDiffers_falseForLiveFields() {
        let base = GenerationSettings.default
        XCTAssertFalse(base.engineLevelDiffers(from: GenerationSettings(systemPrompt: "x")))
        XCTAssertFalse(base.engineLevelDiffers(from: GenerationSettings(temperature: 0.5)))
        XCTAssertFalse(base.engineLevelDiffers(from: GenerationSettings(topP: 0.8)))
        XCTAssertFalse(base.engineLevelDiffers(from: GenerationSettings(topK: 10)))
        XCTAssertFalse(base.engineLevelDiffers(from: GenerationSettings(maxOutputTokens: 64)))
    }
}
```

- [ ] **Step 3: Run the tests — verify they fail to compile**

Run: `xcodebuild test ... -only-testing:GemmaTests/GenerationSettingsTests`
Expected: build failure — `cannot find 'GenerationSettings' in scope`.

- [ ] **Step 4: Implement `GenerationSettings`**

Create `Gemma/Gemma/Settings/GenerationSettings.swift`:

```swift
import Foundation

/// All user-tunable generation/engine parameters. Persisted by SettingsStore.
public struct GenerationSettings: Codable, Equatable, Sendable {
    // Engine-level — changing these requires reloading the model.
    public var backend: ComputeBackend
    public var contextLength: Int
    public var useSpeculativeDecoding: Bool
    // Live — applied on the next generation, no reload.
    public var systemPrompt: String
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var maxOutputTokens: Int

    public init(
        backend: ComputeBackend = .gpu,
        contextLength: Int = 4096,
        useSpeculativeDecoding: Bool = false,
        systemPrompt: String = "",
        temperature: Double = 1.0,
        topP: Double = 0.95,
        topK: Int = 64,
        maxOutputTokens: Int = 256
    ) {
        self.backend = backend
        self.contextLength = contextLength
        self.useSpeculativeDecoding = useSpeculativeDecoding
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxOutputTokens = maxOutputTokens
    }

    /// Edge Gallery iOS recipe for Gemma 4.
    public static let `default` = GenerationSettings()

    /// True when an Engine-level field (backend / contextLength / MTP) differs —
    /// the signal HarnessModel uses to decide whether a reload is needed.
    public func engineLevelDiffers(from other: GenerationSettings) -> Bool {
        backend != other.backend
            || contextLength != other.contextLength
            || useSpeculativeDecoding != other.useSpeculativeDecoding
    }
}
```

- [ ] **Step 5: Run the tests — verify they pass**

Run: `xcodebuild test ... -only-testing:GemmaTests/GenerationSettingsTests`
Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Runtime/ModelRuntime.swift Gemma/Gemma/Settings/GenerationSettings.swift Gemma/GemmaTests/GenerationSettingsTests.swift
git commit -m "feat(settings): GenerationSettings value type (Codable, engineLevelDiffers)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `SettingsStore` (UserDefaults persistence)

**Files:**
- Create: `Gemma/Gemma/Settings/SettingsStore.swift`
- Test: `Gemma/GemmaTests/SettingsStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Gemma/GemmaTests/SettingsStoreTests.swift`:

```swift
import XCTest
@testable import Gemma

final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_load_returnsDefaultWhenEmpty() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), .default)
    }

    func test_saveThenLoad_roundTrips() {
        let store = SettingsStore(defaults: defaults)
        let s = GenerationSettings(backend: .cpu, contextLength: 2048, useSpeculativeDecoding: true,
                                   systemPrompt: "hi", temperature: 0.5, topP: 0.8, topK: 20, maxOutputTokens: 99)
        store.save(s)
        XCTAssertEqual(store.load(), s)
    }
}
```

- [ ] **Step 2: Run the tests — verify they fail to compile**

Run: `xcodebuild test ... -only-testing:GemmaTests/SettingsStoreTests`
Expected: build failure — `cannot find 'SettingsStore' in scope`.

- [ ] **Step 3: Implement `SettingsStore`**

Create `Gemma/Gemma/Settings/SettingsStore.swift`:

```swift
import Foundation

/// Persists GenerationSettings as JSON in UserDefaults. Injectable for tests.
public struct SettingsStore: Sendable {
    private let defaults: UserDefaults
    private let key = "gemma.generationSettings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> GenerationSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(GenerationSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: GenerationSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
```

- [ ] **Step 4: Run the tests — verify they pass**

Run: `xcodebuild test ... -only-testing:GemmaTests/SettingsStoreTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Settings/SettingsStore.swift Gemma/GemmaTests/SettingsStoreTests.swift
git commit -m "feat(settings): SettingsStore (UserDefaults JSON persistence)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `GenerationOptions` gains `systemPrompt`

**Files:**
- Modify: `Gemma/Gemma/Runtime/ModelRuntime.swift`
- Test: `Gemma/GemmaTests/ModelRuntimeTypesTests.swift`

`GenerationOptions` is recreated per generation; carrying `systemPrompt` lets the runtime apply a live system prompt without a reload (the conversation is rebuilt each call).

- [ ] **Step 1: Update the existing defaults test**

In `Gemma/GemmaTests/ModelRuntimeTypesTests.swift`, find `test_generationOptions_defaultsAreSane` and add one assertion at the end of that method (before its closing brace):

```swift
        XCTAssertNil(opts.systemPrompt)
```

- [ ] **Step 2: Run it — verify it fails to compile**

Run: `xcodebuild test ... -only-testing:GemmaTests/ModelRuntimeTypesTests/test_generationOptions_defaultsAreSane`
Expected: build failure — `value of type 'GenerationOptions' has no member 'systemPrompt'`.

- [ ] **Step 3: Add `systemPrompt` to `GenerationOptions`**

In `Gemma/Gemma/Runtime/ModelRuntime.swift`, update the `GenerationOptions` struct. Add the stored property and init parameter (keep all existing fields):

Add after the `topK` property:
```swift
    /// Optional system prompt applied when the conversation is (re)created for this
    /// generation. nil = no system message.
    public var systemPrompt: String?
```

Update the initializer to add the parameter (last, with a default so existing call sites keep compiling) and assignment:
```swift
    public init(
        maxTokens: Int = 4000,
        temperature: Double = 1.0,
        topP: Double = 0.95,
        topK: Int = 64,
        useSpeculativeDecoding: Bool = false,
        systemPrompt: String? = nil
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.useSpeculativeDecoding = useSpeculativeDecoding
        self.systemPrompt = systemPrompt
    }
```

- [ ] **Step 4: Run the full type test — verify it passes**

Run: `xcodebuild test ... -only-testing:GemmaTests/ModelRuntimeTypesTests`
Expected: all tests pass (4).

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Runtime/ModelRuntime.swift Gemma/GemmaTests/ModelRuntimeTypesTests.swift
git commit -m "feat(runtime): GenerationOptions carries optional systemPrompt

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `LiteRTLMRuntime` applies per-generation sampler + system prompt

**Files:**
- Modify: `Gemma/Gemma/Runtime/LiteRTLMRuntime.swift`

The conversation is already recreated per generation; this task sources its `SamplerConfig` and system message from the call's `GenerationOptions` instead of the hardcoded `64 / 0.95 / 1.0` and the load-time system prompt. No unit test (native engine); verified by build + on-device smoke in Task 7.

- [ ] **Step 1: Remove the stored `systemPrompt` property**

In `LiteRTLMRuntime.swift`, delete the line `private var systemPrompt: String?` from the property list, and delete `systemPrompt = nil` from `unload()`.

- [ ] **Step 2: Replace `makeConversation` to take `GenerationOptions`**

Replace the existing `makeConversation(engine:)` method with:

```swift
    /// Creates a fresh `Conversation` (clean context) on the loaded engine, using
    /// this generation's sampler + system prompt. Each generation gets a new one so
    /// history doesn't accumulate and overflow the KV cache.
    private func makeConversation(engine: Engine, options: GenerationOptions) async throws -> Conversation {
        let sampler = try SamplerConfig(
            topK: max(1, options.topK),
            topP: Float(options.topP),
            temperature: Float(options.temperature)
        )
        let trimmed = options.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemMessage = (trimmed?.isEmpty == false) ? Message(trimmed!, role: .system) : nil
        let convCfg = ConversationConfig(systemMessage: systemMessage, samplerConfig: sampler)
        return try await engine.createConversation(with: convCfg)
    }
```

- [ ] **Step 3: Update `load()` to build the initial conversation from load options**

In `load(options:)`, replace the line that creates the initial conversation:

```swift
        self.conversation = try await makeConversation(engine: engine)
```
with:
```swift
        self.conversation = try await makeConversation(
            engine: engine,
            options: GenerationOptions(systemPrompt: options.systemPrompt)
        )
```
(Other lines in `load` — `self.engine = engine`, `self.loaded = true` — stay. Delete the now-removed `self.systemPrompt = options.systemPrompt` assignment if present.)

- [ ] **Step 4: Thread `options` through `generate` → `streamGeneration`**

Replace the `generate(prompt:image:options:)` body's stream setup. Change:
```swift
        let maxTokens = options.maxTokens
        return AsyncThrowingStream { continuation in
            let task = Task { await self.streamGeneration(prompt: prompt, image: image, maxTokens: maxTokens, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
```
to:
```swift
        return AsyncThrowingStream { continuation in
            let task = Task { await self.streamGeneration(prompt: prompt, image: image, options: options, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
```

Change the `streamGeneration` signature from:
```swift
    private func streamGeneration(
        prompt: String,
        image: UIImage?,
        maxTokens: Int,
        into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async {
```
to:
```swift
    private func streamGeneration(
        prompt: String,
        image: UIImage?,
        options: GenerationOptions,
        into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async {
```

Inside `streamGeneration`, update the conversation creation calls (both the first attempt and the retry) from `try await makeConversation(engine: engine)` to `try await makeConversation(engine: engine, options: options)`.

Add `let maxTokens = options.maxTokens` near the top of `streamGeneration` (before the generation loop) so the existing `if maxTokens > 0 && tokenCount >= maxTokens` cap still resolves.

- [ ] **Step 5: Build — verify it compiles**

Run: `xcodebuild build -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Run the full suite minus the device-only runtime tests — verify green**

Run: `xcodebuild test ... -skip-testing:GemmaTests/LiteRTLMRuntimeTests 2>&1 | tail -3`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Runtime/LiteRTLMRuntime.swift
git commit -m "feat(runtime): apply per-generation sampler + system prompt

makeConversation now builds SamplerConfig (topK/topP/temperature) and the
system message from the call's GenerationOptions instead of hardcoded
values, so Settings changes take effect on the next generation.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `HarnessModel` owns settings + `saveSettings`

**Files:**
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift`
- Test: `Gemma/GemmaTests/HarnessModelTests.swift`

- [ ] **Step 1: Write the failing tests**

In `Gemma/GemmaTests/HarnessModelTests.swift`, add these tests inside the `HarnessModelTests` class:

```swift
    func test_init_loadsSettingsFromStore() async {
        let suite = "HM-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.save(GenerationSettings(temperature: 0.3))
        let m = HarnessModel(settingsStore: store)
        XCTAssertEqual(m.settings.temperature, 0.3, accuracy: 0.0001)
        await Task.yield()
    }

    func test_saveSettings_persistsAndUpdates() async {
        let suite = "HM-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let m = HarnessModel(settingsStore: store)
        let new = GenerationSettings(systemPrompt: "be terse", topK: 10)
        await m.saveSettings(new)
        XCTAssertEqual(m.settings, new)
        XCTAssertEqual(store.load(), new)
        await Task.yield()
    }

    func test_saveSettings_liveOnlyChange_keepsModelLoaded() async {
        // .dummy default kind loads without a model file.
        let m = HarnessModel()
        await m.toggleLoad()
        XCTAssertTrue(m.modelLoaded)
        await m.saveSettings(GenerationSettings(temperature: 0.2))  // live-only field
        XCTAssertTrue(m.modelLoaded)
        XCTAssertEqual(m.settings.temperature, 0.2, accuracy: 0.0001)
    }
```

- [ ] **Step 2: Run them — verify they fail to compile**

Run: `xcodebuild test ... -only-testing:GemmaTests/HarnessModelTests`
Expected: build failure — `HarnessModel` has no `settings`, `saveSettings`, or `init(settingsStore:)`.

- [ ] **Step 3: Add settings storage + injection to `HarnessModel`**

In `Gemma/Gemma/Harness/HarnessModel.swift`:

a. Add an observed property near `installedModels` / `partialDownloads`:
```swift
    public private(set) var settings: GenerationSettings
```

b. Add a non-observed collaborator near `installedStore`:
```swift
    @ObservationIgnored
    private let settingsStore: SettingsStore
```

c. Update `init` to accept and use the store. Change the signature to add `settingsStore` and set `settings` before `refreshInstalled()`:
```swift
    public init(
        initialKind: RuntimeKind = .dummy,
        runner: BenchRunner = BenchRunner(),
        installedStore: InstalledModels = .defaultInDocuments(),
        settingsStore: SettingsStore = SettingsStore()
    ) {
        self.runtimeKind = initialKind
        self.runtime = RuntimeFactory.make(initialKind)
        self.runner = runner
        self.installedStore = installedStore
        self.downloader = ModelDownloader(destinationDir: installedStore.rootDir)
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        self.statusMessage = "Runtime: \(initialKind.displayName) (not loaded)"
        refreshInstalled()
    }
```

- [ ] **Step 4: Build `ModelLoadOptions` and `GenerationOptions` from settings**

In `toggleLoad()`, replace the load call:
```swift
            try await runtime.load(options: ModelLoadOptions(modelPath: modelURL))
```
with:
```swift
            try await runtime.load(options: ModelLoadOptions(
                modelPath: modelURL,
                contextLength: settings.contextLength,
                systemPrompt: settings.systemPrompt.isEmpty ? nil : settings.systemPrompt,
                useSpeculativeDecoding: settings.useSpeculativeDecoding,
                backend: settings.backend
            ))
```

Add a private helper method (e.g. right after `toggleLoad`):
```swift
    private func makeGenerationOptions() -> GenerationOptions {
        GenerationOptions(
            maxTokens: settings.maxOutputTokens,
            temperature: settings.temperature,
            topP: settings.topP,
            topK: settings.topK,
            systemPrompt: settings.systemPrompt.isEmpty ? nil : settings.systemPrompt
        )
    }
```

In `runSingle()`, replace `options: GenerationOptions(maxTokens: 128)` with `options: makeGenerationOptions()`.

In `runBench()`, add `generationOptions: makeGenerationOptions(),` to the `runner.run(...)` call (place it right after the `prompts:` argument).

- [ ] **Step 5: Add `saveSettings`**

Add this method to `HarnessModel` (after `runBench`):
```swift
    public func saveSettings(_ new: GenerationSettings) async {
        let needsReload = new.engineLevelDiffers(from: settings) && modelLoaded
        settingsStore.save(new)
        settings = new
        if needsReload {
            await toggleLoad()  // unload current engine
            await toggleLoad()  // reload with the new Engine-level settings
        }
        // Live-only changes (sampler / systemPrompt) apply on the next generation.
    }
```

- [ ] **Step 6: Run the HarnessModel tests — verify they pass**

Run: `xcodebuild test ... -only-testing:GemmaTests/HarnessModelTests`
Expected: all pass (existing + 3 new).

- [ ] **Step 7: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Harness/HarnessModel.swift Gemma/GemmaTests/HarnessModelTests.swift
git commit -m "feat(harness): HarnessModel owns GenerationSettings + saveSettings

Loads settings from an injected SettingsStore; builds ModelLoadOptions and
GenerationOptions from them; saveSettings persists and reloads only when an
Engine-level field changed (backend/context/MTP) and the model is loaded.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `SettingsView` (tabbed sheet) + ⚙️ entry point

**Files:**
- Create: `Gemma/Gemma/Harness/SettingsView.swift`
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift` (add `showSettings` flag)
- Modify: `Gemma/Gemma/Harness/HarnessView.swift` (gear button + `.sheet`)

No unit test (SwiftUI views); verified by build + on-device smoke in Task 7.

- [ ] **Step 1: Add a `showSettings` presentation flag to `HarnessModel`**

In `HarnessModel.swift`, near `showCatalog`:
```swift
    public var showSettings: Bool = false
```

- [ ] **Step 2: Implement `SettingsView`**

Create `Gemma/Gemma/Harness/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @Bindable var model: HarnessModel
    @State private var draft: GenerationSettings
    @FocusState private var promptFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: HarnessModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
    }

    private let contextChoices = [1024, 2048, 4096, 8192]

    var body: some View {
        NavigationStack {
            TabView {
                parametersTab
                    .tabItem { Label("Parameters", systemImage: "slider.horizontal.3") }
                systemPromptTab
                    .tabItem { Label("System Prompt", systemImage: "text.bubble") }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task {
                            await model.saveSettings(draft)
                            dismiss()
                        }
                    }
                    .bold()
                }
            }
        }
    }

    private var parametersTab: some View {
        Form {
            Section("Engine (reload to apply)") {
                Picker("Backend", selection: $draft.backend) {
                    Text("GPU").tag(ComputeBackend.gpu)
                    Text("CPU").tag(ComputeBackend.cpu)
                }
                Picker("Context (KV cache)", selection: $draft.contextLength) {
                    ForEach(contextChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Speculative decoding (MTP)", isOn: $draft.useSpeculativeDecoding)
                if engineLevelChanged {
                    Text("Changing these reloads the model on Save.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Section("Sampler (live)") {
                LabeledContent("Temperature: \(draft.temperature, specifier: "%.2f")") {
                    Slider(value: $draft.temperature, in: 0...2, step: 0.05)
                }
                LabeledContent("Top-P: \(draft.topP, specifier: "%.2f")") {
                    Slider(value: $draft.topP, in: 0...1, step: 0.01)
                }
                Stepper("Top-K: \(draft.topK)", value: $draft.topK, in: 1...128)
                Stepper("Max output tokens: \(draft.maxOutputTokens)", value: $draft.maxOutputTokens, in: 16...2048, step: 16)
            }
        }
    }

    private var systemPromptTab: some View {
        Form {
            Section("System Prompt") {
                TextEditor(text: $draft.systemPrompt)
                    .frame(minHeight: 200)
                    .focused($promptFocused)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { promptFocused = false }
            }
        }
    }

    private var engineLevelChanged: Bool {
        draft.engineLevelDiffers(from: model.settings)
    }
}

#Preview {
    SettingsView(model: HarnessModel())
}
```

- [ ] **Step 3: Add the ⚙️ button + sheet to `HarnessView`**

In `Gemma/Gemma/Harness/HarnessView.swift`, in `statusBar`, add a gear button before the "Models" button:
```swift
            Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                .disabled(model.isGenerating)
```

And add a sheet next to the existing `.sheet(...)` modifiers (after the CatalogView sheet):
```swift
            .sheet(isPresented: $model.showSettings) {
                SettingsView(model: model)
            }
```

- [ ] **Step 4: Build — verify it compiles**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild build -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add Gemma/Gemma/Harness/SettingsView.swift Gemma/Gemma/Harness/HarnessModel.swift Gemma/Gemma/Harness/HarnessView.swift
git commit -m "feat(ui): SettingsView tabbed sheet (Parameters + System Prompt)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Full suite + on-device smoke + tag

**Files:** none.

- [ ] **Step 1: Full simulator suite (minus device-only runtime tests)**

Run: `cd /Users/hashdown/Projects/personal_agent/Gemma && xcodebuild test -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' -skip-testing:GemmaTests/LiteRTLMRuntimeTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: On-device smoke (HUMAN STEP — physical iPhone 16)**

Build, install, and launch on the physical device, then verify by hand:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild -project Gemma.xcodeproj -scheme Gemma -destination 'platform=iOS,id=00008140-000A6216110A801C' -allowProvisioningUpdates -derivedDataPath /tmp/gemma_dd build 2>&1 | tail -2
APP=$(find /tmp/gemma_dd/Build/Products/Debug-iphoneos -maxdepth 1 -name "Gemma.app" | head -1)
xcrun devicectl device install app --device 00008140-000A6216110A801C "$APP"
```
Then on the unlocked device: open the app → ⚙️ → change Temperature and System Prompt (live) → Save → Generate and confirm the output reflects the change; change Backend or Context (engine-level) → Save → confirm the model reloads (status shows loading) and Generate still works. Settings should survive force-quitting and reopening the app.

- [ ] **Step 3: Update the knowledge graph**

Run: `cd /Users/hashdown/Projects/personal_agent && graphify update .`

- [ ] **Step 4: Final commit + tag**

```bash
cd /Users/hashdown/Projects/personal_agent
git commit --allow-empty -m "chore(s1): plan 3b complete — Settings UI, tests green, device smoke clean

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git tag -a s1-plan3b-settings-ui -m "S1 Plan 3b: Settings UI (params + system prompt, persisted, auto-reload)"
git tag -l
```

---

## Out of scope (Plan 3c / later)
- Bench combos (MTP on/off, cpu/gpu, E2B/E4B) over the PromptSet + the S1 runtime report.
- Multimodal image generation (vision backend GPU).
- Per-prompt thermal throttling / pacing.

## Risks
| # | Risk | Mitigation |
|---|------|-----------|
| R1 | `increased-memory-limit` provisioning requires `-allowProvisioningUpdates` on every device build. | Task 7 includes the flag. |
| R2 | An engine-level Save while a generation is in flight could race the reload. | `runSingle`/`runBench` already guard re-entry; the Save button is reachable only from the sheet, and `toggleLoad` is serialized on the MainActor. If flakiness appears, disable Save while `isGenerating`. |
| R3 | Changing context length to 8192 may reintroduce the GPU memory pressure seen at 32K. | 8192 is the max offered; if it fails to load on device, the status shows "Load failed" and the user can drop back to 4096. |
