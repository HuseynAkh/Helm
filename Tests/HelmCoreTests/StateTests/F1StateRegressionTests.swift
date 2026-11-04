// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class F1StateRegressionTests: XCTestCase {
    private let location: Location = .directory(URL(fileURLWithPath: "/a"))
    private let context = ReducerContext(now: .distantPast, homeDirectory: URL(fileURLWithPath: "/home"))
    private func entry(_ name: String) -> FileEntry { FileEntry(url: URL(fileURLWithPath: "/a/" + name)) }
    private func snapshot(_ names: [String]) -> PresentationSnapshot {
        SnapshotBuilder.build(location: location, entries: names.map(entry))
    }
    private func send(_ action: TabAction, _ state: inout TabState) {
        state = TabReducer.reduce(state, action, context: context).0
    }
    func testMetadataRepublishRetainsDeferredAddsAndRemovals() {
        for names in [["one", "two", "new"], ["two"]] {
            for mode in 0..<4 {
                var state = TabState(location: location, homeDirectory: context.homeDirectory)
                send(.refresh, &state)
                send(.loadFinished(state.loadGeneration, snapshot(["one", "two"])), &state)
                send(.setSelection([entry("one").id], source: .user), &state)
                send(.beginInlineRename(entry("one").id), &state)
                send(.monitorSnapshot(state.monitorGeneration, snapshot(names)), &state)
                switch mode {
                case 0: send(.setSort(ItemSort(ascending: false)), &state)
                case 1: send(.monitorEvent(state.monitorGeneration, .unavailable(.unavailable)), &state)
                case 2:
                    send(.refresh, &state)
                    send(.loadFailed(state.loadGeneration, .permissionDenied), &state)
                default:
                    send(.refresh, &state)
                    let failed = PresentationSnapshot(location: location, phase: .failed(.permissionDenied, attempted: location))
                    send(.loadFinished(state.loadGeneration, failed), &state)
                }
                XCTAssertEqual(state.snapshot.sortedEntries.map(\.name), ["one", "two"])
                send(.endInlineRename, &state)
                let expected = SnapshotBuilder.resort(snapshot(names), sort: state.sort)
                XCTAssertEqual(state.snapshot.sortedIDs, expected.sortedIDs, "mode \(mode)")
                XCTAssertEqual(state.snapshot.sort, state.sort)
                if mode == 1 {
                    XCTAssertEqual(state.snapshot.phase, .failed(.other("unavailable"), attempted: location))
                } else if mode > 1 {
                    XCTAssertEqual(state.snapshot.phase, .failed(.permissionDenied, attempted: location))
                }
                if !names.contains("one") { XCTAssertTrue(state.selection.isEmpty) }
            }
        }
    }

    func testHistoryRestorationSurvivesRestartUntilExplicitSelection() {
        for forward in [false, true] {
            for hidden in [false, true] {
                for explicitSelection in [false, true] {
                    let saved = NavigationHistory.Entry(location: location, selection: [entry("two").id])
                    let history = NavigationHistory(back: forward ? [] : [saved], forward: forward ? [saved] : [])
                    var state = TabState(location: .recent, homeDirectory: context.homeDirectory, history: history)
                    send(forward ? .goForward : .goBack, &state)
                    send(.loadProgress(state.loadGeneration, snapshot(["one"])), &state)
                    XCTAssertTrue(state.selection.isEmpty)
                    if explicitSelection { send(.setSelection([entry("one").id], source: .user), &state) }
                    let retired = state.loadGeneration
                    send(hidden ? .toggleHidden : .refresh, &state)
                    send(.loadFinished(retired, snapshot([])), &state)
                    XCTAssertTrue(state.isLoading)
                    send(.loadFinished(state.loadGeneration, snapshot(["one", "two"])), &state)
                    XCTAssertEqual(state.selection, [entry(explicitSelection ? "one" : "two").id])
                    XCTAssertNil(state.restorationIDs)
                }
            }
        }
    }
}
