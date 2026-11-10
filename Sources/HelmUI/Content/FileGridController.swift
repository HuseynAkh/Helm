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
    private var font = NSFont.systemFont(ofSize: 14)
    private var metrics = GridItemMetrics(iconSize: 96, lineHeight: GridNameMetrics.lineHeight(for: .systemFont(ofSize: 14)))
    /// The one item selected, which shows its whole name over the items below it.
    private var expandedPath: IndexPath?
    private var rename: RenameEditor?
    private var typeSelect = TypeSelect()
    /// Recent's Folders and Files groups, each a section with a heading; one plain section everywhere else.
    private var sections = ContentSections(rootCount: 0)
    private var lastSelection: (ids: Set<ItemID>, source: SelectionSource)?
    private var revealSelection = false

    override func loadView() {
        layout.minimumInteritemSpacing = 10; layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        collection.collectionViewLayout = layout
        collection.isSelectable = true; collection.allowsMultipleSelection = true; collection.allowsEmptySelection = true
        collection.dataSource = self; collection.delegate = self
        collection.register(GridItem.self, forItemWithIdentifier: GridItem.identifier)
        collection.register(GridSectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: GridSectionHeader.identifier)
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
        if font.pointSize != text || metrics.iconSize != CGFloat(size) {
            font = .systemFont(ofSize: text)
            metrics = GridItemMetrics(iconSize: CGFloat(size), lineHeight: GridNameMetrics.lineHeight(for: font))
        }
        if changed || refreshCells {
            let keepingScroll = tab.id == tabID && tab.snapshot.location == snapshot?.location
            let origin = scroll.contentView.bounds.origin
            snapshot = tab.snapshot; tabID = tab.id; snapshotID = tab.snapshot.id
            sections = ContentSections.make(for: tab)
            // The items are made again, so which one shows its whole name is worked out again after.
            expandedPath = nil; layout.lower()
            collection.reloadData()
            collection.layoutSubtreeIfNeeded()
            if keepingScroll { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
        }
        applySelection(tab)
    }

    private func applySelection(_ tab: TabState) {
        guard snapshot != nil else { return }
        var paths = Set<IndexPath>()
        for id in tab.selection {
            if let path = indexPath(of: id) { paths.insert(path) }
        }
        if collection.selectionIndexPaths != paths { collection.selectionIndexPaths = paths }
        // A selection made elsewhere (Back, a paste, Show in Finder) is brought into view once, when it arrives, and
        // never again on later renders, such as a file changing in the folder, as in the list.
        if lastSelection?.ids != tab.selection || lastSelection?.source != tab.selectionSource {
            lastSelection = (tab.selection, tab.selectionSource)
            revealSelection = tab.selectionSource != .widget && tab.selectionSource != .user
        }
        if revealSelection, let first = paths.min() {
            collection.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
            revealSelection = false
        }
        updateExpansion()
    }

    /// The one item selected shows its whole name, over the items below it, until something else is clicked. With
    /// several selected, none does, so names never cover each other. A name being renamed keeps its own size.
    private func updateExpansion() {
        guard rename == nil else { return }
        let selected = collection.selectionIndexPaths
        let next = selected.count == 1 ? selected.first : nil
        if let old = expandedPath, old != next { (collection.item(at: old) as? GridItem)?.setExpanded(false) }
        expandedPath = next
        var overflow: CGFloat = 0
        if let next, let entry = entry(at: next) {
            (collection.item(at: next) as? GridItem)?.setExpanded(true)
            let lines = GridNameCache.shared.lines(for: entry.displayName, width: metrics.textWidth, font: font,
                                                   maxLines: GridItemMetrics.linesSelected)
            overflow = metrics.overflow(lines: lines.lines.count)
        }
        layout.raise(next, overflow: overflow)
    }

    func focusContent() { view.window?.makeFirstResponder(collection) }
    var keyResponder: NSResponder? { collection }

    func beginRename(_ entry: FileEntry) {
        guard let path = indexPath(of: entry.id) else { host?.contentRenameFinished(entry, newName: nil); return }
        collection.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        collection.layoutSubtreeIfNeeded()
        guard let item = collection.item(at: path) as? GridItem, let field = item.textField else {
            host?.contentRenameFinished(entry, newName: nil); return
        }
        // The field shows the whole name and grows as it's typed, over the items below, whatever its length.
        item.beginEditingName()
        expandedPath = path
        layout.raise(path, overflow: item.nameOverflow)
        rename = RenameEditor(entry: entry, field: field, edited: { [weak self, weak item] in
            guard let self, let item, self.rename != nil else { return }
            item.fitEditedName()
            self.layout.raise(path, overflow: item.nameOverflow)
        }) { [weak self, weak item] entry, name in
            if let item, item.entryID == entry.id { item.endEditingName() }
            self?.rename = nil
            self?.updateExpansion()
            self?.host?.contentRenameFinished(entry, newName: name)
        }
        rename?.begin(in: view.window)
        // Sized again by the editor's own lines, now that it's there.
        item.fitEditedName()
        layout.raise(path, overflow: item.nameOverflow)
    }

    func screenFrame(of id: ItemID) -> NSRect? {
        guard let path = indexPath(of: id), let window = view.window,
              let item = collection.item(at: path), let icon = item.imageView else { return nil }
        return window.convertToScreen(icon.convert(icon.bounds, to: nil))
    }

    /// The real pixel density of the screen the window is on, so previews are made at exactly the pixels shown.
    private var backingScale: CGFloat { view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    func image(of id: ItemID) -> NSImage? {
        guard let path = indexPath(of: id), let item = collection.item(at: path) else { return nil }
        return item.imageView?.image
    }

    /// Index paths sort by group, then place, which is the order on screen.
    private func selectedEntries() -> [FileEntry] {
        collection.selectionIndexPaths.sorted().compactMap { entry(at: $0) }
    }

    // Every index path goes through the sections, so the right item is opened, dragged, renamed or dropped on.
    private func indexPath(forRoot index: Int) -> IndexPath? {
        sections.position(ofRoot: index).map { IndexPath(item: $0.item, section: $0.section) }
    }
    private func indexPath(of id: ItemID) -> IndexPath? {
        guard let snapshot, let index = snapshot.index(of: id), index < snapshot.rootCount else { return nil }
        return indexPath(forRoot: index)
    }
    private func entry(at path: IndexPath) -> FileEntry? {
        guard let snapshot, let index = sections.rootIndex(section: path.section, item: path.item), index < snapshot.rootCount else { return nil }
        return snapshot.sortedEntries[index]
    }

    private func typeSelect(_ text: String) -> Bool {
        guard let snapshot else { return false }
        let names = snapshot.sortedEntries.prefix(snapshot.rootCount).map(\.name)
        guard let index = typeSelect.select(typing: text, names: Array(names)) else { return false }
        host?.contentSelectionChanged([snapshot.sortedEntries[index].id])
        if let path = indexPath(forRoot: index) { collection.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge) }
        return true
    }

    // MARK: Data

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.sections.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections.sections.indices.contains(section) ? sections.sections[section].range.count : 0
    }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let raw = collectionView.makeItem(withIdentifier: GridItem.identifier, for: indexPath)
        guard let item = raw as? GridItem, var entry = entry(at: indexPath) else { return raw }
        entry.isStarred = host?.starred.contains(entry.id) ?? false
        item.apply(entry, isCut: cut.contains(entry.id), metrics: metrics, font: font, expanded: indexPath == expandedPath,
                   scale: backingScale, icons: host?.icons)
        item.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.host?.contentOpen(self.selectedEntries(), newTab: NSEvent.modifierFlags.contains(.command))
        }
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        // Room for two lines of the name under the icon, as in Finder.
        metrics.cellSize
    }
    /// A group's heading: its name and a hairline across, lined up with the first item's edge.
    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GridSectionHeader.identifier, for: indexPath)
        if let header = view as? GridSectionHeader, sections.sections.indices.contains(indexPath.section) {
            let section = sections.sections[indexPath.section]
            header.heading.apply(title: section.title ?? "", count: section.range.count, textSize: textSize,
                                 leading: Self.headingLeading, trailing: 16, bottom: 4)
        }
        return view
    }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> NSSize {
        guard sections.hasHeadings else { return .zero }
        return NSSize(width: collectionView.bounds.width, height: ceil(textSize * 1.3) + 18)
    }
    /// Without headings this is the usual spacing. With them, each heading sits just above its items, and the
    /// groups keep a little air between them.
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        insetForSectionAt section: Int) -> NSEdgeInsets {
        guard sections.hasHeadings else { return layout.sectionInset }
        return NSEdgeInsets(top: 6, left: 16, bottom: section == sections.sections.count - 1 ? 12 : 10, right: 16)
    }
    /// From the view's edge to where the first item's selection rounding starts.
    static let headingLeading: CGFloat = 20
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    private func selectionChanged() {
        // A click shows the whole name at once, before the window hears of it.
        updateExpansion()
        guard !applying else { return }
        host?.contentSelectionChanged(Set(selectedEntries().map(\.id)))
    }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        entry(at: indexPath)?.url as NSURL?
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
        guard operation == .on, let entry = entry(at: path) else { return nil }
        return entry.takesDrops ? entry : nil
    }

    /// Each heading on show with its number of items, read from the views themselves; empty without headings.
    var sectionSummaryForTesting: [String] {
        guard sections.hasHeadings else { return [] }
        collection.layoutSubtreeIfNeeded()
        return (0..<collection.numberOfSections).map { number in
            let header = collection.supplementaryView(forElementKind: NSCollectionView.elementKindSectionHeader,
                                                      at: IndexPath(item: 0, section: number)) as? GridSectionHeader
            return "\(header?.heading.titleForTesting ?? "missing") \(collection.numberOfItems(inSection: number))"
        }
    }

    // MARK: Testing

    var collectionForTesting: NSCollectionView { collection }
    var layoutForTesting: FileGridLayout { layout }
    /// The item for `id`, scrolled into view and laid out.
    func itemForTesting(_ id: ItemID) -> GridItem? {
        guard let path = indexPath(of: id) else { return nil }
        collection.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        collection.layoutSubtreeIfNeeded()
        return collection.item(at: path) as? GridItem
    }
    /// What the grid shows for an item: its lines, its tooltip, what VoiceOver reads, and whether its whole name is
    /// drawn over the items around it.
    func nameReportForTesting(_ id: ItemID) -> GridNameReport? {
        guard let item = itemForTesting(id) else { return nil }
        // Later subviews are drawn over earlier ones; the collection view orders them by the layout's z-index.
        let drawnLast = collection.subviews.last { $0 is GridItemView || $0 is GridSectionHeader }
        let editor = item.textField?.currentEditor() as? NSTextView
        let label = item.labelFrameForTesting
        let drawn = item.textField?.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.width, height: 100_000)).height ?? 0
        return GridNameReport(name: item.name, lines: item.nameLines.lines, drawnLines: Int((drawn / metrics.lineHeight).rounded()),
                              isShortened: item.nameLines.isShortened, isExpanded: item.isExpanded,
                              toolTip: item.view.toolTip, spokenName: item.view.accessibilityLabel(),
                              spokenWords: item.textField?.accessibilityValue() as? String, isOnTop: drawnLast === item.view,
                              overflow: item.nameOverflow, coversBelow: underNameIsCutAway(item),
                              fieldWords: item.isEditingName ? editor?.string ?? item.textField?.stringValue : nil)
    }
    /// What each picture's item shows now, in the grid's order. It doesn't scroll, so a picture whose item isn't on
    /// show says so.
    func thumbnailsForTesting() -> [GridThumbnailReport] {
        guard let snapshot, let icons = host?.icons else { return [] }
        return snapshot.sortedEntries.prefix(snapshot.rootCount).filter(IconCache.isPicture).map { entry in
            guard let path = indexPath(of: entry.id), let item = collection.item(at: path) as? GridItem,
                  item.entryID == entry.id else { return GridThumbnailReport(name: entry.name, shows: "not on show") }
            return GridThumbnailReport(name: entry.name, shows: icons.describe(item.imageView?.image, for: entry,
                                                                               points: metrics.iconSize, scale: backingScale))
        }
    }
    /// The views of the items and headings on show under the part of `id`'s name past its item.
    func viewsUnderNameForTesting(_ id: ItemID) -> [NSView] { itemForTesting(id).map(viewsUnderName) ?? [] }
    private func pastItem(_ item: GridItem) -> NSRect {
        NSRect(x: item.view.frame.minX, y: item.view.frame.maxY, width: item.view.frame.width, height: item.nameOverflow)
    }
    private func viewsUnderName(of item: GridItem) -> [NSView] {
        let past = pastItem(item)
        guard past.height > 0 else { return [] }
        return collection.subviews.filter { view in
            view !== item.view && !view.isHidden && (view is GridItemView || view is GridSectionHeader) && view.frame.intersects(past)
        }
    }
    /// Whether every item and heading under the part of the item's name past the item cuts that part away, so none
    /// of it shows through the name. True when nothing is under it; false when the name doesn't run past.
    private func underNameIsCutAway(_ item: GridItem) -> Bool {
        let past = pastItem(item)
        guard past.height > 0 else { return false }
        return viewsUnderName(of: item).allSatisfy { view in
            let part = view.frame.intersection(past)
            return [NSPoint(x: part.midX, y: part.midY), NSPoint(x: part.midX, y: part.minY + 0.5)].allSatisfy(view.isCutAwayForTesting)
        }
    }
}

