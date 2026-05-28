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
