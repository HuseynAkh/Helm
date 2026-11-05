// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class SnapshotHistoryWindowTests: XCTestCase {
    let location: Location = .directory(URL(fileURLWithPath: "/"))
    func file(_ path: String, kind: FileEntryKind = .regular) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: path), kind: kind)
    }
    func testSnapshotDuplicateSafetyAndExpandedCycles() {
        let parent = file("/folder", kind: .directory)
        let child = file("/folder/child")
        let snapshot = PresentationSnapshot(location: location, sortedEntries: [parent, parent, child], rootCount: 2,
            children: [parent.id: TreeChildren(sortedIDs: [child.id]), child.id: TreeChildren(sortedIDs: [parent.id])])
        XCTAssertEqual(snapshot.rootCount, 1); XCTAssertEqual(snapshot.sortedEntries.count, 2)
        XCTAssertEqual(snapshot.visibleIDs(expanding: []), [parent.id])
        XCTAssertEqual(snapshot.visibleIDs(expanding: [parent.id, child.id]), [parent.id, child.id])
        XCTAssertEqual(snapshot.entry(child.id), child); XCTAssertEqual(snapshot.index(of: child.id), 1)
        XCTAssertNil(snapshot.entry(ItemID(rawValue: "/missing")))
        XCTAssertNil(SnapshotDiff.anchor(ItemID(rawValue: "/missing"), in: snapshot))
        XCTAssertEqual(SnapshotDiff.anchor(child.id, in: snapshot), child.id)
        let sorted = SnapshotBuilder.resort(snapshot, sort: ItemSort(ascending: false))
        XCTAssertEqual(sorted.children[parent.id]?.sortedIDs, [child.id])
    }
    func testLargeSnapshotLookupDoesNotResort() {
        let entries: [FileEntry] = (0..<100_000).map { file("/item\($0)") }
        let snapshot = SnapshotBuilder.build(location: location, entries: entries)
        let selection = Set(entries.strideSample.map(\.id))
        for _ in 0..<3 {
            XCTAssertEqual(SnapshotDiff.selection(selection, in: snapshot), selection)
            for id in selection { XCTAssertEqual(snapshot.entry(id)?.id, id) }
        }
        XCTAssertEqual(snapshot.indexByID.count, 100_000)
        XCTAssertEqual(snapshot.sortedEntries.count, 100_000)
    }
    func testHistoryDedupeAndEmptyTransitions() {
        var history = NavigationHistory()
        let current = NavigationHistory.Entry(location: location)
        XCTAssertNil(history.goBack(current: current)); XCTAssertNil(history.goForward(current: current))
        XCTAssertFalse(history.push(current: current, movingTo: location))
        XCTAssertTrue(history.push(current: current, movingTo: .recent))
        XCTAssertEqual(history.goBack(current: .init(location: .recent)), current)
        XCTAssertTrue(history.canGoForward); XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.push(current: current, movingTo: location)); XCTAssertTrue(history.canGoForward)
        XCTAssertTrue(history.push(current: current, movingTo: .trash)); XCTAssertFalse(history.canGoForward)
    }
    func testWindowTransitionsAndCloseRules() {
        let a = TabID(), b = TabID(), c = TabID()
        var state = WindowState(tabs: [a, b, c, a], activeTabID: b)
        XCTAssertEqual(state.tabs, [a, b, c])
        let (closed, effects) = WindowReducer.reduce(state, .closeTab(b))
        XCTAssertEqual(closed.tabs, [a, c]); XCTAssertEqual(closed.activeTabID, a)
        XCTAssertEqual(effects, [.deactivate(b), .activate(a), .dispose(b)])
        state = WindowReducer.reduce(closed, .move(c, to: 0)).0
        XCTAssertEqual(state.tabs, [c, a]); XCTAssertEqual(state.activeTabID, a)
        XCTAssertEqual(WindowReducer.reduce(state, .move(a, to: 10)).0, state)
        state = WindowReducer.reduce(state, .closeTab(a)).0
        XCTAssertEqual(WindowReducer.reduce(state, .closeTab(c)).0, state)
        XCTAssertTrue(WindowReducer.reduce(state, .closeTab(c)).1.isEmpty)
        XCTAssertEqual(WindowReducer.reduce(state, .closeCurrentTab).1, [.closeWindow])
        state = WindowReducer.reduce(state, .add(a, activate: false)).0
        XCTAssertEqual(state.activeTabID, c)
        state = WindowReducer.reduce(state, .activate(a)).0
        XCTAssertEqual(state.activeTabID, a)
        XCTAssertEqual(WindowReducer.reduce(state, .activate(b)).0, state)
        XCTAssertEqual(WindowState(tabs: [], activeTabID: b).tabs, [b])
        XCTAssertEqual(WindowState(tabs: [a], activeTabID: b).activeTabID, a)
        XCTAssertFalse(WindowReducer.reduce(state, .setSidebarVisible(false)).0.isSidebarVisible)
    }
}

private extension Array where Element == FileEntry {
    var strideSample: [FileEntry] { stride(from: 0, to: count, by: 97).map { self[$0] } }
}
