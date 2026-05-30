import XCTest
import GRDB
@testable import Gemma

/// Phase 0 de-risk: confirms GRDB links and opens a database.
/// (sqlite-vec was evaluated but deferred — see the plan's Phase 0 decision. Vector search
/// in v1 uses BLOB + cosine in Swift over GRDB; the MemoryStore interface is unchanged, so
/// sqlite-vec can be swapped in later as a pure optimization.)
final class SqliteVecSpikeTests: XCTestCase {
    func testGRDBOpens() throws {
        let q = try DatabaseQueue()
        let n = try q.read { try Int.fetchOne($0, sql: "SELECT 1") }
        XCTAssertEqual(n, 1)
    }
}
