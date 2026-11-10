import Foundation
import XCTest
@testable import HelmCore

/// Search and Recent in the store: a search's results keep an order of their own, apart from the folder's sort,
/// and an item Recent lists at the top isn't listed a second time inside a folder opened there.
final class HuntSearchRecentStateTests: XCTestCase {
    private let folder: Location = .directory(URL(fileURLWithPath: "/a", isDirectory: true))
    private let context = ReducerContext(now: .distantPast, homeDirectory: URL(fileURLWithPath: "/home"))

    private func entry(_ path: String, _ kind: FileEntryKind = .regular) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: path), kind: kind)
    }
    private func send(_ action: TabAction, to state: inout TabState) {
        state = TabReducer.reduce(state, action, context: context).0
    }
    private func query(_ text: String) -> SearchQuery {
        SearchQuery(text: text, scope: .userFolders, bookmarkPaths: [], homeDirectory: context.homeDirectory,
                    lastDirectory: nil, showHidden: false, limit: 100)
    }
    /// /a, listed Name A–Z: one, two.
    private func loaded() -> TabState {
        var state = TabState(location: folder, homeDirectory: context.homeDirectory)
        send(.refresh, to: &state)
        send(.loadFinished(state.loadGeneration, SnapshotBuilder.build(location: folder, entries: [entry("/a/one"), entry("/a/two")],
                                                                       sort: state.sort)), to: &state)
        return state
    }
    private func names(_ state: TabState) -> [String] {
        state.snapshot.sortedEntries.prefix(state.snapshot.rootCount).map(\.name)
    }
    /// Results that read b, a in Best Match order and a, b by name.
    private func results(_ state: TabState) -> TabAction {
        .searchResults(state.searchGeneration, [SearchResult(entry: entry("/x/b"), rank: 0), SearchResult(entry: entry("/x/a"), rank: 1)])
    }

    func testAnOrderChosenDuringASearchIsTheResultsOwn() {
        var state = loaded()
        let folderSort = ItemSort(field: .size, ascending: false)
        send(.setSort(folderSort), to: &state)
        let folderNames = names(state)
        send(.searchStarted(query("x")), to: &state)
        send(results(state), to: &state)
        XCTAssertEqual(names(state), ["b", "a"])
        XCTAssertEqual(state.shownSort.field, .relevance, "The results are in Best Match order, and say so.")
        XCTAssertEqual(state.sort, folderSort)
        // Name A–Z for the results only.
        send(.setSort(ItemSort(field: .name)), to: &state)
        XCTAssertEqual(names(state), ["a", "b"])
        XCTAssertEqual(state.shownSort, ItemSort(field: .name))
        XCTAssertEqual(state.sort, folderSort, "The folder's sort is left alone.")
        // New words keep the order chosen for the results.
        send(.searchStarted(query("xy")), to: &state)
        XCTAssertEqual(state.shownSort, ItemSort(field: .name))
        send(.searchResults(state.searchGeneration, [SearchResult(entry: entry("/x/c"), rank: 0), SearchResult(entry: entry("/x/a"), rank: 1)]), to: &state)
        XCTAssertEqual(names(state), ["a", "c"])
        // Best Match chosen for the results, then the search ends: the folder is back in its own order.
        send(.setSort(SortField.pressing(.relevance, on: state.shownSort)), to: &state)
        XCTAssertEqual(names(state), ["c", "a"])
        XCTAssertEqual(state.sort, folderSort)
        send(.searchEnded, to: &state)
        XCTAssertEqual(state.sort, folderSort)
        XCTAssertEqual(state.shownSort, folderSort)
        XCTAssertEqual(state.snapshot.sort, folderSort)
        XCTAssertEqual(names(state), folderNames)
        // The next search starts with Best Match again.
        send(.searchStarted(query("x")), to: &state)
        XCTAssertEqual(state.shownSort.field, .relevance)
    }

    func testFoldersOnTopDuringASearchKeepsBestMatch() {
        var state = loaded()
        send(.searchStarted(query("x")), to: &state)
        send(results(state), to: &state)
        let shown = state.shownSort
        send(.setSort(ItemSort(field: shown.field, ascending: shown.ascending, directoriesFirst: !shown.directoriesFirst)), to: &state)
        XCTAssertEqual(state.shownSort.field, .relevance)
        XCTAssertEqual(state.shownSort.directoriesFirst, !shown.directoriesFirst)
        XCTAssertEqual(state.sort, loaded().sort)
    }

    func testAFolderIsNeverSortedByBestMatch() {
        var state = loaded()
        let before = state
        send(.setSort(ItemSort(field: .relevance)), to: &state)
        XCTAssertEqual(state.sort, before.sort)
        XCTAssertEqual(state.snapshot, before.snapshot)
    }

    func testAnItemListedAtTheTopIsntListedAgainInsideAnOpenFolder() {
        // Recent holds a folder, a folder inside it, and a file inside that.
        func opened(_ path: String, _ kind: FileEntryKind, _ seconds: TimeInterval) -> FileEntry {
            var value = entry(path, kind)
            value.lastOpenedDate = Date(timeIntervalSince1970: seconds)
            return value
        }
        let outer = opened("/r/Outer", .directory, 10)
        let inner = opened("/r/Outer/Inner", .directory, 20)
        let apple = opened("/r/Outer/Inner/apple.txt", .regular, 30)
        // What reading the two folders finds: no dates, since only Recent knows those.
        let outerFiles = [entry("/r/Outer/Inner", .directory), entry("/r/Outer/z.txt")]
        let innerFiles = [entry("/r/Outer/Inner/apple.txt"), entry("/r/Outer/Inner/Banana.txt"), entry("/r/Outer/Inner/cherry.txt")]
        for ascending in [false, true] {
            let sort = ItemSort(field: .lastOpened, ascending: ascending)
            let built = SnapshotBuilder.build(location: .recent, entries: [outer, inner, apple], sort: sort,
                                              children: [outer.id: outerFiles, inner.id: innerFiles])
            XCTAssertEqual(built.children[outer.id]?.sortedIDs, [entry("/r/Outer/z.txt").id])
            XCTAssertEqual(built.children[inner.id]?.sortedIDs.map(\.url.lastPathComponent), ["Banana.txt", "cherry.txt"])
            let shown = built.visibleIDs(expanding: [outer.id, inner.id])
            XCTAssertEqual(Set(shown).count, shown.count, "every row is a different item")
            XCTAssertEqual(built.entry(apple.id)?.lastOpenedDate, apple.lastOpenedDate)
            // Pressing Last Opened again re-sorts what's on show: the files in a folder still read A to Z.
            let resorted = SnapshotBuilder.resort(built, sort: ItemSort(field: .lastOpened, ascending: !ascending))
            XCTAssertEqual(resorted.children[inner.id]?.sortedIDs.map(\.url.lastPathComponent), ["Banana.txt", "cherry.txt"])
        }
    }
}
