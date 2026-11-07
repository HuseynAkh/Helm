#if os(macOS)
import AppKit
import HelmCore

/// Grid view with thumbnails (F-035). `NSCollectionView` recycles cells, so large folders stay cheap.
@MainActor final class FileGridController: NSViewController, FileContentPresenting, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    weak var host: FileContentHost?
    private let collection = FileCollectionView()
    private let scroll = NSScrollView()
    private let layout = FileGridLayout()
    private var snapshot: PresentationSnapshot?
    private var tabID: TabID?
    private var snapshotID: Generation?
    private var cut: Set<ItemID> = []
    private var applying = false
    private var iconSize = 96
    private var textSize: CGFloat = 14
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
        collection.registerForDraggedTypes(FileDrag.acceptedTypes)
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
        let text = host?.fileTextSize ?? 14
        let refreshCells = tab.cutIDs != cut || size != iconSize || text != textSize
        cut = tab.cutIDs; iconSize = size; textSize = text
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

    /// The real pixel density of the screen the window is on, so previews are made at exactly the pixels shown.
    private var backingScale: CGFloat { view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    func image(of id: ItemID) -> NSImage? {
        guard let index = snapshot?.index(of: id), let item = collection.item(at: IndexPath(item: index, section: 0)) else { return nil }
        return item.imageView?.image
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
        item.apply(entry, isCut: cut.contains(entry.id), size: iconSize, textSize: textSize, scale: backingScale, icons: host?.icons)
        item.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.host?.contentOpen(self.selectedEntries(), newTab: NSEvent.modifierFlags.contains(.command))
        }
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        // Room for three lines of the name under the icon, as in Nautilus.
        NSSize(width: CGFloat(iconSize) + 56, height: CGFloat(iconSize) + ceil(textSize * 1.3) * 3 + 18)
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
    /// A folder or app under the pointer takes the drop and lights up. Anywhere else, including over a document,
    /// the drop goes into the folder on show, and the whole view lights up instead.
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        if let entry = dropEntry(at: proposedDropIndexPath.pointee as IndexPath, operation: proposedDropOperation.pointee) {
            let operation = host?.contentDropOperation(draggingInfo, onto: entry) ?? []
            if operation != [] { collection.isFolderDropTarget = false; return operation }
        }
        proposedDropOperation.pointee = .before
        let operation = host?.contentDropOperation(draggingInfo, onto: nil) ?? []
        collection.isFolderDropTarget = operation != []
        return operation
    }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        collection.isFolderDropTarget = false
        if let entry = dropEntry(at: indexPath, operation: dropOperation), host?.contentDropOperation(draggingInfo, onto: entry) != [] {
            return host?.contentPerformDrop(draggingInfo, onto: entry) ?? false
        }
        return host?.contentPerformDrop(draggingInfo, onto: nil) ?? false
    }
    private func dropEntry(at path: IndexPath, operation: NSCollectionView.DropOperation) -> FileEntry? {
        guard operation == .on, let snapshot, path.item < snapshot.rootCount else { return nil }
        let entry = snapshot.sortedEntries[path.item]
        return entry.takesDrops ? entry : nil
    }
}

/// Grid layout without the insertion gap a flow layout opens during a drag: Helm folders have no manual order.
@MainActor final class FileGridLayout: NSCollectionViewFlowLayout {
    override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? { nil }
}

@MainActor final class FileCollectionView: NSCollectionView {
    var host: (() -> FileContentHost?)?
    /// Lit while a drop would go into the folder on show.
    var isFolderDropTarget = false { didSet { if isFolderDropTarget != oldValue { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isFolderDropTarget else { return }
        let frame = visibleRect.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill(); path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke(); path.lineWidth = 2; path.stroke()
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        isFolderDropTarget = false; host?()?.contentDragEnded()
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        isFolderDropTarget = false; host?()?.contentDragEnded()
    }
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
    private var ticket: IconCache.Ticket?
    private weak var icons: IconCache?

    override func loadView() {
        let root = GridItemView()
        root.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
        selectionLayer.wantsLayer = true; selectionLayer.layer?.cornerRadius = 10
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center; label.font = .systemFont(ofSize: 14); label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping; label.isSelectable = false
        label.cell?.truncatesLastVisibleLine = true
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
        // A folder under a drag gets a stronger fill and an outline, so it's clear what will take the drop.
        let target = highlightState == .asDropTarget
        let alpha: CGFloat = target ? 0.4 : (on ? 0.28 : 0)
        selectionLayer.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor
        selectionLayer.layer?.borderWidth = target ? 2 : 0
        selectionLayer.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.setAccessibilitySelected(on)
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        icons?.cancel(ticket); ticket = nil
    }
    func apply(_ entry: FileEntry, isCut: Bool, size: Int, textSize: CGFloat, scale: CGFloat, icons: IconCache?) {
        _ = view
        iconWidth?.constant = CGFloat(size); iconHeight?.constant = CGFloat(size)
        label.font = .systemFont(ofSize: textSize)
        label.stringValue = entry.displayName
        star.isHidden = !entry.isStarred
        view.alphaValue = ContentLeafPresentation.opacity(isHidden: entry.isHidden, isCut: isCut)
        view.setAccessibilityLabel(entry.name); view.setAccessibilityRole(.cell)
        self.icons?.cancel(ticket); ticket = nil
        path = entry.url.path
        self.icons = icons
        let points = CGFloat(size)
        icon.image = icons?.cachedImage(for: entry, points: points, scale: scale) ?? icons?.placeholder(for: entry)
        ticket = icons?.load(for: entry, points: points, scale: scale, previews: true) { [weak self] image in
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
