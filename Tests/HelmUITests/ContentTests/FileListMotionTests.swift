#if os(macOS)
import AppKit
import XCTest
import HelmCore
@testable import HelmUI

/// Stands in for the window: records what the views ask for, and can feed it back to a store-like closure.
@MainActor final class ContentHostDouble: FileContentHost {
    let icons = IconCache()
    var gridIconSize = 96
    var fileTextSize: CGFloat = 14
    var starred: Set<ItemID> = []
    var expanded: [ItemID] = []
    var collapsed: [ItemID] = []
    var selections: [Set<ItemID>] = []
    var opened: [[FileEntry]] = []
    var menuRequests: [[FileEntry]] = []
    var onExpand: ((ItemID) -> Void)?
    var onCollapse: ((ItemID) -> Void)?
    func contentSelectionChanged(_ ids: Set<ItemID>) { selections.append(ids) }
    func contentOpen(_ entries: [FileEntry], newTab: Bool) { opened.append(entries) }
    func contentMenu(for entries: [FileEntry]) -> NSMenu? { menuRequests.append(entries); return nil }
    func contentRenameFinished(_ entry: FileEntry, newName: String?) {}
    func contentSetSort(_ sort: ItemSort) {}
    func contentExpand(_ id: ItemID) { expanded.append(id); onExpand?(id) }
    func contentCollapse(_ id: ItemID) { collapsed.append(id); onCollapse?(id) }
    func contentDropOperation(_ info: NSDraggingInfo, onto entry: FileEntry?) -> NSDragOperation { [] }
    func contentPerformDrop(_ info: NSDraggingInfo, onto entry: FileEntry?) -> Bool { false }
    func contentDragEnded() {}
    func contentKeyDown(_ event: NSEvent) -> Bool { false }
    func contentActivated() {}
}

