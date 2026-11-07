#if os(macOS)
import AppKit
import HelmCore

/// List view with expandable folders (F-036, F-037). Cells recycle, so large folders cost only their entries.
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
        location.title = "Location"; location.width = 240; location.isHidden = true
        location.headerCell = FileHeaderCell(textCell: "Location")
        outline.addTableColumn(location)
        locationColumn = location
        outline.usesAlternatingRowBackgroundColors = false
        outline.allowsMultipleSelection = true; outline.allowsEmptySelection = true
        outline.allowsTypeSelect = true; outline.style = .inset; outline.rowHeight = 32
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
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
    }

    func render(_ tab: TabState, force: Bool) {
        applying = true
        defer { applying = false }
        locationColumn?.isHidden = tab.search == nil
        let changed = force || tab.id != tabID || tab.snapshot.id != snapshotID || tab.snapshot.location != snapshot?.location
        let cutChanged = tab.cutIDs != cut
        cut = tab.cutIDs
        let textSize = host?.fileTextSize ?? 14
        let rowHeight = ceil(textSize * 2.25)
        let textChanged = outline.rowHeight != rowHeight
        if textChanged { outline.rowHeight = rowHeight }
        if changed || textChanged {
            let keepingScroll = tab.id == tabID && tab.snapshot.location == snapshot?.location
            let origin = scroll.contentView.bounds.origin
            snapshot = tab.snapshot; tabID = tab.id; snapshotID = tab.snapshot.id
            outline.reloadData()
            expand(tab)
            if keepingScroll { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
        } else if cutChanged { outline.reloadData(); expand(tab) }
        let descriptor = NSSortDescriptor(key: tab.snapshot.sort.field.rawValue, ascending: tab.snapshot.sort.ascending)
        if outline.sortDescriptors.first?.key != descriptor.key || outline.sortDescriptors.first?.ascending != descriptor.ascending {
            outline.sortDescriptors = [descriptor]
        }
        showSortDirection(tab.snapshot.sort)
        applySelection(tab.selection)
    }

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
    private func applySelection(_ ids: Set<ItemID>) {
        var rows = IndexSet()
        for id in ids {
            let row = outline.row(forItem: box(id))
            if row >= 0 { rows.insert(row) }
        }
        if rows != outline.selectedRowIndexes { outline.selectRowIndexes(rows, byExtendingSelection: false) }
        if let first = rows.first, snapshot?.selectionSource != .widget, snapshot?.selectionSource != .user {
            outline.scrollRowToVisible(first)
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

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let snapshot else { return 0 }
        guard let box = item as? ItemBox else { return snapshot.rootCount }
        return snapshot.children[box.id]?.sortedIDs.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let snapshot else { return ItemBox(ItemID(rawValue: "/")) }
        if let box = item as? ItemBox, let id = snapshot.children[box.id]?.sortedIDs[index] { return self.box(id) }
        return box(snapshot.sortedEntries[index].id)
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard snapshot?.rankByID == nil else { return false }
        return entry(item)?.isDirectoryLike ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = entry(item), let raw = tableColumn?.identifier.rawValue, let column = Column(rawValue: raw) else { return nil }
        switch column {
        case .name:
            let id = NSUserInterfaceItemIdentifier("name")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? ListNameCell) ?? ListNameCell(identifier: id)
            var shown = entry
            shown.isStarred = host?.starred.contains(entry.id) ?? false
            cell.apply(shown, isCut: cut.contains(entry.id), icons: host?.icons, textSize: host?.fileTextSize ?? 14,
                       scale: view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
            return cell
        case .size: return textCell(outlineView, "size", entry.sizeText, alignment: .right, entry: entry)
        case .dateModified: return textCell(outlineView, "date", entry.dateText, alignment: .left, entry: entry)
        case .kind: return textCell(outlineView, "kind", entry.kindText, alignment: .left, entry: entry)
        case .location: return textCell(outlineView, "location", entry.url.deletingLastPathComponent().path, alignment: .left, entry: entry)
        }
    }
    private func textCell(_ outlineView: NSOutlineView, _ name: String, _ text: String, alignment: NSTextAlignment, entry: FileEntry) -> NSView {
        let id = NSUserInterfaceItemIdentifier(name)
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? ListTextCell) ?? ListTextCell(identifier: id)
        cell.apply(text, alignment: alignment, textSize: (host?.fileTextSize ?? 14) - 1)
        cell.alphaValue = ContentLeafPresentation.opacity(isHidden: entry.isHidden, isCut: cut.contains(entry.id))
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
        guard !applying, let box = notification.userInfo?["NSObject"] as? ItemBox else { return }
        host?.contentExpand(box.id)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !applying, let box = notification.userInfo?["NSObject"] as? ItemBox else { return }
        host?.contentCollapse(box.id)
    }
    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !applying, let descriptor = outline.sortDescriptors.first, let key = descriptor.key,
              let field = ItemSort.Field(rawValue: key) else { return }
        let current = snapshot?.sort ?? .defaultSort
        host?.contentSetSort(ItemSort(field: field, ascending: descriptor.ascending, directoriesFirst: current.directoriesFirst))
    }

    @objc private func doubleClicked() {
        guard outline.clickedRow >= 0 else { return }
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

/// Keeps the checkmarks in the column menu true.
@MainActor final class ColumnMenuSync: NSObject, NSMenuDelegate {
    private let columns: () -> [NSTableColumn]
    init(columns: @escaping () -> [NSTableColumn]) { self.columns = columns }
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            item.state = columns().first { $0.title == item.title }?.isHidden == false ? .on : .off
        }
    }
}

/// Key and menu handling that an outline view can't get from delegates.
@MainActor final class FileOutlineView: NSOutlineView {
    var host: (() -> FileContentHost?)?
    var entryAtRow: ((Int) -> FileEntry?)?
    var selectedEntries: (() -> [FileEntry])?
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
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return host?()?.contentMenu(for: row >= 0 ? (selectedEntries?() ?? []) : [])
    }
    // Clicks in empty space clear the selection and the view keeps focus.
    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row < 0 { deselectAll(nil); window?.makeFirstResponder(self); return }
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
            if self?.path == entry.url.path { self?.icon.image = image }
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
