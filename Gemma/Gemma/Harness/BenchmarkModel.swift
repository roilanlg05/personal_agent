import Foundation
import Observation

@Observable
@MainActor
public final class BenchmarkModel {
    public var config = BenchmarkConfig()
    public private(set) var isRunning = false
    public private(set) var progress: (completed: Int, total: Int)?
    public private(set) var result: BenchmarkResult?
    public private(set) var errorMessage: String?

    public init() {}

    public func run(modelURL: URL) async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        result = nil
        progress = (0, config.runCount)
        defer { isRunning = false }
        do {
            let r = try await PerfBenchmarker.run(
                modelPath: modelURL.path,
                config: config,
                onProgress: { [weak self] completed, total in
                    self?.progress = (completed, total)
                }
            )
            result = r
        } catch {
            errorMessage = "\(error)"
        }
    }
}
