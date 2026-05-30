# Graph Report - personal_agent  (2026-05-29)

## Corpus Check
- 80 files · ~61,762 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1014 nodes · 1314 edges · 83 communities (64 shown, 19 thin omitted)
- Extraction: 87% EXTRACTED · 13% INFERRED · 0% AMBIGUOUS · INFERRED: 173 edges (avg confidence: 0.81)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `4399c595`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_Bench & Runtime Layer|Bench & Runtime Layer]]
- [[_COMMUNITY_Product Concepts & Plans|Product Concepts & Plans]]
- [[_COMMUNITY_Core Test Suite|Core Test Suite]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Prompt Set Model|Prompt Set Model]]
- [[_COMMUNITY_Harness Orchestrator|Harness Orchestrator]]
- [[_COMMUNITY_SwiftUI App Shell|SwiftUI App Shell]]
- [[_COMMUNITY_Model Downloader|Model Downloader]]
- [[_COMMUNITY_Installed Models Storage|Installed Models Storage]]
- [[_COMMUNITY_Bench Report Serialization|Bench Report Serialization]]
- [[_COMMUNITY_Device Capability|Device Capability]]
- [[_COMMUNITY_AccentColor Asset|AccentColor Asset]]
- [[_COMMUNITY_AppIcon Asset|AppIcon Asset]]
- [[_COMMUNITY_Bench Image Asset|Bench Image Asset]]
- [[_COMMUNITY_Assets Catalog Root|Assets Catalog Root]]
- [[_COMMUNITY_AppIcon Asset Node|AppIcon Asset Node]]
- [[_COMMUNITY_AccentColor Asset Node|AccentColor Asset Node]]
- [[_COMMUNITY_Test Sanity Stub|Test Sanity Stub]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 24|Community 24]]
- [[_COMMUNITY_Community 25|Community 25]]
- [[_COMMUNITY_Community 26|Community 26]]
- [[_COMMUNITY_Community 27|Community 27]]
- [[_COMMUNITY_Community 28|Community 28]]
- [[_COMMUNITY_Community 29|Community 29]]
- [[_COMMUNITY_Community 30|Community 30]]
- [[_COMMUNITY_Community 31|Community 31]]
- [[_COMMUNITY_Community 32|Community 32]]
- [[_COMMUNITY_Community 33|Community 33]]
- [[_COMMUNITY_Community 34|Community 34]]
- [[_COMMUNITY_Community 35|Community 35]]
- [[_COMMUNITY_Community 36|Community 36]]
- [[_COMMUNITY_Community 37|Community 37]]
- [[_COMMUNITY_Community 38|Community 38]]
- [[_COMMUNITY_Community 39|Community 39]]
- [[_COMMUNITY_Community 40|Community 40]]
- [[_COMMUNITY_Community 41|Community 41]]
- [[_COMMUNITY_Community 42|Community 42]]
- [[_COMMUNITY_Community 43|Community 43]]
- [[_COMMUNITY_Community 44|Community 44]]
- [[_COMMUNITY_Community 45|Community 45]]
- [[_COMMUNITY_Community 46|Community 46]]
- [[_COMMUNITY_Community 47|Community 47]]
- [[_COMMUNITY_Community 48|Community 48]]
- [[_COMMUNITY_Community 49|Community 49]]
- [[_COMMUNITY_Community 50|Community 50]]
- [[_COMMUNITY_Community 51|Community 51]]
- [[_COMMUNITY_Community 52|Community 52]]
- [[_COMMUNITY_Community 53|Community 53]]
- [[_COMMUNITY_Community 54|Community 54]]
- [[_COMMUNITY_Community 55|Community 55]]
- [[_COMMUNITY_Community 56|Community 56]]
- [[_COMMUNITY_Community 57|Community 57]]
- [[_COMMUNITY_Community 58|Community 58]]
- [[_COMMUNITY_Community 59|Community 59]]
- [[_COMMUNITY_Community 60|Community 60]]
- [[_COMMUNITY_Community 61|Community 61]]
- [[_COMMUNITY_Community 62|Community 62]]
- [[_COMMUNITY_Community 63|Community 63]]
- [[_COMMUNITY_Community 64|Community 64]]
- [[_COMMUNITY_Community 65|Community 65]]
- [[_COMMUNITY_Community 66|Community 66]]
- [[_COMMUNITY_Community 67|Community 67]]
- [[_COMMUNITY_Community 68|Community 68]]
- [[_COMMUNITY_Community 69|Community 69]]
- [[_COMMUNITY_Community 70|Community 70]]
- [[_COMMUNITY_Community 71|Community 71]]
- [[_COMMUNITY_Community 72|Community 72]]
- [[_COMMUNITY_Community 73|Community 73]]
- [[_COMMUNITY_Community 74|Community 74]]
- [[_COMMUNITY_Community 75|Community 75]]
- [[_COMMUNITY_Community 76|Community 76]]
- [[_COMMUNITY_Community 77|Community 77]]
- [[_COMMUNITY_Community 78|Community 78]]
- [[_COMMUNITY_Community 79|Community 79]]
- [[_COMMUNITY_Community 80|Community 80]]
- [[_COMMUNITY_Community 81|Community 81]]
- [[_COMMUNITY_Community 82|Community 82]]

