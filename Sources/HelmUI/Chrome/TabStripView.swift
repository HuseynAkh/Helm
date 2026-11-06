#if os(macOS)
import AppKit
import HelmCore

@MainActor protocol TabStripDelegate: AnyObject {
    func tabStripActivate(_ id: TabID)
    func tabStripClose(_ id: TabID)
    func tabStripNewTab()
}

/// The custom tab strip, hidden when there's only one tab (F-009).
@MainActor final class TabStripView: NSView {
    weak var delegate: TabStripDelegate?
    private let stack = NSStackView()
    private let newTab = NSButton()
    private var views: [TabID: TabItemView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal; stack.distribution = .fillEqually; stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        newTab.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        newTab.isBordered = false; newTab.target = self; newTab.action = #selector(addTab)
        newTab.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newTab)
        let separator = NSBox(); separator.boxType = .separator; separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            stack.trailingAnchor.constraint(equalTo: newTab.leadingAnchor),
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
}

@MainActor private final class TabItemView: NSView {
    private let id: TabID
    private weak var strip: TabStripView?
    private let label = NSTextField(labelWithString: "")
    private let close = NSButton()
    private var active = false
    init(id: TabID, delegate: TabStripView) {
        self.id = id; self.strip = delegate
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.button)
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle; label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        close.isBordered = false; close.target = self; close.action = #selector(closeTab)
        close.imageScaling = .scaleProportionallyDown
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label); addSubview(close)
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 14), close.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 4), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            heightAnchor.constraint(equalToConstant: 28)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func apply(title: String, isActive: Bool) {
        label.stringValue = title
        active = isActive
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        layer?.backgroundColor = (isActive ? NSColor.controlBackgroundColor : NSColor.clear).cgColor
        setAccessibilityLabel("Tab \(title)")
        setAccessibilitySelected(isActive)
    }
    override func updateLayer() { layer?.backgroundColor = (active ? NSColor.controlBackgroundColor : NSColor.clear).cgColor }
    override func mouseDown(with event: NSEvent) { strip?.activate(id) }
    override func otherMouseDown(with event: NSEvent) { strip?.close(id) }
    @objc private func closeTab() { strip?.close(id) }
}
#endif
