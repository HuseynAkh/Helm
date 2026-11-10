#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import HelmCore
@testable import HelmUI

/// Recent's list when it holds a folder and things inside it, and Recent's sort popover.
@MainActor final class HuntSearchRecentListTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/hunt")
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: root) }

    private func file(_ path: String, _ kind: FileEntryKind = .regular) -> FileEntry {
        FileEntry(url: root.appendingPathComponent(path), kind: kind)
    }
    private func opened(_ path: String, _ kind: FileEntryKind, _ seconds: TimeInterval) -> FileEntry {
        var entry = file(path, kind)
        entry.lastOpenedDate = Date(timeIntervalSince1970: seconds)
        return entry
    }
    private func harness(_ entries: [FileEntry], sort: ItemSort) -> HuntListHarness {
        ListMotion.enabled = false
        addTeardownBlock { @MainActor in ListMotion.enabled = true }
        var tab = TabState(location: .recent, homeDirectory: root)
        tab.sort = sort
        tab.isLoading = true
        let snapshot = SnapshotBuilder.build(location: .recent, entries: entries, sort: sort)
        tab = TabReducer.reduce(tab, .loadFinished(tab.loadGeneration, snapshot), context: context).0
        return HuntListHarness(tab: tab, context: context)
    }

    /// Recent holds RecentCase, the Alpha Folder inside it, and apple.txt inside that. Opening RecentCase in the list
    /// used to show Alpha Folder a second time, and the two rows were one item to the list: a click on one lit the
    /// other, and one's triangle opened the other.
    func testAnItemRecentListsIsShownOnceWhenAFolderHoldingItOpens() {
        let recentCase = opened("RecentCase", .directory, 10)
        let alpha = opened("RecentCase/Alpha Folder", .directory, 20)
        let apple = opened("RecentCase/Alpha Folder/apple.txt", .regular, 30)
        let h = harness([recentCase, alpha, apple], sort: ItemSort(field: .lastOpened, ascending: false))
        XCTAssertEqual(h.rows, ["Alpha Folder", "RecentCase", "apple.txt"])
        h.outline.expandItem(h.item("RecentCase"))
        h.children(recentCase, [file("RecentCase/Alpha Folder", .directory), file("RecentCase/Beta Folder", .directory),
                                file("RecentCase/first.txt"), file("RecentCase/second.txt")])
        XCTAssertEqual(h.rows, ["Alpha Folder", "RecentCase", "Beta Folder", "first.txt", "second.txt", "apple.txt"])
        XCTAssertEqual(h.list.sectionSummaryForTesting, ["Folders 2", "Files 1"])
        // A click on Alpha Folder lights its own row: row 1, under the Folders heading.
        h.outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(h.host.selections.last, [alpha.id])
        h.send(.setSelection([alpha.id], source: .user))
        XCTAssertEqual(h.outline.selectedRowIndexes, IndexSet(integer: 1))
        // Its triangle opens it where it is, and its files read A to Z without apple.txt, which Recent lists below.
        XCTAssertTrue(h.list.discloseForTesting(alpha.id))
        h.children(alpha, ["apple.txt", "Banana.txt", "file2.txt", "file10.txt", "inside.txt"].map { file("RecentCase/Alpha Folder/" + $0) })
        XCTAssertTrue(h.outline.isItemExpanded(h.item("Alpha Folder")))
        XCTAssertEqual(h.rows, ["Alpha Folder", "Banana.txt", "file2.txt", "file10.txt", "inside.txt",
                                "RecentCase", "Beta Folder", "first.txt", "second.txt", "apple.txt"])
        // Least Recent First turns Recent's own order round; the files inside a folder still read A to Z.
        h.send(.setSort(ItemSort(field: .lastOpened, ascending: true)))
        XCTAssertEqual(h.rows, ["RecentCase", "Beta Folder", "first.txt", "second.txt",
                                "Alpha Folder", "Banana.txt", "file2.txt", "file10.txt", "inside.txt", "apple.txt"])
        // Every row is a different item, so the list and the store agree on what's on show.
        let shown = h.tab.snapshot.visibleIDs(expanding: h.tab.expandedIDs).compactMap { h.tab.snapshot.entry($0)?.name }
        XCTAssertEqual(shown, h.rows)
    }

    /// Recent's hint about pressing Last Opened again is longer than a line of the popover. The popover pulls its
    /// content as short as the content allows, and the hint used to give way to one line ending in "f…". It keeps
    /// its second line now.
    func testRecentsLongSortHintKeepsItsSecondLineInThePopover() {
        let model = HeaderViewOptionsModel()
        let content = NSHostingController(rootView: HeaderViewOptionsView(model: model)).view
        let frame = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(content)
        let pull = content.heightAnchor.constraint(equalToConstant: 0)
        pull.priority = .defaultLow + 250
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
                                     content.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
                                     content.topAnchor.constraint(equalTo: frame.topAnchor),
                                     content.bottomAnchor.constraint(equalTo: frame.bottomAnchor), pull])
        func heights(_ sort: ItemSort) -> (shown: CGFloat, needed: CGFloat) {
            var state = HeaderViewOptionsState()
            state.sort = sort; state.isGrid = false; state.inRecent = true
            model.state = state
            frame.layoutSubtreeIfNeeded()
            return (frame.fittingSize.height, content.intrinsicContentSize.height)
        }
        // "Press Name again for Z to A." takes one line; "Press Last Opened again for least recent first." takes two.
        let short = heights(ItemSort(field: .name))
        XCTAssertEqual(short.shown, short.needed, accuracy: 0.5)
        for ascending in [false, true] {
            let long = heights(ItemSort(field: .lastOpened, ascending: ascending))
            XCTAssertEqual(long.shown, long.needed, accuracy: 0.5, "nothing in the popover gives way")
            XCTAssertGreaterThan(long.shown - short.shown, 10, "the Last Opened hint takes a second line")
        }
    }
}

/// A list on its own, fed by the reducer, as the window does.
@MainActor private final class HuntListHarness {
    let list = FileListController()
    let host = ContentHostDouble()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
    var tab: TabState
    let context: ReducerContext
    init(tab: TabState, context: ReducerContext) {
        self.tab = tab; self.context = context
        list.host = host
        window.contentView = list.view
        host.onExpand = { [unowned self] id in self.send(.expand(id)) }
        host.onCollapse = { [unowned self] id in self.send(.collapse(id)) }
        list.render(tab, force: true)
        window.layoutIfNeeded()
    }
    func send(_ action: TabAction) {
        tab = TabReducer.reduce(tab, action, context: context).0
        list.render(tab, force: false)
        window.layoutIfNeeded()
    }
    func children(_ folder: FileEntry, _ entries: [FileEntry]) { send(.childrenLoaded(folder.id, tab.loadGeneration, entries)) }
    var outline: NSOutlineView { list.outlineForTesting }
    var rows: [String] { list.rowNamesForTesting }
    func item(_ name: String) -> Any? {
        for row in 0..<outline.numberOfRows {
            if let box = outline.item(atRow: row) as? ItemBox, box.id.url.lastPathComponent == name { return box }
        }
        return nil
    }
}
#endif
