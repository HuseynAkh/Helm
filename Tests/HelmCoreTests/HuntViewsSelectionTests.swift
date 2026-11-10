import XCTest
@testable import HelmCore

/// Bug hunt, views: what stays selected after an operation inside a folder that's open in the list. Each test states
/// what a person expects; a failure here is the bug it names.
final class HuntViewsSelectionTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/huntviews")
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: root) }
    private func file(_ path: String, _ kind: FileEntryKind = .regular) -> FileEntry {
        FileEntry(url: root.appendingPathComponent(path), kind: kind)
    }
    private func reduce(_ tab: TabState, _ action: TabAction) -> TabState { TabReducer.reduce(tab, action, context: context).0 }

    /// After a rename the window asks for the new name to be selected (`refreshSelecting`), which works at the top
    /// level. Inside an open folder the root listing arrives first, without the new name, the wish is dropped, and
    /// the folder's fresh listing then arrives with nothing left to select.
    func testARenamedFileInsideAnOpenFolderStaysSelected() {
        let nested = file("Nested", .directory)
        var tab = TabState(location: .directory(root), homeDirectory: root)
        tab.viewMode = .list
        tab.isLoading = true
        let roots = [nested, file("top.txt")]
        tab = reduce(tab, .loadFinished(tab.loadGeneration, SnapshotBuilder.build(location: .directory(root), entries: roots)))
        tab = reduce(tab, .expand(nested.id))
        tab = reduce(tab, .childrenLoaded(nested.id, tab.loadGeneration, [file("Nested/n.txt")]))
        tab = reduce(tab, .setSelection([file("Nested/n.txt").id], source: .user))
        XCTAssertEqual(tab.selection, [file("Nested/n.txt").id])
        // n.txt was renamed to n2.txt on disk; the window refreshes and asks for n2.txt to be selected.
        let renamed = file("Nested/n2.txt")
        tab = reduce(tab, .refreshSelecting([renamed.id]))
        tab = reduce(tab, .loadFinished(tab.loadGeneration, SnapshotBuilder.build(location: .directory(root), entries: roots)))
        // The open folder is read again, as every refresh does.
        tab = reduce(tab, .childrenLoaded(nested.id, tab.loadGeneration, [renamed]))
        XCTAssertEqual(tab.snapshot.visibleIDs(expanding: tab.expandedIDs).compactMap { tab.snapshot.entry($0)?.name },
                       ["Nested", "n2.txt", "top.txt"])
        XCTAssertEqual(tab.selection, [renamed.id], "the renamed file lost its selection")
        // Once the folder's listing has landed, the wish is done: closing and opening the folder again doesn't bring
        // back a selection the person has since lost by closing it.
        tab = reduce(tab, .collapse(nested.id))
        XCTAssertTrue(tab.selection.isEmpty)
        tab = reduce(tab, .expand(nested.id))
        tab = reduce(tab, .childrenLoaded(nested.id, tab.loadGeneration, [renamed]))
        XCTAssertTrue(tab.selection.isEmpty, "a refresh that's over still selects")
    }

    /// A tab with Nested open in the list, holding n.txt, and top.txt beside it.
    private func listWithNestedOpen() -> TabState {
        var tab = TabState(location: .directory(root), homeDirectory: root)
        tab.viewMode = .list
        tab.isLoading = true
        tab = reduce(tab, .loadFinished(tab.loadGeneration, SnapshotBuilder.build(location: .directory(root),
                                                                                   entries: [file("Nested", .directory), file("top.txt")])))
        tab = reduce(tab, .expand(file("Nested").id))
        return reduce(tab, .childrenLoaded(file("Nested").id, tab.loadGeneration, [file("Nested/n.txt")]))
    }

    /// The grid shows only the folder's own items, so nothing inside the list's open folders stays selected there,
    /// however it was asked for: by switching views, by a selection, or by a refresh that restores one.
    func testTheGridKeepsOnlyASelectionItShows() {
        var tab = listWithNestedOpen()
        tab = reduce(tab, .setSelection([file("Nested/n.txt").id, file("top.txt").id], source: .user))
        XCTAssertEqual(tab.selection.count, 2)
        tab = reduce(tab, .setViewMode(.grid))
        XCTAssertEqual(tab.selection, [file("top.txt").id])
        XCTAssertEqual(tab.shownIDs.map(\.rawValue), ["/huntviews/Nested", "/huntviews/top.txt"])
        tab = reduce(tab, .setSelection([file("Nested/n.txt").id], source: .user))
        XCTAssertTrue(tab.selection.isEmpty)
        tab = reduce(tab, .refreshSelecting([file("Nested/n.txt").id]))
        tab = reduce(tab, .loadFinished(tab.loadGeneration, SnapshotBuilder.build(location: .directory(root),
                                                                                   entries: [file("Nested", .directory), file("top.txt")])))
        tab = reduce(tab, .childrenLoaded(file("Nested").id, tab.loadGeneration, [file("Nested/n.txt")]))
        XCTAssertTrue(tab.selection.isEmpty)
        // Back in the list the folder is still open, and what's inside it can be selected again.
        tab = reduce(tab, .setViewMode(.list))
        tab = reduce(tab, .setSelection([file("Nested/n.txt").id], source: .user))
        XCTAssertEqual(tab.selection, [file("Nested/n.txt").id])
    }

    /// A sort chosen while searching orders the results, and the folder keeps its own sort: Best Match must never
    /// become a folder's order once the search ends.
    func testASortChosenWhileSearchingOrdersOnlyTheResults() {
        var tab = TabState(location: .directory(root), homeDirectory: root)
        tab.isLoading = true
        tab = reduce(tab, .loadFinished(tab.loadGeneration, SnapshotBuilder.build(location: .directory(root),
                                                                                   entries: [file("aq.txt"), file("q.txt")])))
        let folderSort = tab.sort
        let query = SearchQuery(text: "q", scope: .currentFolder(root), bookmarkPaths: [], homeDirectory: root,
                                lastDirectory: nil, showHidden: false, limit: 100)
        tab = reduce(tab, .searchStarted(query))
        tab = reduce(tab, .searchResults(tab.searchGeneration, [SearchResult(entry: file("q.txt"), rank: 0),
                                                                 SearchResult(entry: file("aq.txt"), rank: 1)]))
        XCTAssertEqual(tab.shownSort.field, .relevance)
        XCTAssertEqual(tab.sort, folderSort)
        tab = reduce(tab, .setSort(ItemSort(field: .name, ascending: false)))
        XCTAssertEqual(tab.shownSort, ItemSort(field: .name, ascending: false))
        XCTAssertEqual(tab.snapshot.sortedEntries.map(\.name), ["q.txt", "aq.txt"])
        tab = reduce(tab, .setSort(SortField.pressing(.relevance, on: tab.shownSort)))
        XCTAssertEqual(tab.shownSort.field, .relevance)
        XCTAssertEqual(tab.sort, folderSort, "the folder took the search's order")
        tab = reduce(tab, .searchEnded)
        XCTAssertEqual(tab.shownSort, folderSort)
        XCTAssertEqual(tab.snapshot.sort, folderSort)
        XCTAssertEqual(tab.snapshot.sortedEntries.map(\.name), ["aq.txt", "q.txt"])
    }

    /// Move to Trash hands the selection to the next item on show, inside open folders too, or the previous one at
    /// the end. What's inside a folder going to the Trash goes with it, so it's passed over.
    func testTheNextItemOnShowTakesTheSelectionAfterTheTrash() {
        let ids = ["Many", "Many/file-01.txt", "Many/file-02.txt", "Nested", "Nested/n.txt", "top.txt"].map { file($0).id }
        func next(_ names: [String]) -> String? {
            SelectionModel.successor(afterRemoving: Set(names.map { file($0).id }), in: ids)?.url.path
        }
        XCTAssertEqual(next(["Many/file-01.txt"]), "/huntviews/Many/file-02.txt")
        XCTAssertEqual(next(["Many/file-02.txt"]), "/huntviews/Nested")
        XCTAssertEqual(next(["Many"]), "/huntviews/Nested", "a file inside the folder going to the Trash")
        XCTAssertEqual(next(["Nested", "top.txt"]), "/huntviews/Many/file-02.txt")
        XCTAssertEqual(next(["top.txt"]), "/huntviews/Nested/n.txt")
        XCTAssertNil(next(["Many", "Nested", "top.txt"]))
        XCTAssertNil(next(["elsewhere.txt"]))
    }
}