## God Nodes (most connected - your core abstractions)
1. `HarnessModel` - 45 edges
2. `DummyRuntime` - 28 edges
3. `LiteRTLMRuntime` - 25 edges
4. `InstalledModels` - 21 edges
5. `GenerationOptions` - 20 edges
6. `ModelLoadOptions` - 19 edges
7. `HarnessModelTests` - 18 edges
8. `S1 Runtime — Plan 2 of 4: Model Catalog + Downloader + Memory Pre-flight` - 17 edges
9. `BenchRunner` - 16 edges
10. `RuntimeMetrics` - 16 edges

## Surprising Connections (you probably didn't know these)
- `ModelDownloaderTests` --implements--> `S1 Plan 2: Model Catalog + Downloader + Pre-flight`  [INFERRED]
  Gemma/GemmaTests/ModelDownloaderTests.swift → docs/superpowers/plans/2026-05-28-s1-model-infra.md
- `ModelDescriptorTests` --implements--> `S1 Plan 2: Model Catalog + Downloader + Pre-flight`  [INFERRED]
  Gemma/GemmaTests/ModelDescriptorTests.swift → docs/superpowers/plans/2026-05-28-s1-model-infra.md
- `InstalledModelsTests` --implements--> `S1 Plan 2: Model Catalog + Downloader + Pre-flight`  [INFERRED]
  Gemma/GemmaTests/InstalledModelsTests.swift → docs/superpowers/plans/2026-05-28-s1-model-infra.md
- `ImageTempFileTests` --implements--> `S1 Plan 3a: LiteRT-LM Core Integration`  [INFERRED]
  Gemma/GemmaTests/ImageTempFileTests.swift → docs/superpowers/plans/2026-05-28-s1-litertlm-core.md
- `MemoryReporterTests` --implements--> `S1 Plan 1: Scaffold + Protocol + Dummy Runtime + Bench`  [INFERRED]
  Gemma/GemmaTests/MemoryReporterTests.swift → docs/superpowers/plans/2026-05-27-s1-runtime-scaffold.md

