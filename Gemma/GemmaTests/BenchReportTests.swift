import XCTest
@testable import Gemma

final class BenchReportTests: XCTestCase {
    private func sampleReport() -> BenchReport {
        BenchReport(
            runtimeIdentifier: "dummy",
            modelDescription: "n/a",
            useSpeculativeDecoding: false,
            useMmap: true,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_010),
            results: [
                .init(
                    promptId: "fact-es-1",
                    outputText: "Canberra.",
                    metrics: RuntimeMetrics(
                        tokensGenerated: 3,
                        elapsedSeconds: 0.5,
                        timeToFirstTokenSeconds: 0.1,
                        peakResidentMemoryBytes: 123,
                        draftAcceptanceRate: nil
                    )
                )
            ]
        )
    }

    func test_benchReport_codable_roundTrip() throws {
        let original = sampleReport()
        let encoder = BenchReport.makeJSONEncoder()
        let decoder = BenchReport.makeJSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(BenchReport.self, from: data)
        XCTAssertEqual(decoded.runtimeIdentifier, original.runtimeIdentifier)
        XCTAssertEqual(decoded.results.count, 1)
        XCTAssertEqual(decoded.results[0].promptId, "fact-es-1")
        XCTAssertEqual(decoded.results[0].metrics.tokensGenerated, 3)
    }

    func test_benchReport_writeToDocuments_createsFile() throws {
        let report = sampleReport()
        let url = try report.writeToDocuments(filename: "test-report.json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let decoder = BenchReport.makeJSONDecoder()
        let decoded = try decoder.decode(BenchReport.self, from: data)
        XCTAssertEqual(decoded.runtimeIdentifier, "dummy")
    }
}