/// The list opens and closes folders by moving rows, never by rebuilding itself (the list-animation fix).
@MainActor final class FileListMotionTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/motion")
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: root) }

    private func file(_ path: String, _ kind: FileEntryKind = .regular) -> FileEntry {
        FileEntry(url: root.appendingPathComponent(path), kind: kind)
    }
    private func harness(_ entries: [FileEntry], location: Location? = nil, sort: ItemSort = .defaultSort) -> ListHarness {
        ListMotion.enabled = false
        addTeardownBlock { @MainActor in ListMotion.enabled = true }
        let place = location ?? .directory(root)
        var tab = TabState(location: place, homeDirectory: root)
        tab.sort = sort
        tab.isLoading = true
        tab = TabReducer.reduce(tab, .loadFinished(tab.loadGeneration, SnapshotBuilder.build(location: place, entries: entries, sort: sort)), context: context).0
        return ListHarness(tab: tab, context: context)
    }
    private func children(_ harness: ListHarness, _ folder: FileEntry, _ entries: [FileEntry]) {
        harness.send(.childrenLoaded(folder.id, harness.tab.loadGeneration, entries))
    }

    func testOpeningAFolderAddsItsRowsWithoutReloading() {
        let folder = file("folder", .directory)
        let h = harness([folder, file("a.txt"), file("b.txt")])
        XCTAssertEqual(h.list.fullReloads, 1)
        XCTAssertEqual(h.rows, ["folder", "a.txt", "b.txt"])
        let before = h.rowView("a.txt")
        XCTAssertNotNil(before)
        h.send(.expand(folder.id))
        // No listing yet: the triangle may turn, but no rows arrive.
        XCTAssertEqual(h.rows, ["folder", "a.txt", "b.txt"])
        children(h, folder, [file("folder/two.txt"), file("folder/one.txt")])
        XCTAssertEqual(h.rows, ["folder", "one.txt", "two.txt", "a.txt", "b.txt"])
        XCTAssertTrue(h.outline.isItemExpanded(h.item("folder")))
        XCTAssertEqual(h.list.fullReloads, 1, "opening a folder must not rebuild the list")
        XCTAssertTrue(h.rowView("a.txt") === before, "rows below keep their views as they move down")
    }

    func testAClickOpensThroughTheGate() {
        let folder = file("folder", .directory)
        let h = harness([folder, file("a.txt")])
        h.outline.expandItem(h.item("folder"))
        XCTAssertEqual(h.host.expanded, [folder.id], "the click goes to the store")
        XCTAssertEqual(h.rows, ["folder", "a.txt"], "AppKit's own expansion inserts nothing")
        children(h, folder, [file("folder/inner.txt")])
        XCTAssertEqual(h.rows, ["folder", "inner.txt", "a.txt"])
        XCTAssertEqual(h.list.fullReloads, 1)
    }

    func testReopeningWithTheSameListingChangesNothing() {
        let folder = file("folder", .directory)
        let h = harness([folder, file("a.txt")])
        h.outline.expandItem(h.item("folder"))
        let listing = [file("folder/inner.txt"), file("folder/second.txt")]
        children(h, folder, listing)
        h.outline.collapseItem(h.item("folder"))
        XCTAssertEqual(h.host.collapsed, [folder.id])
        XCTAssertEqual(h.rows, ["folder", "a.txt"])
        XCTAssertFalse(h.outline.isItemExpanded(h.item("folder")))
        // Opening it again shows the rows straight away, from the listing the store kept.
        h.outline.expandItem(h.item("folder"))
        XCTAssertEqual(h.rows, ["folder", "inner.txt", "second.txt", "a.txt"])
        let rowCount = h.outline.numberOfRows
        let inner = h.rowView("inner.txt")
        // The fresh read finds the same files: nothing moves and nothing is rebuilt.
        children(h, folder, listing)
        XCTAssertEqual(h.outline.numberOfRows, rowCount)
        XCTAssertTrue(h.rowView("inner.txt") === inner)
        XCTAssertEqual(h.list.fullReloads, 1)
    }

    /// Closing uses the list's own curve only if AppKit's real triangle click and the Left arrow go through the
    /// overridable collapse method, so check both.
    func testTheTriangleAndTheLeftArrowCloseOnTheListsCurve() {
        let folder = file("folder", .directory)
        let h = harness([folder, file("a.txt")])
        XCTAssertTrue(h.list.discloseForTesting(folder.id))
        children(h, folder, [file("folder/inner.txt")])
        XCTAssertEqual(h.rows, ["folder", "inner.txt", "a.txt"])
        XCTAssertTrue(h.list.discloseForTesting(folder.id))
        XCTAssertEqual(h.list.conceals, 1, "the triangle's click reaches collapseItem(_:collapseChildren:)")
        XCTAssertEqual(h.rows, ["folder", "a.txt"])
        XCTAssertEqual(h.host.collapsed, [folder.id])
        XCTAssertTrue(h.list.discloseForTesting(folder.id))
        XCTAssertEqual(h.rows, ["folder", "inner.txt", "a.txt"])
        h.send(.setSelection([folder.id], source: .user))
        h.window.makeFirstResponder(h.outline)
        let left = String(Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey)) ?? " "))
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
                                           windowNumber: h.window.windowNumber, context: nil, characters: left,
                                           charactersIgnoringModifiers: left, isARepeat: false, keyCode: 123) else { return XCTFail("no event") }
        h.outline.keyDown(with: event)
        XCTAssertEqual(h.list.conceals, 2, "the Left arrow reaches it too")
        XCTAssertEqual(h.rows, ["folder", "a.txt"])
        XCTAssertFalse(h.outline.isItemExpanded(h.item("folder")))
        XCTAssertEqual(h.list.fullReloads, 1)
    }

    func testAChangedListingMovesOnlyTheDifference() {
        let folder = file("folder", .directory)
        let h = harness([folder, file("z.txt")])
        h.send(.expand(folder.id))
        children(h, folder, [file("folder/a.txt"), file("folder/c.txt")])
        let kept = h.rowView("a.txt")
        children(h, folder, [file("folder/a.txt"), file("folder/b.txt")])
        XCTAssertEqual(h.rows, ["folder", "a.txt", "b.txt", "z.txt"])
        XCTAssertTrue(h.rowView("a.txt") === kept)
        XCTAssertEqual(h.list.fullReloads, 1)
    }

    func testAFailedListingClosesTheTriangle() {
        let folder = file("folder", .directory)
        let h = harness([folder, file("a.txt")])
        h.send(.expand(folder.id))
        children(h, folder, [file("folder/inner.txt")])
        h.send(.expand(folder.id))
        h.send(.childrenFailed(folder.id, h.tab.loadGeneration, .permissionDenied))
        XCTAssertFalse(h.outline.isItemExpanded(h.item("folder")))
        XCTAssertEqual(h.rows, ["folder", "a.txt"])
    }

    func testANestedOpenFolderComesBackWithItsParent() {
        let outer = file("outer", .directory), inner = file("outer/inner", .directory)
        let h = harness([outer, file("a.txt")])
        h.send(.expand(outer.id))
        children(h, outer, [inner, file("outer/x.txt")])
        h.send(.expand(inner.id))
        children(h, inner, [file("outer/inner/deep.txt")])
        XCTAssertEqual(h.rows, ["outer", "inner", "deep.txt", "x.txt", "a.txt"])
        h.outline.collapseItem(h.item("outer"))
        XCTAssertEqual(h.rows, ["outer", "a.txt"])
        h.outline.expandItem(h.item("outer"))
        XCTAssertEqual(h.rows, ["outer", "inner", "deep.txt", "x.txt", "a.txt"])
        XCTAssertTrue(h.outline.isItemExpanded(h.item("inner")))
        XCTAssertEqual(h.list.fullReloads, 1)
    }

    func testOptionClosingAFolderClosesTheFoldersInsideIt() {
        let outer = file("outer", .directory), inner = file("outer/inner", .directory)
        let h = harness([outer, file("a.txt")])
        h.send(.expand(outer.id))
        children(h, outer, [inner])
        h.send(.expand(inner.id))
        children(h, inner, [file("outer/inner/deep.txt")])
        h.outline.collapseItem(h.item("outer"), collapseChildren: true)
        XCTAssertEqual(h.host.collapsed, [inner.id, outer.id])
        XCTAssertEqual(h.rows, ["outer", "a.txt"])
        XCTAssertTrue(h.tab.expandedIDs.isEmpty)
        // Opened again, the folder inside stays closed.
        h.outline.expandItem(h.item("outer"))
        XCTAssertEqual(h.rows, ["outer", "inner", "a.txt"])
        XCTAssertFalse(h.outline.isItemExpanded(h.item("inner")))
    }

    /// Opening a level never widens the Name column, so Size, Modified and Kind stay put. Rows the list moves in
    /// itself never resize it; AppKit would, though, when it opens a folder whose rows are already there, which is
    /// how a full rebuild (a sort, a tab switch, a top-level change) puts open folders back. So check those too.
    func testTheNameColumnKeepsItsWidth() {
        let folder = file("folder", .directory)
        let long = "a very long name that would widen the column if it were allowed to.txt"
        let h = harness([folder, file("a.txt")])
        XCTAssertFalse(h.outline.autoresizesOutlineColumn)
        let width = h.outline.outlineTableColumn?.width
        h.send(.expand(folder.id))
        children(h, folder, [file("folder/" + long)])
        XCTAssertEqual(h.outline.outlineTableColumn?.width, width)
        h.list.render(h.tab, force: true)
        h.window.layoutIfNeeded()
        XCTAssertEqual(h.list.fullReloads, 2)
        XCTAssertEqual(h.outline.outlineTableColumn?.width, width, "a full rebuild")
        // Another tab on the same folder: new row objects, so AppKit opens the folder afresh with its rows in place.
        var other = TabState(location: h.tab.location, homeDirectory: root)
        other.snapshot = h.tab.snapshot
        other.expandedIDs = h.tab.expandedIDs
        h.list.render(other, force: false)
        h.window.layoutIfNeeded()
        XCTAssertEqual(h.rows, ["folder", long, "a.txt"])
        XCTAssertEqual(h.outline.outlineTableColumn?.width, width, "a tab switch")
    }

    /// A folder closed before something else was published still opens at once, from the listing the store kept.
    func testReopeningAfterAPublicationShowsTheRowsAtOnce() {
        let folder = file("folder", .directory), other = file("other", .directory)
        let h = harness([folder, other, file("a.txt")])
        h.outline.expandItem(h.item("folder"))
        children(h, folder, [file("folder/inner.txt")])
        h.outline.collapseItem(h.item("folder"))
        // Another folder's listing is published while this one is closed, which leaves its rows out of the snapshot.
        h.outline.expandItem(h.item("other"))
        children(h, other, [file("other/x.txt")])
        XCTAssertNil(h.tab.snapshot.children[folder.id])
        h.outline.expandItem(h.item("folder"))
        XCTAssertEqual(h.rows, ["folder", "inner.txt", "other", "x.txt", "a.txt"])
        XCTAssertEqual(h.list.fullReloads, 1)
    }

    /// Recent's Last Opened order is for what you opened; the files inside a folder opened there read A to Z.
    func testAFolderOpenedInRecentListsItsFilesAToZ() {
        func opened(_ path: String, _ kind: FileEntryKind, _ seconds: TimeInterval) -> FileEntry {
            var entry = file(path, kind)
            entry.lastOpenedDate = Date(timeIntervalSince1970: seconds)
            return entry
        }
        let alpha = opened("Alpha", .directory, 10)
        let entries = [alpha, opened("Beta", .directory, 20), opened("old.txt", .regular, 5), opened("new.txt", .regular, 30)]
        for ascending in [false, true] {
            let h = harness(entries, location: .recent, sort: ItemSort(field: .lastOpened, ascending: ascending))
            h.send(.expand(alpha.id))
            children(h, alpha, ["inside.txt", "file10.txt", "Banana.txt", "file2.txt", "apple.txt"].map { file("Alpha/" + $0) })
            let inside = ["apple.txt", "Banana.txt", "file2.txt", "file10.txt", "inside.txt"]
            XCTAssertEqual(h.rows, ascending ? ["Alpha"] + inside + ["Beta", "old.txt", "new.txt"]
                                             : ["Beta", "Alpha"] + inside + ["new.txt", "old.txt"])
            XCTAssertEqual(h.list.sectionSummaryForTesting, ["Folders 2", "Files 2"])
        }
    }

    func testHeadingsAndTheLoadingRowReadOnceForVoiceOver() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        let heading = SectionHeadingView(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        let loading = ListLoadingCell()
        window.contentView?.addSubview(heading); window.contentView?.addSubview(loading)
        heading.apply(title: "Folders", count: 2, textSize: 14, leading: 2, trailing: 16, bottom: 6)
        loading.apply(textSize: 14)
        XCTAssertTrue(heading.isAccessibilityElement())
        XCTAssertEqual(heading.accessibilityLabel(), "Folders, 2 items")
        XCTAssertEqual(heading.accessibilityChildren()?.count ?? 0, 0, "the words aren't read a second time")
        XCTAssertEqual(loading.accessibilityLabel(), "Loading")
        XCTAssertEqual(loading.accessibilityChildren()?.count ?? 0, 0, "nor the Loading row's words and spinner")
        heading.apply(title: "Files", count: 1, textSize: 14, leading: 2, trailing: 16, bottom: 6)
        XCTAssertEqual(heading.accessibilityLabel(), "Files, 1 item")
    }

    /// One curve both ways: rows fade and slide, or with Reduce Motion on, only fade.
    func testReduceMotionOnlyFades() {
        defer { ListMotion.reducesMotionForTesting = nil; ListMotion.enabled = true }
        ListMotion.enabled = true
        ListMotion.reducesMotionForTesting = false
        XCTAssertEqual(ListMotion.reveal, [.effectFade, .slideDown])
        XCTAssertEqual(ListMotion.conceal, [.effectFade, .slideUp])
        XCTAssertEqual(ListMotion.churn, .effectFade)
        ListMotion.reducesMotionForTesting = true
        XCTAssertEqual(ListMotion.reveal, .effectFade)
        XCTAssertEqual(ListMotion.conceal, .effectFade)
        XCTAssertEqual(ListMotion.churn, .effectFade)
        XCTAssertEqual(ListMotion.duration, 0.28)
        ListMotion.enabled = false
        XCTAssertEqual(ListMotion.reveal, [])
        XCTAssertEqual(ListMotion.conceal, [])
    }

    func testASelectionIsRevealedOnceNotOnEveryRender() {
        let folder = file("folder", .directory)
        let files = (1...60).map { file(String(format: "file-%02d.txt", $0)) }
        let h = harness([folder] + files)
        h.send(.setSelection([files[59].id], source: .operation))
        let clip = h.outline.enclosingScrollView?.contentView
        XCTAssertGreaterThan(clip?.bounds.origin.y ?? 0, 0, "a selection made elsewhere is brought into view")
        clip?.scroll(to: .zero)
        h.send(.expand(folder.id))
        XCTAssertEqual(clip?.bounds.origin.y, 0, "opening a folder doesn't jump back to it")
    }

    func testASlowFolderShowsALoadingRowThatGivesWayToItsFiles() {
        let folder = file("folder", .directory)
        let h = harness([folder, file("a.txt")])
        h.outline.expandItem(h.item("folder"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(h.outline.numberOfRows, 3)
        guard let loadingRow = h.outline.item(atRow: 1) else { return XCTFail("no row under the folder") }
        XCTAssertTrue(loadingRow is LoadingBox)
        XCTAssertFalse(h.list.outlineView(h.outline, shouldSelectItem: loadingRow))
        XCTAssertEqual(h.rows, ["folder", "a.txt"], "the Loading row isn't a file")
        children(h, folder, [file("folder/inner.txt")])
        XCTAssertEqual(h.rows, ["folder", "inner.txt", "a.txt"])
        XCTAssertFalse((0..<h.outline.numberOfRows).contains { h.outline.item(atRow: $0) is LoadingBox })
    }

    func testAQuickFolderNeverShowsALoadingRow() {
        let folder = file("folder", .directory)
        let h = harness([folder, file("a.txt")])
        h.outline.expandItem(h.item("folder"))
        children(h, folder, [])
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        // An empty folder shows nothing under it.
        XCTAssertEqual(h.outline.numberOfRows, 2)
        XCTAssertTrue(h.outline.isItemExpanded(h.item("folder")))
    }

    // MARK: Recent's headings

    private var recentEntries: [FileEntry] {
        [file("Beta", .directory), file("Alpha", .directory), file("c.txt"), file("a.txt"), file("b.txt")]
    }

    func testRecentListHasTwoHeadingRowsThatCantBeSelected() {
        let h = harness(recentEntries, location: .recent)
        XCTAssertEqual(h.outline.numberOfRows, 7)
        XCTAssertTrue(h.outline.item(atRow: 0) is SectionBox)
        XCTAssertTrue(h.outline.item(atRow: 3) is SectionBox)
        XCTAssertEqual(h.list.sectionSummaryForTesting, ["Folders 2", "Files 3"])
        XCTAssertEqual(h.rows, ["Alpha", "Beta", "a.txt", "b.txt", "c.txt"])
        for row in [0, 3] {
            guard let heading = h.outline.item(atRow: row) else { return XCTFail("no row \(row)") }
            XCTAssertFalse(h.list.outlineView(h.outline, shouldSelectItem: heading))
            XCTAssertTrue(h.list.outlineView(h.outline, isGroupItem: heading))
            XCTAssertFalse(h.list.outlineView(h.outline, isItemExpandable: heading))
        }
        XCTAssertEqual((h.outline.item(atRow: 4) as? ItemBox)?.id, file("a.txt").id)
        // Selecting a file selects its own row, below the Files heading.
        h.send(.setSelection([file("a.txt").id], source: .user))
        XCTAssertEqual(h.outline.selectedRowIndexes, IndexSet(integer: 4))
        XCTAssertEqual(h.list.selectedRowNamesForTesting, ["a.txt"])
    }

    func testRecentListOpensAFolderInsideItsGroup() {
        let h = harness(recentEntries, location: .recent)
        let alpha = file("Alpha", .directory)
        h.send(.expand(alpha.id))
        children(h, alpha, [file("Alpha/inside.txt")])
        XCTAssertEqual(h.rows, ["Alpha", "inside.txt", "Beta", "a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(h.list.sectionSummaryForTesting, ["Folders 2", "Files 3"])
        XCTAssertTrue(h.outline.item(atRow: 4) is SectionBox)
        XCTAssertEqual(h.list.fullReloads, 1)
    }

    func testRightClickingAHeadingGivesTheBackgroundMenu() {
        let h = harness(recentEntries, location: .recent)
        h.send(.setSelection([file("a.txt").id], source: .user))
        XCTAssertEqual(h.outline.selectedRowIndexes, IndexSet(integer: 4))
        let rect = h.outline.rect(ofRow: 3)
        let point = h.outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: h.window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return XCTFail("no event") }
        _ = h.outline.menu(for: event)
        XCTAssertEqual(h.host.menuRequests.last?.count, 0, "a heading is part of the background")
        XCTAssertTrue(h.outline.selectedRowIndexes.isEmpty)
        // Right-clicking a file still selects it and asks for its menu.
        let fileRect = h.outline.rect(ofRow: 5)
        let filePoint = h.outline.convert(NSPoint(x: fileRect.midX, y: fileRect.midY), to: nil)
        guard let fileEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: filePoint, modifierFlags: [], timestamp: 0,
                                                 windowNumber: h.window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { return XCTFail("no event") }
        _ = h.outline.menu(for: fileEvent)
        XCTAssertEqual(h.host.menuRequests.last?.map(\.name), ["b.txt"])
    }

    func testEverywhereElseTheListHasNoHeadings() {
        let h = harness(recentEntries)
        XCTAssertEqual(h.outline.numberOfRows, 5)
        XCTAssertEqual(h.list.sectionSummaryForTesting, [])
        XCTAssertFalse((0..<5).contains { h.outline.item(atRow: $0) is SectionBox })
    }

    // MARK: Recent's sections in the grid

    private func grid(_ entries: [FileEntry], location: Location) -> (FileGridController, ContentHostDouble, NSWindow, TabState) {
        let controller = FileGridController()
        let host = ContentHostDouble()
        controller.host = host
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        var tab = TabState(location: location, homeDirectory: root)
        tab.isLoading = true
        tab = TabReducer.reduce(tab, .loadFinished(tab.loadGeneration, SnapshotBuilder.build(location: location, entries: entries)), context: context).0
        controller.render(tab, force: true)
        window.layoutIfNeeded()
        return (controller, host, window, tab)
    }

    func testRecentGridHasAFoldersSectionAndAFilesSection() {
        var (controller, _, window, tab) = grid(recentEntries, location: .recent)
        let collection = (controller.view as? NSScrollView)?.documentView as? NSCollectionView
        XCTAssertEqual(collection?.numberOfSections, 2)
        XCTAssertEqual(collection?.numberOfItems(inSection: 0), 2)
        XCTAssertEqual(collection?.numberOfItems(inSection: 1), 3)
        XCTAssertEqual(controller.sectionSummaryForTesting, ["Folders 2", "Files 3"])
        tab = TabReducer.reduce(tab, .setSelection([file("a.txt").id], source: .user), context: context).0
        controller.render(tab, force: false)
        window.layoutIfNeeded()
        XCTAssertEqual(collection?.selectionIndexPaths, [IndexPath(item: 0, section: 1)])
    }

    func testFoldersGridKeepsOneSection() {
        let (controller, _, _, _) = grid(recentEntries, location: .directory(root))
        let collection = (controller.view as? NSScrollView)?.documentView as? NSCollectionView
        XCTAssertEqual(collection?.numberOfSections, 1)
        XCTAssertEqual(collection?.numberOfItems(inSection: 0), 5)
        XCTAssertEqual(controller.sectionSummaryForTesting, [])
    }
}

/// A list in an offscreen window, wired to a tab the way the window wires it: the list's expand and collapse
/// go to the reducer, and the result is rendered straight back.
@MainActor private final class ListHarness {
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
    var outline: NSOutlineView { list.outlineForTesting }
    var rows: [String] { list.rowNamesForTesting }
    func item(_ name: String) -> Any? {
        for row in 0..<outline.numberOfRows {
            if let box = outline.item(atRow: row) as? ItemBox, box.id.url.lastPathComponent == name { return box }
        }
        return nil
    }
    func rowView(_ name: String) -> NSTableRowView? {
        guard let item = item(name) else { return nil }
        let row = outline.row(forItem: item)
        return row >= 0 ? outline.rowView(atRow: row, makeIfNecessary: false) : nil
    }
}
#endif
