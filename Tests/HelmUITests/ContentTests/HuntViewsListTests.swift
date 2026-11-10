#if os(macOS)
import AppKit
import XCTest
import HelmCore
@testable import HelmUI

/// Bug hunt, views: the list and the grid on their own, wired to the reducer the way the window wires them.
/// Each test states what a person expects; a failure here is the bug it names.
@MainActor final class HuntViewsListTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/huntviews")
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: root) }

    private func file(_ path: String, _ kind: FileEntryKind = .regular) -> FileEntry {
        FileEntry(url: root.appendingPathComponent(path), kind: kind)
    }
    private func loadedTab(_ entries: [FileEntry], sort: ItemSort = .defaultSort) -> TabState {
        var tab = TabState(location: .directory(root), homeDirectory: root)
        tab.sort = sort
        tab.isLoading = true
        let snapshot = SnapshotBuilder.build(location: .directory(root), entries: entries, sort: sort)
        return TabReducer.reduce(tab, .loadFinished(tab.loadGeneration, snapshot), context: context).0
    }
    private func harness(_ entries: [FileEntry], sort: ItemSort = .defaultSort) -> HuntViewsListHarness {
        ListMotion.enabled = false
        addTeardownBlock { @MainActor in ListMotion.enabled = true }
        return HuntViewsListHarness(tab: loadedTab(entries, sort: sort), context: context)
    }

    // MARK: Option-click

    /// Option-click on a triangle (and Option-Right) asks AppKit to open the folder and every folder inside it, as
    /// Finder does. Closing that way already closes the folders inside; opening that way should open them.
    func testOptionClickOpensTheFoldersInsideToo() {
        let outer = file("outer", .directory), inner = file("outer/inner", .directory)
        let h = harness([outer, file("a.txt")])
        // What AppKit calls for an Option-click on the triangle.
        h.outline.expandItem(h.item("outer"), expandChildren: true)
        h.send(.childrenLoaded(outer.id, h.tab.loadGeneration, [inner, file("outer/x.txt")]))
        XCTAssertEqual(h.rows.prefix(2), ["outer", "inner"])
        XCTAssertTrue(h.tab.expandedIDs.contains(inner.id), "the folder inside was never asked to open")
        XCTAssertTrue(h.outline.isItemExpanded(h.item("inner") as Any), "the folder inside stays closed after an Option-click")
    }

    /// The folders inside keep opening as each listing arrives, all the way down. A link to a folder stays closed, so
    /// a link back up the tree can't open forever.
    func testOptionClickOpensEachLevelAsItsListingArrives() {
        let outer = file("outer", .directory), inner = file("outer/inner", .directory)
        let deepest = file("outer/inner/deepest", .directory), link = file("outer/link", .symlinkToDirectory)
        let h = harness([outer, file("a.txt")])
        h.outline.expandItem(h.item("outer"), expandChildren: true)
        h.send(.childrenLoaded(outer.id, h.tab.loadGeneration, [inner, link, file("outer/x.txt")]))
        h.send(.childrenLoaded(inner.id, h.tab.loadGeneration, [deepest, file("outer/inner/y.txt")]))
        h.send(.childrenLoaded(deepest.id, h.tab.loadGeneration, [file("outer/inner/deepest/z.txt")]))
        XCTAssertEqual(h.rows, ["outer", "inner", "deepest", "z.txt", "y.txt", "link", "x.txt", "a.txt"])
        XCTAssertEqual(h.tab.expandedIDs, [outer.id, inner.id, deepest.id])
        XCTAssertFalse(h.outline.isItemExpanded(h.item("link") as Any))
        // A plain click opens one level, as before.
        let other = file("other", .directory)
        let plain = harness([other])
        plain.outline.expandItem(plain.item("other"))
        plain.send(.childrenLoaded(other.id, plain.tab.loadGeneration, [file("other/sub", .directory)]))
        XCTAssertEqual(plain.tab.expandedIDs, [other.id])
    }

    // MARK: Inline rename of an app

    /// The words typed over an app's name get “.app” back, so the app stays an app, unless they end in it already.
    func testRenamingAnAppKeepsItsExtension() {
        let app = FileEntry(url: root.appendingPathComponent("Tool.app"), kind: .package)
        for (typed, expected) in [("Gadget", "Gadget.app"), ("Gadget.app", "Gadget.app"), ("Gadget.APP", "Gadget.APP"),
                                  (" Tool ", "Tool.app"), ("", "")] {
            let h = harness([app, file("a.txt")])
            h.list.beginRename(app)
            guard let editor = h.window.firstResponder as? NSTextView else { return XCTFail("no rename field") }
            XCTAssertEqual(editor.string, "Tool")
            editor.string = typed
            editor.didChangeText()
            h.window.makeFirstResponder(nil)
            XCTAssertEqual(h.host.renames, [expected], "typed “\(typed)”")
            XCTAssertEqual(h.nameText(row: h.outline.row(forItem: h.item("Tool.app"))), "Tool")
        }
        // Other files are named exactly as typed.
        let notes = file("notes.txt")
        XCTAssertEqual(notes.fileName(forShownName: "notes"), "notes")
        XCTAssertEqual(app.fileName(forShownName: "Tool"), "Tool.app")
    }

    // MARK: Sizes

    /// An app's size isn't known without walking it, so it reads “—” as a folder does, not its folder entry's
    /// “96 bytes”.
    func testAnAppShowsNoSize() {
        let app = FileEntry(url: root.appendingPathComponent("Tool.app"), kind: .package, size: 96)
        let h = harness([app, FileEntry(url: root.appendingPathComponent("a.txt"), size: 2_000)])
        let column = h.outline.column(withIdentifier: NSUserInterfaceItemIdentifier("size"))
        func size(_ name: String) -> String? {
            (h.outline.view(atColumn: column, row: h.outline.row(forItem: h.item(name)), makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
        }
        XCTAssertEqual(size("Tool.app"), "—")
        XCTAssertEqual(size("a.txt"), ByteCountFormatter.string(fromByteCount: 2_000, countStyle: .file))
    }

    // MARK: Search results

    /// Search results add a Location column. In a list of the usual width all the columns fit, each giving up some room
    /// (AppKit alone squeezed Kind to its narrowest and left Location mostly past the edge), and every column has its
    /// width back when the search ends.
    func testTheLocationColumnFitsInTheList() {
        let h = harness([file("aq.txt"), file("q.txt")])
        h.window.setContentSize(NSSize(width: 807, height: 420))
        h.window.layoutIfNeeded()
        let before = h.columnWidths
        let query = SearchQuery(text: "q", scope: .currentFolder(root), bookmarkPaths: [], homeDirectory: root,
                                lastDirectory: nil, showHidden: false, limit: 100)
        h.send(.searchStarted(query))
        h.send(.searchResults(h.tab.searchGeneration, [SearchResult(entry: file("q.txt"), rank: 0), SearchResult(entry: file("aq.txt"), rank: 1)]))
        let location = h.outline.column(withIdentifier: NSUserInterfaceItemIdentifier("location"))
        let rect = h.outline.rect(ofColumn: location)
        let visible = h.outline.visibleRect.intersection(rect).width
        XCTAssertGreaterThanOrEqual(rect.width, 150, "the Location column is too narrow to read: \(h.columnWidths)")
        XCTAssertEqual(visible, rect.width, accuracy: 1, "\(Int(visible)) of \(Int(rect.width)) points on show: \(h.columnWidths)")
        for column in h.outline.tableColumns where !column.isHidden {
            XCTAssertGreaterThanOrEqual(column.width, FileListController.narrowest[column.identifier.rawValue] ?? 0, h.columnWidths)
        }
        h.send(.searchEnded)
        XCTAssertTrue(h.outline.tableColumns[location].isHidden)
        XCTAssertEqual(h.columnWidths, before)
    }

    // MARK: The column menu

    /// Right-click a column heading: the menu ticks the columns on show. The sorted column's heading carries an arrow
    /// ("Size  ↓"), and the menu matches columns by that heading, so the sorted column reads as hidden.
    func testTheColumnMenuTicksTheSortedColumn() {
        let h = harness([file("a.txt"), file("b.txt")], sort: ItemSort(field: .size, ascending: false))
        guard let menu = h.outline.headerView?.menu else { return XCTFail("no column menu") }
        menu.delegate?.menuNeedsUpdate?(menu)
        let size = menu.items.first { $0.title == "Size" }
        XCTAssertNotNil(size)
        XCTAssertFalse(h.outline.tableColumns.first { $0.identifier.rawValue == "size" }?.isHidden ?? true, "Size is on show")
        XCTAssertEqual(size?.state, .on, "Size is on show but its menu item isn't ticked, so choosing it hides it")
    }

    // MARK: Inline rename

    /// An app shows without “.app”, and the rename field starts from what's shown. Pressing Return without typing
    /// anything must leave the app alone, not rename “Tool.app” to “Tool”.
    func testRenamingAnAppWithoutChangingItKeepsItsName() {
        let app = FileEntry(url: root.appendingPathComponent("Tool.app"), kind: .package)
        let h = harness([app, file("a.txt")])
        h.list.beginRename(app)
        XCTAssertTrue(h.window.firstResponder is NSTextView, "the rename field took the keys")
        // Return, or a click elsewhere: the field ends editing with the words it shows.
        h.window.makeFirstResponder(nil)
        XCTAssertEqual(h.host.renames.count, 1)
        let newName = h.host.renames.first ?? nil
        XCTAssertTrue(newName == nil || newName == "Tool.app", "a rename nobody typed: “Tool.app” would become “\(newName ?? "")”")
    }

    /// Escape cancels and the row goes back to how it looked: “Tool”, not “Tool.app”.
    func testCancellingAnAppRenameShowsItsNameAsBefore() {
        let app = FileEntry(url: root.appendingPathComponent("Tool.app"), kind: .package)
        let h = harness([app, file("a.txt")])
        let row = h.outline.row(forItem: h.item("Tool.app"))
        let before = h.nameText(row: row)
        XCTAssertEqual(before, "Tool")
        h.list.beginRename(app)
        guard let editor = h.window.firstResponder as? NSTextView else { return XCTFail("no rename field") }
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(h.host.renames.count, 1)
        XCTAssertNil(h.host.renames.first ?? "x")
        XCTAssertEqual(h.nameText(row: row), before, "after Escape the row shows the file's full name instead")
    }

    // MARK: The Loading row

    /// A slow folder shows a Loading row. Anything that rebuilds the list meanwhile (switching tabs and back, a
    /// change at the top level, a sort) takes the Loading row away, and the open triangle sits over nothing.
    func testTheLoadingRowSurvivesARebuild() {
        let folder = file("folder", .directory)
        let h = harness([folder, file("a.txt")])
        h.outline.expandItem(h.item("folder"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertTrue(h.list.showsLoadingRowForTesting(folder.id), "the Loading row came up")
        // Switching to another tab and back renders this tab again from scratch.
        h.list.render(h.tab, force: true)
        h.window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertTrue(h.outline.isItemExpanded(h.item("folder") as Any))
        XCTAssertTrue(h.list.showsLoadingRowForTesting(folder.id), "the folder is open over nothing: its Loading row is gone")
    }

    // MARK: The grid

    /// A selection made elsewhere (Back, a paste, a new folder) is brought into view once. The list does this; the
    /// grid scrolls back to it on every later render, such as a file changing in the folder.
    func testTheGridRevealsASelectionOnceNotOnEveryRender() {
        let files = (1...120).map { file(String(format: "file-%03d.txt", $0)) }
        let grid = FileGridController()
        let host = HuntViewsHost()
        grid.host = host
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = grid.view
        var tab = loadedTab(files)
        grid.render(tab, force: true)
        window.layoutIfNeeded()
        // Back to this folder, or a paste: the last file is selected by the app, not by a click.
        tab = TabReducer.reduce(tab, .setSelection([files[119].id], source: .operation), context: context).0
        grid.render(tab, force: false)
        window.layoutIfNeeded()
        guard let clip = (grid.view as? NSScrollView)?.contentView else { return XCTFail("no scroll view") }
        XCTAssertGreaterThan(clip.bounds.origin.y, 0, "the selection is brought into view")
        // The person scrolls back to the top to look at something else.
        clip.scroll(to: .zero)
        (grid.view as? NSScrollView)?.reflectScrolledClipView(clip)
        XCTAssertEqual(clip.bounds.origin.y, 0)
        // A file changes in the folder: a fresh listing arrives with the same selection.
        tab = TabReducer.reduce(tab, .refresh, context: context).0
        let fresh = SnapshotBuilder.build(location: .directory(root), entries: files + [file("new.txt")])
        tab = TabReducer.reduce(tab, .loadFinished(tab.loadGeneration, fresh), context: context).0
        XCTAssertEqual(tab.selection, [files[119].id])
        grid.render(tab, force: false)
        window.layoutIfNeeded()
        XCTAssertEqual(clip.bounds.origin.y, 0, "the grid jumped back to the selection on a later render")
    }
}

/// Records what the views ask of the window, renames included.
@MainActor final class HuntViewsHost: FileContentHost {
    let icons = IconCache()
    var gridIconSize = 96
    var fileTextSize: CGFloat = 14
    var starred: Set<ItemID> = []
    var renames: [String?] = []
    var opened: [[FileEntry]] = []
    var onExpand: ((ItemID) -> Void)?
    var onCollapse: ((ItemID) -> Void)?
    func contentSelectionChanged(_ ids: Set<ItemID>) {}
    func contentOpen(_ entries: [FileEntry], newTab: Bool) { opened.append(entries) }
    func contentMenu(for entries: [FileEntry]) -> NSMenu? { nil }
    func contentRenameFinished(_ entry: FileEntry, newName: String?) { renames.append(newName) }
    func contentSetSort(_ sort: ItemSort) {}
    func contentExpand(_ id: ItemID) { onExpand?(id) }
    func contentCollapse(_ id: ItemID) { onCollapse?(id) }
    func contentDropOperation(_ info: NSDraggingInfo, onto entry: FileEntry?) -> NSDragOperation { [] }
    func contentPerformDrop(_ info: NSDraggingInfo, onto entry: FileEntry?) -> Bool { false }
    func contentDragEnded() {}
    func contentKeyDown(_ event: NSEvent) -> Bool { false }
    func contentActivated() {}
}

/// A list in an offscreen window: its expand and collapse go to the reducer and the result is rendered straight back.
@MainActor final class HuntViewsListHarness {
    let list = FileListController()
    let host = HuntViewsHost()
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
    var outline: NSOutlineView { list.outlineForTesting }
    var rows: [String] { list.rowNamesForTesting }
    func item(_ name: String) -> Any? {
        for row in 0..<outline.numberOfRows {
            if let box = outline.item(atRow: row) as? ItemBox, box.id.url.lastPathComponent == name { return box }
        }
        return nil
    }
    /// The words the name cell shows on a row.
    func nameText(row: Int) -> String? {
        (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
    }
    /// Each column on show with its width, such as "name 340".
    var columnWidths: String {
        outline.tableColumns.filter { !$0.isHidden }.map { "\($0.identifier.rawValue) \(Int($0.width))" }.joined(separator: ", ")
    }
}
#endif
