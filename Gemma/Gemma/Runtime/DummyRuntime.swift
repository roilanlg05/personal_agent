import Foundation

public actor DummyRuntime: ModelRuntime {
    public nonisolated let identifier = "dummy"
    public func isLoaded() async -> Bool { true }
    public func load(options: ModelLoadOptions) async throws {}
    public func unload() async {}
    public func currentMetrics() async -> RuntimeMetrics? { nil }
    public func generate(prompt: String, options: GenerationOptions) async -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { c in
            c.yield(.token(prompt))
            c.yield(.completed(GenerationResult(text: prompt, metrics: .init(tokensGenerated: 1, elapsedSeconds: 0, timeToFirstTokenSeconds: 0, peakResidentMemoryBytes: 0, draftAcceptanceRate: nil))))
            c.finish()
        }
    }
}
