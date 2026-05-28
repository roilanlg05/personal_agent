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

    // MARK: - Collaborators (not observed)
    @ObservationIgnored
    private var runtime: ModelRuntime
    @ObservationIgnored
    private let runner: BenchRunner

    public init(initialKind: RuntimeKind = .dummy, runner: BenchRunner = BenchRunner()) {
        self.runtimeKind = initialKind
        self.runtime = RuntimeFactory.make(initialKind)
        self.runner = runner
        self.statusMessage = "Runtime: \(initialKind.displayName) (not loaded)"
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
        isLoadingModel = true
        statusMessage = "Loading…"
        do {
            try await runtime.load(options: ModelLoadOptions(modelPath: URL(fileURLWithPath: "/dev/null")))
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
}
