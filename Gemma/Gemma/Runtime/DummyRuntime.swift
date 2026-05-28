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
