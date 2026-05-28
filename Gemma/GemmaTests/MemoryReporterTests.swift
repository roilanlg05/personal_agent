import XCTest
@testable import Gemma

final class MemoryReporterTests: XCTestCase {
    func test_currentRSS_returnsNonZero() {
        let rss = MemoryReporter.currentResidentBytes()
        XCTAssertGreaterThan(rss, 0, "Process must report non-zero RSS")
    }

    func test_currentRSS_isReasonable() {
        // A bare iOS test process should be well under 2 GB.
        let rss = MemoryReporter.currentResidentBytes()
        XCTAssertLessThan(rss, UInt64(2) * 1024 * 1024 * 1024)
    }
}
