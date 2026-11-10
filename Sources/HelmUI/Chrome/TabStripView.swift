#if os(macOS)
import AppKit
import HelmCore

@MainActor protocol TabStripDelegate: AnyObject {
    func tabStripActivate(_ id: TabID)
    func tabStripClose(_ id: TabID)
    func tabStripNewTab()
    func tabStripDropOperation(_ info: NSDraggingInfo, onto id: TabID) -> NSDragOperation
    func tabStripPerformDrop(_ info: NSDraggingInfo, onto id: TabID) -> Bool
    func tabStripDragEnded()
}

/// The custom tab strip, hidden when there's only one tab (F-009). The tabs share the strip equally, shortening their
/// names in the middle to fit, down to `minimumTabWidth`. Past that the strip scrolls, keeping the active tab in view:
/// tabs never make the window wider, however many there are or however long their names.
@MainActor final class TabStripView: NSView {
    weak var delegate: TabStripDelegate?
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let newTab = NSButton()
    private var views: [TabID: TabItemView] = [:]
    private var activeID: TabID?
    /// The narrowest a tab gets: its close button and room for a name as long as "Documents".
    static let minimumTabWidth: CGFloat = 128

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal; stack.distribution = .fillEqually; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        newTab.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        newTab.isBordered = false; newTab.target = self; newTab.action = #selector(addTab)
        newTab.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newTab)
        let separator = NSBox(); separator.boxType = .separator; separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        // The tabs fill the strip while they fit and grow wider than it once they're at their narrowest, which scrolls.
        // That pull is below the window's hold on its size (500), so the strip never widens the window.
        let clip = scroll.contentView
        let fill = stack.widthAnchor.constraint(equalTo: clip.widthAnchor)
        fill.priority = .init(490)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), scroll.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            scroll.trailingAnchor.constraint(equalTo: newTab.leadingAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor), stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: clip.widthAnchor), fill,
            newTab.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            newTab.centerYAnchor.constraint(equalTo: centerYAnchor), newTab.widthAnchor.constraint(equalToConstant: 26),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }

    func render(window state: WindowState, tabs: [TabID: TabState]) {
        for id in Set(views.keys).subtracting(state.tabs) {
            views[id]?.removeFromSuperview(); views[id] = nil
        }
        var ordered: [NSView] = []
        for id in state.tabs {
            let view = views[id] ?? TabItemView(id: id, delegate: self)
            views[id] = view
            view.apply(title: Self.title(tabs[id]), isActive: id == state.activeTabID)
            ordered.append(view)
        }
        if stack.arrangedSubviews != ordered {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            for view in ordered { stack.addArrangedSubview(view) }
            needsLayout = true
        }
        if activeID != state.activeTabID { activeID = state.activeTabID; needsLayout = true }
    }
    /// Whenever the strip is laid out, for new tabs, another active tab or a new width, the active tab is scrolled
    /// into view. Scrolling the strip by hand leaves it where it's put.
    override func layout() {
        super.layout()
        guard let active = activeID.flatMap({ views[$0] }), active.superview != nil else { return }
        stack.layoutSubtreeIfNeeded()
        active.scrollToVisible(active.bounds)
    }
    /// A tab's name, which is also its window's title: the place on show, which while a card is up is the place the card
    /// is about, not the folder hidden under it.
    static func title(_ tab: TabState?) -> String {
        guard let tab else { return "" }
        if let search = tab.search { return "Search: \(search.query.text)" }
        switch ContentStatePresentation.placeOnShow(tab) {
        case .recent: return "Recent"
        case .trash: return "Trash"
        case .directory(let url): return url.path == "/" ? "/" : url.lastPathComponent
        }
    }
    /// The tabs' names as the strip shows them, in order.
    var titlesForTesting: [String] { stack.arrangedSubviews.compactMap { ($0 as? TabItemView)?.title } }
    /// Whether the whole of the active tab is in the strip's view.
    var activeTabInViewForTesting: Bool {
        guard let active = activeID.flatMap({ views[$0] }) else { return false }
        let frame = active.convert(active.bounds, to: scroll.contentView)
        return scroll.contentView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame)
    }
    @objc private func addTab() { delegate?.tabStripNewTab() }
    fileprivate func activate(_ id: TabID) { delegate?.tabStripActivate(id) }
    fileprivate func close(_ id: TabID) { delegate?.tabStripClose(id) }
    fileprivate func dropOperation(_ info: NSDraggingInfo, onto id: TabID) -> NSDragOperation {
        delegate?.tabStripDropOperation(info, onto: id) ?? []
    }
    fileprivate func performDrop(_ info: NSDraggingInfo, onto id: TabID) -> Bool { delegate?.tabStripPerformDrop(info, onto: id) ?? false }
    fileprivate func dragEnded() { delegate?.tabStripDragEnded() }
}

/// A flat tab. The active one is a soft rounded fill; the close button sits on the right, as in Nautilus.
@MainActor private final class TabItemView: NSView {
    private let id: TabID
    private weak var strip: TabStripView?
    private let label = NSTextField(labelWithString: "")
    private let close = NSButton()
    private var active = false
    private var dropTarget = false { didSet { if dropTarget != oldValue { updateFill() } } }
    var title: String { label.stringValue }
    init(id: TabID, delegate: TabStripView) {
        self.id = id; self.strip = delegate
        super.init(frame: .zero)
        wantsLayer = true
        // Dropping on a tab puts the files in its folder; holding a drag over it switches to it.
        registerForDraggedTypes(FileDrag.acceptedTypes)
        layer?.cornerRadius = 7
        setAccessibilityRole(.button)
        label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingMiddle; label.alignment = .center
        // The name gives way to the tab's share of the strip, so a long name shortens rather than widen the window.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        close.isBordered = false; close.target = self; close.action = #selector(closeTab)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.contentTintColor = .secondaryLabelColor
        addSubview(label); addSubview(close)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16), close.heightAnchor.constraint(equalToConstant: 16),
            widthAnchor.constraint(greaterThanOrEqualToConstant: TabStripView.minimumTabWidth)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func apply(title: String, isActive: Bool) {
        label.stringValue = title
        active = isActive
        label.font = .systemFont(ofSize: 13, weight: isActive ? .medium : .regular)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        updateFill()
        setAccessibilityLabel("Tab \(title)")
        setAccessibilitySelected(isActive)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateFill() }
    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = dropTarget ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
                : active ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdate(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdate(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropTarget = false; strip?.dragEnded() }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropTarget = false; strip?.dragEnded() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget = false
        return strip?.performDrop(sender, onto: id) ?? false
    }
    private func dragUpdate(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = strip?.dropOperation(sender, onto: id) ?? []
        dropTarget = operation != []
        return operation
    }
    override func mouseDown(with event: NSEvent) { strip?.activate(id) }
    override func otherMouseDown(with event: NSEvent) { strip?.close(id) }
    @objc private func closeTab() { strip?.close(id) }
}
#endif
