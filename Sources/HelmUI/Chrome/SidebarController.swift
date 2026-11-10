#if os(macOS)
import AppKit
import HelmCore
import HelmPersistence

@MainActor protocol SidebarDelegate: AnyObject {
    func sidebarActivate(_ place: Place, newTab: Bool)
    func sidebarRemoveBookmark(_ place: Place)
    func sidebarEject(_ place: Place)
    /// Adds bookmarks just before `anchor`, a bookmark row, or at the end of the bookmarks when it's nil (P-188).
    func sidebarInsertBookmarks(_ urls: [URL], before anchor: Place?)
    /// Moves a row within its own group, to just before `anchor`, or to the end of the group when it's nil.
    func sidebarMove(_ place: Place, before anchor: Place?)
    func sidebarHide(_ place: Place)
    func sidebarShowSettings()
    func sidebarDropOperation(_ info: NSDraggingInfo, onto place: Place) -> NSDragOperation
    func sidebarPerformDrop(_ info: NSDraggingInfo, onto place: Place) -> Bool
    func sidebarDragEnded()
    func sidebarEmptyTrash()
}

/// The Places sidebar in Nautilus's shape: one full-height translucent pane, plain rows with monochrome icons,
/// and thin lines between groups rather than headings (F-026 to F-031).
/// Any row can be dragged to a new place in its own group, or out of the sidebar to take it out (P-188, P-306).
@MainActor final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: SidebarDelegate?
    private let outline = SidebarOutlineView()
    private let effect = NSVisualEffectView()
    private let tint = TintView()
    private var model: SidebarModel?
    private var rows: [SidebarModel.Row] = []
    /// Boxed so the outline view gets a stable object per row.
    private var items: [NSString] = []
    /// The row being dragged, so letting go of it outside the sidebar takes it out, as in Finder.
    private var draggedPlace: Place?
    /// A row the keys moved the highlight onto that isn't the row highlighted for what it opened, such as a starred
    /// file, which shows its folder, and that row. The highlight stays where the keys left it until something else is
    /// on show, so the next arrow carries on from there rather than from the folder's row.
    private var keyboardHold: (id: String, shown: String?)?

    override func loadView() {
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: HeaderBarView.height, left: 0, bottom: 8, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: .init("place"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        // Plain rows with our own soft selection: a source list would tint the selected row blue, as Finder does.
        outline.headerView = nil; outline.style = .plain; outline.backgroundColor = .clear
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.floatsGroupRows = false; outline.indentationPerLevel = 0
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.action = #selector(clicked)
        outline.registerForDraggedTypes(FileDrag.acceptedTypes + [.helmSidebarPlace])
        outline.onDragEnded = { [weak self] in self?.delegate?.sidebarDragEnded() }
        outline.onDragMoved = { [weak self] session, point in self?.dragMoved(session, to: point) }
        outline.onHighlightMoved = { [weak self] in self?.highlightMoved() }
        outline.onOpenHighlighted = { [weak self] newTab in self?.openHighlighted(newTab: newTab) }
        outline.setDraggingSourceOperationMask(.every, forLocal: false)
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setAccessibilityLabel("Places")
        outline.menuProvider = { [weak self] row in self?.menu(forRow: row) }
        scroll.documentView = outline
        tint.fraction = 0
        tint.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(tint)
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: effect.topAnchor), tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor), tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor), scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor)
        ])
        view = effect
    }

    /// `tint` is how much solid colour covers the glass: 0 is fully see-through, 1 is solid.
    func setTransparent(_ transparent: Bool, tint amount: CGFloat) {
        effect.state = transparent ? .active : .inactive
        effect.material = transparent ? .sidebar : .windowBackground
        effect.blendingMode = transparent ? .behindWindow : .withinWindow
        tint.fraction = transparent ? amount : 0
    }

    /// Favorites (Recent, the standard places and Trash), then bookmarks, starred items and drives, each in your order.
    func render(_ model: SidebarModel) {
        let changed = model.rows != rows
        self.model = model
        if changed {
            rows = model.rows
            items = rows.indices.map { "\($0)" as NSString }
            outline.reloadData()
        }
        if let hold = keyboardHold, hold.shown == model.selectedPlaceID, listIndex(of: hold.id) != nil {
            select(hold.id)
        } else {
            keyboardHold = nil
            select(model.selectedPlaceID)
        }
    }

    private func select(_ id: String?) {
        guard let id, let index = listIndex(of: id) else {
            outline.deselectAll(nil); return
        }
        let row = outline.row(forItem: items[index])
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }
    private func listIndex(of id: String) -> Int? {
        rows.firstIndex { if case .place(let place) = $0 { return place.id == id }; return false }
    }

    private func row(of item: Any?) -> SidebarModel.Row? {
        guard let value = item as? NSString, let index = items.firstIndex(where: { $0 === value }) else { return nil }
        return rows[index]
    }
    private func place(_ item: Any?) -> Place? {
        if case .place(let place)? = row(of: item) { return place }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? rows.count : 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { items[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { place(item) != nil }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { place(item) == nil ? 13 : 34 }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { PlaceRowView() }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let place = place(item) else {
            let box = NSBox(); box.boxType = .separator
            let cell = NSView()
            box.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(box)
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                box.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                box.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("place")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? PlaceCell) ?? PlaceCell(identifier: id)
        cell.apply(place) { [weak self] in self?.delegate?.sidebarEject(place) }
        return cell
    }

    @objc private func clicked() {
        keyboardHold = nil
        guard let place = place(outline.item(atRow: outline.clickedRow)) else { return }
        delegate?.sidebarActivate(place, newTab: NSEvent.modifierFlags.contains(.command))
        // The highlight follows committed navigation, not this click (F-027).
        select(model?.selectedPlaceID)
    }
    /// Arrows and type-select move the highlight, and the place it lands on opens, as in Finder's sidebar, so the
    /// highlight always names what's on show. A starred file shows in its folder, selected.
    private func highlightMoved() {
        keyboardHold = nil
        guard let place = place(outline.item(atRow: outline.selectedRow)) else { return }
        delegate?.sidebarActivate(place, newTab: false)
        if let model, model.selectedPlaceID != place.id { keyboardHold = (place.id, model.selectedPlaceID) }
        select(keyboardHold?.id ?? model?.selectedPlaceID)
    }
    /// Return opens the highlighted row, as a click on it does; ⌘Return opens it in a new tab.
    private func openHighlighted(newTab: Bool) {
        keyboardHold = nil
        guard let place = place(outline.item(atRow: outline.selectedRow)) else { return }
        delegate?.sidebarActivate(place, newTab: newTab)
        select(model?.selectedPlaceID)
    }

    /// What the place offers first, then what the sidebar offers: hiding or removing the row, and its settings.
    /// The empty space below the rows offers the settings alone.
    func menu(forRow row: Int) -> NSMenu? {
        let menu = NSMenu()
        if let place = place(row >= 0 ? outline.item(atRow: row) : nil) {
            if place.url != nil {
                menu.addItem(item("Open in New Tab", place) { [weak self] in self?.delegate?.sidebarActivate($0, newTab: true) })
            }
            if place.isEjectable {
                menu.addItem(item("Eject “\(place.name)”", place) { [weak self] in self?.delegate?.sidebarEject($0) })
            }
            if place.kind == .trash {
                menu.addItem(item("Empty Trash…", place) { [weak self] _ in self?.delegate?.sidebarEmptyTrash() })
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for action in SidebarModel.contextActions(for: place) {
                menu.addItem(item(action.title, place) { [weak self] in self?.perform(action, on: $0) })
            }
        }
        let settings = NSMenuItem(title: "Sidebar Settings…", action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
        let target = ClosureMenuTarget { [weak self] in self?.delegate?.sidebarShowSettings() }
        settings.target = target; settings.representedObject = target
        menu.addItem(settings)
        return menu
    }
    private func item(_ title: String, _ place: Place, _ action: @escaping (Place) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
        let target = ClosureMenuTarget { action(place) }
        item.target = target; item.representedObject = target
        return item
    }
    private func perform(_ action: SidebarContextAction, on place: Place) {
        switch action {
        case .removeBookmark: delegate?.sidebarRemoveBookmark(place)
        case .hide: delegate?.sidebarHide(place)
        }
    }
    /// Dragged out of the sidebar: a bookmark is removed, anything else is hidden, as Finder does.
    func removeFromSidebar(_ place: Place) {
        if place.kind == .bookmark { delegate?.sidebarRemoveBookmark(place) } else { delegate?.sidebarHide(place) }
    }

    // MARK: Drops: onto a place moves, copies or opens as Finder would, onto Trash trashes, between rows bookmarks.

    // MARK: Dragging rows: reorder within the row's group, drop outside the sidebar to take it out (P-188, P-306)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // Every row moves. It carries only its ID, in a private type, so dropping it on a folder can't move the real folder.
        guard let place = place(item) else { return nil }
        let entry = NSPasteboardItem()
        entry.setString(place.id, forType: .helmSidebarPlace)
        return entry
    }
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        draggedPlace = draggedItems.first.flatMap { place($0) }
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDrag(of: draggedPlace, at: screenPoint, operation: operation, cancelled: Self.dragWasCancelled)
    }
    /// A drop needs the mouse button let go of, so a drag that ends with it still down was cancelled with Escape.
    /// The Escape key itself is the event being handled then, too. Either one means the row stays where it is.
    private static var dragWasCancelled: Bool {
        if let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53 { return true }
        return NSEvent.pressedMouseButtons & 1 != 0
    }
    /// The end of a drag of one of the rows: let go of outside the sidebar with nothing taking it, the row comes out
    /// of the sidebar with the poof. The smoke run comes in here too.
    func finishDrag(of place: Place?, at screenPoint: NSPoint, operation: NSDragOperation, cancelled: Bool) {
        draggedPlace = nil
        // NSTableView selects a row as the mouse goes down on it. The highlight belongs to the current folder.
        keyboardHold = nil
        select(model?.selectedPlaceID)
        guard let place, SidebarDragEnd(accepted: operation != [], insideSidebar: isInsideSidebar(screenPoint),
                                        cancelled: cancelled) == .takeOut else { return }
        NSAnimationEffect.disappearingItemDefault.show(centeredAt: screenPoint, size: NSSize(width: 36, height: 36))
        // After the drag has finished, so the list doesn't reload under it.
        DispatchQueue.main.async { [weak self] in self?.removeFromSidebar(place) }
    }
    /// Outside the sidebar the row doesn't slide back, since letting go there takes it out of the sidebar.
    private func dragMoved(_ session: NSDraggingSession, to screenPoint: NSPoint) {
        guard draggedPlace != nil else { return }
        session.animatesToStartingPositionsOnCancelOrFail = slidesBack(at: screenPoint)
    }
    func slidesBack(at screenPoint: NSPoint) -> Bool { SidebarDragEnd.slidesBack(insideSidebar: isInsideSidebar(screenPoint)) }
    private func isInsideSidebar(_ screenPoint: NSPoint) -> Bool {
        guard let window = view.window else { return true }
        let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return view.bounds.contains(point)
    }
    /// The list position a drop proposes. Over a row, it's above the row in its top half and below it in the
    /// bottom half; anywhere else in the list, -1, which means the end of the group.
    private func proposedIndex(_ index: Int, item: Any?, info: NSDraggingInfo) -> Int {
        guard index == NSOutlineViewDropOnItemIndex else { return index }
        guard let value = item as? NSString, let row = items.firstIndex(where: { $0 === value }) else { return -1 }
        let point = outline.convert(info.draggingLocation, from: nil)
        // The outline view is flipped: y grows downwards.
        return point.y > outline.rect(ofRow: row).midY ? row + 1 : row
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if let id = info.draggingPasteboard.string(forType: .helmSidebarPlace) {
            // A row only moves within its own group: the line stays there however far the pointer goes.
            // The ID comes from the pasteboard, so a row dragged from another window's sidebar moves too.
            guard let target = model?.reorderTarget(moving: id, proposedIndex: proposedIndex(index, item: item, info: info)) else { return [] }
            outlineView.setDropItem(nil, dropChildIndex: target.index)
            return .move
        }
        if let place = place(item), index == NSOutlineViewDropOnItemIndex {
            let operation = delegate?.sidebarDropOperation(info, onto: place) ?? []
            if operation != [] { return operation }
        }
        delegate?.sidebarDragEnded()
        // Anywhere else in the list bookmarks the dragged items, where they're dropped among the bookmarks.
        // Promised files don't exist yet, so they can't be.
        guard !BrowserWindowController.fileURLs(info).isEmpty, let model else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: model.bookmarkTarget(proposedIndex: proposedIndex(index, item: item, info: info)).index)
        return .link
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let id = info.draggingPasteboard.string(forType: .helmSidebarPlace) {
            return moveRow(id, toChildIndex: index)
        }
        if let place = place(item), index == NSOutlineViewDropOnItemIndex {
            return delegate?.sidebarPerformDrop(info, onto: place) ?? false
        }
        let urls = BrowserWindowController.fileURLs(info)
        guard !urls.isEmpty, let model else { return false }
        let anchor = model.bookmarkTarget(proposedIndex: index).before.flatMap(model.place(for:))
        delegate?.sidebarInsertBookmarks(urls, before: anchor)
        return true
    }
    /// Drops a dragged row at a list position, kept within its group. The smoke run comes in here too.
    @discardableResult func moveRow(_ id: String, toChildIndex index: Int) -> Bool {
        guard let model, let place = model.place(for: id), let target = model.reorderTarget(moving: id, proposedIndex: index) else { return false }
        let anchor = target.before.flatMap(model.place(for:))
        // After the drop has finished, so the list doesn't reload under it.
        DispatchQueue.main.async { [weak self] in self?.delegate?.sidebarMove(place, before: anchor) }
        return true
    }

    // MARK: For the smoke run

    var currentModel: SidebarModel? { model }
    /// The names in the list as drawn, with "|" for each line between groups.
    var renderedNamesForTesting: [String] {
        (0..<outline.numberOfRows).map { row in place(outline.item(atRow: row))?.name ?? "|" }
    }
    /// The places the outline view has loaded. A list that missed a reload holds rows the model no longer has.
    var renderedPlacesForTesting: [Place] {
        (0..<outline.numberOfRows).compactMap { row in place(outline.item(atRow: row)) }
    }
    var highlightedNameForTesting: String? {
        outline.selectedRow >= 0 ? place(outline.item(atRow: outline.selectedRow))?.name : nil
    }
    /// Whether the outline view, the drag's source, has the hook AppKit calls as a drag moves. AppKit only calls it
    /// on a source that has it, and NSTableView itself doesn't.
    var hearsDragMovesForTesting: Bool { outline.responds(to: #selector(NSDraggingSource.draggingSession(_:movedTo:))) }
    /// A point on screen in the middle of the sidebar, or over the files beside it.
    func screenPointForTesting(insideSidebar: Bool) -> NSPoint? {
        guard let window = view.window else { return nil }
        let bounds = view.convert(view.bounds, to: nil)
        let point = insideSidebar ? NSPoint(x: bounds.midX, y: bounds.midY) : NSPoint(x: bounds.maxX + 160, y: bounds.midY)
        return window.convertPoint(toScreen: point)
    }
    /// Drops `item` with the pointer over a row's upper or lower half, through the outline view's own drop
    /// handling, which proposes the position and calls validateDrop and acceptDrop as a real drag would.
    /// Gives the operation the sidebar offered and whether it took the drop.
    func scriptedDropForTesting(_ item: NSPasteboardItem, overRow row: Int, lowerHalf: Bool) -> (offered: NSDragOperation, taken: Bool) {
        let pasteboard = NSPasteboard(name: .init("helm.smoke.sidebar-drag.\(getpid())"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let rect = outline.rect(ofRow: row)
        // Near the middle of the row, where the outline view proposes the row itself rather than a gap.
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.minY + rect.height * (lowerHalf ? 0.6 : 0.4)), to: nil)
        let drag = ScriptedSidebarDrag(pasteboard: pasteboard, location: point, window: view.window)
        _ = outline.draggingEntered(drag)
        let offered = outline.draggingUpdated(drag)
        let taken = offered != [] && outline.prepareForDragOperation(drag) && outline.performDragOperation(drag)
        // AppKit sends draggingEnded itself, from the real drag session, which a scripted drag doesn't have.
        if taken { outline.concludeDragOperation(drag) } else { outline.draggingExited(drag) }
        return (offered, taken)
    }
    func listIndexForTesting(of id: String) -> Int? { listIndex(of: id) }
}

extension NSPasteboard.PasteboardType {
    /// A row dragged within the sidebar, by its ID.
    static let helmSidebarPlace = NSPasteboard.PasteboardType("com.helm.sidebar-place")
}

private extension Place {
    /// Removable and network drives. The startup disk and cloud folders have nothing to eject.
    var isEjectable: Bool { kind == .device && iconName == "externaldrive" }
}

@MainActor final class SidebarOutlineView: NSOutlineView {
    var menuProvider: ((Int) -> NSMenu?)?
    var onDragEnded: (() -> Void)?
    /// Where a row dragged from here has got to, in screen coordinates.
    var onDragMoved: ((NSDraggingSession, NSPoint) -> Void)?
    /// A key moved the highlight to another row.
    var onHighlightMoved: (() -> Void)?
    /// Return or Enter on the highlighted row; true with ⌘ held.
    var onOpenHighlighted: ((Bool) -> Void)?
    override func keyDown(with event: NSEvent) {
        if opensHighlighted(event) { return }
        let before = selectedRow
        super.keyDown(with: event)
        if selectedRow >= 0, selectedRow != before { onHighlightMoved?() }
    }
    /// The menu bar's Rename is Return too, and it would rename the files selected beside the sidebar. While the
    /// sidebar has the keys, its Return comes first, as a key equivalent goes to the window's views before the menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, opensHighlighted(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    private func opensHighlighted(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard event.type == .keyDown, [36, 76].contains(Int(event.keyCode)), flags.isEmpty || flags == .command else { return false }
        onOpenHighlighted?(flags == .command)
        return true
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { super.draggingExited(sender); onDragEnded?() }
    override func draggingEnded(_ sender: NSDraggingInfo) { super.draggingEnded(sender); onDragEnded?() }
    /// The drag's source is the outline view itself, and its data source hears nothing as the drag moves.
    /// NSTableView doesn't implement this optional NSDraggingSource method, so there's no super to call.
    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) { onDragMoved?(session, screenPoint) }
    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

/// The selected place: a soft rounded fill that doesn't change the row's colours, as in Nautilus.
@MainActor private final class PlaceRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 8, dy: 1)
        NSColor.labelColor.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }
}

@MainActor private final class PlaceCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let eject = NSButton()
    private var onEject: (() -> Void)?
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 14)
        label.textColor = .labelColor
        eject.isBordered = false
        eject.image = NSImage(systemSymbolName: "eject", accessibilityDescription: "Eject")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        eject.contentTintColor = .secondaryLabelColor
        eject.target = self; eject.action = #selector(ejectClicked)
        eject.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(label); addSubview(eject)
        imageView = icon; textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: eject.leadingAnchor, constant: -4),
            eject.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), eject.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func apply(_ place: Place, onEject: @escaping () -> Void) {
        label.stringValue = place.name
        // Monochrome, as Adwaita's symbolic icons are.
        icon.image = NSImage(systemSymbolName: place.iconName.replacingOccurrences(of: ".fill", with: ""), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        eject.isHidden = !(place.kind == .device && place.iconName == "externaldrive")
        eject.setAccessibilityLabel("Eject \(place.name)")
        self.onEject = onEject
        setAccessibilityLabel(place.name)
    }
    @objc private func ejectClicked() { onEject?() }
}

/// Lets a menu item run a closure. The item retains this through `representedObject`.
@MainActor final class ClosureMenuTarget: NSObject {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func run(_ sender: Any?) { body() }
}
#endif