## Hyperedges (group relationships)
- **Streaming generation runtime pattern** — runtime_modelruntime_modelruntime, runtime_litertlmruntime_litertlmruntime, runtime_dummyruntime_dummyruntime, runtime_modelruntime_generationevent, runtime_runtimefactory_runtimefactory [INFERRED 0.85]
- **Benchmark pipeline flow** — bench_promptset_promptset, bench_benchrunner_benchrunner, runtime_modelruntime_modelruntime, bench_benchreport_benchreport, harness_harnessmodel_harnessmodel [INFERRED 0.85]
- **Model catalog + download + install flow** — models_modelcatalog_modelcatalog, models_modeldescriptor_modeldescriptor, models_devicecapability_devicecapability, models_modeldownloader_modeldownloader, models_installedmodels_installedmodels, harness_catalogview_catalogview [INFERRED 0.85]
- **S1 four-plan implementation series** — plans_2026_05_27_s1_runtime_scaffold, plans_2026_05_28_s1_model_infra, plans_2026_05_28_s1_litertlm_core, specs_01_s1_runtime_spec [EXTRACTED 1.00]
- **Bench pipeline test trio (Runner+PromptSet+Report+Runtime)** — gemmatests_benchrunnertests_class, gemmatests_promptsettests_class, gemmatests_benchreporttests_class, gemmatests_dummyruntimetests_class [INFERRED 0.85]
- **Model infra layered subsystem (Descriptor+Catalog+Capability+Downloader+InstalledModels)** — gemmatests_modeldescriptortests_class, gemmatests_modelcatalogtests_class, gemmatests_devicecapabilitytests_class, gemmatests_modeldownloadertests_class, gemmatests_installedmodelstests_class [INFERRED 0.95]

## Communities (83 total, 19 thin omitted)

### Community 0 - "Bench & Runtime Layer"
Cohesion: 0.13
Nodes (4): DummyRuntimeTests, DummyRuntime, GenerationOptions, RuntimeMetrics

### Community 1 - "Product Concepts & Plans"
Cohesion: 0.07
Nodes (46): CLAUDE.md graphify project rules, Bench combos a/b/c (LiteRT-LM±MTP, llama.cpp uncensored), Bilingual ES/EN with code-switching, Gemma 4 E4B (multimodal model), Hey Gemma wake word + espera/continúa, Home server (i3 + Qdrant + graphify), iPhone 16 base 8GB target, LiteRT-LM runtime (+38 more)

### Community 3 - "Community 3"
Cohesion: 0.14
Nodes (13): 1. `GenerationSettings` (Codable, Equatable, Sendable), 2. `SettingsStore`, 3. Runtime wiring (`LiteRTLMRuntime`, `ModelRuntime` types), 4. `HarnessModel`, 5. UI — `SettingsView` (sheet), Components, Data flow, Error handling (+5 more)

