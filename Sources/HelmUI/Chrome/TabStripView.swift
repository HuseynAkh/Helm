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

/// The custom tab strip, hidden when there's only one tab (F-009).
@MainActor final class TabStripView: NSView {
    weak var delegate: TabStripDelegate?
    private let stack = NSStackView()
    private let newTab = NSButton()
    private var views: [TabID: TabItemView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal; stack.distribution = .fillEqually; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        newTab.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        newTab.isBordered = false; newTab.target = self; newTab.action = #selector(addTab)
        newTab.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newTab)
        let separator = NSBox(); separator.boxType = .separator; separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.trailingAnchor.constraint(equalTo: newTab.leadingAnchor, constant: -4),
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
        }
    }
    static func title(_ tab: TabState?) -> String {
        guard let tab else { return "" }
        if let search = tab.search { return "Search: \(search.query.text)" }
        switch tab.location {
        case .recent: return "Recent"
        case .trash: return "Trash"
        case .directory(let url): return url.path == "/" ? "/" : url.lastPathComponent
        }
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
    init(id: TabID, delegate: TabStripView) {
        self.id = id; self.strip = delegate
        super.init(frame: .zero)
        wantsLayer = true
        // Dropping on a tab puts the files in its folder; holding a drag over it switches to it.
        registerForDraggedTypes(FileDrag.acceptedTypes)
        layer?.cornerRadius = 7
        setAccessibilityRole(.button)
        label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingMiddle; label.alignment = .center
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
            close.widthAnchor.constraint(equalToConstant: 16), close.heightAnchor.constraint(equalToConstant: 16)
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
