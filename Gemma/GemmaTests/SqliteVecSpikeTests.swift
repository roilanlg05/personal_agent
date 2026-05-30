import XCTest
import GRDB
@testable import Gemma

/// Phase 0 de-risk: confirms GRDB links and (once sqlite-vec is integrated) that the
/// vec0 virtual table + KNN works. The GRDB-opens test runs everywhere; the vec test
/// is added after sqlite-vec.c is integrated into the build.
final class SqliteVecSpikeTests: XCTestCase {
    func testGRDBOpens() throws {
        let q = try DatabaseQueue()
        let n = try q.read { try Int.fetchOne($0, sql: "SELECT 1") }
        XCTAssertEqual(n, 1)
    }
}
