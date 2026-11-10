// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class SpringNavigationTests: XCTestCase {
    private func entry(_ name: String, size: Int64 = 0, identity: String = "original") -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/" + name), kind: .directory, size: size, objectIdentity: FileObjectIdentity(scope: "test", object: identity))
    }
    private func session() -> SpringNavigationSession {
        SpringNavigationSession(original: SpringNavigationContext(tabID: TabID(), location: .recent,
            selection: [entry("selected").id], scrollAnchor: entry("selected").id, scrollOffset: 42),
            clock: SystemHelmClock(), delay: 1000, sources: [DraggedItem(url: URL(fileURLWithPath: "/source/file"))])
    }
    private func open(_ target: FileEntry, in state: inout SpringNavigationSession) throws -> SpringNavigationRequest {
        state.beginHover(target)
        guard case .load(let request)? = state.poll(openImmediately: true).first else { throw NSError(domain: "test", code: 1) }
        XCTAssertEqual(state.hoverOpened(request: request, target: target), [.displayTemporary(state.current)])
        return request
    }
    func testNestedRetreatRestoresOriginalContext() throws {
        var state = session()
        _ = try open(entry("a"), in: &state); _ = try open(entry("b"), in: &state); _ = try open(entry("c"), in: &state)
        XCTAssertEqual(state.retreat(), [.restore(SpringNavigationContext(tabID: state.original.tabID, location: .directory(entry("b").url)))])
        _ = state.retreat(); XCTAssertEqual(state.retreat(), [.restore(state.original)])
    }
    func testCancelIsTerminalAndRestoresSelectionScroll() throws {
        var state = session(); _ = try open(entry("a"), in: &state)
        XCTAssertEqual(state.cancel(), [.restore(state.original)])
        XCTAssertEqual(state.original.scrollOffset, 42); XCTAssertEqual(state.original.selection.count, 1)
        XCTAssertTrue(state.cancel().isEmpty); XCTAssertTrue(state.poll(openImmediately: true).isEmpty)
    }
    func testSameTargetABARejectsOldRequest() throws {
        var state = session(); state.beginHover(entry("a")); _ = state.poll(openImmediately: true)
        let old = try XCTUnwrap(state.pending)
        state.beginHover(entry("b")); state.beginHover(entry("a")); _ = state.poll(openImmediately: true)
        XCTAssertNotEqual(old, state.pending)
        XCTAssertTrue(state.hoverOpened(request: old, target: entry("a")).isEmpty)
    }
    func testSpaceOnlyOnceAndDeadlineNotReached() {
        var state = session(); state.beginHover(entry("a"))
        XCTAssertTrue(state.poll().isEmpty); XCTAssertEqual(state.poll(openImmediately: true).count, 1)
        state.beginHover(entry("a")); XCTAssertTrue(state.poll(openImmediately: true).isEmpty)
    }
    func testChangedLoadIdentityRejected() throws {
        var state = session(); state.beginHover(entry("a")); _ = state.poll(openImmediately: true)
        let request = try XCTUnwrap(state.pending)
        XCTAssertTrue(state.hoverOpened(request: request, target: entry("a", size: 1, identity: "replacement")).isEmpty)
        XCTAssertTrue(state.stack.isEmpty)
    }
    func testFailedLoadRestoresCurrentAndConsumesRequest() throws {
        var state = session(); state.beginHover(entry("a")); _ = state.poll(openImmediately: true)
        let request = try XCTUnwrap(state.pending)
        XCTAssertEqual(state.loadFailed(request: request), [.restore(state.original)])
        XCTAssertTrue(state.loadFailed(request: request).isEmpty)
        XCTAssertTrue(state.hoverOpened(request: request, target: entry("a")).isEmpty)
    }
    func testLeavingCancelsLoad() throws {
        var state = session(); state.beginHover(entry("a")); _ = state.poll(openImmediately: true)
        let request = try XCTUnwrap(state.pending); state.leaveHover()
        XCTAssertTrue(state.hoverOpened(request: request, target: entry("a")).isEmpty)
    }
    func testTabCloseRejectsLateLoad() throws {
        var state = session(); state.beginHover(entry("a")); _ = state.poll(openImmediately: true)
        let request = try XCTUnwrap(state.pending)
        state.tabClosed(TabID()); XCTAssertFalse(state.isEnded)
        state.tabClosed(state.original.tabID)
        XCTAssertTrue(state.hoverOpened(request: request, target: entry("a")).isEmpty)
        XCTAssertTrue(state.cancel().isEmpty)
    }
    func testSuccessfulDropCommitsOnlyAcceptedDestinationOnce() throws {
        var state = session(); _ = try open(entry("a"), in: &state)
        let target = entry("destination")
        let request = try XCTUnwrap(state.acceptDrop(target: target, destination: DropDestination(location: .directory(target.url)), allowedOperations: [.copy, .move]))
        XCTAssertTrue(state.retreat().isEmpty)
        XCTAssertEqual(state.dropCompleted(request: request, success: true, destination: target),
                       [.commit(SpringNavigationContext(tabID: state.original.tabID, location: .directory(target.url)))])
        XCTAssertTrue(state.dropCompleted(request: request, success: true, destination: target).isEmpty)
    }
    func testFailedAndChangedDestinationDropsRestoreOriginal() throws {
        for success in [false, true] {
            var state = session(); let target = entry("destination")
            let request = try XCTUnwrap(state.acceptDrop(target: target, destination: DropDestination(location: .directory(target.url)), allowedOperations: [.copy, .move]))
            XCTAssertEqual(state.dropCompleted(request: request, success: success, destination: entry("destination", size: 1, identity: "replacement")), [.restore(state.original)])
        }
    }
    func testVirtualAndMismatchedDestinationsRejected() {
        var state = session()
        for location in [Location.recent, .trash, .directory(entry("other").url)] {
            XCTAssertNil(state.acceptDrop(target: entry("a"), destination: DropDestination(location: location), allowedOperations: [.copy, .move]))
        }
    }
    func testInvalidHoverAndScroll() {
        var state = session(); state.beginHover(FileEntry(url: URL(fileURLWithPath: "/file")))
        XCTAssertTrue(state.poll(openImmediately: true).isEmpty)
        XCTAssertEqual(SpringNavigationContext(tabID: TabID(), location: .recent, scrollOffset: .nan).scrollOffset, 0)
    }
    func testDifferentSessionDropCallbackRejected() throws {
        var first = session(); var second = session(); let target = entry("destination")
        let request = try XCTUnwrap(first.acceptDrop(target: target, destination: DropDestination(location: .directory(target.url)), allowedOperations: [.copy, .move]))
        XCTAssertTrue(second.dropCompleted(request: request, success: true, destination: target).isEmpty)
    }
}
