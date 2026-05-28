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
        options: GenerationOptions
    ) async -> AsyncThrowingStream<GenerationEvent, Error> {
        // Snapshot all actor-isolated state we need INSIDE the actor before creating the stream.
        let loadedNow = self.loaded
        let cannedNow = self.cannedResponse
        let targetTps = self.tokensPerSecondTarget

        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard loadedNow else {
                    continuation.finish(throwing: RuntimeError.notLoaded)
                    return
                }
                let tokens = cannedNow.split(separator: " ").map(String.init)
                let limit = min(tokens.count, max(0, options.maxTokens))
                // Soft-clamp: do not silently round up; preserve sub-1 TPS by clamping to a tiny floor.
                let safeTps = max(targetTps, 0.001)
                let intervalNs = UInt64(1_000_000_000 / safeTps)

                let start = Date()
                var firstTokenAt: Date?
                var emitted: [String] = []
                for i in 0..<limit {
                    do {
                        try await Task.sleep(nanoseconds: intervalNs)
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    let piece = i == 0 ? tokens[i] : " " + tokens[i]
                    continuation.yield(.token(piece))
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
                await self?.setLastMetrics(metrics)
                continuation.yield(.completed(GenerationResult(text: emitted.joined(), metrics: metrics)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func currentMetrics() -> RuntimeMetrics? { lastMetrics }

    private func setLastMetrics(_ m: RuntimeMetrics) { lastMetrics = m }
}
