import XCTest
import Foundation
import HelmCore

/// Recent shows its folders apart from its files; everywhere else is one plain run.
final class ContentSectionsTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/recent-items")
    private func item(_ name: String, _ kind: FileEntryKind, opened seconds: TimeInterval = 0) -> FileEntry {
        var entry = FileEntry(url: base.appendingPathComponent(name), kind: kind)
        entry.lastOpenedDate = Date(timeIntervalSince1970: seconds)
        return entry
    }
    /// Folder B, folder A, a link to a folder, an app, an alias and a plain file.
    private var mixed: [FileEntry] {
        [item("B", .directory), item("A", .directory), item("Linked", .symlinkToDirectory),
         item("Tool.app", .package), item("Shortcut", .alias), item("notes.txt", .regular)]
    }
    private func recent(_ entries: [FileEntry], sort: ItemSort = .defaultSort, children: [ItemID: [FileEntry]] = [:]) -> TabState {
        var tab = TabState(location: .recent, homeDirectory: base)
        tab.snapshot = SnapshotBuilder.build(location: .recent, entries: entries, sort: sort, children: children)
        return tab
    }

    func testRecentPutsFoldersAndLinksToFoldersFirstAndEverythingElseUnderFiles() {
        let sections = ContentSections.make(for: recent(mixed))
        XCTAssertTrue(sections.hasHeadings)
        XCTAssertEqual(sections.sections.map(\.title), ["Folders", "Files"])
        XCTAssertEqual(sections.sections.map(\.range), [0..<3, 3..<6])
        XCTAssertEqual(sections.sections.map(\.kind), [.folders, .files])
    }
    func testOneKindAloneHasNoHeadings() {
        for entries in [[item("A", .directory), item("B", .directory)], [item("a.txt", .regular)], []] {
            let sections = ContentSections.make(for: recent(entries))
            XCTAssertFalse(sections.hasHeadings)
            XCTAssertEqual(sections.sections, [ContentSections.Section(kind: .all, range: 0..<entries.count)])
            XCTAssertNil(sections.sections[0].title)
        }
    }
    func testFoldersMixedInWithFilesHaveNoHeadings() {
        let sections = ContentSections.make(for: recent(mixed, sort: ItemSort(directoriesFirst: false)))
        XCTAssertFalse(sections.hasHeadings)
        XCTAssertEqual(sections.sections.first?.range, 0..<6)
    }
    func testASearchFromRecentHasNoHeadings() {
        var tab = recent(mixed)
        tab.search = SearchState(query: SearchQuery(text: "notes", scope: .thisMac, bookmarkPaths: [], homeDirectory: base,
                                                    lastDirectory: nil, showHidden: false, limit: 50))
        XCTAssertFalse(ContentSections.make(for: tab).hasHeadings)
        // Results carry ranks, which also mean a search.
        let ranked = SnapshotBuilder.build(location: .recent, entries: mixed, rankByID: [mixed[0].id: 1])
        XCTAssertFalse(ContentSections.make(for: ranked, searching: false).hasHeadings)
    }
    func testFoldersAndTheTrashNeverSplit() {
        for location in [Location.directory(base), .trash] {
            let snapshot = SnapshotBuilder.build(location: location, entries: mixed)
            XCTAssertFalse(ContentSections.make(for: snapshot, searching: false).hasHeadings, "\(location)")
        }
    }
    func testAnOpenFolderKeepsTheGroupsOnTheTopLevelItems() {
        let inner = FileEntry(url: base.appendingPathComponent("B/inner.txt"))
        let tab = recent(mixed, children: [mixed[0].id: [inner]])
        XCTAssertEqual(tab.snapshot.sortedEntries.count, 7)
        XCTAssertEqual(ContentSections.make(for: tab).sections.map(\.range), [0..<3, 3..<6])
    }
    func testPositionsRoundTrip() {
        let sections = ContentSections.make(for: recent(mixed))
        for index in 0..<6 {
            guard let place = sections.position(ofRoot: index) else { return XCTFail("\(index) has no place") }
            XCTAssertEqual(sections.rootIndex(section: place.section, item: place.item), index)
        }
        XCTAssertEqual(sections.position(ofRoot: 3)?.section, 1)
        XCTAssertEqual(sections.position(ofRoot: 3)?.item, 0)
        XCTAssertNil(sections.position(ofRoot: 6))
        XCTAssertNil(sections.position(ofRoot: -1))
        XCTAssertNil(sections.rootIndex(section: 0, item: 3))
        XCTAssertNil(sections.rootIndex(section: 2, item: 0))
        XCTAssertNil(sections.rootIndex(section: 1, item: -1))
        XCTAssertEqual(ContentSections(rootCount: 0).sections.first?.range, 0..<0)
        XCTAssertNil(ContentSections(rootCount: 0).position(ofRoot: 0))
    }
    func testLastOpenedOrdersEachGroupMostRecentFirst() {
        let entries = [item("Old Folder", .directory, opened: 1), item("old.txt", .regular, opened: 2),
                       item("New Folder", .directory, opened: 3), item("new.txt", .regular, opened: 4)]
        let tab = recent(entries, sort: ItemSort(field: .lastOpened, ascending: false))
        let names = tab.snapshot.sortedEntries.map(\.name)
        XCTAssertEqual(names, ["New Folder", "Old Folder", "new.txt", "old.txt"])
        XCTAssertEqual(ContentSections.make(for: tab).sections.map(\.range), [0..<2, 2..<4])
    }
    /// A folder opened in Recent's list lists its files as the folder itself would, A to Z, whichever way Recent runs:
    /// they were never opened from Helm, so they have no date to sort by.
    func testFilesInsideAFolderOpenedInRecentReadAToZ() {
        let folder = item("Projects", .directory, opened: 100)
        let note = item("notes.txt", .regular, opened: 50)
        let inside = ["file10.txt", "cherry.txt", "Banana.txt", "file2.txt", "apple.txt", "Docs"].map { name in
            FileEntry(url: folder.url.appendingPathComponent(name), kind: name == "Docs" ? .directory : .regular)
        }
        for ascending in [false, true] {
            let sort = ItemSort(field: .lastOpened, ascending: ascending)
            let built = recent([folder, note], sort: sort, children: [folder.id: inside]).snapshot
            let resorted = SnapshotBuilder.resort(recent([folder, note], children: [folder.id: inside]).snapshot, sort: sort)
            for snapshot in [built, resorted] {
                let names = snapshot.children[folder.id]?.sortedIDs.compactMap { snapshot.entry($0)?.name }
                XCTAssertEqual(names, ["Docs", "apple.txt", "Banana.txt", "cherry.txt", "file2.txt", "file10.txt"], "ascending \(ascending)")
            }
        }
    }
}
