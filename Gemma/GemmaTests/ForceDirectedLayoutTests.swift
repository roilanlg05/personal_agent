import XCTest
import CoreGraphics
@testable import Gemma

final class ForceDirectedLayoutTests: XCTestCase {
    private let size = CGSize(width: 400, height: 300)

    private func assertWithinBounds(_ positions: [String: CGPoint], _ size: CGSize) {
        // The layout clamps into a margin-inset box, not the full 0...size box.
        let margin = CGFloat(ForceDirectedLayout.margin)
        let minX = margin, maxX = size.width - margin
        let minY = margin, maxY = size.height - margin
        for (_, p) in positions {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite, "position must be finite: \(p)")
            XCTAssertTrue(p.x >= minX && p.x <= maxX, "x out of margin-inset bounds: \(p.x)")
            XCTAssertTrue(p.y >= minY && p.y <= maxY, "y out of margin-inset bounds: \(p.y)")
        }
    }

    func testSmallGraphFiniteWithinBoundsAndComplete() {
        let ids = ["a", "b", "c", "d"]
        let edges = [("a", "b"), ("b", "c"), ("c", "d")]
        let positions = ForceDirectedLayout.layout(nodeIDs: ids, edges: edges, in: size)
        XCTAssertEqual(Set(positions.keys), Set(ids))
        assertWithinBounds(positions, size)
    }

    func testDeterministic() {
        let ids = ["a", "b", "c", "d"]
        let edges = [("a", "b"), ("b", "c"), ("c", "d")]
        let first = ForceDirectedLayout.layout(nodeIDs: ids, edges: edges, in: size)
        let second = ForceDirectedLayout.layout(nodeIDs: ids, edges: edges, in: size)
        XCTAssertEqual(first.keys.sorted(), second.keys.sorted())
        for id in ids {
            XCTAssertEqual(first[id]?.x, second[id]?.x)
            XCTAssertEqual(first[id]?.y, second[id]?.y)
        }
    }

    func testZeroNodesDoesNotCrash() {
        let positions = ForceDirectedLayout.layout(nodeIDs: [], edges: [], in: size)
        XCTAssertTrue(positions.isEmpty)
    }

    func testSingleNodeCentered() {
        let positions = ForceDirectedLayout.layout(nodeIDs: ["solo"], edges: [], in: size)
        XCTAssertEqual(positions.count, 1)
        assertWithinBounds(positions, size)
        XCTAssertEqual(positions["solo"]?.x, size.width / 2)
        XCTAssertEqual(positions["solo"]?.y, size.height / 2)
    }

    func testDanglingEdgesIgnored() {
        let positions = ForceDirectedLayout.layout(nodeIDs: ["a", "b"],
                                                   edges: [("a", "zzz"), ("a", "b")],
                                                   in: size)
        XCTAssertEqual(Set(positions.keys), Set(["a", "b"]))
        assertWithinBounds(positions, size)
    }
}
