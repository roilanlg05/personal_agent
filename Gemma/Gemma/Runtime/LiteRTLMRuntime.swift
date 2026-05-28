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

    /// Creates a fresh `Conversation` (clean context) on the loaded engine.
    private func makeConversation(engine: Engine) async throws -> Conversation {
        let sampler = try SamplerConfig(topK: 64, topP: 0.95, temperature: 1.0)
        let convCfg = ConversationConfig(
            systemMessage: systemPrompt.map { Message($0, role: .system) },
            samplerConfig: sampler
        )
        return try await engine.createConversation(with: convCfg)
    }

    /// Starts a fresh conversation (clean context) for a new run. The engine allows
    /// only one session at a time, so release the current one first — Conversation
    /// .deinit calls litert_lm_conversation_delete — before creating the new one.
    public func reset() async throws {
        guard let engine else { return }
        conversation = nil
        do {
            conversation = try await makeConversation(engine: engine)
        } catch {
            // If the prior session hasn't finished tearing down, let pending cleanup
            // run and retry once.
            await Task.yield()
            conversation = nil
            conversation = try await makeConversation(engine: engine)
        }
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
        let maxTokens = options.maxTokens
        return AsyncThrowingStream { continuation in
            let task = Task { await self.streamGeneration(prompt: prompt, image: image, maxTokens: maxTokens, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamGeneration(
        prompt: String,
        image: UIImage?,
        maxTokens: Int,
        into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async {
        // Reuse the current conversation (created at load / reset). Recreating it
        // per generation churned a fresh 4096-token KV cache each prompt; freeing
        // lagged allocation and a 20-prompt bench OOM-killed the app around prompt
        // 17. reset() gives a fresh context per run instead. cancel() (token cap)
        // leaves the conversation reusable for the next prompt in the run.
        guard loaded, let conv = conversation else {
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
        var capped = false
        do {
            for try await chunk in conv.sendMessageStream(userMessage) {
                if Task.isCancelled {
                    try? conv.cancel()
                    continuation.finish(throwing: CancellationError())
                    return
                }
                // After hitting the output-token budget we keep draining the stream
                // (without yielding) until it ends. Breaking early would leave the
                // native stream's context holding the Conversation, so releasing it
                // wouldn't tear the single engine session down in time and the next
                // generation's createConversation would intermittently fail with
                // FAILED_PRECONDITION ("a session already exists"). cancel() makes
                // the stream end promptly, so draining is cheap.
                if capped { continue }
                let piece = chunk.toString
                if !piece.isEmpty {
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    accumulated += piece
                    tokenCount += 1
                    continuation.yield(.token(piece))
                    // Enforce the output-token budget: without this each prompt runs
                    // until EOS (hundreds of tokens), making a 20-prompt bench take
                    // 10+ minutes and look stuck at "Running bench…".
                    if maxTokens > 0 && tokenCount >= maxTokens {
                        try? conv.cancel()
                        capped = true
                    }
                }
            }
        } catch {
            // Reaching the token budget cancels the conversation, which surfaces
            // here as a thrown "CANCELLED: Process cancelled" error. That's the
            // expected end of a capped generation, not a failure — fall through to
            // emit the (truncated) completion. Only real errors propagate.
            if !capped {
                continuation.finish(throwing: RuntimeError.generationFailed("\(error)"))
                return
            }
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
