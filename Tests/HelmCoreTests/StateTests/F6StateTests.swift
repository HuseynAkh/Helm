// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class F6StateTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/a")
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: root) }
    private func snapshot(_ names: [String]) -> PresentationSnapshot {
        SnapshotBuilder.build(location: .directory(root), entries: names.map {
            FileEntry(url: root.appendingPathComponent($0))
        })
    }
    @discardableResult private func send(_ action: TabAction, to state: inout TabState) -> [TabEffect] {
        let result = TabReducer.reduce(state, action, context: context)
        state = result.0
        return result.1
    }
    func testHeldMonitorResultCannotUndoHiddenToggleOrRefresh() {
        for toggle in [false, true] {
            var state = TabState(location: .directory(root), homeDirectory: root)
            state.showHidden = true
            let old = state.monitorGeneration
            let effects = send(toggle ? .toggleHidden : .refresh, to: &state)
            XCTAssertTrue(effects.contains(.cancel(.monitor, old)))
            XCTAssertNotEqual(state.monitorGeneration, old)
            send(.loadFinished(state.loadGeneration, snapshot(["visible"])), to: &state)
            send(.monitorSnapshot(old, snapshot(["visible", ".hidden"])), to: &state)
            XCTAssertEqual(state.snapshot.sortedEntries.map(\.name), ["visible"])
            XCTAssertEqual(state.showHidden, !toggle)
        }
    }
    func testDirtyMonitorReplaysOnceAfterAllTerminalLoadPaths() {
        for terminal in 0..<3 {
            var state = TabState(location: .directory(root), homeDirectory: root)
            send(.refresh, to: &state)
            let generation = state.monitorGeneration
            XCTAssertTrue(send(.monitorEvent(generation, .changed(paths: ["/a/x"])), to: &state).isEmpty)
            XCTAssertTrue(send(.monitorEvent(generation, .rescan), to: &state).isEmpty)
            send(.monitorSnapshot(generation, snapshot([])), to: &state)
            // A superseding same-location load must preserve the invalidation.
            send(.refresh, to: &state)
            let action: TabAction
            if terminal == 0 { action = .loadFinished(state.loadGeneration, snapshot(["x"])) }
            else if terminal == 1 { action = .loadFailed(state.loadGeneration, .timedOut) }
            else { action = .loadFinished(state.loadGeneration, PresentationSnapshot(location: .directory(root), phase: .failed(.timedOut, attempted: .directory(root)))) }
            let effects = send(action, to: &state)
            XCTAssertEqual(effects.filter { if case .refreshPaths = $0 { return true }; return false }, [.refreshPaths([], state.monitorGeneration)])
            send(.monitorSnapshot(state.monitorGeneration, snapshot([])), to: &state)
            XCTAssertTrue(state.snapshot.sortedIDs.isEmpty)
            XCTAssertTrue(send(action, to: &state).isEmpty)
        }
    }
    func testRefreshRestartsCompletedSearchAndRejectsOldResults() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        let query = SearchQuery(text: "match", scope: .userFolders, bookmarkPaths: [], homeDirectory: root, lastDirectory: root, showHidden: false, limit: 100)
        send(.searchStarted(query), to: &state)
        let old = state.searchGeneration
        send(.searchResults(old, []), to: &state)
        let effects = send(.refresh, to: &state)
        XCTAssertTrue(effects.contains(.cancel(.search, old)))
        XCTAssertTrue(effects.contains(.startSearch(query, state.searchGeneration)))
        XCTAssertNotEqual(old, state.searchGeneration)
        let fresh = state.snapshot
        send(.searchResults(old, [SearchResult(entry: FileEntry(url: root.appendingPathComponent("old")), rank: 0)]), to: &state)
        XCTAssertEqual(state.snapshot, fresh)
        send(.searchResults(state.searchGeneration, [SearchResult(entry: FileEntry(url: root.appendingPathComponent("new")), rank: 0)]), to: &state)
        XCTAssertEqual(state.snapshot.sortedEntries.map(\.name), ["new"])
    }
    func testDirtyStateRetiresOnDifferentNavigationAndWaitsForActivation() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        send(.refresh, to: &state)
        send(.monitorEvent(state.monitorGeneration, .rescan), to: &state)
        send(.deactivated, to: &state)
        XCTAssertTrue(send(.loadFinished(state.loadGeneration, snapshot([])), to: &state).isEmpty)
        XCTAssertTrue(send(.activated, to: &state).contains(.refreshPaths([], state.monitorGeneration)))
        send(.refresh, to: &state)
        send(.monitorEvent(state.monitorGeneration, .rescan), to: &state)
        let target = Location.directory(URL(fileURLWithPath: "/b"))
        send(.navigate(target, .push), to: &state)
        let effects = send(.loadFinished(state.loadGeneration, PresentationSnapshot(location: target)), to: &state)
        XCTAssertFalse(effects.contains(.refreshPaths([], state.monitorGeneration)))
    }

}
