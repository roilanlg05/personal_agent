import Foundation

/// User-tunable benchmark parameters. Package-agnostic (uses ComputeBackend).
public struct BenchmarkConfig: Equatable, Sendable {
    public var backend: ComputeBackend
    public var prefillTokens: Int
    public var decodeTokens: Int
    public var runCount: Int

    public init(
        backend: ComputeBackend = .gpu,
        prefillTokens: Int = 256,
        decodeTokens: Int = 256,
        runCount: Int = 5
    ) {
        self.backend = backend
        self.prefillTokens = prefillTokens
        self.decodeTokens = decodeTokens
        self.runCount = runCount
    }
}

/// One benchmark run's measurements (mapped from LiteRTLM.BenchmarkInfo).
public struct BenchmarkRun: Equatable, Sendable {
    public var initSeconds: Double
    public var ttftSeconds: Double
    public var prefillTokPerSec: Double
    public var decodeTokPerSec: Double

    public init(initSeconds: Double, ttftSeconds: Double, prefillTokPerSec: Double, decodeTokPerSec: Double) {
        self.initSeconds = initSeconds
        self.ttftSeconds = ttftSeconds
        self.prefillTokPerSec = prefillTokPerSec
        self.decodeTokPerSec = decodeTokPerSec
    }
}

/// Aggregated benchmark results. The first run's init time is reported separately
/// because it includes cold compilation; warm runs (2…N) are averaged.
public struct BenchmarkResult: Equatable, Sendable {
    public var runs: [BenchmarkRun]
    public var firstInitSeconds: Double
    public var avgWarmInitSeconds: Double
    public var avgTTFTSeconds: Double
    public var avgPrefillTokPerSec: Double
    public var avgDecodeTokPerSec: Double

    public init(
        runs: [BenchmarkRun],
        firstInitSeconds: Double,
        avgWarmInitSeconds: Double,
        avgTTFTSeconds: Double,
        avgPrefillTokPerSec: Double,
        avgDecodeTokPerSec: Double
    ) {
        self.runs = runs
        self.firstInitSeconds = firstInitSeconds
        self.avgWarmInitSeconds = avgWarmInitSeconds
        self.avgTTFTSeconds = avgTTFTSeconds
        self.avgPrefillTokPerSec = avgPrefillTokPerSec
        self.avgDecodeTokPerSec = avgDecodeTokPerSec
    }

    public static func aggregate(_ runs: [BenchmarkRun]) -> BenchmarkResult {
        func avg(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        let first = runs.first?.initSeconds ?? 0
        let warm = Array(runs.dropFirst())
        let warmInit = warm.isEmpty ? first : avg(warm.map(\.initSeconds))
        return BenchmarkResult(
            runs: runs,
            firstInitSeconds: first,
            avgWarmInitSeconds: warmInit,
            avgTTFTSeconds: avg(runs.map(\.ttftSeconds)),
            avgPrefillTokPerSec: avg(runs.map(\.prefillTokPerSec)),
            avgDecodeTokPerSec: avg(runs.map(\.decodeTokPerSec))
        )
    }
}
