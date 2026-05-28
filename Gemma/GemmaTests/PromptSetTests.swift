import XCTest
@testable import Gemma

final class PromptSetTests: XCTestCase {
    func test_promptSet_hasExpectedTotalCount() {
        XCTAssertEqual(PromptSet.all.count, 20)
    }

    func test_promptSet_categoryCountsMatchSpec() {
        let by = Dictionary(grouping: PromptSet.all, by: { $0.category })
        XCTAssertEqual(by[.factual]?.count, 8)
        XCTAssertEqual(by[.conversational]?.count, 6)
        XCTAssertEqual(by[.long]?.count, 4)
        XCTAssertEqual(by[.image]?.count, 2)
    }

    func test_promptSet_languageCounts_balanced() {
        let by = Dictionary(grouping: PromptSet.all, by: { $0.language })
        // 4 ES + 4 EN factual, 3+3 conversational, 2+2 long, 1+1 image  → 10 each
        XCTAssertEqual(by[.es]?.count, 10)
        XCTAssertEqual(by[.en]?.count, 10)
    }

    func test_promptSet_idsAreUnique() {
        let ids = PromptSet.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func test_promptSet_isDeterministic() {
        let a = PromptSet.all.map(\.id)
        let b = PromptSet.all.map(\.id)
        XCTAssertEqual(a, b)
    }

    func test_imagePrompts_haveImageNames() {
        let imgs = PromptSet.all.filter { $0.category == .image }
        for p in imgs {
            XCTAssertNotNil(p.imageAssetName)
            XCTAssertFalse(p.imageAssetName!.isEmpty)
        }
    }
}
