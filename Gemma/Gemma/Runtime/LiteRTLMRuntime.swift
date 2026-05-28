import Foundation
import UIKit
import LiteRTLM

/// Pinned to the main actor on purpose: LiteRT-LM's GPU/Metal backend is
/// thread-affine and crashes (SIGSEGV) when driven from an arbitrary executor.
/// The official iOS sample drives Engine + Conversation from @MainActor; doing the
/// same here is what makes the GPU backend work on-device. CPU tolerates other
/// executors, but @MainActor keeps both paths correct.
@MainActor
public final class LiteRTLMRuntime: ModelRuntime {
    public nonisolated let identifier: String = "litertlm"

    private var engine: Engine?
    private var conversation: Conversation?
    private var loaded: Bool = false
    private var lastMetrics: RuntimeMetrics?
    private var systemPrompt: String?

    public nonisolated init() {}

    public func isLoaded() -> Bool { loaded }

    public func load(options: ModelLoadOptions) async throws {
        // Opt into experimental APIs and set MTP flag BEFORE engine.initialize().
        // ExperimentalFlags.enableSpeculativeDecoding is read only at Engine creation.
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = options.useSpeculativeDecoding

        // Don't request vision/audio backends unconditionally: a text-only .litertlm
        // has no TF_LITE_VISION_ENCODER section, so asking for one fails engine
        // creation with NOT_FOUND. Leave them nil (matches the official iOS sample);
        // multimodal support requires a vision-capable model file.
        let backend: Backend = options.backend == .gpu ? .gpu : .cpu()
        let cfg = try EngineConfig(
            modelPath: options.modelPath.path,
            backend: backend,
            maxNumTokens: options.contextLength,
            cacheDir: NSTemporaryDirectory()
        )
        let engine = Engine(engineConfig: cfg)
        try await engine.initialize()  // actor isolation requires await; method itself is sync-throws

        self.engine = engine
        self.systemPrompt = options.systemPrompt
        self.conversation = try await makeConversation(engine: engine)
        self.loaded = true
    }

    /// Creates a fresh `Conversation` (clean context) on the loaded engine. Each
    /// generation gets a new one so history doesn't accumulate across prompts and
    /// overflow the KV cache — otherwise a second bench/run stalls in prefill.
    private func makeConversation(engine: Engine) async throws -> Conversation {
        let sampler = try SamplerConfig(topK: 64, topP: 0.95, temperature: 1.0)
        let convCfg = ConversationConfig(
            systemMessage: systemPrompt.map { Message($0, role: .system) },
            samplerConfig: sampler
        )
        return try await engine.createConversation(with: convCfg)
    }

    public func unload() {
        conversation = nil
        engine = nil
        loaded = false
        lastMetrics = nil
        systemPrompt = nil
    }

    public func generate(
        prompt: String,
        image: UIImage?,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<GenerationEvent, Error> {
        // Drive generation through an actor-isolated method so the native
        // Conversation (a non-Sendable class) is only ever touched from the same
        // executor that created the Engine. A detached Task would run off-actor on
        // an arbitrary thread and crash the native runtime (SIGSEGV).
        return AsyncThrowingStream { continuation in
            let task = Task { await self.streamGeneration(prompt: prompt, image: image, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamGeneration(
        prompt: String,
        image: UIImage?,
        into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async {
        guard loaded, let engine else {
            continuation.finish(throwing: RuntimeError.notLoaded)
            return
        }
        // Fresh conversation per generation → clean context, no KV-cache overflow
        // from accumulated history on repeated runs.
        let conv: Conversation
        do {
            conv = try await makeConversation(engine: engine)
            conversation = conv
        } catch {
            continuation.finish(throwing: RuntimeError.generationFailed("conversation init: \(error)"))
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
        lastMetrics = metrics
        continuation.yield(.completed(GenerationResult(text: accumulated, metrics: metrics)))
        continuation.finish()
    }

    public func currentMetrics() -> RuntimeMetrics? { lastMetrics }
}
