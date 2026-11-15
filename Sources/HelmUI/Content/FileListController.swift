#if os(macOS)
import AppKit
import HelmCore

/// List view with expandable folders (F-036, F-037). Cells recycle, so large folders cost only their entries.
///
/// The list owns the motion of opening and closing folders. A folder has no rows until the list reveals them,
/// and every reveal or conceal is one insert or remove on `ListMotion`'s curve, so a first opening, opening again,
/// a click, a key and the store all look the same, and the rest of the list is never rebuilt for it. A new snapshot
/// that changes only what's inside folders moves just the rows that changed; anything at the top level (a new
/// place, a sort, a search, an outside change) still rebuilds the whole list, as before.
@MainActor final class FileListController: NSViewController, FileContentPresenting, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var host: FileContentHost?
    private let outline = FileOutlineView()
    private let scroll = NSScrollView()
    private var snapshot: PresentationSnapshot?
    private var boxes: [ItemID: ItemBox] = [:]
    private var tabID: TabID?
    private var snapshotID: Generation?
    private var cut: Set<ItemID> = []
    private var locationColumn: NSTableColumn?
    private var applying = false
    private var rename: RenameEditor?
    /// The children the outline has been given, per open folder. A folder has no rows until the list puts them here.
    private var shown: [ItemID: [ItemID]] = [:]
    /// Folders AppKit shows open, from its own expand and collapse notifications.
    private var opened: Set<ItemID> = []
    /// Open folders showing a Loading row while a slow listing is on its way.
    private var loading: Set<ItemID> = []
    private var loadingBoxes: [ItemID: LoadingBox] = [:]
    private var lastExpanded: Set<ItemID> = []
    private var lastSelection: (ids: Set<ItemID>, source: SelectionSource)?
    private var revealSelection = false
    /// Folders opened with Option (an Option-click on the triangle, or Option-Right) whose folders inside open too, each
    /// as its parent's rows arrive, and how many more folders that request may open.
    private var openingInside: Set<ItemID> = []
    private var openInsideLeft = 0
    /// Recent's Folders and Files headings, when it has both kinds.
    private var sections = ContentSections(rootCount: 0)
    private let folderHeading = SectionBox(.folders)
    private let fileHeading = SectionBox(.files)
    /// How many times the whole list was rebuilt. Opening and closing folders never adds to it.
    private(set) var fullReloads = 0
    /// How many folders closed on the list's own curve, rather than AppKit's.
    private(set) var conceals = 0
    /// Why each result matched, while a search a model helped with has reasons. Each is its row's tooltip.
    private var reasons: [ItemID: SearchReason] = [:]

    private enum Column: String { case name, size, dateModified, kind, location }

    override func loadView() {
        outline.host = { [weak self] in self?.host }
        outline.entryAtRow = { [weak self] row in self?.entry(atRow: row) }
        outline.selectedEntries = { [weak self] in self?.selectedEntries() ?? [] }
        // The first click on a column goes the way you'd want first: A–Z, newest, largest.
        let columns: [(Column, String, CGFloat, Bool)] = [
            (.name, "Name", 340, true), (.size, "Size", 90, false),
            (.dateModified, "Modified", 180, false), (.kind, "Kind", 160, true)]
        for (column, title, width, ascendingFirst) in columns {
            let value = NSTableColumn(identifier: .init(column.rawValue))
            value.title = title; value.width = width; value.minWidth = 50
            value.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: ascendingFirst)
            value.headerCell = FileHeaderCell(textCell: title)
            outline.addTableColumn(value)
            if column == .name { outline.outlineTableColumn = value }
        }
        let location = NSTableColumn(identifier: .init(Column.location.rawValue))
        location.title = "Location"; location.width = Self.locationWidth; location.isHidden = true
        location.headerCell = FileHeaderCell(textCell: "Location")
        outline.addTableColumn(location)
        locationColumn = location
        outline.usesAlternatingRowBackgroundColors = false
        outline.allowsMultipleSelection = true; outline.allowsEmptySelection = true
        outline.allowsTypeSelect = true; outline.style = .inset; outline.rowHeight = 32
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // The Name column keeps its width as levels open, as in Finder, so Size, Modified and Kind never jump sideways.
        outline.autoresizesOutlineColumn = false
        // Recent's headings scroll with the items rather than sticking to the top.
        outline.floatsGroupRows = false
        outline.willCollapse = { [weak self] item in self?.conceal(item) }
        outline.willExpandChildren = { [weak self] item in self?.openInside(item) }
        outline.dataSource = self; outline.delegate = self
        outline.doubleAction = #selector(doubleClicked); outline.target = self
        outline.registerForDraggedTypes(FileDrag.acceptedTypes)
        outline.setDraggingSourceOperationMask(.every, forLocal: false)
        outline.setDraggingSourceOperationMask(.every, forLocal: true)
        outline.setAccessibilityLabel("Files")
        outline.headerView?.menu = columnsMenu()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view = scroll
        chosenWidths = Dictionary(uniqueKeysWithValues: outline.tableColumns.map { ($0.identifier, $0.width) })
        // A narrower or wider list fits its columns again, Name first.
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(roomChanged(_:)), name: NSView.frameDidChangeNotification,
                                               object: scroll.contentView)
    }

    // MARK: Fitting the columns

    /// The widths the columns start at, or the ones the person dragged them to: what a narrower list takes from and
    /// what a wider one gives back.
    private var chosenWidths: [NSUserInterfaceItemIdentifier: CGFloat] = [:]
    /// The room the columns were last fitted to.
    private var fittedRoom: CGFloat = 0
    private var fitting = false

    @objc private func roomChanged(_ notification: Notification) { refitColumns() }

    /// When the list's room changes, as the panel opens, the window narrows or a search adds Location, the columns are
    /// fitted to it again. Name gives way first, down to its narrowest; then the others give the room their words don't
    /// use, so Size, Modified and Kind stay whole; then Name gives a little more, down to its least; and only then do
    /// the others cut their words, down to their narrowest. As the room comes back, the widths come back the same way,
    /// up to the ones the person gave them, and the last column takes what is left over.
    func refitColumns(force: Bool = false) {
        let room = scroll.contentView.bounds.width
        guard !fitting, room > 0, force || abs(room - fittedRoom) > 0.5 else { return }
        let columns = outline.tableColumns.filter { !$0.isHidden }
        guard let nameIndex = columns.firstIndex(where: { $0.identifier.rawValue == Column.name.rawValue }) else { return }
        fittedRoom = room
        fittedRows = FittedRows(snapshot: snapshotID, rows: outline.numberOfRows)
        fitting = true
        let style = outline.columnAutoresizingStyle
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        defer { outline.columnAutoresizingStyle = style; fitting = false }
        let margins = columnMargins()
        let widths = Self.fittedWidths(chosen: chosenForFitting(columns, nameIndex: nameIndex), nameIndex: nameIndex,
                                       narrowest: columns.map { Self.narrowest[$0.identifier.rawValue] ?? $0.minWidth },
                                       room: room - margins, words: { self.wordsWidths(columns) })
        for (column, width) in zip(columns, widths) where abs(column.width - width) > 0.25 { column.width = width }
        outline.tile()
        if widths.reduce(0, +) + margins < room { outline.sizeLastColumnToFit() }
    }

    /// The widths the columns are fitted from. The last column stretches to the list's edge rather than keep the width
    /// it was given, so the width its words need counts as given too: Name gives way for it first, down to its
    /// narrowest, before its words are cut. Search's Location is the exception: a long path would take the room of
    /// every other column, so it keeps the width it was given.
    private func chosenForFitting(_ columns: [NSTableColumn], nameIndex: Int) -> [CGFloat] {
        var chosen = columns.map { chosenWidths[$0.identifier] ?? $0.width }
        if let last = chosen.indices.last, last != nameIndex, columns[last].identifier.rawValue != Column.location.rawValue {
            chosen[last] = max(chosen[last], wordsWidths(columns)[last])
        }
        return chosen
    }

    /// What the list adds round its columns, from where it lays them out: the spacing between them and the inset
    /// style's margin at each end.
    private func columnMargins() -> CGFloat {
        guard let first = outline.tableColumns.firstIndex(where: { !$0.isHidden }),
              let last = outline.tableColumns.lastIndex(where: { !$0.isHidden }) else { return 0 }
        outline.tile()
        let widths = outline.tableColumns.filter { !$0.isHidden }.reduce(0) { $0 + $1.width }
        return max(0, outline.rect(ofColumn: last).maxX + outline.rect(ofColumn: first).minX - widths)
    }

    /// The room in which every column is on show with its words whole, Name at its least: what opening the AI panel
    /// makes room for.
    var roomNeeded: CGFloat {
        let columns = outline.tableColumns.filter { !$0.isHidden }
        guard columns.contains(where: { $0.identifier.rawValue == Column.name.rawValue }) else { return 0 }
        let words = wordsWidths(columns)
        let chosen = chosenForFitting(columns, nameIndex: columns.firstIndex { $0.identifier.rawValue == Column.name.rawValue } ?? 0)
        var total = columnMargins()
        for (index, column) in columns.enumerated() {
            if column.identifier.rawValue == Column.name.rawValue { total += Self.leastNameWidth; continue }
            total += min(chosen[index], words[index])
        }
        // A scroller that takes room from the rows takes it from the columns too.
        total += max(0, scroll.frame.width - scroll.contentView.bounds.width)
        return ceil(total)
    }

    /// The columns' widths for this much room, from the widths they were given. `words` answers how wide each column
    /// must be to show its words whole; it is asked only when Name alone can't make the room.
    static func fittedWidths(chosen: [CGFloat], nameIndex: Int, narrowest: [CGFloat], room: CGFloat,
                             words: () -> [CGFloat]) -> [CGFloat] {
        var widths = chosen
        var excess = widths.reduce(0, +) - room
        let others = widths.indices.filter { $0 != nameIndex }
        excess = give(excess, from: [nameIndex], downTo: narrowest, &widths)
        if excess > 0 {
            let needed = words()
            let whole = widths.indices.map { min(widths[$0], needed.indices.contains($0) ? needed[$0] : 0) }
            excess = give(excess, from: others, downTo: whole, &widths)
        }
        var least = narrowest
        least[nameIndex] = min(narrowest[nameIndex], leastNameWidth)
        excess = give(excess, from: [nameIndex], downTo: least, &widths)
        _ = give(excess, from: others, downTo: narrowest, &widths)
        return widths
    }

    /// Takes up to `excess` from these columns, each in proportion to its width above its floor, and answers what is
    /// still missing.
    private static func give(_ excess: CGFloat, from indices: [Int], downTo floors: [CGFloat], _ widths: inout [CGFloat]) -> CGFloat {
        guard excess > 0 else { return excess }
        let spare = indices.map { max(0, widths[$0] - floors[$0]) }
        let total = spare.reduce(0, +)
        guard total > 0 else { return excess }
        let share = min(1, excess / total)
        var given: CGFloat = 0
        for (index, spare) in zip(indices, spare) {
            let cut = min(spare, (spare * share).rounded(.up))
            widths[index] -= cut
            given += cut
        }
        return excess - given
    }

    /// How narrow Name gets to keep the other columns' words whole, still showing most names.
    static let leastNameWidth: CGFloat = 150

    /// The rows the columns were last fitted to, so a new folder or more rows on show fit them again.
    private struct FittedRows: Equatable { var snapshot: Generation?; var rows: Int }
    private var fittedRows = FittedRows(snapshot: nil, rows: 0)
    private var wordsCache: (key: String, widths: [String: CGFloat])?
    private let wordsProbe: NSTextFieldCell = {
        let cell = NSTextFieldCell(textCell: "")
        cell.isBordered = false; cell.isBezeled = false; cell.lineBreakMode = .byClipping
        return cell
    }()
    /// How many rows are read for the widths their words need: the first ones and those on show.
    private static let wordsRows = 400

    /// How wide each column must be for its heading and the words in its rows to show whole, as its cells draw them.
    private func wordsWidths(_ columns: [NSTableColumn]) -> [CGFloat] {
        let textSize = (host?.fileTextSize ?? 14) - 1
        let ids = columns.map(\.identifier.rawValue)
        let key = "\(snapshotID.map { "\($0)" } ?? "-") \(outline.numberOfRows) \(textSize) \(ids.joined(separator: ","))"
        if let cache = wordsCache, cache.key == key { return ids.map { cache.widths[$0] ?? 0 } }
        var rows = IndexSet(integersIn: 0..<min(outline.numberOfRows, Self.wordsRows))
        let visible = outline.rows(in: outline.visibleRect)
        if visible.length > 0 { rows.insert(integersIn: visible.location..<(visible.location + visible.length)) }
        var words: [String: Set<String>] = [:]
        for row in rows {
            guard let entry = entry(atRow: row) else { continue }
            for id in ids {
                switch Column(rawValue: id) {
                case .size: words[id, default: []].insert(entry.sizeText)
                case .dateModified: words[id, default: []].insert(entry.dateText)
                case .kind: words[id, default: []].insert(entry.kindText)
                case .location: words[id, default: []].insert(entry.url.deletingLastPathComponent().path)
                case .name, nil: break
                }
            }
        }
        wordsProbe.font = .systemFont(ofSize: textSize)
        var widths: [String: CGFloat] = [:]
        for column in columns {
            let id = column.identifier.rawValue
            var widest = ceil(column.headerCell.cellSize.width)
            for text in words[id] ?? [] {
                wordsProbe.stringValue = text
                widest = max(widest, ceil(wordsProbe.cellSize.width) + Self.textCellInset * 2 + 1)
            }
            widths[id] = widest
        }
        wordsCache = (key, widths)
        return ids.map { widths[$0] ?? 0 }
    }
    /// The space a text cell leaves at each side of its words.
    private static let textCellInset: CGFloat = 2

    /// A column the person drags keeps the width they gave it.
    func outlineViewColumnDidResize(_ notification: Notification) {
        guard !fitting, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              let dragged = outline.headerView?.resizedColumn, dragged >= 0, outline.tableColumns.indices.contains(dragged),
              outline.tableColumns[dragged] === column else { return }
        chosenWidths[column.identifier] = column.width
    }

    /// The columns on show, left to right: each one's width, whether the list shows all of it, and whether every row's
    /// words fit in it whole.
    func columnFitForTesting() -> [ListColumnFit] {
        outline.layoutSubtreeIfNeeded()
        let visible = scroll.contentView.documentVisibleRect
        return outline.tableColumns.indices.filter { !outline.tableColumns[$0].isHidden }.map { index in
            let column = outline.tableColumns[index]
            let rect = outline.rect(ofColumn: index)
            var whole = true
            for row in 0..<outline.numberOfRows where entry(atRow: row) != nil {
                guard let cell = outline.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView,
                      let label = cell.textField else { continue }
                cell.layoutSubtreeIfNeeded()
                let words = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 100_000, height: 100_000)).width ?? 0
                if words > label.frame.width + 0.5 { whole = false }
            }
            return ListColumnFit(column: column.identifier.rawValue, width: column.width,
                                 isOnShow: rect.intersection(visible).width >= rect.width - 0.5, wordsWhole: whole)
        }
    }

    /// Each column on show with its width, such as "name 340".
    var columnWidthsForTesting: [String: CGFloat] {
        Dictionary(uniqueKeysWithValues: outline.tableColumns.filter { !$0.isHidden }.map { ($0.identifier.rawValue, $0.width) })
    }

    func render(_ tab: TabState, force: Bool) {
        apply(tab, force: force)
        // After the rows are in step, so opening a folder goes through the store as a click does.
        openFoldersInside()
    }

    private func apply(_ tab: TabState, force: Bool) {
        applying = true
        defer { applying = false }
        showLocationColumn(tab.search != nil)
        let cutChanged = tab.cutIDs != cut
        cut = tab.cutIDs
        let textSize = host?.fileTextSize ?? 14
        let rowHeight = ceil(textSize * 2.25)
        let textChanged = outline.rowHeight != rowHeight
        if textChanged { outline.rowHeight = rowHeight }
        let samePlace = tab.id == tabID && tab.snapshot.location == snapshot?.location
        let newSnapshot = tab.snapshot.id != snapshotID
        let nextSections = ContentSections.make(for: tab)
        if force || textChanged || cutChanged || !samePlace || nextSections != sections
            || (newSnapshot && !Self.onlyChildrenChanged(from: snapshot, to: tab.snapshot, loading: tab.isLoading)) {
            reloadAll(tab, sections: nextSections, keepingScroll: samePlace)
        } else if newSnapshot || tab.expandedIDs != lastExpanded {
            let previous = snapshot
            snapshot = tab.snapshot; snapshotID = tab.snapshot.id
            reconcile(tab, previous: previous)
        }
        lastExpanded = tab.expandedIDs
        let descriptor = NSSortDescriptor(key: tab.snapshot.sort.field.rawValue, ascending: tab.snapshot.sort.ascending)
        if outline.sortDescriptors.first?.key != descriptor.key || outline.sortDescriptors.first?.ascending != descriptor.ascending {
            outline.sortDescriptors = [descriptor]
        }
        showSortDirection(tab.snapshot.sort)
        applySelection(tab)
        showReasons(tab.search?.assist?.reasons ?? [:])
        // Other rows can need more room for their words, or less.
        if textChanged || FittedRows(snapshot: snapshotID, rows: outline.numberOfRows) != fittedRows { refitColumns(force: true) }
    }

    /// Puts each result's reason on its row as the tooltip, and takes it off once there's none. The reasons can come
    /// after the rows, so the rows on show are brought up to date here; rows made later get theirs as they're made.
    private func showReasons(_ next: [ItemID: SearchReason]) {
        guard next != reasons else { return }
        reasons = next
        outline.enumerateAvailableRowViews { rowView, row in
            let tip = self.entry(atRow: row).flatMap { self.reasons[$0.id]?.line }
            for column in 0..<rowView.numberOfColumns { (rowView.view(atColumn: column) as? NSView)?.toolTip = tip }
        }
    }

    /// Whether a new snapshot changes only what's inside folders, so the list can move just those rows.
    static func onlyChildrenChanged(from old: PresentationSnapshot?, to new: PresentationSnapshot, loading: Bool) -> Bool {
        guard let old, !loading, old.sort == new.sort, old.rankByID == nil, new.rankByID == nil,
              old.rootCount == new.rootCount else { return false }
        return old.sortedEntries.prefix(old.rootCount).elementsEqual(new.sortedEntries.prefix(new.rootCount))
    }

    /// Rebuilds everything: a new place, tab, sort, search, text size or top-level change. Open folders come back
    /// open at once, with no motion.
    private func reloadAll(_ tab: TabState, sections next: ContentSections, keepingScroll: Bool) {
        let origin = scroll.contentView.bounds.origin
        // New row objects for a new place or tab, so AppKit can't carry a folder's open state across.
        let samePlace = tab.id == tabID && tab.snapshot.location == snapshot?.location
        if !samePlace {
            boxes = [:]; loadingBoxes = [:]; opened = []; openingInside = []
        }
        // A folder still waiting for its listing keeps its Loading row through the rebuild.
        let stillLoading = samePlace ? loading : []
        snapshot = tab.snapshot; tabID = tab.id; snapshotID = tab.snapshot.id
        sections = next
        loading = []
        shown = [:]
        for id in tab.expandedIDs {
            if let ids = tab.snapshot.children[id]?.sortedIDs { shown[id] = ids } else if stillLoading.contains(id) { loading.insert(id) }
        }
        outline.reloadData()
        fullReloads += 1
        expand(tab)
        for id in opened.subtracting(tab.expandedIDs) where outline.isItemExpanded(box(id)) { outline.collapseItem(box(id)) }
        pruneShown()
        // Any other open folder still waiting shows one after the usual moment, as when it opened.
        for id in tab.expandedIDs where shown[id] == nil && !loading.contains(id) { scheduleLoadingRow(for: id) }
        if keepingScroll { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
    }

    /// Brings the outline in step with the store when only folders' contents or their open state changed,
    /// moving just the rows that differ, all on one curve.
    private func reconcile(_ tab: TabState, previous: PresentationSnapshot?) {
        var arrived: Set<ItemID> = []
        ListMotion.run {
            // Close what the store closed, such as a folder that couldn't be read. The collapse hook conceals the rows first.
            for id in opened.subtracting(tab.expandedIDs) where outline.row(forItem: box(id)) >= 0 && outline.isItemExpanded(box(id)) {
                outline.collapseItem(box(id))
            }
            // Folders already open whose listing changed: only the rows that came or went move, by fading.
            let visible = Set(tab.snapshot.visibleIDs(expanding: tab.expandedIDs))
            var reordered: [ItemID] = []
            outline.beginUpdates()
            for (id, before) in shown where visible.contains(id) {
                guard let after = tab.snapshot.children[id]?.sortedIDs, after != before else { continue }
                guard let change = SnapshotDiff.childChange(from: before, to: after) else { reordered.append(id); continue }
                shown[id] = after
                if !change.removed.isEmpty { outline.removeItems(at: change.removed, inParent: box(id), withAnimation: ListMotion.churn) }
                if !change.inserted.isEmpty { outline.insertItems(at: change.inserted, inParent: box(id), withAnimation: ListMotion.churn) }
                arrived.formUnion(change.inserted.map { after[$0] })
            }
            outline.endUpdates()
            for id in reordered {
                shown[id] = tab.snapshot.children[id]?.sortedIDs
                outline.reloadItem(box(id), reloadChildren: true)
            }
            // Reveal folders that opened, top down, so open folders inside them come out in the same motion.
            for id in tab.snapshot.visibleIDs(expanding: tab.expandedIDs) where tab.expandedIDs.contains(id) && shown[id] == nil {
                guard let ids = tab.snapshot.children[id]?.sortedIDs, outline.row(forItem: box(id)) >= 0 else { continue }
                reveal(ids, in: id)
                arrived.formUnion(ids)
            }
            // Rows still on show whose details changed (a size, a date) are refreshed where they are.
            var rows = IndexSet()
            for ids in shown.values {
                for child in ids where !arrived.contains(child) {
                    guard let old = previous?.entry(child), let new = tab.snapshot.entry(child), old != new else { continue }
                    let row = outline.row(forItem: box(child))
                    if row >= 0 { rows.insert(row) }
                }
            }
            if !rows.isEmpty { outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns)) }
        }
        pruneShown()
    }

    /// Opens a folder's rows: they fade and slide in under it. A Loading row, if one is up, cross-fades into them,
    /// and an empty folder shows nothing, as in Finder.
    private func reveal(_ ids: [ItemID], in id: ItemID) {
        let item = box(id)
        if !outline.isItemExpanded(item) { outline.expandItem(item) }
        outline.beginUpdates()
        if loading.remove(id) != nil {
            outline.removeItems(at: IndexSet(integer: 0), inParent: item, withAnimation: ListMotion.churn)
            shown[id] = ids
            if !ids.isEmpty { outline.insertItems(at: IndexSet(integersIn: 0..<ids.count), inParent: item, withAnimation: ListMotion.churn) }
        } else {
            shown[id] = ids
            if !ids.isEmpty { outline.insertItems(at: IndexSet(integersIn: 0..<ids.count), inParent: item, withAnimation: ListMotion.reveal) }
        }
        outline.endUpdates()
    }

    /// Called just before AppKit closes a folder, however that happens (a click, a key or the store): its rows leave
    /// on the list's curve, then AppKit closes a folder with nothing in it and only turns the triangle.
    private func conceal(_ item: Any) {
        guard let box = item as? ItemBox else { return }
        let count = loading.contains(box.id) ? 1 : shown[box.id]?.count
        guard let count else { return }
        // AppKit drops selected rows as they go; the store hears about it from the collapse itself.
        let wasApplying = applying
        applying = true
        defer { applying = wasApplying }
        conceals += 1
        ListMotion.run {
            outline.beginUpdates()
            shown[box.id] = nil; loading.remove(box.id)
            if count > 0 { outline.removeItems(at: IndexSet(integersIn: 0..<count), inParent: box, withAnimation: ListMotion.conceal) }
            outline.endUpdates()
        }
    }

    /// Keeps the gate true to what AppKit shows, including rows AppKit took away by itself.
    private func pruneShown() {
        shown = shown.filter { outline.row(forItem: box($0.key)) >= 0 && outline.isItemExpanded(box($0.key)) }
        loading = loading.filter { outline.row(forItem: box($0)) >= 0 && outline.isItemExpanded(box($0)) }
    }

    /// A folder whose listing hasn't come after a moment shows a Loading row, so an open triangle never sits over
    /// nothing for long on a slow disk or share. Quick folders never show it.
    private func scheduleLoadingRow(for id: ItemID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.showLoadingRow(for: id) }
    }
    private func showLoadingRow(for id: ItemID) {
        guard let item = boxes[id], shown[id] == nil, !loading.contains(id), lastExpanded.contains(id),
              snapshot?.children[id] == nil, outline.row(forItem: item) >= 0, outline.isItemExpanded(item) else { return }
        ListMotion.run {
            outline.beginUpdates()
            loading.insert(id)
            outline.insertItems(at: IndexSet(integer: 0), inParent: item, withAnimation: ListMotion.reveal)
            outline.endUpdates()
        }
    }
    private func loadingBox(for id: ItemID) -> LoadingBox {
        if let value = loadingBoxes[id] { return value }
        let value = LoadingBox(parent: id); loadingBoxes[id] = value
        return value
    }

    /// One Option-click opens at most this many folders inside, so a deep tree can't flood the list.
    static let openInsideLimit = 200
    /// Option-click on a triangle, or Option-Right, opens the folder and the folders inside it, as in Finder. AppKit
    /// can't open those itself, since a folder has no rows until its listing arrives, so the list opens each one as
    /// its parent's rows come in.
    private func openInside(_ item: Any) {
        guard let box = item as? ItemBox, snapshot?.rankByID == nil else { return }
        if openingInside.isEmpty { openInsideLeft = Self.openInsideLimit }
        openingInside.insert(box.id)
    }
    /// Opens the folders inside a folder opened with Option, once its rows are on show, the way a click on each
    /// triangle would: the store hears of it, and a slow folder shows its Loading row.
    private func openFoldersInside() {
        guard !openingInside.isEmpty, !applying else { return }
        guard snapshot?.rankByID == nil else { openingInside = []; return }
        for id in openingInside {
            guard let rows = shown[id] else { continue }
            openingInside.remove(id)
            for child in rows where openInsideLeft > 0 {
                // Links are left closed, so a link back up the tree can't open forever.
                let item = box(child)
                guard snapshot?.entry(child)?.kind == .directory, outline.row(forItem: item) >= 0, !outline.isItemExpanded(item) else { continue }
                openInsideLeft -= 1
                openingInside.insert(child)
                outline.expandItem(item)
            }
        }
    }

    /// Search results add a Location column at the end, and the columns on show are fitted to the list again, so
    /// Location isn't left past the window's edge. Their widths come back when the search ends.
    private func showLocationColumn(_ searching: Bool) {
        guard let location = locationColumn, location.isHidden == searching else { return }
        location.isHidden = !searching
        refitColumns(force: true)
    }
    static let locationWidth: CGFloat = 240
    /// How narrow each column gets to make room, still showing most of what it says.
    static let narrowest: [String: CGFloat] = [Column.name.rawValue: 180, Column.size.rawValue: 64, Column.dateModified.rawValue: 120,
                                               Column.kind.rawValue: 90, Column.location.rawValue: 150]

    /// The sorted column's title carries a plain arrow: up for ascending, down for descending.
    private func showSortDirection(_ sort: ItemSort) {
        let names: [String: String] = [Column.name.rawValue: "Name", Column.size.rawValue: "Size",
                                       Column.dateModified.rawValue: "Modified", Column.kind.rawValue: "Kind"]
        for column in outline.tableColumns {
            guard let name = names[column.identifier.rawValue], let cell = column.headerCell as? FileHeaderCell else { continue }
            let active = column.identifier.rawValue == sort.field.rawValue
            let title = active ? "\(name)  \(sort.ascending ? "↑" : "↓")" : name
            if cell.stringValue != title || cell.isSorted != active {
                cell.isSorted = active
                cell.stringValue = title
                cell.font = .systemFont(ofSize: 13, weight: active ? .semibold : .regular)
                outline.headerView?.needsDisplay = true
            }
        }
    }

    /// Right-click a column header to show or hide columns. The name always stays.
    private func columnsMenu() -> NSMenu {
        let menu = NSMenu()
        for column in outline.tableColumns where column.identifier.rawValue != Column.name.rawValue && column.identifier.rawValue != Column.location.rawValue {
            let target = ClosureMenuTarget { column.isHidden.toggle() }
            let item = NSMenuItem(title: column.title, action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
            item.target = target; item.representedObject = target
            // Matched to its column by identifier: the sorted column's heading carries an arrow, such as "Size  ↓".
            item.identifier = column.identifier
            item.state = .on
            menu.addItem(item)
        }
        menu.delegate = columnMenuSync
        return menu
    }
    private lazy var columnMenuSync = ColumnMenuSync { [weak self] in self?.outline.tableColumns ?? [] }

    private func expand(_ tab: TabState) {
        for id in tab.snapshot.visibleIDs(expanding: tab.expandedIDs) where tab.expandedIDs.contains(id) {
            outline.expandItem(box(id))
        }
    }
    private func applySelection(_ tab: TabState) {
        var rows = IndexSet()
        for id in tab.selection {
            let row = outline.row(forItem: box(id))
            if row >= 0 { rows.insert(row) }
        }
        if rows != outline.selectedRowIndexes { outline.selectRowIndexes(rows, byExtendingSelection: false) }
        // A selection made elsewhere (Back, a paste, a new folder) is brought into view once, when it arrives,
        // and never again on later renders, such as opening a folder.
        if lastSelection?.ids != tab.selection || lastSelection?.source != tab.selectionSource {
            lastSelection = (tab.selection, tab.selectionSource)
            revealSelection = tab.selectionSource != .widget && tab.selectionSource != .user
        }
        if revealSelection, let first = rows.first {
            outline.scrollRowToVisible(first)
            revealSelection = false
        }
    }

    func focusContent() { view.window?.makeFirstResponder(outline) }
    var keyResponder: NSResponder? { outline }

    func beginRename(_ entry: FileEntry) {
        let row = outline.row(forItem: box(entry.id))
        guard row >= 0, let column = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == Column.name.rawValue }) else {
            host?.contentRenameFinished(entry, newName: nil); return
        }
        outline.scrollRowToVisible(row)
        guard let cell = outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView, let field = cell.textField else {
            host?.contentRenameFinished(entry, newName: nil); return
        }
        rename = RenameEditor(entry: entry, field: field) { [weak self] entry, name in
            self?.rename = nil
            self?.host?.contentRenameFinished(entry, newName: name)
        }
        rename?.begin(in: view.window)
    }

    func screenFrame(of id: ItemID) -> NSRect? {
        let row = outline.row(forItem: box(id))
        guard row >= 0, let window = view.window else { return nil }
        let rect = outline.rect(ofRow: row)
        guard outline.visibleRect.intersects(rect) else { return nil }
        // Zoom from the icon, as Finder does, rather than from the whole row.
        if let cell = nameCell(row: row) {
            return window.convertToScreen(cell.iconView.convert(cell.iconView.bounds, to: nil))
        }
        return window.convertToScreen(outline.convert(rect, to: nil))
    }
    func image(of id: ItemID) -> NSImage? {
        let row = outline.row(forItem: box(id))
        return row >= 0 ? nameCell(row: row)?.iconView.image : nil
    }
    private func nameCell(row: Int) -> ListNameCell? {
        guard let column = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == Column.name.rawValue }) else { return nil }
        return outline.view(atColumn: column, row: row, makeIfNecessary: false) as? ListNameCell
    }

    private func box(_ id: ItemID) -> ItemBox {
        if let value = boxes[id] { return value }
        let value = ItemBox(id); boxes[id] = value
        return value
    }
    private func entry(_ item: Any?) -> FileEntry? {
        guard let box = item as? ItemBox else { return nil }
        return snapshot?.entry(box.id)
    }
    private func entry(atRow row: Int) -> FileEntry? { row >= 0 ? entry(outline.item(atRow: row)) : nil }
    private func selectedEntries() -> [FileEntry] { outline.selectedRowIndexes.compactMap { entry(atRow: $0) } }

    // MARK: Data

    // A folder's rows come from `shown`, never straight from the snapshot, so AppKit's own expansion (a click, an
    // arrow key, Option-click) inserts nothing and only turns the triangle; the list then moves the rows in itself.
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let snapshot else { return 0 }
        guard let item else { return snapshot.rootCount + (sections.hasHeadings ? sections.sections.count : 0) }
        guard let box = item as? ItemBox else { return 0 }
        return loading.contains(box.id) ? 1 : shown[box.id]?.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let snapshot else { return ItemBox(ItemID(rawValue: "/")) }
        guard let box = item as? ItemBox else { return rootItem(at: index, in: snapshot) }
        if loading.contains(box.id) { return loadingBox(for: box.id) }
        if let ids = shown[box.id], ids.indices.contains(index) { return self.box(ids[index]) }
        return ItemBox(ItemID(rawValue: "/"))
    }
    /// The top level: in Recent with both kinds, each group's heading followed by its items.
    private func rootItem(at index: Int, in snapshot: PresentationSnapshot) -> Any {
        guard sections.hasHeadings else { return box(snapshot.sortedEntries[index].id) }
        var offset = index
        for section in sections.sections {
            if offset == 0 { return section.kind == .files ? fileHeading : folderHeading }
            offset -= 1
            if offset < section.range.count { return box(snapshot.sortedEntries[section.range.lowerBound + offset].id) }
            offset -= section.range.count
        }
        return ItemBox(ItemID(rawValue: "/"))
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard snapshot?.rankByID == nil else { return false }
        return entry(item)?.isDirectoryLike ?? false
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SectionBox }
    /// Headings and Loading rows aren't files, so they can't be selected; arrow keys pass over them.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is ItemBox }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        item is SectionBox ? SectionHeadingRowView() : nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        // A heading is one cell across the whole row, which AppKit asks for with no column.
        if let heading = item as? SectionBox { return tableColumn == nil ? headingCell(heading) : nil }
        if item is LoadingBox {
            guard tableColumn?.identifier.rawValue == Column.name.rawValue else { return nil }
            let cell = (outlineView.makeView(withIdentifier: ListLoadingCell.identifier, owner: nil) as? ListLoadingCell) ?? ListLoadingCell()
            cell.apply(textSize: host?.fileTextSize ?? 14)
            return cell
        }
        guard let entry = entry(item), let raw = tableColumn?.identifier.rawValue, let column = Column(rawValue: raw) else { return nil }
        switch column {
        case .name:
            let id = NSUserInterfaceItemIdentifier("name")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? ListNameCell) ?? ListNameCell(identifier: id)
            var shown = entry
            shown.isStarred = host?.starred.contains(entry.id) ?? false
            cell.apply(shown, isCut: cut.contains(entry.id), icons: host?.icons, textSize: host?.fileTextSize ?? 14,
                       scale: view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
            cell.toolTip = reasons[entry.id]?.line
            return cell
        case .size: return textCell(outlineView, "size", entry.sizeText, alignment: .right, entry: entry)
        case .dateModified: return textCell(outlineView, "date", entry.dateText, alignment: .left, entry: entry)
        case .kind: return textCell(outlineView, "kind", entry.kindText, alignment: .left, entry: entry)
        case .location: return textCell(outlineView, "location", entry.url.deletingLastPathComponent().path, alignment: .left, entry: entry)
        }
    }
    /// A heading spans the row. Its label lines up with the file names' icons below it.
    private func headingCell(_ heading: SectionBox) -> NSView {
        let cell = (outline.makeView(withIdentifier: ListSectionHeadingCell.identifier, owner: nil) as? ListSectionHeadingCell) ?? ListSectionHeadingCell()
        let section = sections.sections.first { $0.kind == heading.kind }
        let textSize = host?.fileTextSize ?? 14
        cell.heading.apply(title: section?.title ?? "", count: section?.range.count ?? 0, textSize: textSize,
                           leading: Self.headingLeading, trailing: 16, bottom: max(5, ceil(textSize * 0.4)))
        return cell
    }
    /// The heading's cell starts where a top-level row's name cell does, so this lines the label up with the icons.
    static let headingLeading: CGFloat = 2

    private func textCell(_ outlineView: NSOutlineView, _ name: String, _ text: String, alignment: NSTextAlignment, entry: FileEntry) -> NSView {
        let id = NSUserInterfaceItemIdentifier(name)
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? ListTextCell) ?? ListTextCell(identifier: id)
        cell.apply(text, alignment: alignment, textSize: (host?.fileTextSize ?? 14) - 1)
        cell.alphaValue = ContentLeafPresentation.opacity(isHidden: entry.isHidden, isCut: cut.contains(entry.id))
        cell.toolTip = reasons[entry.id]?.line
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        tableColumn?.identifier.rawValue == Column.name.rawValue ? entry(item)?.name : nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applying else { return }
        var ids = Set<ItemID>()
        for row in outline.selectedRowIndexes { if let id = (outline.item(atRow: row) as? ItemBox)?.id { ids.insert(id) } }
        host?.contentSelectionChanged(ids)
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let box = notification.userInfo?["NSObject"] as? ItemBox else { return }
        opened.insert(box.id)
        guard !applying else { return }
        // The store answers at once: the rows come in now if the listing is known, or when it arrives.
        host?.contentExpand(box.id)
        if shown[box.id] == nil { scheduleLoadingRow(for: box.id) }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let box = notification.userInfo?["NSObject"] as? ItemBox else { return }
        opened.remove(box.id)
        openingInside.remove(box.id)
        pruneShown()
        guard !applying else { return }
        host?.contentCollapse(box.id)
    }
    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !applying, let descriptor = outline.sortDescriptors.first, let key = descriptor.key,
              let field = ItemSort.Field(rawValue: key) else { return }
        let current = snapshot?.sort ?? .defaultSort
        host?.contentSetSort(ItemSort(field: field, ascending: descriptor.ascending, directoriesFirst: current.directoriesFirst))
    }

    @objc private func doubleClicked() {
        // A heading or a Loading row opens nothing.
        guard outline.clickedRow >= 0, entry(atRow: outline.clickedRow) != nil else { return }
        host?.contentOpen(selectedEntries(), newTab: NSEvent.modifierFlags.contains(.command))
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        entry(item)?.url as NSURL?
    }
    /// A folder or app row takes the drop; anywhere else means the folder being shown, which lights up whole.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if index == NSOutlineViewDropOnItemIndex, let entry = entry(item), entry.takesDrops {
            let operation = host?.contentDropOperation(info, onto: entry) ?? []
            if operation != [] { return operation }
        }
        // A drop between rows is retargeted to the folder inside which those rows sit.
        if let parent = parentFolder(of: item, index: index) {
            let operation = host?.contentDropOperation(info, onto: parent) ?? []
            if operation != [] { outlineView.setDropItem(box(parent.id), dropChildIndex: NSOutlineViewDropOnItemIndex); return operation }
        }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return host?.contentDropOperation(info, onto: nil) ?? []
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let entry = entry(item), entry.takesDrops, host?.contentDropOperation(info, onto: entry) != [] {
            return host?.contentPerformDrop(info, onto: entry) ?? false
        }
        return host?.contentPerformDrop(info, onto: nil) ?? false
    }
    /// The expanded folder a between-rows drop falls inside, if any.
    private func parentFolder(of item: Any?, index: Int) -> FileEntry? {
        if index != NSOutlineViewDropOnItemIndex, let entry = entry(item), entry.isDirectoryLike { return entry }
        if index == NSOutlineViewDropOnItemIndex, let item, let parent = entry(outline.parent(forItem: item)), parent.isDirectoryLike { return parent }
        return nil
    }

    // MARK: Testing

    var outlineForTesting: NSOutlineView { outline }
    /// The names on the rows, top to bottom, without headings or Loading rows.
    var rowNamesForTesting: [String] { (0..<outline.numberOfRows).compactMap { entry(atRow: $0)?.name } }
    var selectedRowNamesForTesting: [String] { outline.selectedRowIndexes.compactMap { entry(atRow: $0)?.name } }
    /// Each heading with the number of top-level items under it, such as "Folders 2"; empty without headings.
    var sectionSummaryForTesting: [String] {
        var groups: [(title: String, count: Int)] = []
        for row in 0..<outline.numberOfRows {
            let item = outline.item(atRow: row)
            if let heading = item as? SectionBox {
                groups.append((sections.sections.first { $0.kind == heading.kind }?.title ?? "?", 0))
            } else if item is ItemBox, outline.level(forRow: row) == 0, !groups.isEmpty {
                groups[groups.count - 1].count += 1
            }
        }
        return groups.map { "\($0.title) \($0.count)" }
    }
    /// What a row's name cell shows, whether the words fit its column whole, and how many lines they take: the list
    /// cuts a name in the middle, on one line, only when the Name column is too narrow for it.
    func nameFitForTesting(_ id: ItemID) -> ListNameFit? {
        let row = outline.row(forItem: box(id))
        guard row >= 0 else { return nil }
        outline.scrollRowToVisible(row)
        outline.layoutSubtreeIfNeeded()
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let label = cell.textField else { return nil }
        cell.layoutSubtreeIfNeeded()
        let oneLine = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 100_000, height: 100_000)) ?? .zero
        let lines = oneLine.height > 0 ? Int((label.frame.height / oneLine.height).rounded()) : 0
        return ListNameFit(words: label.stringValue, fitsWhole: oneLine.width <= label.frame.width + 0.5, lines: lines,
                           cutsInMiddle: label.lineBreakMode == .byTruncatingMiddle && label.cell?.wraps == false,
                           columnWidth: outline.tableColumns.first?.width ?? 0)
    }
    func isOpenForTesting(_ id: ItemID) -> Bool { outline.isItemExpanded(box(id)) }
    /// The tooltip of an item's row, read from its name cell as AppKit would show it.
    func toolTipForTesting(_ id: ItemID) -> String? {
        let row = outline.row(forItem: box(id))
        guard row >= 0 else { return nil }
        outline.scrollRowToVisible(row)
        return outline.view(atColumn: 0, row: row, makeIfNecessary: true)?.toolTip
    }
    /// The row view on show for an item, if it has one now, so a scripted run can watch it move.
    func rowViewForTesting(_ id: ItemID) -> NSView? {
        let row = outline.row(forItem: box(id))
        return row >= 0 ? outline.rowView(atRow: row, makeIfNecessary: false) : nil
    }
    /// Whether the row right under this folder is its Loading row.
    func showsLoadingRowForTesting(_ id: ItemID) -> Bool {
        let row = outline.row(forItem: box(id))
        return row >= 0 && row + 1 < outline.numberOfRows && outline.item(atRow: row + 1) is LoadingBox
    }
    /// Clicks a folder's disclosure triangle through AppKit's own click path. False if the row or its triangle
    /// can't be found.
    func discloseForTesting(_ id: ItemID) -> Bool {
        let item = box(id)
        let row = outline.row(forItem: item)
        guard row >= 0 else { return false }
        outline.scrollRowToVisible(row)
        guard let rowView = outline.rowView(atRow: row, makeIfNecessary: true),
              let button = Self.disclosureButton(in: rowView) else { return false }
        button.performClick(nil)
        return true
    }
    private static func disclosureButton(in view: NSView) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton, button.identifier == NSOutlineView.disclosureButtonIdentifier { return button }
            if let found = disclosureButton(in: subview) { return found }
        }
        return nil
    }
}

