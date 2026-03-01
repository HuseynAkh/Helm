import Cocoa

/// Manages a borderless floating panel that shows path completion suggestions
/// below the BreadcrumbBar's edit field.
final class PathCompletionWindowController: NSObject {

    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var scrollView: NSScrollView?
    private var parentWindowObservers: [NSObjectProtocol] = []

    private(set) var items: [PathCompletionItem] = []
    private(set) var selectedIndex: Int = -1

    /// Called when the user accepts a completion (Tab, Return, or click).
    var onAccept: ((PathCompletionItem) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    private let maxVisibleRows = 8
    private let rowHeight: CGFloat = 24

    // MARK: - Show / Hide / Update

    func show(below anchorView: NSView, items newItems: [PathCompletionItem]) {
        items = newItems
        selectedIndex = newItems.isEmpty ? -1 : 0

        if panel == nil {
            createPanel()
        }

        guard let panel, let tableView, let scrollView else { return }
        guard let parentWindow = anchorView.window else { return }

        tableView.reloadData()
        if selectedIndex >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }

        // Size the scroll view to fit content
        let visibleRows = min(items.count, maxVisibleRows)
        let contentHeight = CGFloat(visibleRows) * rowHeight
        scrollView.frame = NSRect(x: 0, y: 0, width: panel.frame.width, height: contentHeight)
        panel.contentView?.subviews.compactMap { $0 as? NSVisualEffectView }.first?.frame = scrollView.frame

        // Position below the anchor view
        positionPanel(below: anchorView)

        if !panel.isVisible {
            parentWindow.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            observeParentWindow(parentWindow)
        }

        // Update panel height
        var frame = panel.frame
        let topLeft = NSPoint(x: frame.origin.x, y: frame.origin.y + frame.height)
        frame.size.height = contentHeight
        frame.origin.y = topLeft.y - contentHeight
        panel.setFrame(frame, display: true)
    }

    func hide() {
        panel?.parent?.removeChildWindow(panel!)
        panel?.orderOut(nil)
        removeParentWindowObservers()
    }

    func updateItems(_ newItems: [PathCompletionItem]) {
        items = newItems
        selectedIndex = newItems.isEmpty ? -1 : 0
        tableView?.reloadData()
        if selectedIndex >= 0 {
            tableView?.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }

        if let panel, let scrollView {
            let visibleRows = min(items.count, maxVisibleRows)
            let contentHeight = CGFloat(visibleRows) * rowHeight
            scrollView.frame.size.height = contentHeight
            panel.contentView?.subviews.compactMap { $0 as? NSVisualEffectView }.first?.frame = scrollView.frame

            var frame = panel.frame
            let topLeft = NSPoint(x: frame.origin.x, y: frame.origin.y + frame.height)
            frame.size.height = contentHeight
            frame.origin.y = topLeft.y - contentHeight
            panel.setFrame(frame, display: true)
        }
    }

    func teardown() {
        hide()
        panel = nil
        tableView = nil
        scrollView = nil
        items = []
        selectedIndex = -1
    }

    // MARK: - Selection

    func moveSelectionDown() {
        guard !items.isEmpty else { return }
        selectedIndex = min(selectedIndex + 1, items.count - 1)
        tableView?.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView?.scrollRowToVisible(selectedIndex)
    }

    func moveSelectionUp() {
        guard !items.isEmpty else { return }
        selectedIndex = max(selectedIndex - 1, 0)
        tableView?.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView?.scrollRowToVisible(selectedIndex)
    }

    func selectedItem() -> PathCompletionItem? {
        guard selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let contentRect = NSRect(x: 0, y: 0, width: 400, height: CGFloat(maxVisibleRows) * rowHeight)

        let p = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.level = .popUpMenu
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = true
        p.becomesKeyOnlyIfNeeded = true
        p.isMovableByWindowBackground = false
        p.animationBehavior = .utilityWindow

        // Visual effect background
        let effectView = NSVisualEffectView(frame: contentRect)
        effectView.material = .menu
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 6
        effectView.layer?.masksToBounds = true
        p.contentView?.addSubview(effectView)

        // Scroll view + table view
        let sv = NSScrollView(frame: contentRect)
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.borderType = .noBorder

        let tv = NSTableView()
        tv.headerView = nil
        tv.backgroundColor = .clear
        tv.rowHeight = rowHeight
        tv.intercellSpacing = NSSize(width: 0, height: 0)
        tv.selectionHighlightStyle = .regular
        tv.usesAlternatingRowBackgroundColors = false
        tv.allowsMultipleSelection = false
        tv.style = .plain
        tv.dataSource = self
        tv.delegate = self
        tv.target = self
        tv.doubleAction = #selector(tableDoubleClicked)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        column.isEditable = false
        tv.addTableColumn(column)

        sv.documentView = tv
        effectView.addSubview(sv)

        self.panel = p
        self.tableView = tv
        self.scrollView = sv
    }

