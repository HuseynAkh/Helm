#if os(macOS)
import AppKit
import HelmCore
import HelmPersistence

@MainActor protocol SidebarDelegate: AnyObject {
    func sidebarActivate(_ place: Place, newTab: Bool)
    func sidebarRemoveBookmark(_ place: Place)
    func sidebarEject(_ place: Place)
    func sidebarAddBookmarks(_ urls: [URL])
    func sidebarDropOperation(_ info: NSDraggingInfo, onto place: Place) -> NSDragOperation
    func sidebarPerformDrop(_ info: NSDraggingInfo, onto place: Place) -> Bool
    func sidebarDragEnded()
    func sidebarEmptyTrash()
}

/// The Places sidebar in Nautilus's shape: one full-height translucent pane, plain rows with monochrome icons,
/// and thin lines between groups rather than headings (F-026 to F-031).
@MainActor final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: SidebarDelegate?
    private enum Row: Equatable { case place(Place), line(Int) }
    private let outline = SidebarOutlineView()
    private let effect = NSVisualEffectView()
    private let tint = TintView()
    private var model: SidebarModel?
    private var rows: [Row] = []
    /// Boxed so the outline view gets a stable object per row.
    private var items: [NSString] = []

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
        outline.registerForDraggedTypes(FileDrag.acceptedTypes)
        outline.onDragEnded = { [weak self] in self?.delegate?.sidebarDragEnded() }
        outline.setDraggingSourceOperationMask(.every, forLocal: false)
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

    func render(_ model: SidebarModel) {
        let next = Self.flatten(model)
        let changed = next != rows
        self.model = model
        if changed {
            rows = next
            items = rows.enumerated().map { "\($0.offset)" as NSString }
            outline.reloadData()
        }
        select(model.selectedPlaceID)
    }

    /// Recent, the standard places and Trash first, then bookmarks, starred items and drives.
    private static func flatten(_ model: SidebarModel) -> [Row] {
        func rows(_ id: String) -> [Row] {
            model.sections.first { $0.id == id }?.rows.map(Row.place) ?? []
        }
        var groups: [[Row]] = [rows("recent") + rows("favorites") + rows("trash")]
        for id in ["bookmarks", "starred", "devices"] where !rows(id).isEmpty { groups.append(rows(id)) }
        var result: [Row] = []
        for (index, group) in groups.enumerated() {
            if index > 0 { result.append(.line(index)) }
            result += group
        }
        return result
    }

    private func select(_ id: String?) {
        guard let id, let index = rows.firstIndex(where: { if case .place(let place) = $0 { return place.id == id }; return false }) else {
            outline.deselectAll(nil); return
        }
        let row = outline.row(forItem: items[index])
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    private func row(of item: Any?) -> Row? {
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
        guard let place = place(outline.item(atRow: outline.clickedRow)) else { return }
        delegate?.sidebarActivate(place, newTab: NSEvent.modifierFlags.contains(.command))
        // The highlight follows committed navigation, not this click (F-027).
        select(model?.selectedPlaceID)
    }

    private func menu(forRow row: Int) -> NSMenu? {
        guard let place = place(outline.item(atRow: row)) else { return nil }
        let menu = NSMenu()
        if place.url != nil {
            menu.addItem(item("Open in New Tab", place) { [weak self] in self?.delegate?.sidebarActivate($0, newTab: true) })
        }
        if place.kind == .bookmark {
            menu.addItem(item("Remove Bookmark", place) { [weak self] in self?.delegate?.sidebarRemoveBookmark($0) })
        }
        if place.isEjectable {
            menu.addItem(item("Eject “\(place.name)”", place) { [weak self] in self?.delegate?.sidebarEject($0) })
        }
        if place.kind == .trash {
            menu.addItem(item("Empty Trash…", place) { [weak self] _ in self?.delegate?.sidebarEmptyTrash() })
        }
        return menu.items.isEmpty ? nil : menu
    }
    private func item(_ title: String, _ place: Place, _ action: @escaping (Place) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
        let target = ClosureMenuTarget { action(place) }
        item.target = target; item.representedObject = target
        return item
    }

    // MARK: Drops: onto a place moves, copies or opens as Finder would, onto Trash trashes, between rows bookmarks.

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if let place = place(item), index == NSOutlineViewDropOnItemIndex {
            let operation = delegate?.sidebarDropOperation(info, onto: place) ?? []
            if operation != [] { return operation }
        }
        delegate?.sidebarDragEnded()
        // Anywhere else in the list bookmarks the dragged items. Promised files don't exist yet, so they can't be.
        guard !BrowserWindowController.fileURLs(info).isEmpty else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: rows.count)
        return .link
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let place = place(item), index == NSOutlineViewDropOnItemIndex {
            return delegate?.sidebarPerformDrop(info, onto: place) ?? false
        }
        let urls = BrowserWindowController.fileURLs(info)
        guard !urls.isEmpty else { return false }
        delegate?.sidebarAddBookmarks(urls)
        return true
    }
}

private extension Place {
    /// Removable and network drives. The startup disk and cloud folders have nothing to eject.
    var isEjectable: Bool { kind == .device && iconName == "externaldrive" }
}

@MainActor final class SidebarOutlineView: NSOutlineView {
    var menuProvider: ((Int) -> NSMenu?)?
    var onDragEnded: (() -> Void)?
    override func draggingExited(_ sender: NSDraggingInfo?) { super.draggingExited(sender); onDragEnded?() }
    override func draggingEnded(_ sender: NSDraggingInfo) { super.draggingEnded(sender); onDragEnded?() }
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