/// One column of the list as a test sees it.
public struct ListColumnFit: Equatable, CustomStringConvertible {
    public let column: String
    public let width: CGFloat
    /// Whether the list shows the whole column, none of it past the list's edge.
    public let isOnShow: Bool
    /// Whether every row's words fit in the column whole.
    public let wordsWhole: Bool
    public init(column: String, width: CGFloat, isOnShow: Bool, wordsWhole: Bool) {
        self.column = column; self.width = width; self.isOnShow = isOnShow; self.wordsWhole = wordsWhole
    }
    public var description: String { "\(column) \(Int(width.rounded()))\(isOnShow ? "" : " past the edge")\(wordsWhole ? "" : " cut")" }
}

/// A column heading without the system's small sort chevron, since the title shows the direction itself.
final class FileHeaderCell: NSTableHeaderCell {
    var isSorted = false
    override init(textCell string: String) {
        super.init(textCell: string)
        font = .systemFont(ofSize: 13)
    }
    required init(coder: NSCoder) { super.init(coder: coder) }
    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {}
}

/// Keeps the checkmarks in the column menu true. Each item carries its column's identifier, since a heading's words
/// change with the sort.
@MainActor final class ColumnMenuSync: NSObject, NSMenuDelegate {
    private let columns: () -> [NSTableColumn]
    init(columns: @escaping () -> [NSTableColumn]) { self.columns = columns }
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            item.state = columns().first { $0.identifier == item.identifier }?.isHidden == false ? .on : .off
        }
    }
}

