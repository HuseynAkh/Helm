#if os(macOS)
import AppKit
import HelmCore

/// Grid view with thumbnails (F-035). `NSCollectionView` recycles cells, so large folders stay cheap.
@MainActor final class FileGridController: NSViewController, FileContentPresenting, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    weak var host: FileContentHost?
    private let collection = FileCollectionView()
    private let scroll = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private var snapshot: PresentationSnapshot?
    private var tabID: TabID?
    private var snapshotID: Generation?
    private var cut: Set<ItemID> = []
    private var applying = false
    private var iconSize = 96
    private var rename: RenameEditor?
    private var typeSelect = TypeSelect()

    override func loadView() {
        layout.minimumInteritemSpacing = 10; layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        collection.collectionViewLayout = layout
        collection.isSelectable = true; collection.allowsMultipleSelection = true; collection.allowsEmptySelection = true
        collection.dataSource = self; collection.delegate = self
        collection.register(GridItem.self, forItemWithIdentifier: GridItem.identifier)
        collection.backgroundColors = [.clear]
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask(.every, forLocal: false)
        collection.setDraggingSourceOperationMask(.every, forLocal: true)
        collection.setAccessibilityLabel("Files")
        collection.host = { [weak self] in self?.host }
        collection.selectedEntries = { [weak self] in self?.selectedEntries() ?? [] }
        collection.onType = { [weak self] text in self?.typeSelect(text) ?? false }
        scroll.documentView = collection
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        view = scroll
    }

    func render(_ tab: TabState, force: Bool) {
        applying = true
        defer { applying = false }
        let size = host?.gridIconSize ?? 96
        let changed = force || tab.id != tabID || tab.snapshot.id != snapshotID || tab.snapshot.location != snapshot?.location
        let refreshCells = tab.cutIDs != cut || size != iconSize
        cut = tab.cutIDs; iconSize = size
        if changed || refreshCells {
            let keepingScroll = tab.id == tabID && tab.snapshot.location == snapshot?.location
            let origin = scroll.contentView.bounds.origin
            snapshot = tab.snapshot; tabID = tab.id; snapshotID = tab.snapshot.id
            collection.reloadData()
            collection.layoutSubtreeIfNeeded()
            if keepingScroll { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
        }
        applySelection(tab)
    }

    private func applySelection(_ tab: TabState) {
        guard let snapshot else { return }
        var paths = Set<IndexPath>()
        for id in tab.selection {
            if let index = snapshot.index(of: id), index < snapshot.rootCount { paths.insert(IndexPath(item: index, section: 0)) }
        }
        if collection.selectionIndexPaths != paths { collection.selectionIndexPaths = paths }
        if let first = paths.min(), tab.selectionSource != .user, tab.selectionSource != .widget {
            collection.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
        }
    }

    func focusContent() { view.window?.makeFirstResponder(collection) }
    var keyResponder: NSResponder? { collection }

    func beginRename(_ entry: FileEntry) {
        guard let index = snapshot?.index(of: entry.id) else { host?.contentRenameFinished(entry, newName: nil); return }
        let path = IndexPath(item: index, section: 0)
        collection.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        collection.layoutSubtreeIfNeeded()
        guard let item = collection.item(at: path) as? GridItem, let field = item.textField else {
            host?.contentRenameFinished(entry, newName: nil); return
        }
        rename = RenameEditor(entry: entry, field: field) { [weak self] entry, name in
            self?.rename = nil
            self?.host?.contentRenameFinished(entry, newName: name)
        }
        rename?.begin(in: view.window)
    }

    func screenFrame(of id: ItemID) -> NSRect? {
        guard let index = snapshot?.index(of: id), let window = view.window,
              let item = collection.item(at: IndexPath(item: index, section: 0)), let icon = item.imageView else { return nil }
        return window.convertToScreen(icon.convert(icon.bounds, to: nil))
    }

    private func selectedEntries() -> [FileEntry] {
        guard let snapshot else { return [] }
        return collection.selectionIndexPaths.sorted().compactMap { path in
            path.item < snapshot.sortedEntries.count ? snapshot.sortedEntries[path.item] : nil
        }
    }

    private func typeSelect(_ text: String) -> Bool {
        guard let snapshot else { return false }
        let names = snapshot.sortedEntries.prefix(snapshot.rootCount).map(\.name)
        guard let index = typeSelect.select(typing: text, names: Array(names)) else { return false }
        host?.contentSelectionChanged([snapshot.sortedEntries[index].id])
        collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestHorizontalEdge)
        return true
    }

    // MARK: Data

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { snapshot?.rootCount ?? 0 }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let raw = collectionView.makeItem(withIdentifier: GridItem.identifier, for: indexPath)
        guard let item = raw as? GridItem, let snapshot, indexPath.item < snapshot.sortedEntries.count else { return raw }
        var entry = snapshot.sortedEntries[indexPath.item]
        entry.isStarred = host?.starred.contains(entry.id) ?? false
        item.apply(entry, isCut: cut.contains(entry.id), size: iconSize, icons: host?.icons)
        item.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.host?.contentOpen(self.selectedEntries(), newTab: NSEvent.modifierFlags.contains(.command))
        }
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        NSSize(width: iconSize + 44, height: iconSize + 44)
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    private func selectionChanged() {
        guard !applying else { return }
        host?.contentSelectionChanged(Set(selectedEntries().map(\.id)))
    }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let snapshot, indexPath.item < snapshot.sortedEntries.count else { return nil }
        return snapshot.sortedEntries[indexPath.item].url as NSURL
    }
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let urls = droppedURLs(draggingInfo)
        let path = proposedDropIndexPath.pointee as IndexPath
        if proposedDropOperation.pointee == .on, let snapshot, path.item < snapshot.rootCount {
            let entry = snapshot.sortedEntries[path.item]
            if entry.isDirectoryLike, host?.contentCanAcceptDrop(into: entry.url, from: urls) == true {
                return host?.contentDragOperation(from: urls, into: entry.url) ?? []
            }
        }
        proposedDropOperation.pointee = .before
        guard host?.contentCanAcceptDrop(into: nil, from: urls) == true else { return [] }
        return host?.contentDragOperation(from: urls, into: nil) ?? []
    }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        var target: URL?
        if dropOperation == .on, let snapshot, indexPath.item < snapshot.rootCount, snapshot.sortedEntries[indexPath.item].isDirectoryLike {
            target = snapshot.sortedEntries[indexPath.item].url
        }
        return host?.contentAcceptDrop(droppedURLs(draggingInfo), into: target) ?? false
    }
    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

