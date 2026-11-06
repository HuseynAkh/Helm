#if os(macOS)
import AppKit
import HelmCore
import HelmPersistence

@MainActor protocol SidebarDelegate: AnyObject {
    func sidebarActivate(_ place: Place, newTab: Bool)
    func sidebarRemoveBookmark(_ place: Place)
    func sidebarEject(_ place: Place)
    func sidebarAddBookmarks(_ urls: [URL])
    func sidebarAcceptDrop(_ urls: [URL], into url: URL) -> Bool
    func sidebarEmptyTrash()
    func sidebarTrash(_ urls: [URL])
}

/// The Places sidebar: flat sections in a fixed order, no tree (F-026 to F-031).
@MainActor final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: SidebarDelegate?
    private let outline = SidebarOutlineView()
    private var model: SidebarModel?
    private var applying = false

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: .init("place"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.style = .sourceList; outline.backgroundColor = .clear
        outline.floatsGroupRows = false; outline.rowSizeStyle = .default; outline.indentationPerLevel = 0
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.action = #selector(clicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.every, forLocal: false)
        outline.setAccessibilityLabel("Places")
        outline.menuProvider = { [weak self] row in self?.menu(forRow: row) }
        scroll.documentView = outline
        view = scroll
    }

    func render(_ model: SidebarModel) {
        let sectionsChanged = self.model?.sections.map({ $0.rows.map(\.id) }) != model.sections.map({ $0.rows.map(\.id) })
        self.model = model
        applying = true
        defer { applying = false }
        if sectionsChanged {
            outline.reloadData()
            for section in model.sections { outline.expandItem(Self.sectionItem(section.id)) }
        }
        select(model.selectedPlaceID)
    }

    private func select(_ id: String?) {
        guard let id else { outline.deselectAll(nil); return }
        let row = outline.row(forItem: Self.placeItem(id))
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { outline.deselectAll(nil) }
    }

    // Sections and places share an id space ("trash" is both), so outline items carry their type.
    private static func sectionItem(_ id: String) -> String { "section:" + id }
    private static func placeItem(_ id: String) -> String { "place:" + id }
    private func place(_ item: Any?) -> Place? {
        guard let value = item as? String, value.hasPrefix("place:") else { return nil }
        return model?.place(for: String(value.dropFirst(6)))
    }
    private func section(_ item: Any?) -> SidebarSection? {
        guard let value = item as? String, value.hasPrefix("section:") else { return nil }
        return model?.sections.first { $0.id == String(value.dropFirst(8)) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let model else { return 0 }
        if let section = section(item) { return section.rows.count }
        return item == nil ? model.sections.count : 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let section = section(item) { return Self.placeItem(section.rows[index].id) }
        return Self.sectionItem(model?.sections[index].id ?? "")
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { section(item) != nil }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { section(item) != nil }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { place(item) != nil }
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let section = section(item) { return section.title == nil ? 6 : 26 }
        return 26
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = section(item) {
            let label = NSTextField(labelWithString: section.title ?? "")
            label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor
            let cell = NSTableCellView()
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                                         label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3)])
            return cell
        }
        guard let place = place(item) else { return nil }
        let id = NSUserInterfaceItemIdentifier("place")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? PlaceCell) ?? PlaceCell(identifier: id)
        cell.apply(place)
        return cell
    }

    @objc private func clicked() {
        guard let place = place(outline.item(atRow: outline.clickedRow)) else { return }
        delegate?.sidebarActivate(place, newTab: NSEvent.modifierFlags.contains(.command))
        // The highlight follows committed navigation, not this click (F-027).
        applying = true; select(model?.selectedPlaceID); applying = false
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
        if place.kind == .device, place.url?.path != "/" {
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

    // MARK: Drops: onto a folder moves or copies into it, between rows adds a bookmark.

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if let place = place(item), place.kind == .trash, index == NSOutlineViewDropOnItemIndex { return .delete }
        if let place = place(item), place.url != nil, index == NSOutlineViewDropOnItemIndex {
            return NSEvent.modifierFlags.contains(.option) ? .copy : .move
        }
        // Anywhere else in the list adds a bookmark.
        guard let bookmarks = model?.sections.first(where: { $0.id == "bookmarks" }) ?? model?.sections.first(where: { $0.id == "favorites" }) else { return [] }
        outlineView.setDropItem(Self.sectionItem(bookmarks.id), dropChildIndex: bookmarks.rows.count)
        return .link
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        if let place = place(item), place.kind == .trash, index == NSOutlineViewDropOnItemIndex {
            delegate?.sidebarTrash(urls)
            return true
        }
        if let place = place(item), let url = place.url, index == NSOutlineViewDropOnItemIndex {
            return delegate?.sidebarAcceptDrop(urls, into: url) ?? false
        }
        delegate?.sidebarAddBookmarks(urls)
        return true
    }
}

@MainActor final class SidebarOutlineView: NSOutlineView {
    var menuProvider: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

@MainActor private final class PlaceCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(icon); addSubview(label)
        imageView = icon; textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func apply(_ place: Place) {
        label.stringValue = place.name
        icon.image = NSImage(systemSymbolName: place.iconName, accessibilityDescription: nil)
        icon.contentTintColor = place.kind == .starred ? .systemYellow : .controlAccentColor
        setAccessibilityLabel(place.name)
    }
}

/// Lets a menu item run a closure. The item retains this through `representedObject`.
@MainActor final class ClosureMenuTarget: NSObject {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func run(_ sender: Any?) { body() }
}
#endif
