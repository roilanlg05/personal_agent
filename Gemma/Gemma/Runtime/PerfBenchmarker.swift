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

        // Dedicated temp cache dir, cleaned up afterwards (matches Edge Gallery).
        let cacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bench-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        var runs: [BenchmarkRun] = []
        for i in 0..<max(1, config.runCount) {
            let info = try await benchmark(
                modelPath: modelPath,
                backend: backend,
                prefillTokens: config.prefillTokens,
                decodeTokens: config.decodeTokens,
                cacheDir: cacheDir.path
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