@MainActor final class FileCollectionView: NSCollectionView {
    var host: (() -> FileContentHost?)?
    var selectedEntries: (() -> [FileEntry])?
    var onType: ((String) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if host?()?.contentKeyDown(event) == true { return }
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if plain, let text = event.characters, let scalar = text.unicodeScalars.first,
           CharacterSet.alphanumerics.union(.punctuationCharacters).contains(scalar), onType?(text) == true { return }
        super.keyDown(with: event)
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { host?()?.contentActivated() }
        return result
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point) else {
            deselectAll(nil)
            return host?()?.contentMenu(for: [])
        }
        if !selectionIndexPaths.contains(path) {
            selectionIndexPaths = [path]
            delegate?.collectionView?(self, didSelectItemsAt: [path])
        }
        return host?()?.contentMenu(for: selectedEntries?() ?? [])
    }
}

/// One grid cell: icon over a two-line name.
@MainActor final class GridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("grid")
    var onDoubleClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let selectionLayer = NSView()
    private let star = NSImageView()
    private var iconWidth: NSLayoutConstraint?
    private var iconHeight: NSLayoutConstraint?
    private var path: String?

    override func loadView() {
        let root = GridItemView()
        root.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
        selectionLayer.wantsLayer = true; selectionLayer.layer?.cornerRadius = 8
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center; label.font = .systemFont(ofSize: 11); label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle; label.isSelectable = false
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Starred")
        star.contentTintColor = .systemYellow
        for view in [selectionLayer, icon, label, star] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let width = icon.widthAnchor.constraint(equalToConstant: 96), height = icon.heightAnchor.constraint(equalToConstant: 96)
        iconWidth = width; iconHeight = height
        NSLayoutConstraint.activate([
            width, height,
            selectionLayer.leadingAnchor.constraint(equalTo: root.leadingAnchor), selectionLayer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            selectionLayer.topAnchor.constraint(equalTo: root.topAnchor), selectionLayer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 4), icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4), label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            star.trailingAnchor.constraint(equalTo: icon.trailingAnchor), star.bottomAnchor.constraint(equalTo: icon.bottomAnchor),
            star.widthAnchor.constraint(equalToConstant: 14), star.heightAnchor.constraint(equalToConstant: 14)
        ])
        view = root
        imageView = icon; textField = label
    }
    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }
    private func updateSelection() {
        let on = isSelected || highlightState == .forSelection
        selectionLayer.layer?.backgroundColor = on ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
        view.setAccessibilitySelected(on)
    }
    func apply(_ entry: FileEntry, isCut: Bool, size: Int, icons: IconCache?) {
        _ = view
        iconWidth?.constant = CGFloat(size); iconHeight?.constant = CGFloat(size)
        label.stringValue = entry.displayName
        star.isHidden = !entry.isStarred
        view.alphaValue = ContentLeafPresentation.opacity(isHidden: entry.isHidden, isCut: isCut)
        view.setAccessibilityLabel(entry.name); view.setAccessibilityRole(.cell)
        path = entry.url.path
        icon.image = icons?.placeholder(for: entry)
        icons?.load(for: entry, pixels: size * 2, thumbnails: true) { [weak self] image in
            if self?.path == entry.url.path { self?.icon.image = image }
        }
        updateSelection()
    }
}

@MainActor private final class GridItemView: NSView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }
}
#endif
