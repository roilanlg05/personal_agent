import Foundation

public struct BenchPromptResult: Sendable, Codable, Equatable {
    public let promptId: String
    public let outputText: String
    public let metrics: RuntimeMetrics

    public init(promptId: String, outputText: String, metrics: RuntimeMetrics) {
        self.promptId = promptId
        self.outputText = outputText
        self.metrics = metrics
    }
}

public struct BenchReport: Sendable, Codable, Equatable {
    public let runtimeIdentifier: String
    public let modelDescription: String
    public let useSpeculativeDecoding: Bool
    public let useMmap: Bool
    public let startedAt: Date
    public let completedAt: Date
    public let results: [BenchPromptResult]

    public init(
        runtimeIdentifier: String,
        modelDescription: String,
        useSpeculativeDecoding: Bool,
        useMmap: Bool,
        startedAt: Date,
        completedAt: Date,
        results: [BenchPromptResult]
    ) {
        self.runtimeIdentifier = runtimeIdentifier
        self.modelDescription = modelDescription
        self.useSpeculativeDecoding = useSpeculativeDecoding
        self.useMmap = useMmap
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.results = results
    }

    /// Writes JSON to `Documents/<filename>` and returns the file URL.
    @discardableResult
    public func writeToDocuments(filename: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)

        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = docs.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}
