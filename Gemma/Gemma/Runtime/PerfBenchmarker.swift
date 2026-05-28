import Foundation
import LiteRTLM

/// Runs the official LiteRTLM `benchmark()` N times and aggregates. Each call
/// creates and tears down its own engine with synthetic prefill/decode tokens, so
/// there is no chat loop or per-prompt KV-cache churn.
public enum PerfBenchmarker {
    public static func run(
        modelPath: String,
        config: BenchmarkConfig,
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> BenchmarkResult {
        let backend: Backend = config.backend == .gpu ? .gpu : .cpu()

        // Disable the on-disk weight cache. In benchmark mode the engine forces
        // `wait_for_weights_conversion_complete_in_benchmark`, so a failed MLDrift
        // weight-cache write ("cannot append buffer to cache file") becomes fatal —
        // engine creation fails and its native cleanup path bad-accesses (crash).
        // ":nocache" is the documented opt-out and is the right behavior for a
        // benchmark (each run measures a cold build).
        let cacheDir = ":nocache"

        var runs: [BenchmarkRun] = []
        for i in 0..<max(1, config.runCount) {
            let info = try await benchmark(
                modelPath: modelPath,
                backend: backend,
                prefillTokens: config.prefillTokens,
                decodeTokens: config.decodeTokens,
                cacheDir: cacheDir
            )
            runs.append(BenchmarkRun(
                initSeconds: info.initTimeInSecond,
                ttftSeconds: info.timeToFirstTokenInSecond,
                prefillTokPerSec: info.lastPrefillTokensPerSecond,
                decodeTokPerSec: info.lastDecodeTokensPerSecond
            ))
            await onProgress?(i + 1, max(1, config.runCount))
        }
        return BenchmarkResult.aggregate(runs)
    }
}
