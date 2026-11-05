// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class F17SearchTests: XCTestCase {
    func testCriteriaOnlyStartRefreshAndEmptyExit() throws {
        let root = URL(fileURLWithPath: "/root")
        let context = ReducerContext(now: .distantPast, homeDirectory: root)
        for filter: SearchClause in [.kind(.directory), .tag("work")] {
            let initial = TabState(location: .directory(root), homeDirectory: root)
            let query = SearchQuery(text: " \n", scope: .currentFolder(root), bookmarkPaths: [], homeDirectory: root,
                                    lastDirectory: root, showHidden: false, limit: 100, filters: [filter])
            let (started, effects) = TabReducer.reduce(initial, .searchStarted(query), context: context)
            XCTAssertEqual(started.search?.query, query)
            XCTAssertTrue(effects.contains(.startSearch(query, started.searchGeneration)))
            let (refreshed, refreshEffects) = TabReducer.reduce(started, .refresh, context: context)
            XCTAssertEqual(refreshed.search?.query, query)
            XCTAssertTrue(refreshEffects.contains(.startSearch(query, refreshed.searchGeneration)))
            XCTAssertNotEqual(refreshed.searchGeneration, started.searchGeneration)
            var empty = query; empty.filters = []
            let (ended, _) = TabReducer.reduce(refreshed, .searchStarted(empty), context: context)
            XCTAssertNil(ended.search)
            XCTAssertEqual(ended.snapshot.sortedEntries, initial.snapshot.sortedEntries)
        }
    }
}