/// Key and menu handling that an outline view can't get from delegates.
@MainActor final class FileOutlineView: NSOutlineView {
    var host: (() -> FileContentHost?)?
    var entryAtRow: ((Int) -> FileEntry?)?
    var selectedEntries: (() -> [FileEntry])?
    /// Told just before a folder closes, however that happens, so its rows can leave on the list's own curve.
    var willCollapse: ((Any) -> Void)?
    /// Told just before a folder opens with the folders inside it, from an Option-click on its triangle or Option-Right.
    var willExpandChildren: ((Any) -> Void)?
    override func expandItem(_ item: Any?, expandChildren: Bool) {
        if expandChildren, let item { willExpandChildren?(item) }
        super.expandItem(item, expandChildren: expandChildren)
    }
    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        if let item, isItemExpanded(item) {
            // Option-click closes the open folders inside first, so each of them is closed in the store too.
            if collapseChildren {
                for index in 0..<numberOfChildren(ofItem: item) {
                    if let child = self.child(index, ofItem: item), isItemExpanded(child) { collapseItem(child, collapseChildren: true) }
                }
            }
            willCollapse?(item)
        }
        super.collapseItem(item, collapseChildren: collapseChildren)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { super.draggingExited(sender); host?()?.contentDragEnded() }
    override func draggingEnded(_ sender: NSDraggingInfo) { super.draggingEnded(sender); host?()?.contentDragEnded() }
    override func keyDown(with event: NSEvent) {
        if host?()?.contentKeyDown(event) == true { return }
        super.keyDown(with: event)
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { host?()?.contentActivated() }
        return result
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        var row = self.row(at: convert(event.locationInWindow, from: nil))
        // A heading or a Loading row is part of the background, so it gets the background's menu.
        if row >= 0, entryAtRow?(row) == nil { deselectAll(nil); row = -1 }
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return host?()?.contentMenu(for: row >= 0 ? (selectedEntries?() ?? []) : [])
    }
    // Clicks in empty space, or on a heading, clear the selection and the view keeps focus.
    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row < 0 || entryAtRow?(row) == nil { deselectAll(nil); window?.makeFirstResponder(self); return }
        super.mouseDown(with: event)
    }
}

