// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class F1ColumnGenerationTests: XCTestCase {
    func testReturningToSameDirectoryMustRejectOldReply() throws {
        let folder = FileEntry(url: URL(fileURLWithPath: "/a/folder"), kind: .directory)
        let other = FileEntry(url: URL(fileURLWithPath: "/a/other"), kind: .directory)
        var state = ColumnBrowserState(root: SnapshotBuilder.build(location: .directory(URL(fileURLWithPath: "/a")), entries: [folder, other]))
        let oldRequest = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest)
        _ = state.select(other.id, in: 0)
        let newRequest = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest)
        let fresh = FileEntry(url: folder.url.appendingPathComponent("new"))
        let stale = FileEntry(url: folder.url.appendingPathComponent("old"))
        XCTAssertTrue(state.push(SnapshotBuilder.build(location: .directory(folder.url), entries: [fresh]), request: newRequest))
        XCTAssertFalse(state.push(SnapshotBuilder.build(location: .directory(folder.url), entries: [stale]), request: oldRequest))
        XCTAssertEqual(state.columns.last?.snapshot.sortedIDs, [fresh.id])
    }
}