### Community 4 - "Prompt Set Model"
Cohesion: 0.04
Nodes (41): code:block1 (Gemma/Gemma/), code:swift (/// Optional system prompt applied when the conversation is ), code:bash (cd /Users/hashdown/Projects/personal_agent), code:swift (/// Creates a fresh `Conversation` (clean context) on the lo), code:swift (self.conversation = try await makeConversation(engine: engin), code:swift (let maxTokens = options.maxTokens), code:swift (return AsyncThrowingStream { continuation in), code:swift (public enum ComputeBackend: Sendable, Equatable, Codable {) (+33 more)

### Community 5 - "Harness Orchestrator"
Cohesion: 0.05
Nodes (7): GenerationSettingsTests, HarnessModelTests, SettingsStoreTests, DownloadProgress, HarnessModel, GenerationSettings, SettingsStore

### Community 6 - "SwiftUI App Shell"
Cohesion: 0.07
Nodes (14): App, GemmaApp, BenchmarkView, CatalogView, ModelRow, HarnessView, Coordinator, ImagePickerView (+6 more)

### Community 7 - "Model Downloader"
Cohesion: 0.07
Nodes (19): Error, ModelDownloaderTests, MockURLProtocol, ModelDownloaderTests, Response, DownloadError, cancelled, httpError (+11 more)

### Community 9 - "Bench Report Serialization"
Cohesion: 0.05
Nodes (40): code:block1 (Gemma/Gemma/), code:bash (xcodebuild test ... -only-testing:GemmaTests/ModelRuntimeTyp), code:bash (xcodebuild test ... 2>&1 | tail -10), code:bash (git add Gemma/Gemma/Runtime/ModelRuntime.swift Gemma/GemmaTe), code:swift (import XCTest), code:swift (import Foundation), code:bash (git add Gemma/Gemma/Runtime/ImageTempFile.swift Gemma/GemmaT), code:swift (import XCTest) (+32 more)

### Community 11 - "AccentColor Asset"
Cohesion: 0.40
Nodes (4): colors, info, author, version

### Community 12 - "AppIcon Asset"
Cohesion: 0.40
Nodes (4): images, info, author, version

### Community 13 - "Bench Image Asset"
Cohesion: 0.40
Nodes (4): images, info, author, version

### Community 14 - "Assets Catalog Root"
Cohesion: 0.50
Nodes (3): info, author, version

### Community 18 - "Community 18"
Cohesion: 0.17
Nodes (13): ImageProvider typealias, BenchPrompt, PromptCategory, conversational, factual, image, long, PromptLanguage (+5 more)

### Community 19 - "Community 19"
Cohesion: 0.10
Nodes (19): 1. Identidad del proyecto, 2. Decisiones bloqueadas, 3.1 · Estado de S1 (2026-05-28), 3.2 · S1.2 — Runtime MLX (modelo-agnóstico) (2026-05-29), 3. Route map por fases, 4. Gráfico de dependencias (alto nivel), 5. Decisiones diferidas (cada una se resuelve dentro de su spec), 6.1 Capacidades de la introducción (párrafo grande) (+11 more)

### Community 20 - "Community 20"
Cohesion: 0.12
Nodes (16): 10. Riesgos / preguntas abiertas dentro del spec, 11. Definición de "hecho", 12. Out of scope explícito (para evitar scope creep), 13. Próximos specs que dependen del resultado de S1, 1. Objetivo, 2. Alcance, 3. Decisiones heredadas (del roadmap, no se discuten en S1), 4. Decisiones tomadas en el brainstorming de S1 (+8 more)

### Community 21 - "Community 21"
Cohesion: 0.22
Nodes (9): code:swift (import XCTest), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:swift (import Foundation), code:swift (let decoder = JSONDecoder()), code:swift (func test_benchReport_codable_roundTrip() throws {), code:swift (let decoder = JSONDecoder()), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (cd /Users/hashdown/Projects/personal_agent) (+1 more)

### Community 22 - "Community 22"
Cohesion: 0.22
Nodes (9): code:swift (import Foundation), code:swift (// MARK: - Catalog state), code:swift (@ObservationIgnored), code:swift (refreshInstalled()), code:swift (public func refreshInstalled() {), code:swift (func test_catalog_isModelCatalogBuiltIn() {), code:bash (xcodebuild test ... -only-testing:GemmaTests/HarnessModelTes), code:bash (git commit -am "feat(harness): extend HarnessModel with cata) (+1 more)

### Community 23 - "Community 23"
Cohesion: 0.29
Nodes (6): code:block1 (Gemma/Gemma/), File structure produced by this plan, Out of scope (Plan 3 or later), Risks for Plan 3, S1 Runtime — Plan 2 of 4: Model Catalog + Downloader + Memory Pre-flight, Self-review notes

### Community 24 - "Community 24"
Cohesion: 0.33
Nodes (5): code:block1 (Gemma/Gemma/                                    (existing ap), File structure produced by this plan, Out of scope for this plan (handled by Plans 2 and 3), S1 Runtime — Plan 1 of 3: Scaffold + Protocol + Dummy Runtime + Bench Framework, Self-review summary

### Community 25 - "Community 25"
Cohesion: 0.33
Nodes (6): code:swift (import XCTest), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:swift (import Foundation), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (cd /Users/hashdown/Projects/personal_agent), Task 2: Define `ModelRuntime` protocol + value types

### Community 26 - "Community 26"
Cohesion: 0.33
Nodes (6): code:swift (import XCTest), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:swift (import Foundation), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (cd /Users/hashdown/Projects/personal_agent), Task 3: Implement `MemoryReporter` (Mach RSS reader)

### Community 27 - "Community 27"
Cohesion: 0.33
Nodes (6): code:bash (xcodebuild -version), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (mkdir -p /Users/hashdown/Projects/personal_agent/Gemma/Gemma), code:bash (grep -c "PBXFileSystemSynchronizedRootGroup" /Users/hashdown), code:bash (cd /Users/hashdown/Projects/personal_agent), Task 0: Preflight — verify Xcode and create folders on disk

### Community 28 - "Community 28"
Cohesion: 0.33
Nodes (6): code:swift (import XCTest), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:swift (import Foundation), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (cd /Users/hashdown/Projects/personal_agent), Task 4: Implement `DummyRuntime`

### Community 29 - "Community 29"
Cohesion: 0.33
Nodes (6): code:swift (import XCTest), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:swift (import Foundation), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (cd /Users/hashdown/Projects/personal_agent), Task 5: Define the fixed `PromptSet`

### Community 30 - "Community 30"
Cohesion: 0.33
Nodes (6): code:swift (import XCTest), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:swift (import Foundation), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (cd /Users/hashdown/Projects/personal_agent), Task 7: Implement `BenchRunner`

### Community 31 - "Community 31"
Cohesion: 0.33
Nodes (6): code:swift (import XCTest), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:swift (import Foundation), code:bash (xcodebuild test -project Gemma.xcodeproj -scheme Gemma \), code:bash (cd /Users/hashdown/Projects/personal_agent), Task 1: Define `ModelDescriptor` value type

### Community 32 - "Community 32"
Cohesion: 0.40
Nodes (5): code:swift (import SwiftUI), code:bash (rm /Users/hashdown/Projects/personal_agent/Gemma/Gemma/Conte), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (cd /Users/hashdown/Projects/personal_agent), Task 10: Wire `HarnessView` into `GemmaApp` and delete `ContentView`

### Community 33 - "Community 33"
Cohesion: 0.40
Nodes (5): code:swift (import XCTest), code:bash (xcodebuild test ... -only-testing:GemmaTests/ModelCatalogTes), code:swift (import Foundation), code:bash (git add -A), Task 2: Define `ModelCatalog` (static catalog of E4B + E2B)

### Community 34 - "Community 34"
Cohesion: 0.40
Nodes (5): code:swift (import XCTest), code:swift (import Foundation), code:bash (xcodebuild test ... -only-testing:GemmaTests/ModelDownloader), code:bash (git commit -am "feat(models): add ModelDownloader actor with), Task 5: Implement `ModelDownloader` actor with `URLSession` + Range resume

### Community 35 - "Community 35"
Cohesion: 0.40
Nodes (5): code:swift (import Foundation), code:swift (func test_runtimeKind_litertlmE4B_displayNameAndModelId() {), code:bash (xcodebuild test ... -only-testing:GemmaTests/RuntimeFactoryT), code:bash (git commit -am "feat(runtime): add .litertlmE4B and .litertl), Task 7: Extend `RuntimeKind` and `RuntimeFactory` for the two new kinds

### Community 36 - "Community 36"
Cohesion: 0.40
Nodes (5): code:swift (private var statusBar: some View {), code:swift (.sheet(isPresented: $model.showCatalog) {), code:bash (xcodebuild build ... 2>&1 | tail -3), code:bash (git commit -am "feat(harness): wire Models button + CatalogV), Task 10: Add Models button to `HarnessView` + sheet wiring

### Community 37 - "Community 37"
Cohesion: 0.50
Nodes (4): code:swift (import SwiftUI), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (cd /Users/hashdown/Projects/personal_agent), Task 8: Implement `ImagePickerView` (UIKit bridge)

### Community 38 - "Community 38"
Cohesion: 0.50
Nodes (4): code:swift (import SwiftUI), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (cd /Users/hashdown/Projects/personal_agent), Task 9: Implement `HarnessView` (main UI)

### Community 39 - "Community 39"
Cohesion: 0.50
Nodes (4): code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (xcrun simctl get_app_container booted lambert-dev-group.Gemm), code:bash (cd /Users/hashdown/Projects/personal_agent), Task 11: Run all tests + manual smoke on simulator

### Community 40 - "Community 40"
Cohesion: 0.50
Nodes (4): code:swift (import XCTest), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (cd /Users/hashdown/Projects/personal_agent), Task 1: Add a Unit Test target to the Xcode project

### Community 41 - "Community 41"
Cohesion: 0.50
Nodes (4): code:swift (import XCTest), code:swift (import Foundation), code:bash (git commit -am "feat(models): add DeviceCapability pre-fligh), Task 3: Implement `DeviceCapability` pre-flight

### Community 42 - "Community 42"
Cohesion: 0.50
Nodes (4): code:swift (import Foundation), code:bash (xcodebuild build -project Gemma.xcodeproj -scheme Gemma \), code:bash (git commit -am "feat(models): add DownloadEvent + DownloadEr), Task 4: Define `DownloadEvent` enum

### Community 43 - "Community 43"
Cohesion: 0.50
Nodes (4): code:bash (cd /Users/hashdown/Projects/personal_agent), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (mkdir -p /Users/hashdown/Projects/personal_agent/Gemma/Gemma), Task 0: Preflight — confirm starting state

### Community 44 - "Community 44"
Cohesion: 0.50
Nodes (4): code:swift (import XCTest), code:swift (import Foundation), code:bash (git commit -am "feat(models): add InstalledModels (filesyste), Task 6: Implement `InstalledModels` (filesystem listing + integrity)

### Community 45 - "Community 45"
Cohesion: 0.50
Nodes (4): code:swift (import SwiftUI), code:bash (xcodebuild build ... 2>&1 | tail -3), code:bash (git commit -am "feat(harness): add CatalogView (browse + dow), Task 9: Build `CatalogView` SwiftUI (list of models + status + actions)

### Community 46 - "Community 46"
Cohesion: 0.50
Nodes (4): code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (xcrun simctl boot "iPhone 17" 2>/dev/null || true), code:bash (cd /Users/hashdown/Projects/personal_agent), Task 11: Full test suite + launch smoke + tag

### Community 48 - "Community 48"
Cohesion: 0.07
Nodes (29): code:block1 (Gemma/Gemma/), code:swift (public var showBenchmark: Bool = false), code:swift (public func presentBenchmark() async {), code:bash (cd /Users/hashdown/Projects/personal_agent), code:swift (import SwiftUI), code:swift (Button("Run Bench") {), code:swift (Button("Benchmark") {), code:swift (.sheet(isPresented: $model.showBenchmark) {) (+21 more)

### Community 49 - "Community 49"
Cohesion: 0.06
Nodes (30): code:swift (import MLXLLM), code:swift (public enum ModelFormat: String, Sendable, Codable, Hashable), code:swift (public let format: ModelFormat), code:swift (format: ModelFormat = .litertlmFile,), code:swift (,), code:bash (git add Gemma/Gemma/Models/ModelDescriptor.swift Gemma/Gemma), code:swift (var mlxRepoId: String? = nil), code:swift (if descriptor.format == .mlxRepo {) (+22 more)

### Community 50 - "Community 50"
Cohesion: 0.14
Nodes (13): 1. Value types (package-agnostic — no LiteRTLM import), 2. `PerfBenchmarker` (imports LiteRTLM), 3. `BenchmarkModel` (@Observable @MainActor), 4. `BenchmarkView` (sheet), 5. `HarnessModel` / `HarnessView` integration, Components, Data flow, Error handling (+5 more)

### Community 51 - "Community 51"
Cohesion: 0.27
Nodes (4): BenchPromptResult, BenchReport, Codable, Equatable

### Community 52 - "Community 52"
Cohesion: 0.22
Nodes (8): GenerationEvent, completed, token, RuntimeError, generationFailed, loadFailed, modelNotFound, notLoaded

### Community 53 - "Community 53"
Cohesion: 0.12
Nodes (6): BenchmarkConfig, BenchmarkResult, BenchmarkRun, MTPComparison, BenchmarkTypesTests, PerfBenchmarker

### Community 54 - "Community 54"
Cohesion: 0.50
Nodes (3): FitDecision, insufficient, ok

### Community 55 - "Community 55"
Cohesion: 0.08
Nodes (24): code:block1 (Gemma/Gemma/), code:bash (cd /Users/hashdown/Projects/personal_agent), code:swift (Button {), code:swift (if let c = model.comparison {), code:swift (private func comparisonRow(_ label: String, _ off: String, _), code:bash (cd /Users/hashdown/Projects/personal_agent), code:bash (cd /Users/hashdown/Projects/personal_agent/Gemma), code:bash (cd /Users/hashdown/Projects/personal_agent) (+16 more)

### Community 56 - "Community 56"
Cohesion: 0.16
Nodes (3): LiteRTLMRuntime, MemoryReporter, GenerationResult

### Community 57 - "Community 57"
Cohesion: 0.13
Nodes (14): 1. `MTPComparison` (value type — append to `Gemma/Gemma/Bench/BenchmarkTypes.swift`), 2. `PerfBenchmarker.compareMTP(...)` (in `PerfBenchmarker.swift`, imports LiteRTLM), 3. `BenchmarkModel`, 4. `BenchmarkView`, 5. Report (authored after the device run, not code), code:block1 (public struct MTPComparison: Equatable, Sendable {), Components, Data flow (+6 more)

### Community 59 - "Community 59"
Cohesion: 0.22
Nodes (5): Mutex, ComputeBackend, cpu, gpu, Sendable

### Community 60 - "Community 60"
Cohesion: 0.05
Nodes (33): code:swift (public var supportsImage: Bool), code:bash (git add Gemma/Gemma/Runtime/ModelRuntime.swift Gemma/Gemma/R), code:swift (private var visionEnabled = false), code:swift (let backend: Backend = options.backend == .gpu ? .gpu : .cpu), code:swift (visionEnabled = false), code:swift (let task = Task { await self.streamGeneration(prompt: prompt), code:swift (var tempImageURL: URL?), code:bash (git add Gemma/Gemma/Runtime/LiteRTLMRuntime.swift) (+25 more)

### Community 61 - "Community 61"
Cohesion: 0.18
Nodes (12): Hashable, FitReason, insufficientDisk, insufficientRAM, ModelDescriptor, ModelFormat, litertlmFile, mlxRepo (+4 more)

### Community 62 - "Community 62"
Cohesion: 0.22
Nodes (8): 1. Resumen ejecutivo, 2. Comparación MTP off vs on, 3. Análisis, 4. Decisión, 5. Caveats, 6. Pendiente (Plan 4 / futuro), 7. Multimodal (imagen + audio) — S1.1 #5, S1 — Reporte del runtime (resultados medidos)

### Community 63 - "Community 63"
Cohesion: 0.17
Nodes (8): CaseIterable, MultimodalBackendsTests, MMAttempt, cpu, primary, textOnly, multimodalAttemptPlan(), multimodalBackends()

### Community 64 - "Community 64"
Cohesion: 0.14
Nodes (13): 1. Problema, 2. Objetivo, 3.1 Flujo de capacidad (descriptor → runtime), 3.2 Cascada de fallback en `LiteRTLMRuntime.load`, 3.3 Estado observable de multimodal, 3. Diseño (Enfoque A — capability-gated + fallback en cascada), 4. Pruebas y verificación, 5. Riesgos (+5 more)

### Community 65 - "Community 65"
Cohesion: 0.07
Nodes (25): code:swift (import XCTest), code:swift (if descriptor.format == .mlxRepo {), code:swift (var installed = installedStore.allInstalled(from: catalog)), code:bash (git add Gemma/Gemma/Harness/LoadAlert.swift Gemma/Gemma/Harn), code:swift (if descriptor.format == .mlxRepo {), code:bash (git add Gemma/Gemma/Harness/CatalogView.swift), code:swift (.alert(item: $model.loadAlert) { alert in), code:bash (git add Gemma/Gemma/Harness/HarnessView.swift) (+17 more)

### Community 67 - "Community 67"
Cohesion: 0.18
Nodes (3): MLXRuntime, ModelRuntime, RuntimeFactory

### Community 68 - "Community 68"
Cohesion: 0.18
Nodes (8): LoadAlert, Identifiable, ModelCatalog, RuntimeKind, dummy, litertlmE2B, litertlmE4B, mlx

### Community 71 - "Community 71"
Cohesion: 0.25
Nodes (7): 1. Problema y objetivo, 2. Arquitectura, 3. UI (alerta + navegación + highlight), 4. Pruebas, 5. Riesgos, 6. Entregables, S1.2.1 — Descarga explícita de modelos MLX — Diseño

### Community 72 - "Community 72"
Cohesion: 0.25
Nodes (7): 1. Problema y objetivo, 2. Arquitectura, 3. Secuenciación, 4. Pruebas, 5. Riesgos, 6. Entregables, S1.2 — Runtime MLX (modelo-agnóstico, texto + visión) — Diseño

### Community 73 - "Community 73"
Cohesion: 0.25
Nodes (3): GemmaTests, ImageTempFileTests, XCTestCase

### Community 80 - "Community 80"
Cohesion: 0.40
Nodes (4): Status, corrupted, installed, notInstalled

## Knowledge Gaps
- **436 isolated node(s):** `factual`, `conversational`, `long`, `image`, `es` (+431 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **19 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `ModelDownloaderTests` connect `Model Downloader` to `Community 73`?**
  _High betweenness centrality (0.063) - this node is a cross-community bridge._
- **Why does `HarnessModel` connect `Harness Orchestrator` to `Bench & Runtime Layer`, `Community 67`, `Community 68`, `Community 69`, `Community 70`, `SwiftUI App Shell`, `Installed Models Storage`, `Model Downloader`, `Device Capability`, `Community 18`, `Community 51`, `Community 61`?**
  _High betweenness centrality (0.063) - this node is a cross-community bridge._
- **Are the 15 inferred relationships involving `HarnessModel` (e.g. with `.test_catalog_isModelCatalogBuiltIn()` and `.test_deviceCapability_isRealisticForTestDevice()`) actually correct?**
  _`HarnessModel` has 15 INFERRED edges - model-reasoned connections that need verification._
- **Are the 13 inferred relationships involving `DummyRuntime` (e.g. with `.test_run_completedAtIsAfterStartedAt()` and `.test_run_executesAllNonImagePromptsAgainstRuntime()`) actually correct?**
  _`DummyRuntime` has 13 INFERRED edges - model-reasoned connections that need verification._
- **Are the 7 inferred relationships involving `LiteRTLMRuntime` (e.g. with `.test_generate_audio_producesNonEmptyOutput()` and `.test_generate_image_producesNonEmptyOutput()`) actually correct?**
  _`LiteRTLMRuntime` has 7 INFERRED edges - model-reasoned connections that need verification._
- **What connects `factual`, `conversational`, `long` to the rest of the system?**
  _439 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Bench & Runtime Layer` be split into smaller, more focused modules?**
  _Cohesion score 0.13043478260869565 - nodes in this community are weakly interconnected._