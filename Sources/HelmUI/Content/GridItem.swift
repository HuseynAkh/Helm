#if os(macOS)
import AppKit
import HelmCore

/// One grid cell: icon over the name. The name takes two lines at most, cut in the middle of the second when it's
/// longer (P-035). While it's the one item selected it shows whole, up to five lines, on a highlight that grows with
/// it and covers the items below, as in Finder. A shortened name is in full in the tooltip (P-053), and VoiceOver
/// always reads it in full.
@MainActor final class GridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("grid")
    var onDoubleClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = GridNameLabel(wrappingLabelWithString: "")
    private let highlight = GridHighlightView()
    private let star = NSImageView()
    private var iconWidth: NSLayoutConstraint?
    private var iconHeight: NSLayoutConstraint?
    private var labelHeight: NSLayoutConstraint?
    private var highlightBottom: NSLayoutConstraint?
    private var path: String?
    private var ticket: IconCache.Ticket?
    private weak var icons: IconCache?
    private var metrics = GridItemMetrics(iconSize: 96, lineHeight: 17)
    private var font = NSFont.systemFont(ofSize: 14)
    /// The item on show, and its name as shown everywhere: an app's without ".app".
    private(set) var entryID: ItemID?
    private(set) var name = ""
    /// The name's lines on show now.
    private(set) var nameLines = GridNameLines(lines: [""], isShortened: false)
    /// Whether it's the one item selected, which shows its whole name.
    private(set) var isExpanded = false
    private(set) var isEditingName = false

    override func loadView() {
        let root = GridItemView()
        root.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
        // The highlight and the whole name run past the bottom of the item while it's the one selected.
        root.clipsToBounds = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center; label.font = .systemFont(ofSize: 14)
        label.lineBreakMode = .byWordWrapping; label.isSelectable = false
        // A name that fits is the label's to wrap, on the lines worked out for it; a shortened one comes as lines
        // that each fit, so the label never wraps them again. This is only a fallback.
        label.cell?.truncatesLastVisibleLine = true
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Starred")
        star.contentTintColor = .systemYellow
        for view in [highlight, icon, label, star] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let width = icon.widthAnchor.constraint(equalToConstant: 96), height = icon.heightAnchor.constraint(equalToConstant: 96)
        let lines = label.heightAnchor.constraint(equalToConstant: 34)
        let bottom = highlight.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        iconWidth = width; iconHeight = height; labelHeight = lines; highlightBottom = bottom
        NSLayoutConstraint.activate([
            width, height, lines, bottom,
            highlight.leadingAnchor.constraint(equalTo: root.leadingAnchor), highlight.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            highlight.topAnchor.constraint(equalTo: root.topAnchor),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: GridItemMetrics.iconTop),
            icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: GridItemMetrics.nameGap),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: GridItemMetrics.nameInset),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -GridItemMetrics.nameInset),
            star.trailingAnchor.constraint(equalTo: icon.trailingAnchor), star.bottomAnchor.constraint(equalTo: icon.bottomAnchor),
            star.widthAnchor.constraint(equalToConstant: 14), star.heightAnchor.constraint(equalToConstant: 14)
        ])
        view = root
        imageView = icon; textField = label
    }
    override var isSelected: Bool { didSet { updateHighlight() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateHighlight() } }
    private func updateHighlight() {
        let on = isSelected || highlightState == .forSelection
        // A folder under a drag gets a stronger fill and an outline, so it's clear what will take the drop.
        highlight.style = highlightState == .asDropTarget ? .dropTarget : (on ? .selected : .none)
        view.setAccessibilitySelected(on)
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        icons?.cancel(ticket); ticket = nil
        isEditingName = false
        view.cutAway(.zero, frame: view.frame)
    }
    /// Where the selected item's whole name lies over this one, this one cuts itself away, so nothing of it shows
    /// through the name's highlight.
    override func apply(_ layoutAttributes: NSCollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        view.cutAway((layoutAttributes as? GridLayoutAttributes)?.coveredBy ?? .zero, frame: layoutAttributes.frame)
    }
    func apply(_ entry: FileEntry, isCut: Bool, metrics: GridItemMetrics, font: NSFont, expanded: Bool, scale: CGFloat, icons: IconCache?) {
        _ = view
        self.metrics = metrics; self.font = font
        entryID = entry.id; name = entry.displayName
        isExpanded = expanded; isEditingName = false
        iconWidth?.constant = metrics.iconSize; iconHeight?.constant = metrics.iconSize
        label.font = font
        showName()
        star.isHidden = !entry.isStarred
        // Hidden and cut items are dimmed, but not their highlight, which stays fully visible.
        let opacity = CGFloat(ContentLeafPresentation.opacity(isHidden: entry.isHidden, isCut: isCut))
        for part in [icon, label, star] as [NSView] { part.alphaValue = opacity }
        view.setAccessibilityLabel(entry.name); view.setAccessibilityRole(.cell)
        self.icons?.cancel(ticket); ticket = nil
        path = entry.url.path
        self.icons = icons
        let points = metrics.iconSize
        icon.image = icons?.cachedImage(for: entry, points: points, scale: scale) ?? icons?.placeholder(for: entry)
        ticket = icons?.load(for: entry, points: points, scale: scale, previews: true) { [weak self] image in
            if self?.path == entry.url.path { self?.icon.image = image }
        }
    }

    /// Shows the whole name, up to five lines, or goes back to two.
    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        if !isEditingName { showName() }
    }

    private func showName() {
        let limit = isExpanded ? GridItemMetrics.linesSelected : GridItemMetrics.linesShown
        nameLines = GridNameCache.shared.lines(for: name, width: metrics.textWidth, font: font, maxLines: limit)
        label.maximumNumberOfLines = nameLines.lines.count
        label.stringValue = nameLines.text
        // VoiceOver reads the label's words, so they're the whole name, never the shortened lines.
        label.cell?.setAccessibilityValue(name)
        labelHeight?.constant = CGFloat(nameLines.lines.count) * metrics.lineHeight
        highlightBottom?.constant = metrics.overflow(lines: nameLines.lines.count)
        view.toolTip = nameLines.isShortened ? name : nil
        updateHighlight()
    }

    /// How far the name on show runs past the bottom of the item.
    var nameOverflow: CGFloat { max(0, highlightBottom?.constant ?? 0) }

    /// The rename field shows the whole name, however long, and grows as it's typed.
    func beginEditingName() {
        isEditingName = true
        label.maximumNumberOfLines = 0
        label.stringValue = name
        view.toolTip = nil
        fitEditedName()
    }
    func fitEditedName() {
        guard isEditingName else { return }
        let editor = label.currentEditor() as? NSTextView
        let words = editor?.string ?? label.stringValue
        let shown = CGFloat(GridItemMetrics.linesShown) * metrics.lineHeight
        var needed = GridNameMetrics.height(of: words, labelWidth: metrics.labelFrameWidth, font: font)
        // Once typing starts, the editor's own lines are what must fit, and it can break them a little differently.
        if let editor, let layout = editor.layoutManager, let container = editor.textContainer {
            layout.ensureLayout(for: container)
            needed = max(needed, ceil(layout.usedRect(for: container).height + 2 * editor.textContainerInset.height))
        }
        let height = max(shown, needed)
        labelHeight?.constant = height
        highlightBottom?.constant = height - shown
        updateHighlight()
    }
    /// Back to the name's lines once renaming ends.
    func endEditingName() {
        guard isEditingName else { return }
        isEditingName = false
        showName()
    }

    /// For tests: the highlight's frame and the name's, in the item's own coordinates.
    var highlightFrameForTesting: NSRect { view.layoutSubtreeIfNeeded(); return highlight.frame }
    var labelFrameForTesting: NSRect { view.layoutSubtreeIfNeeded(); return label.frame }
    /// The highlight's colour as drawn now, in the item's appearance.
    var highlightFillForTesting: NSColor? {
        highlight.needsDisplay = true
        highlight.displayIfNeeded()
        return highlight.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
    }
}

