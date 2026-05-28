import Foundation
import UIKit

public typealias ImageProvider = @Sendable (BenchPrompt) -> UIImage?

public struct BenchRunner: Sendable {
    public init() {}

    public func run(
        runtime: ModelRuntime,
        modelDescription: String,
        useSpeculativeDecoding: Bool,
        useMmap: Bool,
        prompts: [BenchPrompt],
        generationOptions: GenerationOptions = GenerationOptions(maxTokens: 64),
        imageProvider: ImageProvider = { _ in nil }
    ) async throws -> BenchReport {
        let started = Date()
        var results: [BenchPromptResult] = []
        results.reserveCapacity(prompts.count)

        for prompt in prompts {
            let image = imageProvider(prompt)
            let stream = await runtime.generate(
                prompt: prompt.text,
                image: image,
                options: generationOptions
            )
            var streamedText = ""
            var finalResult: GenerationResult?
            for try await event in stream {
                switch event {
                case .token(let piece):
                    streamedText += piece
                case .completed(let result):
                    finalResult = result
                }
            }
            guard let r = finalResult else {
                throw RuntimeError.generationFailed("stream ended without .completed for prompt \(prompt.id)")
            }
            results.append(BenchPromptResult(
                promptId: prompt.id,
                outputText: r.text.isEmpty ? streamedText : r.text,
                metrics: r.metrics
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
