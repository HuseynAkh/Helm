import Foundation
import XCTest
@testable import HelmCore

/// After an operation the window reloads the folder and asks for the item it made to be selected
/// (`refreshSelecting`): a renamed file, a duplicate, what Undo put back. Inside an open folder in the list, that
/// item only arrives with the open folder's own listing, which is read after the folder on show.
final class HuntOperationsSelectionTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var reports: URL { documents.appendingPathComponent("Reports", isDirectory: true) }
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: home) }
    @discardableResult private func send(_ action: TabAction, _ state: inout TabState) -> [TabEffect] {
        let result = TabReducer.reduce(state, action, context: context)
        state = result.0
        return result.1
    }
    private func root(_ extra: [String] = []) -> PresentationSnapshot {
        let folder = FileEntry(url: reports, kind: .directory)
        return SnapshotBuilder.build(location: .directory(documents),
                                     entries: [folder] + (["a.txt"] + extra).map { FileEntry(url: documents.appendingPathComponent($0)) })
    }
    private func inside(_ names: [String]) -> [FileEntry] { names.map { FileEntry(url: reports.appendingPathComponent($0)) } }
    private var reportsID: ItemID { ItemID(url: reports) }

    /// Documents listed, with Reports open in the list and q1.txt inside it selected.
    private func openReports() -> TabState {
        var state = TabState(location: .directory(documents), homeDirectory: home)
        state.viewMode = .list  // Folders open in place only in the list.
        send(.navigate(.directory(documents), .restore), &state)
        send(.loadFinished(state.loadGeneration, root()), &state)
        send(.expand(reportsID), &state)
        send(.childrenLoaded(reportsID, state.loadGeneration, inside(["q1.txt", "2026"])), &state)
        send(.setSelection([ItemID(url: reports.appendingPathComponent("q1.txt"))], source: .user), &state)
        return state
    }
    private func selectedNames(_ state: TabState) -> [String] { state.selection.map(\.url.lastPathComponent).sorted() }

    /// The window's refresh after an operation: the folder on show, then the open folders, as the store reads them.
    private func refresh(selecting ids: Set<ItemID>, children: [String], _ state: inout TabState) {
        send(.refreshSelecting(ids), &state)
        send(.loadFinished(state.loadGeneration, root()), &state)
        send(.childrenLoaded(reportsID, state.loadGeneration, inside(children)), &state)
    }

    func testARenamedItemInsideAnOpenFolderStaysSelected() {
        var state = openReports()
        let renamed = ItemID(url: reports.appendingPathComponent("q1-renamed.txt"))
        refresh(selecting: [renamed], children: ["q1-renamed.txt", "2026"], &state)
        XCTAssertTrue(state.snapshot.visibleIDs(expanding: state.expandedIDs).contains(renamed), "the new name is on show")
        XCTAssertEqual(selectedNames(state), ["q1-renamed.txt"], "the renamed item stays selected, as it does at the top level")
    }

    func testADuplicateInsideAnOpenFolderIsSelected() {
        var state = openReports()
        let copy = ItemID(url: reports.appendingPathComponent("q1 2.txt"))
        refresh(selecting: [copy], children: ["q1.txt", "q1 2.txt", "2026"], &state)
        XCTAssertEqual(selectedNames(state), ["q1 2.txt"])
    }

    /// The same request at the top level works, which is what the smoke run's "Rename" and "Duplicate" check.
    func testAtTheTopLevelTheItemIsSelected() {
        var state = openReports()
        let copy = ItemID(url: documents.appendingPathComponent("a 2.txt"))
        send(.refreshSelecting([copy]), &state)
        send(.loadFinished(state.loadGeneration, root(["a 2.txt"])), &state)
        send(.childrenLoaded(reportsID, state.loadGeneration, inside(["q1.txt", "2026"])), &state)
        XCTAssertEqual(selectedNames(state), ["a 2.txt"])
    }
}
