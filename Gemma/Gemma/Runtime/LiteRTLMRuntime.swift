import Foundation
import UIKit
import LiteRTLM

public actor LiteRTLMRuntime: ModelRuntime {
    public nonisolated let identifier: String = "litertlm"

    private var engine: Engine?
    private var conversation: Conversation?
    private var loaded: Bool = false
    private var lastMetrics: RuntimeMetrics?

    public init() {}

    public func isLoaded() -> Bool { loaded }

    public func load(options: ModelLoadOptions) async throws {
        // Opt into experimental APIs and set MTP flag BEFORE engine.initialize().
        // ExperimentalFlags.enableSpeculativeDecoding is read only at Engine creation.
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = options.useSpeculativeDecoding

        let cfg = try EngineConfig(
            modelPath: options.modelPath.path,
            backend: .gpu,
            visionBackend: .cpu(),
            audioBackend: .cpu(),
            maxNumTokens: options.contextLength,
            cacheDir: NSTemporaryDirectory()
        )
        let engine = Engine(engineConfig: cfg)
        try await engine.initialize()  // actor isolation requires await; method itself is sync-throws

        let sampler = try SamplerConfig(
            topK: 64,
            topP: 0.95,
            temperature: 1.0
        )
        let convCfg = ConversationConfig(
            systemMessage: options.systemPrompt.map { Message($0, role: .system) },
            samplerConfig: sampler
        )
        let conv = try await engine.createConversation(with: convCfg)

        self.engine = engine
        self.conversation = conv
        self.loaded = true
    }

    public func unload() {
        conversation = nil
        engine = nil
        loaded = false
        lastMetrics = nil
    }

    public func generate(
        prompt: String,
        image: UIImage?,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<GenerationEvent, Error> {
        let conv = self.conversation
        let loadedNow = self.loaded
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard loadedNow, let conv else {
                    continuation.finish(throwing: RuntimeError.notLoaded)
                    return
                }
                var tempImageURL: URL?
                let userMessage: Message
                if let image {
                    do {
                        let url = try ImageTempFile.writeJPEG(image)
                        tempImageURL = url
                        userMessage = Message(contents: [
                            .imageFile(url.path),
                            .text(prompt)
                        ])
                    } catch {
                        continuation.finish(throwing: RuntimeError.generationFailed("image encoding failed: \(error)"))
                        return
                    }
                } else {
                    userMessage = Message(prompt)
                }
                defer { tempImageURL.flatMap { try? FileManager.default.removeItem(at: $0) } }

                let start = Date()
                var firstTokenAt: Date?
                var accumulated = ""
                var tokenCount = 0
                do {
                    for try await chunk in conv.sendMessageStream(userMessage) {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        let piece = chunk.toString
                        if !piece.isEmpty {
                            if firstTokenAt == nil { firstTokenAt = Date() }
                            accumulated += piece
                            tokenCount += 1
                            continuation.yield(.token(piece))
                        }
                    }
                } catch {
                    continuation.finish(throwing: RuntimeError.generationFailed("\(error)"))
                    return
                }
                let elapsed = Date().timeIntervalSince(start)
                let ttft = firstTokenAt?.timeIntervalSince(start) ?? 0
                let metrics = RuntimeMetrics(
                    tokensGenerated: tokenCount,
                    elapsedSeconds: elapsed,
                    timeToFirstTokenSeconds: ttft,
                    peakResidentMemoryBytes: MemoryReporter.currentResidentBytes(),
                    draftAcceptanceRate: nil
                )
                await self.setLastMetrics(metrics)
                continuation.yield(.completed(GenerationResult(text: accumulated, metrics: metrics)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func currentMetrics() -> RuntimeMetrics? { lastMetrics }

    private func setLastMetrics(_ m: RuntimeMetrics) { lastMetrics = m }
}
