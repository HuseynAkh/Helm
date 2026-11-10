// DRAFT: pending Opus review. F-043, F-044 and F-049 regressions.
import Foundation
import XCTest
import HelmCore

final class AK2SearchCoreRegressionTests: XCTestCase {
    func testRefreshRetainsResultsUntilReplacementAndEmptyClears() throws {
        var state = SearchSessionState()
        let query = SearchQuery(text: "report", scope: .home, bookmarkPaths: [], homeDirectory: URL(fileURLWithPath: "/home"), lastDirectory: nil, showHidden: false, limit: 10)
        let first = try XCTUnwrap(state.start(query))
        let batch = SearchRankedBatch(results: [SearchResult(entry: FileEntry(url: URL(fileURLWithPath: "/home/report")), rank: 0)], truncated: false, candidateLimitReached: false, consideredCount: 1)
        XCTAssertTrue(state.receive(.search(.results(batch, isFinal: true)), generation: first))
        let next = try XCTUnwrap(state.refresh())
        XCTAssertNotEqual(first, next)
        XCTAssertEqual(state.batch, batch)
        XCTAssertFalse(state.receive(.failed("stale"), generation: first))
        let replacement = SearchRankedBatch(results: [], truncated: false, candidateLimitReached: false, consideredCount: 0)
        XCTAssertTrue(state.receive(.search(.results(replacement, isFinal: true)), generation: next))
        XCTAssertEqual(state.batch, replacement)
        var empty = query; empty.text = ""
        XCTAssertNil(state.start(empty)); XCTAssertNil(state.batch)
    }
    func testCloudRejectsEncodedSeparatorsAndNUL() throws {
        for spelling in ["file:///home/a%2Fb", "file:///home/%00"] {
            let entry = FileEntry(url: try XCTUnwrap(URL(string: spelling)), cloudAvailability: .local)
            XCTAssertEqual(CloudActionPlan.build(entry: entry, purpose: .explicitOpen, capabilities: .init()), .unsupported)
            XCTAssertEqual(CloudActionPlan.eviction(entry: entry, explicitlyRequested: true, capabilities: .init(canEvict: true)), .unsupported)
        }
    }
}
