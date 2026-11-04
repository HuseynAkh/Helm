// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class TabReducerTests: XCTestCase {
    let a: Location = .directory(URL(fileURLWithPath: "/a"))
    let b: Location = .directory(URL(fileURLWithPath: "/b"))
    let context = ReducerContext(now: .distantPast, homeDirectory: URL(fileURLWithPath: "/home"))
    func entry(_ path: String) -> FileEntry { FileEntry(url: URL(fileURLWithPath: path)) }
    func initial() -> TabState { TabState(location: a, homeDirectory: context.homeDirectory) }
    @discardableResult
    func send(_ action: TabAction, to state: inout TabState) -> [TabEffect] {
        let result = TabReducer.reduce(state, action, context: context)
        state = result.0; return result.1
    }
    func finish(_ state: inout TabState, entries: [FileEntry] = []) {
        let target = state.pendingNavigation?.target ?? state.location
        send(.loadFinished(state.loadGeneration, SnapshotBuilder.build(location: target, entries: entries, sort: state.sort)), to: &state)
    }
    func loaded() -> TabState {
        var state = initial()
        send(.refresh, to: &state); finish(&state, entries: [entry("/a/one"), entry("/a/two")])
        return state
    }
    func query(_ text: String) -> SearchQuery {
        SearchQuery(text: text, scope: .userFolders, bookmarkPaths: [], homeDirectory: context.homeDirectory,
                    lastDirectory: nil, showHidden: false, limit: 100)
    }
    func testNavigationTransitionTableAndEffects() {
        var state = loaded()
        let selected = entry("/a/one").id
        send(.setSelection([selected], source: .user), to: &state)
        let transitions: [(TabAction, Location, Int, Int)] = [
            (.navigate(b, .push), b, 1, 0), (.goBack, a, 0, 1), (.goForward, b, 1, 0)
        ]
        for (action, destination, back, forward) in transitions {
            let oldLocation = state.location
            let oldHistory = state.history
            let effects = send(action, to: &state)
            XCTAssertEqual(state.location, oldLocation); XCTAssertEqual(state.history, oldHistory)
            XCTAssertTrue(effects.contains(.load(destination, state.loadGeneration, LoadOptions(sort: state.sort))))
            let result = send(.loadFinished(state.loadGeneration, SnapshotBuilder.build(location: destination,
                                         entries: destination == a ? [entry("/a/one")] : [])), to: &state)
            XCTAssertEqual(state.location, destination)
            XCTAssertEqual(state.history.back.count, back); XCTAssertEqual(state.history.forward.count, forward)
            XCTAssertTrue(result.contains(.startMonitor(destination, state.monitorGeneration)))
            if let url = destination.mutationTarget { XCTAssertTrue(result.contains(.recordRecent(url))) }
            if destination == a { XCTAssertEqual(state.selection, [selected]) }
        }
    }
    func testDenialAndFailurePreserveCommittedState() {
        for error: LoadError in [.permissionDenied, .notFound, .cancelled, .timedOut] {
            var state = loaded()
            let previous = state
            send(.navigate(b, .push), to: &state)
            send(.loadFailed(state.loadGeneration, error), to: &state)
            XCTAssertEqual(state.location, previous.location); XCTAssertEqual(state.history, previous.history)
            XCTAssertEqual(state.snapshot.sortedIDs, previous.snapshot.sortedIDs)
            XCTAssertEqual(state.snapshot.phase, .failed(error, attempted: b))
            XCTAssertNil(state.pendingNavigation)
            let failed = state
            finish(&state)
            XCTAssertEqual(state, failed)
        }
    }
    func testCommitOnceAndPartialFailure() {
        var state = loaded()
        send(.navigate(b, .push), to: &state)
        let partial = SnapshotBuilder.build(location: b, entries: [entry("/b/one")], phase: .loading(loadedCount: 1))
        let first = send(.loadProgress(state.loadGeneration, partial), to: &state)
        XCTAssertEqual(state.history.back.count, 1)
        let second = send(.loadProgress(state.loadGeneration, partial), to: &state)
        XCTAssertTrue(second.isEmpty); XCTAssertFalse(first.isEmpty)
        send(.loadFailed(state.loadGeneration, .permissionDenied), to: &state)
        XCTAssertEqual(state.location, b); XCTAssertEqual(state.history.back.count, 1)
        XCTAssertEqual(state.snapshot.sortedEntries, partial.sortedEntries)
    }
    func testHistoryRestorationWaitsForLaterBatch() {
        var state = loaded()
        let selected = entry("/a/two").id
        send(.setSelection([selected], source: .user), to: &state)
        send(.navigate(b, .push), to: &state); finish(&state)
        send(.goBack, to: &state)
        send(.loadProgress(state.loadGeneration, SnapshotBuilder.build(location: a, entries: [entry("/a/one")])), to: &state)
        XCTAssertTrue(state.selection.isEmpty)
        finish(&state, entries: [entry("/a/one"), entry("/a/two")])
        XCTAssertEqual(state.selection, [selected]); XCTAssertEqual(state.snapshot.selectionSource, .history)
    }
    func testStaleLoadAndWrongDestinationCannotCommit() {
        var state = loaded()
        send(.navigate(b, .push), to: &state)
        let old = state.loadGeneration
        send(.navigate(.recent, .push), to: &state)
        let before = state
        send(.loadFinished(old, PresentationSnapshot(location: b)), to: &state)
        send(.loadFailed(old, .permissionDenied), to: &state)
        send(.loadFinished(state.loadGeneration, PresentationSnapshot(location: b)), to: &state)
        XCTAssertEqual(state, before)
        finish(&state); XCTAssertEqual(state.location, .recent); XCTAssertNil(state.mutationTarget)
    }
    func testSortReloadSelectionAndMonitorRevision() {
        var state = loaded()
        let selected = entry("/a/two").id
        send(.setSelection([selected], source: .user), to: &state)
        send(.setSort(ItemSort(ascending: false)), to: &state)
        XCTAssertEqual(state.selection, [selected]); XCTAssertEqual(state.snapshot.sortedIDs.first, selected)
        let previous = state.snapshot
        send(.monitorSnapshot(state.monitorGeneration, previous), to: &state)
        XCTAssertNotEqual(state.snapshot, previous); XCTAssertEqual(state.snapshot.sortedEntries, previous.sortedEntries)
        send(.refresh, to: &state); finish(&state, entries: [entry("/a/one")])
        XCTAssertTrue(state.selection.isEmpty)
    }
    func testMonitorAndSearchGenerationsAreIndependent() {
        var state = loaded()
        let monitor = state.monitorGeneration
        let history = state.history
        send(.searchStarted(query("one")), to: &state)
        let stale = state.searchGeneration
        send(.searchStarted(query("two")), to: &state)
        let before = state
        send(.searchResults(stale, [SearchResult(entry: entry("/result"), rank: 1)]), to: &state)
        XCTAssertEqual(state, before)
        send(.searchResults(state.searchGeneration, [SearchResult(entry: entry("/result"), rank: 1)]), to: &state)
        send(.monitorSnapshot(monitor, SnapshotBuilder.build(location: a, entries: [entry("/a/new")])), to: &state)
        XCTAssertEqual(state.snapshot.sortedIDs, [entry("/result").id]); XCTAssertEqual(state.history, history)
        let effects = send(.searchEnded, to: &state)
        XCTAssertEqual(state.snapshot.sortedIDs, [entry("/a/new").id]); XCTAssertEqual(state.history, history)
        XCTAssertEqual(effects.count, 1)
        let ended = state
        send(.searchResults(stale, []), to: &state); XCTAssertEqual(state, ended)
        send(.deactivated, to: &state)
        let inactive = state
        send(.monitorSnapshot(monitor, PresentationSnapshot(location: a)), to: &state)
        send(.monitorEvent(monitor, .rescan), to: &state)
        XCTAssertEqual(state, inactive)
        send(.activated, to: &state)
        XCTAssertNotEqual(state.monitorGeneration, monitor)
    }
    func testCompletionLaneRejectsOldRowsWithoutInvalidatingLoad() {
        var state = loaded()
        send(.addressBar(.beginEditing), to: &state)
        let old = state.completionGeneration
        let load = state.loadGeneration
        send(.addressBar(.textChanged("/different/")), to: &state)
        let current = state
        send(.addressBar(.completions(old, [])), to: &state)
        XCTAssertEqual(state, current); XCTAssertEqual(state.loadGeneration, load)
        XCTAssertNotEqual(state.completionGeneration, old)
    }
    func testRootUpAndVirtualMutations() {
        for location: Location in [.directory(URL(fileURLWithPath: "/")), .recent, .trash] {
            var state = TabState(location: location, homeDirectory: context.homeDirectory)
            let before = state
            XCTAssertTrue(send(.goUp, to: &state).isEmpty); XCTAssertEqual(state, before)
            XCTAssertEqual(state.mutationTarget, location.mutationTarget)
        }
        var state = loaded()
        send(.goUp, to: &state); finish(&state)
        XCTAssertEqual(state.location.mutationTarget?.path, "/"); XCTAssertEqual(state.history.back.count, 1)
    }
    func testInlineRenameDefersSnapshotAndSelectionRemoval() {
        var state = loaded()
        let id = entry("/a/one").id
        send(.setSelection([id], source: .user), to: &state)
        send(.beginInlineRename(id), to: &state)
        let snapshot = state.snapshot
        send(.monitorSnapshot(state.monitorGeneration, PresentationSnapshot(location: a)), to: &state)
        XCTAssertEqual(state.snapshot, snapshot); XCTAssertEqual(state.selection, [id])
        send(.endInlineRename, to: &state)
        XCTAssertTrue(state.selection.isEmpty); XCTAssertTrue(state.snapshot.sortedEntries.isEmpty)
    }
    func testHiddenSettingsAndMonitorEffects() {
        var state = loaded()
        let effects = send(.toggleHidden, to: &state)
        XCTAssertTrue(state.showHidden); XCTAssertTrue(effects.contains(.persistShowHidden(true)))
        finish(&state)
        XCTAssertEqual(send(.monitorEvent(state.monitorGeneration, .rootChanged), to: &state),
                       [.validateNavigation(a, state.monitorGeneration)])
        XCTAssertEqual(send(.monitorEvent(state.monitorGeneration, .changed(paths: ["/a/x"])), to: &state),
                       [.refreshPaths(["/a/x"], state.monitorGeneration)])
        send(.setViewMode(.list), to: &state); XCTAssertEqual(state.viewMode, .list)
        send(.cutSetChanged([entry("/a/x").id]), to: &state); XCTAssertEqual(state.cutIDs.count, 1)
    }
    func testDeniedBackPreservesStacksAndSelection() {
        var state = loaded()
        send(.navigate(b, .push), to: &state); finish(&state, entries: [entry("/b/file")])
        send(.setSelection([entry("/b/file").id], source: .user), to: &state)
        let history = state.history
        send(.goBack, to: &state)
        send(.loadFailed(state.loadGeneration, .permissionDenied), to: &state)
        XCTAssertEqual(state.history, history); XCTAssertEqual(state.location, b)
        XCTAssertEqual(state.selection, [entry("/b/file").id])
    }
    func testExpandedSelectionAndCollapse() {
        var state = loaded()
        let folder = FileEntry(url: URL(fileURLWithPath: "/a/folder"), kind: .directory)
        let child = entry("/a/folder/child")
        let snapshot = SnapshotBuilder.build(location: a, entries: [folder], children: [folder.id: [child]])
        send(.monitorSnapshot(state.monitorGeneration, snapshot), to: &state)
        send(.setSelection([child.id], source: .user), to: &state)
        XCTAssertTrue(state.selection.isEmpty)
        send(.expand(folder.id), to: &state)
        send(.setSelection([child.id], source: .user), to: &state)
        XCTAssertEqual(state.selection, [child.id]); XCTAssertEqual(state.snapshot.entry(child.id), child)
        send(.setScrollAnchor(child.id), to: &state); XCTAssertEqual(state.anchorID, child.id)
        send(.setSort(ItemSort(ascending: false)), to: &state)
        XCTAssertEqual(state.selection, [child.id])
        send(.collapse(folder.id), to: &state); XCTAssertTrue(state.selection.isEmpty)
    }
    func testSortDuringLoadAndHiddenCompletionInvalidation() {
        var state = loaded()
        send(.refresh, to: &state)
        send(.setSort(ItemSort(ascending: false)), to: &state)
        send(.loadFinished(state.loadGeneration, SnapshotBuilder.build(location: a,
                                  entries: [entry("/a/one"), entry("/a/two")])), to: &state)
        XCTAssertEqual(state.snapshot.sort, state.sort)
        XCTAssertEqual(state.snapshot.sortedIDs.first, entry("/a/two").id)
        send(.addressBar(.beginEditing), to: &state)
        let stale = state.completionGeneration
        send(.toggleHidden, to: &state)
        XCTAssertNotEqual(state.completionGeneration, stale)
        let before = state
        send(.addressBar(.completions(stale, [])), to: &state)
        XCTAssertEqual(state, before)
    }
    func testSearchPreservesUnderlyingSelectionAndLoadCannotOverwriteOverlay() {
        var state = loaded()
        let selected = entry("/a/two").id
        send(.setSelection([selected], source: .user), to: &state)
        send(.refresh, to: &state)
        send(.searchStarted(query("two")), to: &state)
        send(.searchResults(state.searchGeneration, [SearchResult(entry: entry("/found"), rank: 0)]), to: &state)
        finish(&state, entries: [entry("/a/two")])
        XCTAssertEqual(state.snapshot.sortedIDs, [entry("/found").id])
        send(.searchStarted(query("  ")), to: &state)
        XCTAssertNil(state.search); XCTAssertEqual(state.selection, [selected])
        XCTAssertEqual(state.snapshot.sortedIDs, [selected])
    }
    func testStaleMonitorAfterNavigationAndFailedSnapshotGuard() {
        var state = loaded()
        let old = state.monitorGeneration
        send(.navigate(b, .push), to: &state)
        send(.loadFinished(state.loadGeneration, PresentationSnapshot(location: b,
                             phase: .failed(.permissionDenied, attempted: b))), to: &state)
        XCTAssertEqual(state.location, a); XCTAssertTrue(state.history.back.isEmpty)
        send(.navigate(b, .push), to: &state); finish(&state)
        let current = state
        send(.monitorSnapshot(old, PresentationSnapshot(location: b)), to: &state)
        XCTAssertEqual(state, current)
    }

}
