// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class InspectorPresentationTests: XCTestCase {
    func testSizeMetadataDoesNotTreatUnknownOrDirectoryAsZero() {
        XCTAssertEqual(InspectorSizeState.metadata(bytes: -1, isDirectory: false), .unavailable)
        XCTAssertEqual(InspectorSizeState.metadata(bytes: 123, isDirectory: true), .calculating)
        XCTAssertEqual(InspectorSizeState.metadata(bytes: 0, isDirectory: false), .final(InspectorSizeTotal(bytes: 0, itemCount: 1)))
    }
    func testAggregateAllStatePairs() {
        let total = InspectorSizeTotal(bytes: 12, itemCount: 1)
        let states: [InspectorSizeState] = [.calculating, .unavailable, .partial(total), .final(total)]
        for left in states.indices {
            for right in states.indices {
                let result = InspectorSizeState.aggregate([states[left], states[right]])
                if left < 2 && right < 2 {
                    XCTAssertEqual(result, left == 0 || right == 0 ? .calculating : .unavailable)
                } else {
                    let count: Int64 = (left >= 2 ? 1 : 0) + (right >= 2 ? 1 : 0)
                    let sum = InspectorSizeTotal(bytes: count * 12, itemCount: count)
                    XCTAssertEqual(result, left == 3 && right == 3 ? .final(sum) : .partial(sum))
                }
            }
        }
        XCTAssertEqual(InspectorSizeState.aggregate([]), .unavailable)
    }
    func testOverflowAndPriorOverflowNeverTrapOrDisappear() {
        let large = InspectorSizeTotal(bytes: .max, itemCount: .max)
        let one = InspectorSizeTotal(bytes: 1, itemCount: 1)
        let saturated = InspectorSizeTotal(bytes: .max, itemCount: .max, overflowed: true)
        XCTAssertEqual(InspectorSizeState.aggregate([.final(large), .final(one)]), .final(saturated))
        XCTAssertEqual(InspectorSizeState.aggregate([.partial(saturated), .final(one)]), .partial(saturated))
        XCTAssertEqual(InspectorSizeTotal(bytes: -1, itemCount: -2), InspectorSizeTotal(bytes: 0, itemCount: 0))
    }
    func testSectionsPersistOverridesAndUnknownKeys() throws {
        var sections = InspectorSections(expandedByKey: ["future": true])
        for section in InspectorSection.allCases {
            XCTAssertEqual(sections.isExpanded(section), section == .general || section == .nameAndExtension)
            sections.setExpanded(!sections.isExpanded(section), for: section)
        }
        let decoded = try JSONDecoder().decode(InspectorSections.self, from: JSONEncoder().encode(sections))
        XCTAssertEqual(decoded, sections)
        XCTAssertEqual(decoded.expandedByKey["future"], true)
        XCTAssertFalse(decoded.isExpanded(.general))
        XCTAssertTrue(decoded.isExpanded(.permissions))
    }
}
