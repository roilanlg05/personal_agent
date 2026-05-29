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
        imageProvider: ImageProvider = { _ in nil },
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> BenchReport {
        let started = Date()
        var results: [BenchPromptResult] = []
        results.reserveCapacity(prompts.count)

        for prompt in prompts {
            let image = imageProvider(prompt)
            let stream = await runtime.generate(
                prompt: prompt.text,
                image: image,
                audioURL: nil,
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
            // Real runtimes may signal `.completed(_)` with an empty `result.text` and rely
            // on the streamed `.token(_)` pieces for the visible output (e.g. when text is
            // accumulated by the caller). Fall back to the collected stream in that case.
            results.append(BenchPromptResult(
                promptId: prompt.id,
                outputText: r.text.isEmpty ? streamedText : r.text,
                metrics: r.metrics
            ))
            await onProgress?(results.count, prompts.count)
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
