// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
@testable import HelmCore

final class OP2NavigationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home", isDirectory: true)
    private let folder = URL(fileURLWithPath: "/a", isDirectory: true)
    func testSameFolderEndsSearchAndRestoresSelectionWithoutReload() {
        let context = ReducerContext(now: .distantPast, homeDirectory: home)
        let entry = FileEntry(url: folder.appendingPathComponent("file"))
        var state = TabState(location: .directory(folder), homeDirectory: home)
        state.snapshot = SnapshotBuilder.build(location: state.location, entries: [entry])
        state.selection = [entry.id]
        let query = SearchQuery(text: "file", scope: .userFolders, bookmarkPaths: [], homeDirectory: home,
                                lastDirectory: nil, showHidden: false, limit: 100)
        state = TabReducer.reduce(state, .searchStarted(query), context: context).0
        let generation = state.searchGeneration
        let (next, effects) = TabReducer.reduce(state, .navigate(.directory(folder), .push), context: context)
        XCTAssertNil(next.search)
        XCTAssertEqual(next.selection, [entry.id])
        XCTAssertEqual(effects, [.cancel(.search, generation)])
        XCTAssertEqual(next.history, state.history)
    }
    func testSameFolderRetriesFailedListingWithoutHistoryEntry() {
        let context = ReducerContext(now: .distantPast, homeDirectory: home)
        var state = TabState(location: .directory(folder), homeDirectory: home)
        state = TabReducer.reduce(state, .navigate(.directory(home), .push), context: context).0
        state = TabReducer.reduce(state, .loadFailed(state.loadGeneration, .permissionDenied), context: context).0
        let history = state.history
        let (retry, effects) = TabReducer.reduce(state, .navigate(.directory(folder), .push), context: context)
        XCTAssertTrue(effects.contains { if case .load = $0 { return true }; return false })
        let ready = SnapshotBuilder.build(location: .directory(folder), entries: [])
        let next = TabReducer.reduce(retry, .loadFinished(retry.loadGeneration, ready), context: context).0
        XCTAssertEqual(next.snapshot.phase, ready.phase)
        XCTAssertEqual(next.history, history)
        XCTAssertFalse(next.isLoading)
    }
    func testLocationCommandEnabledWhileTyping() {
        XCTAssertEqual(CommandValidation.state(for: .location, in: CommandContext(textFieldFocused: true)), .enabled)
    }
}
