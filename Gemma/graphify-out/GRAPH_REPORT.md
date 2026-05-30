# Graph Report - Gemma  (2026-05-29)

## Corpus Check
- 58 files · ~13,751 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 434 nodes · 653 edges · 24 communities (17 shown, 7 thin omitted)
- Extraction: 80% EXTRACTED · 20% INFERRED · 0% AMBIGUOUS · INFERRED: 130 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `4a6b68f7`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 13|Community 13]]
- [[_COMMUNITY_Community 14|Community 14]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 23|Community 23]]

## God Nodes (most connected - your core abstractions)
1. `HarnessModel` - 25 edges
2. `DummyRuntime` - 21 edges
3. `InstalledModels` - 19 edges
4. `ModelLoadOptions` - 18 edges
5. `GenerationOptions` - 17 edges
6. `LiteRTLMRuntime` - 16 edges
7. `HarnessModelTests` - 16 edges
8. `RuntimeFactoryTests` - 15 edges
9. `GenerationSettings` - 13 edges
10. `InstalledModelsTests` - 13 edges

## Surprising Connections (you probably didn't know these)
- `LiteRTLMRuntime` --inherits--> `ModelRuntime`  [EXTRACTED]
  Gemma/Runtime/LiteRTLMRuntime.swift → Gemma/Runtime/ModelRuntime.swift
- `DummyRuntime` --inherits--> `ModelRuntime`  [EXTRACTED]
  Gemma/Runtime/DummyRuntime.swift → Gemma/Runtime/ModelRuntime.swift
- `MLXRuntime` --inherits--> `ModelRuntime`  [EXTRACTED]
  Gemma/Runtime/MLXRuntime.swift → Gemma/Runtime/ModelRuntime.swift

## Communities (24 total, 7 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.07
Nodes (9): BenchRunner, BenchRunnerTests, DummyRuntimeTests, LiteRTLMRuntimeTests, MLXRuntimeTests, DummyRuntime, LiteRTLMRuntime, GenerationOptions (+1 more)

### Community 1 - "Community 1"
Cohesion: 0.06
Nodes (7): GenerationSettingsTests, HarnessModelTests, SettingsStoreTests, DownloadProgress, HarnessModel, GenerationSettings, SettingsStore

### Community 2 - "Community 2"
Cohesion: 0.07
Nodes (39): BenchPrompt, PromptCategory, conversational, factual, image, long, PromptLanguage, en (+31 more)

### Community 3 - "Community 3"
Cohesion: 0.06
Nodes (25): BenchPromptResult, BenchReport, Equatable, Error, DownloadError, cancelled, httpError, insufficientDisk (+17 more)

### Community 4 - "Community 4"
Cohesion: 0.06
Nodes (7): GemmaTests, ImageTempFileTests, MemoryReporterTests, ModelCatalogTests, ModelDescriptorTests, PromptSetTests, XCTestCase

### Community 5 - "Community 5"
Cohesion: 0.12
Nodes (6): BenchmarkConfig, BenchmarkResult, BenchmarkRun, MTPComparison, BenchmarkTypesTests, PerfBenchmarker

### Community 6 - "Community 6"
Cohesion: 0.13
Nodes (5): MockURLProtocol, ModelDownloaderTests, Response, ModelDownloader, URLProtocol

### Community 8 - "Community 8"
Cohesion: 0.12
Nodes (4): MLXGenerateParametersTests, mlxGenerateParameters(), MLXRuntime, RuntimeFactory

### Community 9 - "Community 9"
Cohesion: 0.16
Nodes (5): DeviceCapabilityTests, DeviceCapability, FitDecision, insufficient, ok

### Community 10 - "Community 10"
Cohesion: 0.17
Nodes (8): CaseIterable, MultimodalBackendsTests, MMAttempt, cpu, primary, textOnly, multimodalAttemptPlan(), multimodalBackends()

### Community 12 - "Community 12"
Cohesion: 0.14
Nodes (6): BenchmarkView, CatalogView, ModelRow, HarnessView, SettingsView, View

### Community 13 - "Community 13"
Cohesion: 0.17
Nodes (6): Coordinator, ImagePickerView, NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIViewControllerRepresentable

### Community 14 - "Community 14"
Cohesion: 0.19
Nodes (3): BenchReportTests, ModelRuntimeTypesTests, RuntimeMetrics

### Community 15 - "Community 15"
Cohesion: 0.40
Nodes (4): colors, info, author, version

### Community 16 - "Community 16"
Cohesion: 0.40
Nodes (4): images, info, author, version

### Community 17 - "Community 17"
Cohesion: 0.40
Nodes (4): images, info, author, version

### Community 20 - "Community 20"
Cohesion: 0.50
Nodes (3): info, author, version

## Knowledge Gaps
- **54 isolated node(s):** `factual`, `conversational`, `long`, `image`, `es` (+49 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **7 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `InstalledModels` connect `Community 7` to `Community 1`, `Community 2`, `Community 3`?**
  _High betweenness centrality (0.070) - this node is a cross-community bridge._
- **Why does `ModelDownloaderTests` connect `Community 6` to `Community 4`?**
  _High betweenness centrality (0.068) - this node is a cross-community bridge._
- **Why does `GenerationOptions` connect `Community 0` to `Community 8`, `Community 1`, `Community 2`, `Community 14`?**
  _High betweenness centrality (0.064) - this node is a cross-community bridge._
- **Are the 13 inferred relationships involving `HarnessModel` (e.g. with `.test_catalog_isModelCatalogBuiltIn()` and `.test_deviceCapability_isRealisticForTestDevice()`) actually correct?**
  _`HarnessModel` has 13 INFERRED edges - model-reasoned connections that need verification._
- **Are the 12 inferred relationships involving `DummyRuntime` (e.g. with `.test_run_completedAtIsAfterStartedAt()` and `.test_run_executesAllNonImagePromptsAgainstRuntime()`) actually correct?**
  _`DummyRuntime` has 12 INFERRED edges - model-reasoned connections that need verification._
- **What connects `factual`, `conversational`, `long` to the rest of the system?**
  _54 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.06868686868686869 - nodes in this community are weakly interconnected._