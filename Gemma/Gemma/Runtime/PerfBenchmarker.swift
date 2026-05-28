import Foundation
import LiteRTLM

/// Runs the official LiteRTLM `benchmark()` N times and aggregates. Each call
/// creates and tears down its own engine with synthetic prefill/decode tokens, so
/// there is no chat loop or per-prompt KV-cache churn.
public enum PerfBenchmarker {
    /// Runs `config.runCount` benchmark() calls (GPU/CPU per config, no on-disk
    /// cache) and returns the per-run measurements. `progressBase`/`progressTotal`
    /// let callers report progress across multiple blocks.
    private static func runBlock(
        modelPath: String,
        backend: Backend,
        config: BenchmarkConfig,
        progressBase: Int,
        progressTotal: Int,
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) async throws -> [BenchmarkRun] {
        var runs: [BenchmarkRun] = []
        for i in 0..<max(1, config.runCount) {
            let info = try await benchmark(
                modelPath: modelPath,
                backend: backend,
                prefillTokens: config.prefillTokens,
                decodeTokens: config.decodeTokens,
                cacheDir: ":nocache"
            )
            runs.append(BenchmarkRun(
                initSeconds: info.initTimeInSecond,
                ttftSeconds: info.timeToFirstTokenInSecond,
                prefillTokPerSec: info.lastPrefillTokensPerSecond,
                decodeTokPerSec: info.lastDecodeTokensPerSecond
            ))
            await onProgress?(progressBase + i + 1, progressTotal)
        }
        return runs
    }

    public static func run(
        modelPath: String,
        config: BenchmarkConfig,
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> BenchmarkResult {
        let backend: Backend = config.backend == .gpu ? .gpu : .cpu()
        let total = max(1, config.runCount)
        let runs = try await runBlock(modelPath: modelPath, backend: backend, config: config,
                                      progressBase: 0, progressTotal: total, onProgress: onProgress)
        return BenchmarkResult.aggregate(runs)
    }

    /// Runs the model with MTP (speculative decoding) off, then on, and returns the
    /// comparison. MTP is toggled via ExperimentalFlags (read when each fresh engine
    /// is created inside benchmark()).
    public static func compareMTP(
        modelPath: String,
        config: BenchmarkConfig,
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> MTPComparison {
        ExperimentalFlags.optIntoExperimentalAPIs()
        let previous = ExperimentalFlags.enableSpeculativeDecoding
        defer { ExperimentalFlags.enableSpeculativeDecoding = previous }

        let backend: Backend = config.backend == .gpu ? .gpu : .cpu()
        let n = max(1, config.runCount)
        let total = n * 2

        ExperimentalFlags.enableSpeculativeDecoding = false
        let offRuns = try await runBlock(modelPath: modelPath, backend: backend, config: config,
                                         progressBase: 0, progressTotal: total, onProgress: onProgress)

        ExperimentalFlags.enableSpeculativeDecoding = true
        let onRuns = try await runBlock(modelPath: modelPath, backend: backend, config: config,
                                        progressBase: n, progressTotal: total, onProgress: onProgress)

        return MTPComparison(mtpOff: BenchmarkResult.aggregate(offRuns),
                             mtpOn: BenchmarkResult.aggregate(onRuns))
    }
}