/// A grid item's name. A name that fits is the label's to wrap; a shortened one comes as lines that each fit.
@MainActor final class GridNameLabel: NSTextField {
    /// How far the label's frame runs past its constraints on each side. AppKit lays a text field out by a rect this
    /// much inside its frame; it's fixed here, so the room a name is given is worked out from the same number.
    nonisolated static let outset: CGFloat = 2
    /// The points a wrapping label keeps clear of its text across its frame: 4 on each side, 2 of cell inset and 2 of
    /// line padding. A line of text this much narrower than the frame stays on one line.
    nonisolated static let textInset: CGFloat = 8
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: Self.outset, bottom: 0, right: Self.outset) }
}

/// What's behind a grid item: the accent wash while it's selected, or under a drag. It's the same wash where a
/// selected name runs past the item: the items under the name cut that part of themselves away instead.
@MainActor final class GridHighlightView: NSView {
    enum Style { case none, selected, dropTarget }
    var style = Style.none { didSet { if style != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { nil }
    static let cornerRadius: CGFloat = 10
    override var wantsUpdateLayer: Bool { true }
    /// AppKit calls this in the view's own appearance, so light and dark each get their colours.
    override func updateLayer() {
        let accent = NSColor.controlAccentColor
        let strength: CGFloat = style == .dropTarget ? 0.4 : 0.28
        layer?.backgroundColor = (style == .none ? NSColor.clear : accent.withAlphaComponent(strength)).cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = style == .dropTarget ? 2 : 0
        layer?.borderColor = accent.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    // Clicks go to the item, as before.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class GridItemView: NSView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }
}

extension NSView {
    /// Hides the part of this grid element under `covering`, the highlight of an item showing its whole name, in the
    /// grid's coordinates, so the name reads on its highlight alone. `.zero` shows all of it again.
    func cutAway(_ covering: NSRect, frame: NSRect) {
        guard covering.width > 0, covering.height > 0, frame.width > 0, frame.height > 0 else {
            if layer?.mask != nil { layer?.mask = nil }
            return
        }
        wantsLayer = true
        // The grid is flipped and this view isn't: lower in the grid is nearer this view's bottom.
        let hole = NSRect(x: covering.minX - frame.minX, y: frame.height - (covering.maxY - frame.minY),
                          width: covering.width, height: covering.height)
        let radius = min(GridHighlightView.cornerRadius, hole.width / 2, hole.height / 2)
        let path = CGMutablePath()
        path.addRect(NSRect(origin: .zero, size: frame.size))
        path.addRoundedRect(in: hole, cornerWidth: radius, cornerHeight: radius)
        let mask = (layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = NSRect(origin: .zero, size: frame.size)
        mask.fillRule = .evenOdd
        mask.path = path
        layer?.mask = mask
    }
    /// For tests: whether this element's own point `point`, in the grid's coordinates, is cut away.
    func isCutAwayForTesting(at point: NSPoint) -> Bool {
        guard let mask = layer?.mask as? CAShapeLayer, let path = mask.path else { return false }
        let local = NSPoint(x: point.x - frame.minX, y: frame.height - (point.y - frame.minY))
        return bounds.contains(local) && !path.contains(local, using: .evenOdd)
    }
}
#endif
