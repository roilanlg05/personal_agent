# S1 Runtime — Plan 2 of 4: Model Catalog + Downloader + Memory Pre-flight

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the infrastructure that gets a `.litertlm` model file from the network onto the iPhone, BEFORE any real model runtime exists. After this plan: the app shows a browsable model catalog, checks device fit (RAM + disk), downloads via Hugging Face HTTP with progress and resume, lists installed models, and exposes the path to a downloaded model file. The actual LiteRT-LM runtime that consumes the file is Plan 3.

**Architecture:** Three independently testable layers stacked behind `HarnessModel`:
1. `ModelCatalog` — pure data: a `ModelDescriptor` per model (id, displayName, modelFile, sourceURL, sizeInBytes, minDeviceMemoryGB, multimodal flags). Hard-coded subset of the Google AI Edge Gallery catalog for E4B + E2B.
2. `DeviceCapability` — synchronous pre-flight reading free disk + total RAM + a `fits(_: ModelDescriptor)` decision.
3. `ModelDownloader` — actor backed by `URLSession`, exposing an `AsyncStream<DownloadEvent>` for progress, supporting HTTP Range resume, atomic completion via `.partial` → final rename, cancellation.

Layered on top: `InstalledModels` (lists what's in `Documents/Models/`), a SwiftUI `CatalogView` (model list + status + download button), a `DownloadView` (progress + cancel), and integration into `HarnessView` via a `Models` tab. `RuntimeKind` adds `.litertlmE4B` and `.litertlmE2B` but `RuntimeFactory.make` for those still returns `DummyRuntime` (Plan 3 swaps in the real runtime; nothing in this plan breaks the existing test suite).

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Concurrency, `URLSession` (no third-party deps), `Observation` (@Observable), XCTest, Xcode 16.2+, iOS 17+ target.

**Position in series:** Plan 2 of 4 for spec `01-s1-runtime.md` (S1 Runtime). Previous: `s1-plan1-refactored` (tag). Next: Plan 3 (LiteRT-LM real runtime), Plan 4 (llama.cpp + mmap + final S1 report).

---

## File structure produced by this plan

```
Gemma/Gemma/
├── Runtime/
│   └── RuntimeFactory.swift                (modified — adds .litertlmE4B / .litertlmE2B kinds; factory still returns DummyRuntime)
├── Models/                                  (new folder)
│   ├── ModelDescriptor.swift               (catalog data type)
│   ├── ModelCatalog.swift                  (static catalog: E4B + E2B)
│   ├── DeviceCapability.swift              (RAM + disk pre-flight)
│   ├── ModelDownloader.swift               (actor + URLSession + Range resume)
│   ├── DownloadEvent.swift                 (event type for the AsyncStream)
│   └── InstalledModels.swift               (filesystem listing + integrity)
└── Harness/
    ├── HarnessModel.swift                  (modified — selectedModel, installedModels, downloads dict)
    ├── HarnessView.swift                   (modified — tabbed: Chat / Models)
    ├── CatalogView.swift                   (new — list of catalog + installed)
    └── DownloadView.swift                  (new — sheet with progress + cancel)

Gemma/GemmaTests/
├── ModelDescriptorTests.swift              (new)
├── ModelCatalogTests.swift                 (new)
├── DeviceCapabilityTests.swift             (new)
├── ModelDownloaderTests.swift              (new — URLProtocol mock)
├── InstalledModelsTests.swift              (new)
└── HarnessModelTests.swift                 (modified — add 2 new tests)
```

**Responsibility per file:**
- `ModelDescriptor.swift`: value type only, no logic.
- `ModelCatalog.swift`: static array, accessors by `id`. No I/O.
- `DeviceCapability.swift`: pure read of system info + decision function. No state.
- `ModelDownloader.swift`: only HTTP + filesystem write + progress events. Knows nothing about the catalog.
- `DownloadEvent.swift`: enum cases only.
- `InstalledModels.swift`: listing + size check in `Documents/Models/`. No download.
- `CatalogView.swift`: pure SwiftUI, observes `HarnessModel`.
- `DownloadView.swift`: pure SwiftUI sheet, observes `HarnessModel.downloads[modelId]`.

---

## Task 0: Preflight — confirm starting state

**Files:** none.

- [ ] **Step 1: Confirm we are at tag `s1-plan1-refactored`**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent
git describe --tags --abbrev=0
git status
```
Expected: tag `s1-plan1-refactored`. `git status` clean.

- [ ] **Step 2: Confirm test baseline (34 green)**

Run:
```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "(TEST SUCCEEDED|Executed)" | tail -3
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Create the `Models/` source folder**

```bash
mkdir -p /Users/hashdown/Projects/personal_agent/Gemma/Gemma/Models
```

No commit yet — folder is empty.

---

## Task 1: Define `ModelDescriptor` value type

**Files:**
- Create: `Gemma/Gemma/Models/ModelDescriptor.swift`
- Create: `Gemma/GemmaTests/ModelDescriptorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/ModelDescriptorTests.swift`:

```swift
import XCTest
@testable import Gemma

final class ModelDescriptorTests: XCTestCase {
    private let sample = ModelDescriptor(
        id: "gemma-4-e4b-it",
        displayName: "Gemma 4 E4B",
        modelFile: "gemma-4-E4B-it.litertlm",
        sourceURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/28299f30ee4d43294517a4ac93abd6163412f07f/gemma-4-E4B-it.litertlm")!,
        sizeInBytes: 3_659_530_240,
        minDeviceMemoryGB: 8,
        supportsImage: true,
        supportsAudio: true,
        supportsSpeculativeDecoding: true,
        maxContextLength: 32_000,
        license: .gemmaTermsOfUse
    )

    func test_descriptor_sizeInMB_isCorrect() {
        XCTAssertEqual(sample.sizeInMB, 3489, accuracy: 1)
    }

    func test_descriptor_sizeInGB_isCorrect() {
        XCTAssertEqual(sample.sizeInGB, 3.41, accuracy: 0.01)
    }

    func test_descriptor_codable_roundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(sample)
        let decoded = try decoder.decode(ModelDescriptor.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_descriptor_idIsHashable() {
        let set: Set<ModelDescriptor> = [sample, sample]
        XCTAssertEqual(set.count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GemmaTests/ModelDescriptorTests 2>&1 | tail -10
```
Expected: compile errors — `ModelDescriptor` not found.

- [ ] **Step 3: Implement**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Models/ModelDescriptor.swift`:

```swift
import Foundation

public enum ModelLicense: String, Sendable, Codable, Hashable {
    case gemmaTermsOfUse
    case apache2
    case other
}

public struct ModelDescriptor: Sendable, Codable, Hashable, Identifiable {
    public let id: String                           // canonical id e.g. "gemma-4-e4b-it"
    public let displayName: String                  // user-facing
    public let modelFile: String                    // filename on disk e.g. "gemma-4-E4B-it.litertlm"
    public let sourceURL: URL                       // direct HTTP URL to the model file
    public let sizeInBytes: Int64
    public let minDeviceMemoryGB: Int               // from the Google catalog
    public let supportsImage: Bool
    public let supportsAudio: Bool
    public let supportsSpeculativeDecoding: Bool
    public let maxContextLength: Int
    public let license: ModelLicense

    public init(
        id: String,
        displayName: String,
        modelFile: String,
        sourceURL: URL,
        sizeInBytes: Int64,
        minDeviceMemoryGB: Int,
        supportsImage: Bool,
        supportsAudio: Bool,
        supportsSpeculativeDecoding: Bool,
        maxContextLength: Int,
        license: ModelLicense
    ) {
        self.id = id
        self.displayName = displayName
        self.modelFile = modelFile
        self.sourceURL = sourceURL
        self.sizeInBytes = sizeInBytes
        self.minDeviceMemoryGB = minDeviceMemoryGB
        self.supportsImage = supportsImage
        self.supportsAudio = supportsAudio
        self.supportsSpeculativeDecoding = supportsSpeculativeDecoding
        self.maxContextLength = maxContextLength
        self.license = license
    }

    public var sizeInMB: Double {
        Double(sizeInBytes) / (1024.0 * 1024.0)
    }
    public var sizeInGB: Double {
        Double(sizeInBytes) / (1024.0 * 1024.0 * 1024.0)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:GemmaTests/ModelDescriptorTests 2>&1 | tail -10
```
Expected: 4 tests passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/hashdown/Projects/personal_agent
git add -A
git commit -m "feat(models): add ModelDescriptor value type

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Define `ModelCatalog` (static catalog of E4B + E2B)

**Files:**
- Create: `Gemma/Gemma/Models/ModelCatalog.swift`
- Create: `Gemma/GemmaTests/ModelCatalogTests.swift`

- [ ] **Step 1: Write failing tests**

Create `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/ModelCatalogTests.swift`:

```swift
import XCTest
@testable import Gemma

final class ModelCatalogTests: XCTestCase {
    func test_builtIn_containsE4BAndE2B() {
        let ids = Set(ModelCatalog.builtIn.map(\.id))
        XCTAssertTrue(ids.contains("gemma-4-e4b-it"))
        XCTAssertTrue(ids.contains("gemma-4-e2b-it"))
    }

    func test_builtIn_e4b_metadataMatchesGoogleCatalog() {
        guard let e4b = ModelCatalog.find("gemma-4-e4b-it") else {
            return XCTFail("E4B descriptor missing")
        }
        XCTAssertEqual(e4b.modelFile, "gemma-4-E4B-it.litertlm")
        XCTAssertEqual(e4b.sizeInBytes, 3_659_530_240)
        XCTAssertEqual(e4b.minDeviceMemoryGB, 8)
        XCTAssertEqual(e4b.maxContextLength, 32_000)
        XCTAssertTrue(e4b.supportsImage)
        XCTAssertTrue(e4b.supportsAudio)
        XCTAssertTrue(e4b.supportsSpeculativeDecoding)
    }

    func test_builtIn_e2b_metadataMatchesGoogleCatalog() {
        guard let e2b = ModelCatalog.find("gemma-4-e2b-it") else {
            return XCTFail("E2B descriptor missing")
        }
        XCTAssertEqual(e2b.modelFile, "gemma-4-E2B-it.litertlm")
        XCTAssertEqual(e2b.sizeInBytes, 2_588_147_712)
        XCTAssertEqual(e2b.minDeviceMemoryGB, 6)
        XCTAssertEqual(e2b.maxContextLength, 32_000)
    }

    func test_find_unknownId_returnsNil() {
        XCTAssertNil(ModelCatalog.find("does-not-exist"))
    }

    func test_builtIn_idsAreUnique() {
        let ids = ModelCatalog.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
```

- [ ] **Step 2: Run tests to fail**

```bash
xcodebuild test ... -only-testing:GemmaTests/ModelCatalogTests
```
Expected: compile errors.

- [ ] **Step 3: Implement**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Models/ModelCatalog.swift`:

```swift
import Foundation

/// Static catalog of supported models. Mirrors the relevant entries from the Google AI Edge Gallery iOS catalog.
public enum ModelCatalog {
    public static let builtIn: [ModelDescriptor] = [
        ModelDescriptor(
            id: "gemma-4-e4b-it",
            displayName: "Gemma 4 E4B",
            modelFile: "gemma-4-E4B-it.litertlm",
            sourceURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/28299f30ee4d43294517a4ac93abd6163412f07f/gemma-4-E4B-it.litertlm")!,
            sizeInBytes: 3_659_530_240,
            minDeviceMemoryGB: 8,
            supportsImage: true,
            supportsAudio: true,
            supportsSpeculativeDecoding: true,
            maxContextLength: 32_000,
            license: .gemmaTermsOfUse
        ),
        ModelDescriptor(
            id: "gemma-4-e2b-it",
            displayName: "Gemma 4 E2B",
            modelFile: "gemma-4-E2B-it.litertlm",
            sourceURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/6e5c4f1e395deb959c494953478fa5cec4b8008f/gemma-4-E2B-it.litertlm")!,
            sizeInBytes: 2_588_147_712,
            minDeviceMemoryGB: 6,
            supportsImage: true,
            supportsAudio: true,
            supportsSpeculativeDecoding: true,
            maxContextLength: 32_000,
            license: .gemmaTermsOfUse
        )
    ]

    public static func find(_ id: String) -> ModelDescriptor? {
        builtIn.first { $0.id == id }
    }
}
```

- [ ] **Step 4: Run tests pass**

Expected: 5 tests passed.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(models): add ModelCatalog with Gemma 4 E4B and E2B entries

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Implement `DeviceCapability` pre-flight

**Files:**
- Create: `Gemma/Gemma/Models/DeviceCapability.swift`
- Create: `Gemma/GemmaTests/DeviceCapabilityTests.swift`

- [ ] **Step 1: Write failing tests**

Create `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/DeviceCapabilityTests.swift`:

```swift
import XCTest
@testable import Gemma

final class DeviceCapabilityTests: XCTestCase {
    func test_current_reportsNonZeroRAMandDisk() {
        let cap = DeviceCapability.current()
        XCTAssertGreaterThan(cap.totalRAMBytes, 0)
        XCTAssertGreaterThan(cap.freeDiskBytes, 0)
    }

    func test_fits_acceptsModelWhenRAMAndDiskAreSufficient() {
        let cap = DeviceCapability(
            totalRAMBytes: UInt64(16) * 1024 * 1024 * 1024,
            freeDiskBytes: UInt64(50) * 1024 * 1024 * 1024
        )
        let desc = ModelCatalog.find("gemma-4-e4b-it")!
        let decision = cap.fits(desc)
        switch decision {
        case .ok: break
        case .insufficient(let reasons):
            XCTFail("Expected .ok, got insufficient: \(reasons)")
        }
    }

    func test_fits_rejectsForInsufficientRAM() {
        let cap = DeviceCapability(
            totalRAMBytes: UInt64(4) * 1024 * 1024 * 1024,
            freeDiskBytes: UInt64(50) * 1024 * 1024 * 1024
        )
        let desc = ModelCatalog.find("gemma-4-e4b-it")!
        guard case .insufficient(let reasons) = cap.fits(desc) else {
            return XCTFail("Expected .insufficient")
        }
        XCTAssertTrue(reasons.contains(.insufficientRAM(requiredGB: 8, actualGB: 4)))
    }

    func test_fits_rejectsForInsufficientDisk() {
        let cap = DeviceCapability(
            totalRAMBytes: UInt64(16) * 1024 * 1024 * 1024,
            freeDiskBytes: UInt64(2) * 1024 * 1024 * 1024
        )
        let desc = ModelCatalog.find("gemma-4-e4b-it")!
        guard case .insufficient(let reasons) = cap.fits(desc) else {
            return XCTFail("Expected .insufficient")
        }
        XCTAssertTrue(reasons.contains(where: {
            if case .insufficientDisk = $0 { return true } else { return false }
        }))
    }
}
```

- [ ] **Step 2: Run tests to fail**

Expected: compile errors.

- [ ] **Step 3: Implement**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Models/DeviceCapability.swift`:

```swift
import Foundation

public struct DeviceCapability: Sendable, Equatable {
    public let totalRAMBytes: UInt64
    public let freeDiskBytes: UInt64

    public init(totalRAMBytes: UInt64, freeDiskBytes: UInt64) {
        self.totalRAMBytes = totalRAMBytes
        self.freeDiskBytes = freeDiskBytes
    }

    public static func current() -> DeviceCapability {
        DeviceCapability(
            totalRAMBytes: ProcessInfo.processInfo.physicalMemory,
            freeDiskBytes: freeDiskBytesAtHome()
        )
    }

    public enum FitDecision: Sendable, Equatable {
        case ok
        case insufficient(reasons: [FitReason])
    }

    public enum FitReason: Sendable, Equatable, Hashable {
        case insufficientRAM(requiredGB: Int, actualGB: Int)
        case insufficientDisk(requiredBytes: Int64, actualBytes: Int64)
    }

    public func fits(_ descriptor: ModelDescriptor) -> FitDecision {
        var reasons: [FitReason] = []
        let actualRAMGB = Int(totalRAMBytes / (1024 * 1024 * 1024))
        if actualRAMGB < descriptor.minDeviceMemoryGB {
            reasons.append(.insufficientRAM(
                requiredGB: descriptor.minDeviceMemoryGB,
                actualGB: actualRAMGB
            ))
        }
        // Demand at least 1.5× the model size in free disk to accommodate the
        // .partial download file plus the final atomic rename.
        let requiredDisk = Int64(Double(descriptor.sizeInBytes) * 1.5)
        if Int64(freeDiskBytes) < requiredDisk {
            reasons.append(.insufficientDisk(
                requiredBytes: requiredDisk,
                actualBytes: Int64(freeDiskBytes)
            ))
        }
        return reasons.isEmpty ? .ok : .insufficient(reasons: reasons)
    }

    private static func freeDiskBytesAtHome() -> UInt64 {
        let path = NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber else {
            return 0
        }
        return free.uint64Value
    }
}
```

- [ ] **Step 4: Tests pass**

Expected: 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(models): add DeviceCapability pre-flight check

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Define `DownloadEvent` enum

**Files:**
- Create: `Gemma/Gemma/Models/DownloadEvent.swift`

> No tests for this enum on its own — it's exercised through `ModelDownloader` tests.

- [ ] **Step 1: Implement**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Models/DownloadEvent.swift`:

```swift
import Foundation

public enum DownloadEvent: Sendable {
    /// Bytes transferred so far / total bytes (total may be 0 if server didn't send Content-Length).
    case progress(bytesDownloaded: Int64, totalBytes: Int64)
    /// Final file URL on disk. Always the last event on success.
    case completed(URL)
    /// Stream finishes with `throw error` if cancelled or failed.
}

public enum DownloadError: Error, Sendable, Equatable {
    case cancelled
    case httpError(statusCode: Int)
    case unexpectedResponse
    case insufficientDisk
    case io(String)
}
```

- [ ] **Step 2: Verify build**

```bash
xcodebuild build -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(models): add DownloadEvent + DownloadError

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Implement `ModelDownloader` actor with `URLSession` + Range resume

**Files:**
- Create: `Gemma/Gemma/Models/ModelDownloader.swift`
- Create: `Gemma/GemmaTests/ModelDownloaderTests.swift`

> Tests use a custom `URLProtocol` subclass to mock HTTP responses (no real network).

- [ ] **Step 1: Write failing tests**

Create `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/ModelDownloaderTests.swift`:

```swift
import XCTest
@testable import Gemma

final class ModelDownloaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModelDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        MockURLProtocol.reset()
    }

    func test_download_writesFileAndYieldsCompletedEvent() async throws {
        let payload = Data(repeating: 0xAB, count: 1024)
        MockURLProtocol.responseFor = { _ in
            MockURLProtocol.Response(
                statusCode: 200,
                headers: ["Content-Length": "1024"],
                body: payload
            )
        }

        let downloader = ModelDownloader(
            session: makeMockedSession(),
            destinationDir: tempDir
        )
        let url = URL(string: "https://mock/model.bin")!

        var lastProgress: (Int64, Int64) = (0, 0)
        var completedURL: URL?
        for try await event in downloader.download(from: url, filename: "model.bin") {
            switch event {
            case .progress(let downloaded, let total):
                lastProgress = (downloaded, total)
            case .completed(let final):
                completedURL = final
            }
        }
        XCTAssertEqual(lastProgress.0, 1024)
        XCTAssertEqual(lastProgress.1, 1024)
        XCTAssertNotNil(completedURL)
        XCTAssertEqual(try Data(contentsOf: completedURL!), payload)
    }

    func test_download_httpErrorThrowsViaStream() async {
        MockURLProtocol.responseFor = { _ in
            MockURLProtocol.Response(statusCode: 404, headers: [:], body: Data())
        }
        let downloader = ModelDownloader(session: makeMockedSession(), destinationDir: tempDir)
        do {
            for try await _ in downloader.download(from: URL(string: "https://mock/missing")!, filename: "x.bin") {}
            XCTFail("Expected DownloadError.httpError")
        } catch DownloadError.httpError(let code) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_download_resumesFromPartialFile() async throws {
        let full = Data(repeating: 0x42, count: 2048)
        let partial = full.prefix(1024)
        // Place existing partial file
        let partialURL = tempDir.appendingPathComponent("resume.bin.partial")
        try partial.write(to: partialURL)

        MockURLProtocol.responseFor = { request in
            // Server must see Range header.
            let range = request.value(forHTTPHeaderField: "Range")
            XCTAssertEqual(range, "bytes=1024-")
            let remainder = full.suffix(1024)
            return MockURLProtocol.Response(
                statusCode: 206,
                headers: [
                    "Content-Length": "1024",
                    "Content-Range": "bytes 1024-2047/2048"
                ],
                body: Data(remainder)
            )
        }

        let downloader = ModelDownloader(session: makeMockedSession(), destinationDir: tempDir)
        var completed: URL?
        for try await event in downloader.download(from: URL(string: "https://mock/resume.bin")!, filename: "resume.bin") {
            if case .completed(let u) = event { completed = u }
        }
        XCTAssertEqual(try Data(contentsOf: completed!), full)
    }

    // MARK: helpers
    private func makeMockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// Minimal URLProtocol mock: tests inject a static response handler.
final class MockURLProtocol: URLProtocol {
    struct Response { let statusCode: Int; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var responseFor: ((URLRequest) -> Response)?
    static func reset() { responseFor = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = MockURLProtocol.responseFor else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let response = handler(request)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: Run tests to fail**

Expected: compile errors — `ModelDownloader` missing.

- [ ] **Step 3: Implement**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Models/ModelDownloader.swift`:

```swift
import Foundation

public actor ModelDownloader {
    private let session: URLSession
    private let destinationDir: URL
    private let fileManager: FileManager

    public init(
        session: URLSession = .shared,
        destinationDir: URL,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.destinationDir = destinationDir
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
    }

    /// Streams progress events until the file is fully downloaded or an error is thrown.
    /// Resumes from an existing `<filename>.partial` if present.
    public func download(from url: URL, filename: String) -> AsyncThrowingStream<DownloadEvent, Error> {
        let finalURL = destinationDir.appendingPathComponent(filename)
        let partialURL = destinationDir.appendingPathComponent(filename + ".partial")
        let session = self.session
        let fm = self.fileManager

        return AsyncThrowingStream { continuation in
            let task = Task {
                let existingBytes = Self.fileSize(at: partialURL, fileManager: fm)
                var request = URLRequest(url: url)
                if existingBytes > 0 {
                    request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
                }

                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: DownloadError.unexpectedResponse)
                        return
                    }
                    guard http.statusCode == 200 || http.statusCode == 206 else {
                        continuation.finish(throwing: DownloadError.httpError(statusCode: http.statusCode))
                        return
                    }

                    let contentLength = http.expectedContentLength
                    let totalBytes: Int64 = (existingBytes > 0 && http.statusCode == 206)
                        ? existingBytes + contentLength
                        : contentLength

                    // Append (or create) the .partial file.
                    if !fm.fileExists(atPath: partialURL.path) {
                        fm.createFile(atPath: partialURL.path, contents: nil)
                    }
                    let handle = try FileHandle(forWritingTo: partialURL)
                    try handle.seekToEnd()

                    var downloaded: Int64 = existingBytes
                    var buffer = Data()
                    buffer.reserveCapacity(64 * 1024)
                    let flushThreshold = 64 * 1024
                    var lastReport: Date = .distantPast

                    for try await byte in bytes {
                        if Task.isCancelled {
                            try? handle.close()
                            continuation.finish(throwing: DownloadError.cancelled)
                            return
                        }
                        buffer.append(byte)
                        if buffer.count >= flushThreshold {
                            try handle.write(contentsOf: buffer)
                            downloaded += Int64(buffer.count)
                            buffer.removeAll(keepingCapacity: true)
                            // throttle progress events
                            let now = Date()
                            if now.timeIntervalSince(lastReport) > 0.1 {
                                continuation.yield(.progress(bytesDownloaded: downloaded, totalBytes: totalBytes))
                                lastReport = now
                            }
                        }
                    }
                    if !buffer.isEmpty {
                        try handle.write(contentsOf: buffer)
                        downloaded += Int64(buffer.count)
                    }
                    try handle.close()

                    // Atomic rename
                    if fm.fileExists(atPath: finalURL.path) {
                        try fm.removeItem(at: finalURL)
                    }
                    try fm.moveItem(at: partialURL, to: finalURL)

                    continuation.yield(.progress(bytesDownloaded: downloaded, totalBytes: totalBytes))
                    continuation.yield(.completed(finalURL))
                    continuation.finish()
                } catch let urlErr as URLError where urlErr.code == .cancelled {
                    continuation.finish(throwing: DownloadError.cancelled)
                } catch let dlErr as DownloadError {
                    continuation.finish(throwing: dlErr)
                } catch {
                    continuation.finish(throwing: DownloadError.io("\(error)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }
}
```

- [ ] **Step 4: Run tests pass**

```bash
xcodebuild test ... -only-testing:GemmaTests/ModelDownloaderTests
```
Expected: 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(models): add ModelDownloader actor with URLSession + Range resume

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Implement `InstalledModels` (filesystem listing + integrity)

**Files:**
- Create: `Gemma/Gemma/Models/InstalledModels.swift`
- Create: `Gemma/GemmaTests/InstalledModelsTests.swift`

- [ ] **Step 1: Write failing tests**

Create `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/InstalledModelsTests.swift`:

```swift
import XCTest
@testable import Gemma

final class InstalledModelsTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InstalledModelsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func test_status_returnsNotInstalledWhenFileAbsent() {
        let store = InstalledModels(rootDir: dir)
        let desc = ModelCatalog.find("gemma-4-e4b-it")!
        XCTAssertEqual(store.status(of: desc), .notInstalled)
    }

    func test_status_returnsCorruptedWhenFileSizeMismatches() throws {
        let desc = ModelCatalog.find("gemma-4-e4b-it")!
        try Data(repeating: 0, count: 32).write(to: dir.appendingPathComponent(desc.modelFile))
        let store = InstalledModels(rootDir: dir)
        XCTAssertEqual(store.status(of: desc), .corrupted(actualSize: 32, expectedSize: desc.sizeInBytes))
    }

    func test_status_returnsInstalledWhenSizeMatches() throws {
        let desc = ModelCatalog.find("gemma-4-e2b-it")!
        let fileURL = dir.appendingPathComponent(desc.modelFile)
        // Make a file of exactly the expected size (sparse via truncate)
        let fh = try FileHandle(forWritingTo: createEmptyFile(at: fileURL))
        try fh.truncate(atOffset: UInt64(desc.sizeInBytes))
        try fh.close()
        let store = InstalledModels(rootDir: dir)
        XCTAssertEqual(store.status(of: desc), .installed(at: fileURL))
    }

    func test_remove_deletesFile() throws {
        let desc = ModelCatalog.find("gemma-4-e2b-it")!
        let fileURL = dir.appendingPathComponent(desc.modelFile)
        try Data().write(to: createEmptyFile(at: fileURL))
        let store = InstalledModels(rootDir: dir)
        try store.remove(desc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func test_allInstalled_listsOnlyExistingMatches() throws {
        let e4b = ModelCatalog.find("gemma-4-e4b-it")!
        let e2bURL = dir.appendingPathComponent(ModelCatalog.find("gemma-4-e2b-it")!.modelFile)
        let fh = try FileHandle(forWritingTo: createEmptyFile(at: e2bURL))
        try fh.truncate(atOffset: UInt64(ModelCatalog.find("gemma-4-e2b-it")!.sizeInBytes))
        try fh.close()
        let store = InstalledModels(rootDir: dir)
        let installed = store.allInstalled(from: ModelCatalog.builtIn)
        XCTAssertEqual(installed.map(\.id), ["gemma-4-e2b-it"])
        XCTAssertFalse(installed.contains(e4b))
    }

    private func createEmptyFile(at url: URL) -> URL {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }
}
```

- [ ] **Step 2: Run tests to fail**

Expected: compile errors.

- [ ] **Step 3: Implement**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Models/InstalledModels.swift`:

```swift
import Foundation

public struct InstalledModels: Sendable {
    public enum Status: Sendable, Equatable {
        case notInstalled
        case installed(at: URL)
        case corrupted(actualSize: Int64, expectedSize: Int64)
    }

    public let rootDir: URL
    private let fileManager: FileManager

    public init(rootDir: URL, fileManager: FileManager = .default) {
        self.rootDir = rootDir
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    /// `Documents/Models/` for the running app. Used in production.
    public static func defaultInDocuments() -> InstalledModels {
        let docs = (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return InstalledModels(rootDir: docs.appendingPathComponent("Models", isDirectory: true))
    }

    public func fileURL(for descriptor: ModelDescriptor) -> URL {
        rootDir.appendingPathComponent(descriptor.modelFile)
    }

    public func status(of descriptor: ModelDescriptor) -> Status {
        let url = fileURL(for: descriptor)
        guard fileManager.fileExists(atPath: url.path) else { return .notInstalled }
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return .corrupted(actualSize: 0, expectedSize: descriptor.sizeInBytes)
        }
        let actual = size.int64Value
        if actual == descriptor.sizeInBytes {
            return .installed(at: url)
        } else {
            return .corrupted(actualSize: actual, expectedSize: descriptor.sizeInBytes)
        }
    }

    public func remove(_ descriptor: ModelDescriptor) throws {
        let url = fileURL(for: descriptor)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func allInstalled(from catalog: [ModelDescriptor]) -> [ModelDescriptor] {
        catalog.filter {
            if case .installed = status(of: $0) { return true } else { return false }
        }
    }
}
```

- [ ] **Step 4: Tests pass**

Expected: 5 tests passed.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(models): add InstalledModels (filesystem listing + integrity)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Extend `RuntimeKind` and `RuntimeFactory` for the two new kinds

**Files:**
- Modify: `Gemma/Gemma/Runtime/RuntimeFactory.swift`
- Modify: `Gemma/GemmaTests/RuntimeFactoryTests.swift`

> The factory still returns `DummyRuntime` for the new kinds — Plan 3 swaps in `LiteRTLMRuntime`. The point of this task is just to make the new kinds available in the UI picker so Plan 2 can wire installation state to runtime selection.

- [ ] **Step 1: Update the enum and factory**

Replace `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Runtime/RuntimeFactory.swift` with:

```swift
import Foundation

public enum RuntimeKind: String, Sendable, CaseIterable, Codable, Hashable, Identifiable {
    case dummy
    case litertlmE4B
    case litertlmE2B
    // Plan 4 adds: case llamacpp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dummy: return "Dummy (no model)"
        case .litertlmE4B: return "Gemma 4 E4B (LiteRT-LM)"
        case .litertlmE2B: return "Gemma 4 E2B (LiteRT-LM)"
        }
    }

    /// The catalog id this runtime requires installed, or nil if it needs no model on disk.
    public var requiredModelId: String? {
        switch self {
        case .dummy: return nil
        case .litertlmE4B: return "gemma-4-e4b-it"
        case .litertlmE2B: return "gemma-4-e2b-it"
        }
    }
}

public enum RuntimeFactory {
    /// Returns a fresh runtime instance for the given kind. Caller owns the lifecycle.
    /// Plan 2 returns a DummyRuntime for the LiteRT-LM kinds; Plan 3 swaps in the real runtime.
    public static func make(_ kind: RuntimeKind) -> ModelRuntime {
        switch kind {
        case .dummy, .litertlmE4B, .litertlmE2B:
            return DummyRuntime()
        }
    }
}
```

- [ ] **Step 2: Extend tests**

Append to `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/RuntimeFactoryTests.swift`:

```swift
    func test_runtimeKind_litertlmE4B_displayNameAndModelId() {
        let kind = RuntimeKind.litertlmE4B
        XCTAssertEqual(kind.displayName, "Gemma 4 E4B (LiteRT-LM)")
        XCTAssertEqual(kind.requiredModelId, "gemma-4-e4b-it")
    }

    func test_runtimeKind_litertlmE2B_displayNameAndModelId() {
        let kind = RuntimeKind.litertlmE2B
        XCTAssertEqual(kind.displayName, "Gemma 4 E2B (LiteRT-LM)")
        XCTAssertEqual(kind.requiredModelId, "gemma-4-e2b-it")
    }

    func test_runtimeKind_dummy_requiresNoModel() {
        XCTAssertNil(RuntimeKind.dummy.requiredModelId)
    }

    func test_runtimeKind_allCases_includesNewKinds() {
        XCTAssertTrue(RuntimeKind.allCases.contains(.litertlmE4B))
        XCTAssertTrue(RuntimeKind.allCases.contains(.litertlmE2B))
    }
```

- [ ] **Step 3: Tests pass**

```bash
xcodebuild test ... -only-testing:GemmaTests/RuntimeFactoryTests
```
Expected: 7 tests passed (3 existing + 4 new).

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(runtime): add .litertlmE4B and .litertlmE2B RuntimeKinds

Factory still returns DummyRuntime for the new kinds; Plan 3 swaps in
LiteRTLMRuntime.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Extend `HarnessModel` with catalog state + download orchestration

**Files:**
- Modify: `Gemma/Gemma/Harness/HarnessModel.swift`
- Modify: `Gemma/GemmaTests/HarnessModelTests.swift`

> This is the integration point. `HarnessModel` now exposes:
> - `catalog: [ModelDescriptor]` (constant — `ModelCatalog.builtIn`)
> - `installedModels: [ModelDescriptor]` (refreshed on view appear and after downloads)
> - `deviceCapability: DeviceCapability` (cached at init)
> - `downloads: [String: DownloadProgress]` keyed by descriptor id
> - actions: `startDownload(_ descriptor:) async`, `cancelDownload(_ id:)`, `removeInstalled(_:) throws`

- [ ] **Step 1: Add helper type + extend the model**

Add a new file `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Harness/DownloadProgress.swift`:

```swift
import Foundation

public struct DownloadProgress: Sendable, Equatable {
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    public var isActive: Bool
    public var error: String?

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesDownloaded) / Double(totalBytes))
    }

    public init(bytesDownloaded: Int64 = 0, totalBytes: Int64 = 0, isActive: Bool = false, error: String? = nil) {
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.isActive = isActive
        self.error = error
    }
}
```

Modify `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Harness/HarnessModel.swift` to add the catalog state. Insert these properties under the existing UI state block:

```swift
    // MARK: - Catalog state
    public let catalog: [ModelDescriptor] = ModelCatalog.builtIn
    public let deviceCapability: DeviceCapability = .current()
    public private(set) var installedModels: [ModelDescriptor] = []
    public private(set) var downloads: [String: DownloadProgress] = [:]
    public var showCatalog: Bool = false  // sheet presentation
```

Add these collaborators (under the existing `@ObservationIgnored` block):

```swift
    @ObservationIgnored
    private let installedStore: InstalledModels = .defaultInDocuments()
    @ObservationIgnored
    private let downloader: ModelDownloader = ModelDownloader(destinationDir: InstalledModels.defaultInDocuments().rootDir)
    @ObservationIgnored
    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]
```

Add at the end of `init`:

```swift
        refreshInstalled()
```

Add these methods (after `runBench`):

```swift
    public func refreshInstalled() {
        installedModels = installedStore.allInstalled(from: catalog)
    }

    public func startDownload(_ descriptor: ModelDescriptor) {
        // Pre-flight
        switch deviceCapability.fits(descriptor) {
        case .insufficient(let reasons):
            downloads[descriptor.id] = DownloadProgress(error: "Device unfit: \(reasons)")
            return
        case .ok: break
        }
        // Already installed?
        if case .installed = installedStore.status(of: descriptor) {
            refreshInstalled()
            return
        }
        downloads[descriptor.id] = DownloadProgress(isActive: true)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in await self.downloader.download(from: descriptor.sourceURL, filename: descriptor.modelFile) {
                    switch event {
                    case .progress(let downloaded, let total):
                        await MainActor.run {
                            self.downloads[descriptor.id] = DownloadProgress(
                                bytesDownloaded: downloaded,
                                totalBytes: total,
                                isActive: true
                            )
                        }
                    case .completed:
                        await MainActor.run {
                            self.downloads[descriptor.id] = DownloadProgress(
                                bytesDownloaded: descriptor.sizeInBytes,
                                totalBytes: descriptor.sizeInBytes,
                                isActive: false
                            )
                            self.refreshInstalled()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.downloads[descriptor.id] = DownloadProgress(
                        isActive: false,
                        error: "\(error)"
                    )
                }
            }
            await MainActor.run { self.activeDownloadTasks[descriptor.id] = nil }
        }
        activeDownloadTasks[descriptor.id] = task
    }

    public func cancelDownload(_ id: String) {
        activeDownloadTasks[id]?.cancel()
        activeDownloadTasks[id] = nil
        if var progress = downloads[id] {
            progress.isActive = false
            progress.error = "cancelled"
            downloads[id] = progress
        }
    }

    public func removeInstalled(_ descriptor: ModelDescriptor) {
        do {
            try installedStore.remove(descriptor)
            refreshInstalled()
        } catch {
            downloads[descriptor.id] = DownloadProgress(error: "remove failed: \(error)")
        }
    }
```

- [ ] **Step 2: Add HarnessModel tests**

Append to `/Users/hashdown/Projects/personal_agent/Gemma/GemmaTests/HarnessModelTests.swift`:

```swift
    func test_catalog_isModelCatalogBuiltIn() {
        let m = HarnessModel()
        XCTAssertEqual(m.catalog.map(\.id), ModelCatalog.builtIn.map(\.id))
    }

    func test_deviceCapability_isRealisticForTestDevice() {
        let m = HarnessModel()
        XCTAssertGreaterThan(m.deviceCapability.totalRAMBytes, 0)
        XCTAssertGreaterThan(m.deviceCapability.freeDiskBytes, 0)
    }

    func test_initialInstalledModels_isEmptyOrSubsetOfCatalog() {
        let m = HarnessModel()
        for installed in m.installedModels {
            XCTAssertTrue(m.catalog.contains(installed))
        }
    }
```

We deliberately do NOT test the actual download in `HarnessModelTests` (that hits real network). The download path is exercised by `ModelDownloaderTests`.

- [ ] **Step 3: Run tests**

```bash
xcodebuild test ... -only-testing:GemmaTests/HarnessModelTests
```
Expected: existing 6 + 3 new = 9 tests passed.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(harness): extend HarnessModel with catalog + download orchestration

- catalog, installedModels, downloads (dict by model id), deviceCapability
- startDownload(_:), cancelDownload(_:), removeInstalled(_:), refreshInstalled()
- downloads dict drives the upcoming CatalogView / DownloadView UI

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Build `CatalogView` SwiftUI (list of models + status + actions)

**Files:**
- Create: `Gemma/Gemma/Harness/CatalogView.swift`

> SwiftUI views are not unit-tested; manual smoke covers them.

- [ ] **Step 1: Implement**

Create `/Users/hashdown/Projects/personal_agent/Gemma/Gemma/Harness/CatalogView.swift`:

```swift
import SwiftUI

struct CatalogView: View {
    @Bindable var model: HarnessModel

    var body: some View {
        NavigationStack {
            List {
                Section("Device") {
                    HStack {
                        Text("Total RAM")
                        Spacer()
                        Text(formattedGiB(model.deviceCapability.totalRAMBytes))
                    }
                    HStack {
                        Text("Free disk")
                        Spacer()
                        Text(formattedGiB(model.deviceCapability.freeDiskBytes))
                    }
                }
                Section("Models") {
                    ForEach(model.catalog) { descriptor in
                        ModelRow(descriptor: descriptor, model: model)
                    }
                }
            }
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { model.showCatalog = false }
                }
            }
        }
    }

    private func formattedGiB(_ bytes: UInt64) -> String {
        String(format: "%.2f GiB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
    }
}

private struct ModelRow: View {
    let descriptor: ModelDescriptor
    @Bindable var model: HarnessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(descriptor.displayName).font(.headline)
                    Text(String(format: "%.2f GiB · min %d GB RAM · ctx %d", descriptor.sizeInGB, descriptor.minDeviceMemoryGB, descriptor.maxContextLength))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actionButton
            }
            if let progress = model.downloads[descriptor.id], progress.isActive {
                ProgressView(value: progress.fractionCompleted)
                Text(String(format: "%.1f / %.1f MiB", Double(progress.bytesDownloaded) / 1_048_576.0, Double(progress.totalBytes) / 1_048_576.0))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let error = model.downloads[descriptor.id]?.error {
                Text("Error: \(error)").font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionButton: some View {
        if model.installedModels.contains(descriptor) {
            Button("Remove") { model.removeInstalled(descriptor) }
                .tint(.red)
        } else if model.downloads[descriptor.id]?.isActive == true {
            Button("Cancel") { model.cancelDownload(descriptor.id) }
                .tint(.orange)
        } else {
            Button("Download") { model.startDownload(descriptor) }
                .tint(.blue)
        }
    }
}

#Preview {
    CatalogView(model: HarnessModel())
}
```

- [ ] **Step 2: Verify build**

```bash
xcodebuild build ... 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(harness): add CatalogView (browse + download + remove models)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Add Models button to `HarnessView` + sheet wiring

**Files:**
- Modify: `Gemma/Gemma/Harness/HarnessView.swift`

- [ ] **Step 1: Add a Models button in the status bar and a sheet that presents `CatalogView`**

Modify `HarnessView.statusBar` to add a button next to Load:

```swift
    private var statusBar: some View {
        HStack {
            Text(model.statusMessage).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Models") { model.showCatalog = true }
                .disabled(model.isGenerating)
            Button(model.modelLoaded ? "Unload" : "Load") {
                Task { await model.toggleLoad() }
            }
            .disabled(model.isLoadingModel || model.isGenerating)
        }
    }
```

Add a second `.sheet(...)` modifier at the same level as the existing `ImagePickerView` sheet (just below it inside `.navigationTitle("Gemma Harness")`):

```swift
            .sheet(isPresented: $model.showCatalog) {
                CatalogView(model: model)
            }
```

- [ ] **Step 2: Verify build**

```bash
xcodebuild build ... 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(harness): wire Models button + CatalogView sheet into HarnessView

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Full test suite + launch smoke + tag

**Files:** none.

- [ ] **Step 1: Run full suite**

```bash
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild test -project Gemma.xcodeproj -scheme Gemma \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -40
```
Expected: `** TEST SUCCEEDED **`. Expected approximate total:
- Previous Plan-1 + refactor totals: 34
- New in Plan 2:
  - ModelDescriptorTests: 4
  - ModelCatalogTests: 5
  - DeviceCapabilityTests: 4
  - ModelDownloaderTests: 3
  - InstalledModelsTests: 5
  - RuntimeFactoryTests: +4
  - HarnessModelTests: +3
  - **Total: 34 + 28 = 62 tests**

Report the actual final count.

- [ ] **Step 2: Automated launch smoke (same harness as Plan 1 Task 11)**

```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
cd /Users/hashdown/Projects/personal_agent/Gemma
xcodebuild -project Gemma.xcodeproj -scheme Gemma -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath ./build build 2>&1 | tail -3
APP_PATH=$(find ./build/Build/Products -name "Gemma.app" -type d | head -1)
xcrun simctl install booted "$APP_PATH"
LAUNCH_OUT=$(xcrun simctl launch booted lambert-dev-group.Gemma 2>&1)
PID=$(echo "$LAUNCH_OUT" | sed -n 's/.*: \([0-9][0-9]*\)$/\1/p')
sleep 4
kill -0 "$PID" 2>/dev/null && echo "SMOKE OK" || { echo "SMOKE FAIL"; exit 1; }
xcrun simctl terminate booted lambert-dev-group.Gemma
rm -rf ./build
```
Expected: `SMOKE OK`.

- [ ] **Step 3: Final commit + tag**

```bash
cd /Users/hashdown/Projects/personal_agent
git commit --allow-empty -m "chore(s1): plan 2 complete — model infra, all tests green, launch smoke clean

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
git tag -a s1-plan2-model-infra -m "S1 Plan 2 (catalog + downloader + memcheck) complete; runtime kinds extended"
git tag -l
```

---

## Out of scope (Plan 3 or later)

- Real LiteRT-LM SPM dependency (Plan 3).
- `LiteRTLMRuntime` (Plan 3).
- Multimodal image/audio plumbing through to a real engine (Plan 3).
- Hugging Face token / gated model auth (Plan 3 if needed).
- llama.cpp + GGUF runtime (Plan 4).
- mmap sub-evaluation (Plan 4 — needs a real runtime).
- Final S1 report consolidating bench across runtimes (Plan 4).
- Background download (foreground only for now).
- Checksum verification (we only verify file size against catalog; Plan 3+ may add SHA256 if HF provides it).
- Multiple concurrent downloads (one at a time is fine; the model dict supports multiple but UI presents one at a time).

---

## Risks for Plan 3

| # | Risk | Mitigation suggestion for Plan 3 |
|---|---|---|
| R1 | Hugging Face may require an auth token for some Gemma models. | Plan 3 should add `huggingfaceToken: String?` to `ModelDescriptor` or to `ModelDownloader.download(...)` as an `Authorization: Bearer ...` header. |
| R2 | The `URLSession.bytes(for:)` byte-by-byte iteration in `ModelDownloader` may be slow for multi-GB downloads. | If profiling shows it's a bottleneck, switch to `URLSession.download(for:)` (background download API) or chunked `dataTask` with delegate callbacks. |
| R3 | iOS data protection may make the file unreadable after device lock for the first few seconds of next launch. | If LiteRT-LM fails to open the file on cold launch, set the file's protection class to `.completeUntilFirstUserAuthentication` after the rename. |
| R4 | The 1.5× disk-headroom factor in `DeviceCapability.fits` is a guess. | Plan 3 should validate against real downloads and refine if needed. |

---

## Self-review notes

- **Spec coverage:** This plan covers the "model infrastructure" portion of S1's pre-conditions to actually run a real runtime. It does not yet satisfy any bullet in `01-s1-runtime.md` §11 (those all require a real model loaded — Plans 3 and 4).
- **Placeholders:** none — every code step includes complete code.
- **Type consistency:** `ModelDescriptor`, `ModelCatalog`, `DeviceCapability`, `DownloadEvent`, `DownloadError`, `ModelDownloader`, `InstalledModels`, `DownloadProgress`, `RuntimeKind`, `RuntimeFactory`, `HarnessModel`, `CatalogView` — all names consistent across tasks.
- **File responsibility:** every new file has exactly one purpose; the `Models/` directory is self-contained and free of UI imports.
