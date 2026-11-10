// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class K29ColumnRequestTests: XCTestCase {
    private let folder = FileEntry(url: URL(fileURLWithPath: "/root/folder"), kind: .directory)
    private func root() -> PresentationSnapshot {
        PresentationSnapshot(location: .directory(URL(fileURLWithPath: "/root")), sortedEntries: [folder])
    }
    private func child() -> PresentationSnapshot {
        PresentationSnapshot(location: .directory(folder.url), sortedEntries: [])
    }
    func testRepeatedSelectionSupersedesEvenBeforeFreshResponse() throws {
        var state = ColumnBrowserState(root: root())
        let old = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest)
        let fresh = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest)
        XCTAssertEqual(old.columnID, fresh.columnID)
        XCTAssertNotEqual(old.generation, fresh.generation)
        XCTAssertFalse(state.push(child(), request: old))
        XCTAssertTrue(state.push(child(), request: fresh))
        XCTAssertFalse(state.push(child(), request: fresh), "Requests are consumed once")
    }
    func testSnapshotReplacementInvalidatesOwnerEvenWithSamePathAndSelection() throws {
        var state = ColumnBrowserState(root: root())
        let old = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest)
        XCTAssertTrue(state.replaceSnapshot(root(), at: 0))
        let fresh = try XCTUnwrap(state.moveRight().loadRequest)
        XCTAssertNotEqual(old.columnID, fresh.columnID)
        XCTAssertFalse(state.push(child(), request: old))
        XCTAssertTrue(state.push(child(), request: fresh))
    }
    func testPopAndLeftRetirePendingRequests() throws {
        for useLeft in [false, true] {
            var state = ColumnBrowserState(root: root())
            let request = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest)
            if useLeft {
                XCTAssertTrue(state.push(child(), request: request))
                state.moveLeft()
            } else { state.pop() }
            XCTAssertFalse(state.push(child(), request: request))
        }
    }
    func testReusedChildIndexCannotAcceptRemovedOwnersReply() throws {
        let nested = FileEntry(url: folder.url.appendingPathComponent("nested"), kind: .directory)
        let listing = PresentationSnapshot(location: .directory(folder.url), sortedEntries: [nested])
        let nestedListing = PresentationSnapshot(location: .directory(nested.url), sortedEntries: [])
        var state = ColumnBrowserState(root: root())
        let first = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest)
        XCTAssertTrue(state.push(listing, request: first))
        let stale = try XCTUnwrap(state.select(nested.id, in: 1).loadRequest)
        state.pop()
        let second = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest)
        XCTAssertTrue(state.push(listing, request: second))
        let fresh = try XCTUnwrap(state.select(nested.id, in: 1).loadRequest)
        XCTAssertFalse(state.push(nestedListing, request: stale))
        XCTAssertTrue(state.push(nestedListing, request: fresh))
    }
    func testForgedOwnerAndWrongLocationDoNotConsumeValidRequest() throws {
        var state = ColumnBrowserState(root: root())
        let request = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest)
        let forged = ColumnLoadRequest(columnID: UUID(), generation: request.generation,
                                       directory: request.directory, fromColumn: 0)
        XCTAssertFalse(state.push(child(), request: forged))
        XCTAssertFalse(state.push(root(), request: request))
        XCTAssertTrue(state.push(child(), request: request))
    }
}
