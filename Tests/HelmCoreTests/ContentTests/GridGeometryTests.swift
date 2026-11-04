// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class GridGeometryTests: XCTestCase {
    func testLegacyMetricsAndColumnThreshold() {
        let grid = GridGeometry(itemCount: 10, availableWidth: 322)
        XCTAssertEqual(grid.columns, 2); XCTAssertEqual(grid.rows, 5)
        XCTAssertEqual(grid.rect(at: 0), CGRect(x: 16, y: 12, width: 140, height: 140))
        XCTAssertEqual(grid.rect(at: 3), CGRect(x: 166, y: 166, width: 140, height: 140))
        XCTAssertEqual(grid.contentHeight, 780)
        XCTAssertEqual(GridGeometry(itemCount: 10, availableWidth: 321).columns, 1)
    }
    func testRoundTripsAndGaps() throws {
        let grid = GridGeometry(itemCount: 5, availableWidth: 322)
        for index in 0..<5 {
            let rect = try XCTUnwrap(grid.rect(at: index))
            XCTAssertEqual(grid.index(at: CGPoint(x: rect.midX, y: rect.midY)), index)
        }
        for point in [CGPoint(x: 156, y: 20), CGPoint(x: 20, y: 152), CGPoint(x: 0, y: 0),
                      CGPoint(x: 200, y: 330), CGPoint(x: -1, y: 20)] {
            XCTAssertNil(grid.index(at: point))
        }
        XCTAssertNil(grid.rect(at: -1)); XCTAssertNil(grid.rect(at: 5))
    }
    func testVisibleRowsAndSpacing() {
        let grid = GridGeometry(itemCount: 5, availableWidth: 322)
        XCTAssertEqual(grid.visibleRange(scrollOffset: 0, viewportHeight: 12), 0..<0)
        XCTAssertEqual(grid.visibleRange(scrollOffset: 12, viewportHeight: 140), 0..<2)
        XCTAssertTrue(grid.visibleRange(scrollOffset: 152, viewportHeight: 14).isEmpty)
        XCTAssertEqual(grid.visibleRange(scrollOffset: 166, viewportHeight: 300), 2..<5)
        XCTAssertTrue(grid.visibleRange(scrollOffset: 1_000, viewportHeight: 10).isEmpty)
        XCTAssertEqual(grid.visibleRange(scrollOffset: -10, viewportHeight: 30), 0..<2)
    }
    func testRubberBandIntersectionBoundaries() {
        let grid = GridGeometry(itemCount: 5, availableWidth: 322)
        XCTAssertEqual(grid.indices(intersecting: CGRect(x: 0, y: 0, width: 400, height: 1000)), Set(0..<5))
        XCTAssertEqual(grid.indices(intersecting: CGRect(x: 150, y: 140, width: 30, height: 40)), [0, 1, 2, 3])
        XCTAssertTrue(grid.indices(intersecting: CGRect(x: 156, y: 12, width: 10, height: 140)).isEmpty)
        XCTAssertEqual(grid.indices(intersecting: CGRect(x: 30, y: 30, width: -10, height: -10)), [0])
        XCTAssertTrue(grid.indices(intersecting: .zero).isEmpty)
    }
    func testNonFiniteAndEmptyInputs() {
        let grid = GridGeometry(itemCount: -1, availableWidth: .nan, itemSize: .zero,
                                horizontalSpacing: -.infinity, verticalInset: -4)
        XCTAssertEqual(grid.columns, 1); XCTAssertEqual(grid.rows, 0); XCTAssertEqual(grid.contentHeight, 0)
        XCTAssertNil(grid.index(at: CGPoint(x: CGFloat.infinity, y: 0)))
        XCTAssertTrue(grid.visibleRange(scrollOffset: .nan, viewportHeight: 10).isEmpty)
        XCTAssertTrue(grid.visibleRange(scrollOffset: 0, viewportHeight: -1).isEmpty)
        XCTAssertTrue(grid.indices(intersecting: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)).isEmpty)
    }
    func testExhaustiveRectangleAgainstNaiveIntersection() throws {
        let grid = GridGeometry(itemCount: 23, availableWidth: 650)
        for x in stride(from: -20, through: 700, by: 51) {
            for y in stride(from: -20, through: 1000, by: 63) {
                let query = CGRect(x: x, y: y, width: 73, height: 91)
                let expected = Set((0..<23).filter { index in
                    guard let rect = grid.rect(at: index) else { return false }
                    return rect.minX < query.maxX && rect.maxX > query.minX && rect.minY < query.maxY && rect.maxY > query.minY
                })
                XCTAssertEqual(grid.indices(intersecting: query), expected)
            }
        }
    }
    func testHundredThousandItemsStayViewportBounded() {
        let grid = GridGeometry(itemCount: 100_000, availableWidth: 1000)
        let start = Date()
        for offset in stride(from: 0, to: 100_000, by: 10) {
            let visible = grid.visibleRange(scrollOffset: CGFloat(offset), viewportHeight: 800)
            XCTAssertLessThan(visible.count, 50)
            XCTAssertLessThan(grid.indices(intersecting: CGRect(x: 0, y: offset, width: 1000, height: 800)).count, 50)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }
}
