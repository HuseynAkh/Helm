import Foundation
import XCTest
@testable import HelmCore

/// Up, Back and the selection they leave. Finder and Nautilus both select the folder you came from after Go ›
/// Enclosing Folder (Cmd-Up), so Cmd-Down goes straight back and the arrow keys carry on from there. And Back
/// brings back what you had selected, which the history keeps for that purpose (B-011).
final class HuntNavigationHistoryTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home", isDirectory: true)
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: home) }

    func testUpSelectsTheFolderYouCameFrom() {
        let parent = URL(fileURLWithPath: "/a", isDirectory: true)
        let child = parent.appendingPathComponent("b", isDirectory: true)
        var state = TabState(location: .directory(child), homeDirectory: home)
        state.snapshot = SnapshotBuilder.build(location: state.location, entries: [])
        state = TabReducer.reduce(state, .goUp, context: context).0
        let listing = SnapshotBuilder.build(location: .directory(parent), entries: [
            FileEntry(url: parent.appendingPathComponent("a.txt")),
            FileEntry(url: child, kind: .directory),
            FileEntry(url: parent.appendingPathComponent("c.txt"))
        ])
        state = TabReducer.reduce(state, .loadFinished(state.loadGeneration, listing), context: context).0
        XCTAssertEqual(state.location, .directory(parent))
        XCTAssertEqual(state.selection, [ItemID(url: child)], "Up should leave the folder you came from selected")
    }

    func testBackBringsBackASelectionInsideAnOpenedFolder() {
        let documents = URL(fileURLWithPath: "/d", isDirectory: true)
        let reports = documents.appendingPathComponent("Reports", isDirectory: true)
        let q1 = reports.appendingPathComponent("q1.txt")
        let roots = [FileEntry(url: reports, kind: .directory), FileEntry(url: documents.appendingPathComponent("a.txt"))]
        var state = TabState(location: .directory(documents), homeDirectory: home)
        state.viewMode = .list  // Folders open in place only in the list.
        state.snapshot = SnapshotBuilder.build(location: state.location, entries: roots)
        // In the list, Reports is opened and q1.txt inside it is selected.
        state = TabReducer.reduce(state, .expand(ItemID(url: reports)), context: context).0
        state = TabReducer.reduce(state, .childrenLoaded(ItemID(url: reports), state.loadGeneration, [FileEntry(url: q1)]), context: context).0
        state = TabReducer.reduce(state, .setSelection([ItemID(url: q1)], source: .user), context: context).0
        XCTAssertEqual(state.selection, [ItemID(url: q1)])
        // Somewhere else, then Back.
        let other = URL(fileURLWithPath: "/o", isDirectory: true)
        state = TabReducer.reduce(state, .navigate(.directory(other), .push), context: context).0
        state = TabReducer.reduce(state, .loadFinished(state.loadGeneration, SnapshotBuilder.build(location: .directory(other), entries: [])), context: context).0
        XCTAssertEqual(state.history.back.last?.selection, [ItemID(url: q1)], "The history kept the selection")
        XCTAssertEqual(state.history.back.last?.expanded, [ItemID(url: reports)], "The history kept the open folder")
        state = TabReducer.reduce(state, .goBack, context: context).0
        let (listed, effects) = TabReducer.reduce(state, .loadFinished(state.loadGeneration, SnapshotBuilder.build(location: .directory(documents), entries: roots)), context: context)
        state = listed
        XCTAssertEqual(state.location, .directory(documents))
        // Reports opens again, and its rows are read, as when it was first opened.
        XCTAssertEqual(state.expandedIDs, [ItemID(url: reports)])
        XCTAssertTrue(effects.contains { if case .loadChildren(_, ItemID(url: reports), _, _) = $0 { return true }; return false },
                      "Reports' rows weren't asked for: \(effects)")
        state = TabReducer.reduce(state, .childrenLoaded(ItemID(url: reports), state.loadGeneration, [FileEntry(url: q1)]), context: context).0
        XCTAssertEqual(state.selection, [ItemID(url: q1)],
                       "Back lost the selection inside the opened folder (open folders: \(state.expandedIDs.map(\.rawValue)))")
        // Once the rows are in, the selection is yours again: a click elsewhere isn't undone by a later refresh.
        state = TabReducer.reduce(state, .setSelection([ItemID(url: reports)], source: .user), context: context).0
        state = TabReducer.reduce(state, .childrenLoaded(ItemID(url: reports), state.loadGeneration, [FileEntry(url: q1)]), context: context).0
        XCTAssertEqual(state.selection, [ItemID(url: reports)])
    }

    /// A folder opened inside another opened folder opens again too, once the outer one's rows are in.
    func testBackReopensFoldersOpenedInsideOpenedFolders() {
        let documents = URL(fileURLWithPath: "/d", isDirectory: true)
        let reports = documents.appendingPathComponent("Reports", isDirectory: true)
        let year = reports.appendingPathComponent("2026", isDirectory: true)
        let q2 = year.appendingPathComponent("q2.txt")
        let other = URL(fileURLWithPath: "/o", isDirectory: true)
        let saved = NavigationHistory.Entry(location: .directory(documents), selection: [ItemID(url: q2)],
                                            expanded: [ItemID(url: reports), ItemID(url: year)])
        var state = TabState(location: .directory(other), homeDirectory: home, history: NavigationHistory(back: [saved]))
        state.viewMode = .list  // Folders open in place only in the list.
        state.snapshot = SnapshotBuilder.build(location: state.location, entries: [])
        state = TabReducer.reduce(state, .goBack, context: context).0
        var effects: [TabEffect]
        (state, effects) = TabReducer.reduce(state, .loadFinished(state.loadGeneration, SnapshotBuilder.build(
            location: .directory(documents), entries: [FileEntry(url: reports, kind: .directory)])), context: context)
        XCTAssertEqual(effects.compactMap(Self.childrenAskedFor), [ItemID(url: reports)], "2026 isn't listed yet")
        (state, effects) = TabReducer.reduce(state, .childrenLoaded(ItemID(url: reports), state.loadGeneration,
                                                                    [FileEntry(url: year, kind: .directory)]), context: context)
        XCTAssertEqual(effects.compactMap(Self.childrenAskedFor), [ItemID(url: year)])
        state = TabReducer.reduce(state, .childrenLoaded(ItemID(url: year), state.loadGeneration, [FileEntry(url: q2)]), context: context).0
        XCTAssertEqual(state.selection, [ItemID(url: q2)])
        XCTAssertEqual(state.snapshot.visibleIDs(expanding: state.expandedIDs),
                       [ItemID(url: reports), ItemID(url: year), ItemID(url: q2)])
    }

    private static func childrenAskedFor(_ effect: TabEffect) -> ItemID? {
        if case .loadChildren(_, let id, _, _) = effect { return id }
        return nil
    }
}
