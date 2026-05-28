import Foundation
import Observation
import UIKit

/// Owns the runtime lifecycle and harness UI state. Held by HarnessView as `@State`, so
/// it survives SwiftUI view-struct re-creation across re-renders.
@Observable
@MainActor
public final class HarnessModel {
    // MARK: - UI state (observed by HarnessView)
    public var prompt: String = "Hola, ¿cómo estás?"
    public var streamedOutput: String = ""
    public var isGenerating: Bool = false
    public var isLoadingModel: Bool = false
    public var modelLoaded: Bool = false
    public var lastMetrics: RuntimeMetrics?
    public var benchReportPath: String?
    public var pickedImage: UIImage?
    public var showImagePicker: Bool = false
    public var statusMessage: String
    public var runtimeKind: RuntimeKind {
        didSet {
            if oldValue != runtimeKind {
                swapRuntime(to: runtimeKind)
            }
        }
    }

    // MARK: - Catalog state
    public let catalog: [ModelDescriptor] = ModelCatalog.builtIn
    public let deviceCapability: DeviceCapability = .current()
    public private(set) var installedModels: [ModelDescriptor] = []
    public private(set) var downloads: [String: DownloadProgress] = [:]
    public var showCatalog: Bool = false  // sheet presentation

    // MARK: - Collaborators (not observed)
    @ObservationIgnored
    private var runtime: ModelRuntime
    @ObservationIgnored
    private let runner: BenchRunner
    @ObservationIgnored
    private let installedStore: InstalledModels = .defaultInDocuments()
    @ObservationIgnored
    private let downloader: ModelDownloader = ModelDownloader(destinationDir: InstalledModels.defaultInDocuments().rootDir)
    @ObservationIgnored
    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]

    public init(initialKind: RuntimeKind = .dummy, runner: BenchRunner = BenchRunner()) {
        self.runtimeKind = initialKind
        self.runtime = RuntimeFactory.make(initialKind)
        self.runner = runner
        self.statusMessage = "Runtime: \(initialKind.displayName) (not loaded)"
        refreshInstalled()
    }

    private func swapRuntime(to kind: RuntimeKind) {
        Task { await runtime.unload() }
        runtime = RuntimeFactory.make(kind)
        modelLoaded = false
        lastMetrics = nil
        statusMessage = "Runtime: \(kind.displayName) (not loaded)"
    }

    // MARK: - Actions

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

    public func runSingle() async {
        isGenerating = true
        streamedOutput = ""
        defer { isGenerating = false }
        do {
            let stream = await runtime.generate(
                prompt: prompt,
                image: pickedImage,
                options: GenerationOptions(maxTokens: 128)
            )
            for try await event in stream {
                switch event {
                case .token(let piece):
                    streamedOutput += piece
                case .completed(let result):
                    lastMetrics = result.metrics
                }
            }
        } catch {
            streamedOutput += "\n[error: \(error)]"
        }
    }

    public func runBench() async {
        isGenerating = true
        streamedOutput = "Running bench…"
        defer { isGenerating = false }
        do {
            let report = try await runner.run(
                runtime: runtime,
                modelDescription: "\(runtimeKind.displayName) (Plan 1 scaffold)",
                useSpeculativeDecoding: false,
                useMmap: true,
                prompts: PromptSet.all,
                imageProvider: { prompt in
                    guard let name = prompt.imageAssetName else { return nil }
                    return UIImage(named: name)
                }
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

    // MARK: - Catalog / download actions

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
                for try await event in self.downloader.download(from: descriptor.sourceURL, filename: descriptor.modelFile) {
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
}