@MainActor private final class ListNameCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let star = NSImageView()
    private var path: String?
    private var iconWidth: NSLayoutConstraint?
    private var iconHeight: NSLayoutConstraint?
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        for view in [icon, label, star] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon; textField = label
        label.lineBreakMode = .byTruncatingMiddle; label.font = .systemFont(ofSize: 13)
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Starred")
        star.contentTintColor = .systemYellow; star.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        let width = icon.widthAnchor.constraint(equalToConstant: 22), height = icon.heightAnchor.constraint(equalToConstant: 22)
        iconWidth = width; iconHeight = height
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            width, height,
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            star.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4), star.centerYAnchor.constraint(equalTo: centerYAnchor),
            star.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }
    private var ticket: IconCache.Ticket?
    private weak var icons: IconCache?
    /// The icon's frame, for Quick Look's zoom.
    var iconView: NSImageView { icon }
    func apply(_ entry: FileEntry, isCut: Bool, icons: IconCache?, textSize: CGFloat, scale: CGFloat) {
        label.stringValue = entry.displayName
        label.font = .systemFont(ofSize: textSize)
        let side = ceil(textSize * 1.6)
        iconWidth?.constant = side; iconHeight?.constant = side
        star.isHidden = !entry.isStarred
        alphaValue = ContentLeafPresentation.opacity(isHidden: entry.isHidden, isCut: isCut)
        setAccessibilityLabel(entry.name)
        path = entry.url.path
        self.icons?.cancel(ticket); ticket = nil
        self.icons = icons
        // Previews show in the list too, as Finder's "Show icon preview" does by default.
        icon.image = icons?.cachedImage(for: entry, points: side, scale: scale) ?? icons?.placeholder(for: entry)
        ticket = icons?.load(for: entry, points: side, scale: scale, previews: true) { [weak self] image in
            guard let self, self.path == entry.url.path, self.icon.image !== image else { return }
            // The placeholder gives way to the file's icon, then its preview, by a short cross-fade rather than a pop.
            // An image already in the cache arrives before the row is on screen, so it just appears.
            if self.window != nil, ListMotion.enabled {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.15
                self.icon.layer?.add(fade, forKey: "iconFade")
            }
            self.icon.image = image
        }
    }
}

@MainActor private final class ListTextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail; label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 12)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func apply(_ text: String, alignment: NSTextAlignment, textSize: CGFloat) {
        label.stringValue = text; label.alignment = alignment
        label.font = .systemFont(ofSize: textSize)
    }
}
#endif