/// A grid element's place, and the selected item's whole name where it lies over this element.
final class GridLayoutAttributes: NSCollectionViewLayoutAttributes {
    /// The highlight of the item showing its whole name, in the grid's coordinates, when it runs over this item or
    /// heading; otherwise `.zero`. The element cuts that part of itself away, so nothing of it shows through the
    /// name, which is on the same see-through highlight as any other selection.
    var coveredBy = NSRect.zero
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        (copy as? GridLayoutAttributes)?.coveredBy = coveredBy
        return copy
    }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? GridLayoutAttributes, other.coveredBy == coveredBy else { return false }
        return super.isEqual(object)
    }
}

/// Grid layout without the insertion gap a flow layout opens during a drag: Helm folders have no manual order.
/// The one item showing its whole name is drawn over the items around it, which cut away the part under the name,
/// and the grid grows at the bottom when that name runs past the last row, so all of it can be scrolled into view.
@MainActor final class FileGridLayout: NSCollectionViewFlowLayout {
    private(set) var raised: IndexPath?
    /// How far the raised item's name runs past the bottom of the item.
    private(set) var raisedOverflow: CGFloat = 0

    override class var layoutAttributesClass: AnyClass { GridLayoutAttributes.self }
    override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? { nil }

    /// Draws the item at `path` over the others, with its name running `overflow` points past its bottom. Only the
    /// items that change, and those under the name, are laid out again, so it stays cheap in a big folder.
    func raise(_ path: IndexPath?, overflow: CGFloat) {
        let next = path == nil ? 0 : max(0, overflow)
        guard path != raised || next != raisedOverflow else { return }
        var items = Set([raised, path].compactMap { $0 }).filter(isValid)
        var headings = Set<IndexPath>()
        let before = covered()
        raised = path; raisedOverflow = next
        for attributes in before + covered() {
            guard let indexPath = attributes.indexPath else { continue }
            if attributes.representedElementCategory == .item { items.insert(indexPath) } else { headings.insert(indexPath) }
        }
        let context = NSCollectionViewFlowLayoutInvalidationContext()
        context.invalidateFlowLayoutAttributes = false
        context.invalidateFlowLayoutDelegateMetrics = false
        context.invalidateItems(at: items)
        if !headings.isEmpty { context.invalidateSupplementaryElements(ofKind: NSCollectionView.elementKindSectionHeader, at: headings) }
        invalidateLayout(with: context)
    }
    /// Forgets the raised item without laying anything out, for a reload that lays out everything anyway.
    func lower() { raised = nil; raisedOverflow = 0 }

