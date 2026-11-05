// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
@testable import HelmCore

final class TabDragTests: XCTestCase {
    func testInsertionMidpointsAndOutsideEdges() {
        for (x, index) in [(-1.0, 0), (0, 0), (49, 0), (50, 1), (199, 1), (200, 2), (500, 2)] {
            XCTAssertEqual(TabDragModel.insertionIndex(x: x, widths: [100, 200]), index)
        }
        XCTAssertEqual(TabDragModel.insertionIndex(x: 0, widths: []), 0)
        XCTAssertNil(TabDragModel.insertionIndex(x: .nan, widths: [100]))
        for width in [0, -1, Double.nan, .infinity] {
            XCTAssertNil(TabDragModel.insertionIndex(x: 10, widths: [width]))
        }
    }
    func testAllReorderSlots() {
        for count in 1...6 {
            for source in 0..<count {
                for slot in 0...count {
                    let expected = slot > source ? slot - 1 : slot
                    XCTAssertEqual(TabDragModel.reorderIndex(sourceIndex: source, insertionIndex: slot, count: count), expected == source ? nil : expected)
                }
            }
        }
        for (source, slot, count) in [(-1, 0, 3), (3, 0, 3), (0, -1, 3), (0, 4, 3), (0, 0, 0)] {
            XCTAssertNil(TabDragModel.reorderIndex(sourceIndex: source, insertionIndex: slot, count: count))
        }
    }
    func testTransferReorderAndDetachRules() {
        func intent(_ widths: [Double]?, _ same: Bool = true, _ distance: Double = 40, count: Int = 3,
                    source: Int = 0, threshold: Double = 40) -> TabDropIntent {
            TabDragModel.intent(sourceIndex: source, sourceCount: count, destinationWidths: widths,
                                destinationX: 300, sameWindow: same, distanceOutsideStrip: distance, detachThreshold: threshold)
        }
        XCTAssertEqual(intent([100, 100, 100]), .reorder(from: 0, to: 2))
        XCTAssertEqual(intent([100, 100, 100], source: 2), .none)
        XCTAssertEqual(intent([100]), .none)
        XCTAssertEqual(intent([], false), .transfer(insertionIndex: 0))
        XCTAssertEqual(intent([100], false), .transfer(insertionIndex: 1))
        XCTAssertEqual(intent([.nan], false), .none)
        XCTAssertEqual(intent(nil), .detach)
        XCTAssertEqual(intent(nil, count: 1), .none)
        XCTAssertEqual(intent(nil, source: -1), .none)
        for distance in [0, -1, 39, Double.nan, .infinity] { XCTAssertEqual(intent(nil, true, distance), .none) }
        for threshold in [-1, Double.nan, .infinity] { XCTAssertEqual(intent(nil, threshold: threshold), .none) }
    }
}