    // MARK: - Positioning

    private func positionPanel(below anchorView: NSView) {
        guard let panel, let parentWindow = anchorView.window else { return }

        let viewFrameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let viewFrameOnScreen = parentWindow.convertToScreen(viewFrameInWindow)

        let width = viewFrameOnScreen.width
        let topLeft = NSPoint(
            x: viewFrameOnScreen.origin.x,
            y: viewFrameOnScreen.origin.y // Bottom of the anchor in screen coords
        )

        panel.setFrameTopLeftPoint(topLeft)
        var frame = panel.frame
        frame.size.width = width
        panel.setFrame(frame, display: false)

        // Update scroll view and effect view widths
        scrollView?.frame.size.width = width
        panel.contentView?.subviews.compactMap { $0 as? NSVisualEffectView }.first?.frame.size.width = width
        tableView?.tableColumns.first?.width = width
    }

    // MARK: - Parent Window Observation

    private func observeParentWindow(_ parentWindow: NSWindow) {
        removeParentWindowObservers()

        let moveObs = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: parentWindow,
            queue: .main
        ) { [weak self, weak parentWindow] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if let anchor = self.findAnchorView(in: parentWindow) {
                self.positionPanel(below: anchor)
            }
        }

        let resizeObs = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: parentWindow,
            queue: .main
        ) { [weak self, weak parentWindow] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if let anchor = self.findAnchorView(in: parentWindow) {
                self.positionPanel(below: anchor)
            }
        }

        parentWindowObservers = [moveObs, resizeObs]
    }

    private func removeParentWindowObservers() {
        for observer in parentWindowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        parentWindowObservers.removeAll()
    }

    /// Walk up from the panel's child relationship to find the BreadcrumbBar anchor.
    private func findAnchorView(in parentWindow: NSWindow?) -> NSView? {
        // The panel was positioned relative to a BreadcrumbBar.
        // Find it via the window's toolbar items.
        guard let toolbar = parentWindow?.toolbar else { return nil }
        for item in toolbar.items {
            if let bar = item.view as? BreadcrumbBar {
                return bar
            }
        }
        return nil
    }

    // MARK: - Actions

    @objc private func tableDoubleClicked() {
        guard let tv = tableView else { return }
        let row = tv.clickedRow
        guard row >= 0, row < items.count else { return }
        selectedIndex = row
        onAccept?(items[row])
    }
}

// MARK: - NSTableViewDataSource

extension PathCompletionWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }
}

// MARK: - NSTableViewDelegate

extension PathCompletionWindowController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        let cellID = NSUserInterfaceItemIdentifier("CompletionCell")
        let cell: CompletionRowView
        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) as? CompletionRowView {
            cell = existing
        } else {
            cell = CompletionRowView()
            cell.identifier = cellID
        }

        cell.configure(with: item)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tv = tableView else { return }
        selectedIndex = tv.selectedRow
    }
}

// MARK: - CompletionRowView

private class CompletionRowView: NSTableCellView {

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let typeIndicator = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        addSubview(nameLabel)

        typeIndicator.translatesAutoresizingMaskIntoConstraints = false
        typeIndicator.font = NSFont.systemFont(ofSize: 13)
        typeIndicator.textColor = .tertiaryLabelColor
        addSubview(typeIndicator)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: typeIndicator.leadingAnchor, constant: -4),

            typeIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            typeIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            typeIndicator.widthAnchor.constraint(lessThanOrEqualToConstant: 20)
        ])
    }

    func configure(with item: PathCompletionItem) {
        iconView.image = item.icon
        nameLabel.stringValue = item.name
        typeIndicator.stringValue = item.isDirectory ? "/" : ""
    }
}
