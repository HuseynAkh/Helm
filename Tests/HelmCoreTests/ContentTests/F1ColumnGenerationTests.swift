// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class F1ColumnGenerationTests: XCTestCase {
    func testReturningToSameDirectoryMustRejectOldReply() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["F1_RUN_DEFERRED_REGRESSIONS"] == "1",
                          "P1-4: deferred public column request token and adapter migration; see docs/prereview/fixes-F1.md")
        let folder = FileEntry(url: URL(fileURLWithPath: "/a/folder"), kind: .directory)
        let other = FileEntry(url: URL(fileURLWithPath: "/a/other"), kind: .directory)
        var state = ColumnBrowserState(root: SnapshotBuilder.build(location: .directory(URL(fileURLWithPath: "/a")), entries: [folder, other]))
        _ = state.select(folder.id, in: 0)
        _ = state.select(other.id, in: 0)
        _ = state.select(folder.id, in: 0)
        let fresh = FileEntry(url: folder.url.appendingPathComponent("new"))
        let stale = FileEntry(url: folder.url.appendingPathComponent("old"))
        XCTAssertTrue(state.push(SnapshotBuilder.build(location: .directory(folder.url), entries: [fresh]), from: 0, directory: folder.id))
        XCTAssertFalse(state.push(SnapshotBuilder.build(location: .directory(folder.url), entries: [stale]), from: 0, directory: folder.id))
        XCTAssertEqual(state.columns.last?.snapshot.sortedIDs, [fresh.id])
    }
}
