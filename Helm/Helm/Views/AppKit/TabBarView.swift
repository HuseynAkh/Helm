import Cocoa

/// Custom tab bar at the top of the content area
class TabBarView: NSView {

    var tabs: [Tab] = [] {
        didSet { rebuildTabs() }
    }
    var selectedTabID: UUID? {
        didSet { updateSelection() }
    }

    var onTabSelected: ((UUID) -> Void)?
    var onTabClosed: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?

    private var stackView: NSStackView!
    private var newTabButton: NSButton!
    private var tabViews: [UUID: NSView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 0
        stackView.alignment = .centerY
        stackView.distribution = .fillEqually
        stackView.translatesAutoresizingMaskIntoConstraints = false

        newTabButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")!, target: self, action: #selector(newTabClicked))
        newTabButton.bezelStyle = .inline
        newTabButton.isBordered = false
        newTabButton.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stackView)
        addSubview(newTabButton)
        addSubview(separator)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -4),
            stackView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            newTabButton.centerYAnchor.constraint(equalTo: stackView.centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 24),
            newTabButton.heightAnchor.constraint(equalToConstant: 24),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 30)
    }

    var isTabBarVisible: Bool {
        tabs.count > 1
    }

    private func rebuildTabs() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabViews.removeAll()

        for tab in tabs {
            let tabView = makeTabButton(for: tab)
            stackView.addArrangedSubview(tabView)
            tabViews[tab.id] = tabView
        }

        updateSelection()
        invalidateIntrinsicContentSize()
    }

    private func makeTabButton(for tab: Tab) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true

        let titleButton = NSButton(title: tab.title, target: self, action: #selector(tabClicked(_:)))
        titleButton.bezelStyle = .inline
        titleButton.isBordered = false
        titleButton.font = NSFont.systemFont(ofSize: 12)
        titleButton.tag = tab.id.hashValue
        titleButton.translatesAutoresizingMaskIntoConstraints = false
        titleButton.lineBreakMode = .byTruncatingTail

        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")!, target: self, action: #selector(closeTabClicked(_:)))
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.tag = tab.id.hashValue
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = tabs.count <= 1

        container.addSubview(titleButton)
        container.addSubview(closeButton)

        // Store tab ID via associated object
        objc_setAssociatedObject(titleButton, &TabBarAssociatedKeys.tabIDKey, tab.id, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(closeButton, &TabBarAssociatedKeys.tabIDKey, tab.id, .OBJC_ASSOCIATION_RETAIN)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 28),

            titleButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            titleButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            titleButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16)
        ])

        return container
    }

    private func updateSelection() {
        for tab in tabs {
            if let view = tabViews[tab.id] {
                view.layer?.backgroundColor = tab.id == selectedTabID
                    ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
                    : nil
                view.layer?.cornerRadius = 6
            }
        }
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let tabID = objc_getAssociatedObject(sender, &TabBarAssociatedKeys.tabIDKey) as? UUID else { return }
        onTabSelected?(tabID)
    }

    @objc private func closeTabClicked(_ sender: NSButton) {
        guard let tabID = objc_getAssociatedObject(sender, &TabBarAssociatedKeys.tabIDKey) as? UUID else { return }
        onTabClosed?(tabID)
    }

    @objc private func newTabClicked() {
        onNewTab?()
    }

    // Handle middle-click to close tab
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            let point = convert(event.locationInWindow, from: nil)
            for tab in tabs {
                if let view = stackView.arrangedSubviews.first(where: { v in
                    v.subviews.compactMap { objc_getAssociatedObject($0, &TabBarAssociatedKeys.tabIDKey) as? UUID }.contains(tab.id)
                }), view.frame.contains(point) {
                    onTabClosed?(tab.id)
                    return
                }
            }
        }
        super.otherMouseDown(with: event)
    }
}

private enum TabBarAssociatedKeys {
    nonisolated(unsafe) static var tabIDKey: UInt8 = 0
}