    /// The raised item's highlight with its whole name, in the grid's coordinates, while the name runs past the item.
    private var covering: NSRect? {
        guard let raised, raisedOverflow > 0, isValid(raised), let frame = super.layoutAttributesForItem(at: raised)?.frame else { return nil }
        return whole(frame)
    }
    /// The items and headings under the raised item's name, as the flow layout places them.
    private func covered() -> [NSCollectionViewLayoutAttributes] {
        guard let covering else { return [] }
        return super.layoutAttributesForElements(in: covering).filter { attributes in
            attributes.frame.intersects(covering) && !(attributes.representedElementCategory == .item && attributes.indexPath == raised)
                && attributes.representedElementCategory != .decorationView
        }
    }
    /// The raised item over the others; anything under its name told what covers it.
    private func adjusted(_ attributes: NSCollectionViewLayoutAttributes, covering: NSRect?) -> NSCollectionViewLayoutAttributes {
        if attributes.representedElementCategory == .item, attributes.indexPath == raised { return raisedCopy(attributes) }
        guard let covering, attributes.frame.intersects(covering),
              let copy = attributes.copy() as? GridLayoutAttributes else { return attributes }
        copy.coveredBy = covering
        return copy
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var all = super.layoutAttributesForElements(in: rect)
        guard let raised, isValid(raised) else { return all }
        let covering = covering
        all = all.map { adjusted($0, covering: covering) }
        if !all.contains(where: { $0.representedElementCategory == .item && $0.indexPath == raised }),
           let attributes = super.layoutAttributesForItem(at: raised), whole(attributes.frame).intersects(rect) {
            // Scrolled so that only its name is in view, it stays on show.
            all.append(raisedCopy(attributes))
        }
        return all
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let attributes = super.layoutAttributesForItem(at: indexPath) else { return nil }
        return adjusted(attributes, covering: covering)
    }
    override func layoutAttributesForSupplementaryView(ofKind elementKind: NSCollectionView.SupplementaryElementKind,
                                                       at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let attributes = super.layoutAttributesForSupplementaryView(ofKind: elementKind, at: indexPath) else { return nil }
        return adjusted(attributes, covering: covering)
    }
    /// A drag over the part of the whole name past the item is over that item, as a click there is.
    override func layoutAttributesForDropTarget(at pointInCollectionView: NSPoint) -> NSCollectionViewLayoutAttributes? {
        if let raised = raisedItem(at: pointInCollectionView), let attributes = layoutAttributesForItem(at: raised) { return attributes }
        return super.layoutAttributesForDropTarget(at: pointInCollectionView)
    }
    override var collectionViewContentSize: NSSize {
        var size = super.collectionViewContentSize
        if let raised, raisedOverflow > 0, isValid(raised), let frame = super.layoutAttributesForItem(at: raised)?.frame {
            size.height = max(size.height, whole(frame).maxY + 12)
        }
        return size
    }
    /// The raised item, for a point on the part of its name that runs past the item, which is drawn over whatever
    /// is there.
    func raisedItem(at point: NSPoint) -> IndexPath? {
        guard let raised, raisedOverflow > 0, isValid(raised), let frame = super.layoutAttributesForItem(at: raised)?.frame,
              point.y >= frame.maxY, whole(frame).contains(point) else { return nil }
        return raised
    }
    /// The item's frame with its whole name; the collection view is flipped, so down is a larger y.
    private func whole(_ frame: NSRect) -> NSRect {
        NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + raisedOverflow)
    }
    /// Over the other items, and over the group headings too, which a flow layout puts at 10.
    static let raisedZIndex = 100
    private func raisedCopy(_ attributes: NSCollectionViewLayoutAttributes) -> NSCollectionViewLayoutAttributes {
        let copy = attributes.copy() as? NSCollectionViewLayoutAttributes ?? attributes
        copy.zIndex = Self.raisedZIndex
        return copy
    }
    private func isValid(_ path: IndexPath) -> Bool {
        guard let collection = collectionView, path.section >= 0, path.section < collection.numberOfSections else { return false }
        return path.item >= 0 && path.item < collection.numberOfItems(inSection: path.section)
    }
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
    /// A selected item's whole name is drawn over the items below it, so a click on it is a click on that item.
    override func indexPathForItem(at point: NSPoint) -> IndexPath? {
        (collectionViewLayout as? FileGridLayout)?.raisedItem(at: point) ?? super.indexPathForItem(at: point)
    }
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

#endif
