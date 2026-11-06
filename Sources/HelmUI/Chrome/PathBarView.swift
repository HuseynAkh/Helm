#if os(macOS)
import AppKit
import HelmCore

@MainActor protocol PathBarDelegate: AnyObject {
    func pathBarNavigate(to url: URL)
    func pathBarOpenInNewTab(_ url: URL)
    func pathBarBeginEditing()
    func pathBarAction(_ action: AddressEditorAction)
    func pathBarAcceptDrop(_ urls: [URL], into url: URL) -> Bool
}

/// The Nautilus-style location control. An ancestor navigates, the current folder or empty space
/// switches to typing (Q1), and typing accepts paths and URLs (balance document, section 3).
@MainActor final class PathBarView: NSView, NSTextFieldDelegate {
    weak var delegate: PathBarDelegate?
    private let background = NSVisualEffectView()
    private var segments: [(title: String, url: URL?)] = []
    private var buttons: [PathSegmentButton] = []
    private let overflowButton = NSButton(title: "…", target: nil, action: nil)
    private var hiddenSegments: [(title: String, url: URL?)] = []
    private var stack = NSStackView()
    private let field = LocationTextField()
    private let ghost = NSTextField(labelWithString: "")
    private let popup = CompletionPopup()
    private var editing = false
    private var applyingText = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.09).cgColor
        setAccessibilityRole(.group)
        setAccessibilityLabel("Location")
        stack.orientation = .horizontal; stack.spacing = 0; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        overflowButton.isBordered = false
        overflowButton.target = self; overflowButton.action = #selector(showHidden(_:))
        overflowButton.setAccessibilityLabel("Show enclosing folders")
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13); field.delegate = self; field.isHidden = true
        field.cell?.isScrollable = true; field.cell?.wraps = false; field.lineBreakMode = .byClipping
        field.setAccessibilityLabel("Location path")
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        ghost.textColor = .tertiaryLabelColor; ghost.font = .systemFont(ofSize: 13); ghost.isHidden = true
        ghost.lineBreakMode = .byClipping
        addSubview(ghost)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28)
        ])
        registerForDraggedTypes([.fileURL])
        field.onAction = { [weak self] action in self?.delegate?.pathBarAction(action) }
        popup.onSelect = { [weak self] index in
            self?.delegate?.pathBarAction(.select(index))
            self?.delegate?.pathBarAction(.acceptSelection)
            self?.window?.makeFirstResponder(self?.field)
        }
    }
    required init?(coder: NSCoder) { nil }

    var isEditingLocation: Bool { editing }
    /// Flexible: the toolbar decides how wide this is.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

    /// Applies the tab's state. Rebuilds segments only when the location actually changed.
    func render(location: Location, editor: AddressEditorState) {
        let next = Self.segments(for: location)
        if next.map(\.url) != segments.map(\.url) || next.map(\.title) != segments.map(\.title) {
            segments = next
            rebuild()
        }
        if editor.isEditing != editing {
            editing = editor.isEditing
            stack.isHidden = editing; field.isHidden = !editing
            ghost.isHidden = !editing
            if editing {
                window?.makeFirstResponder(field)
            } else {
                popup.hide()
                if window?.firstResponder === field.currentEditor() { window?.makeFirstResponder(nil) }
            }
        }
        guard editing else { return }
        if field.stringValue != editor.text {
            applyingText = true
            field.stringValue = editor.text
            field.currentEditor()?.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
            applyingText = false
        }
        updateGhost(editor)
        if editor.isPopupVisible {
            popup.show(rows: editor.rows, selected: editor.selectedIndex, below: self)
        } else { popup.hide() }
    }

    func shake() {
        NSSound.beep()
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [0, 8, -8, 6, -6, 3, 0]
        animation.isAdditive = true; animation.duration = 0.3
        layer?.add(animation, forKey: "shake")
    }

    private func updateGhost(_ editor: AddressEditorState) {
        guard let suffix = editor.ghostSuffix, !suffix.isEmpty else { ghost.isHidden = true; return }
        let attributes: [NSAttributedString.Key: Any] = [.font: field.font ?? NSFont.systemFont(ofSize: 13)]
        let width = (editor.text as NSString).size(withAttributes: attributes).width
        ghost.stringValue = suffix
        ghost.sizeToFit()
        let origin = NSPoint(x: 10 + ceil(width) + 2, y: (bounds.height - ghost.frame.height) / 2)
        ghost.frame = NSRect(origin: origin, size: NSSize(width: min(ghost.frame.width, max(0, bounds.width - origin.x - 10)), height: ghost.frame.height))
        ghost.isHidden = false
    }

    static func segments(for location: Location) -> [(title: String, url: URL?)] {
        switch location {
        case .recent: return [("Recent", nil)]
        case .trash: return [("Trash", nil)]
        case .directory(let url):
            let model = PathPresentation(location: location, selectedEntries: [])
            let values = model.segments
            if values.isEmpty { return [(url.lastPathComponent, url)] }
            return values.map { ($0.id.path == "/" ? "/" : $0.title, $0.id) }
        }
    }

    private func rebuild() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        buttons = segments.enumerated().map { index, segment in
            let button = PathSegmentButton(title: segment.title, url: segment.url, isLast: index == segments.count - 1)
            button.target = self; button.action = #selector(segmentClicked(_:))
            button.onMenu = { [weak self] url in self?.menu(forSegment: url) }
            return button
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Keep the current folder and as many parents as fit, like Nautilus does when it's narrow.
        let available = bounds.width - 12
        let overflowWidth: CGFloat = 26
        var used: CGFloat = 0
        var shown: [PathSegmentButton] = []
        for button in buttons.reversed() {
            let width = button.intrinsicContentSize.width + 4
            if used + width > available - (shown.count < buttons.count ? overflowWidth : 0), !shown.isEmpty { break }
            used += width; shown.insert(button, at: 0)
        }
        hiddenSegments = Array(segments.prefix(buttons.count - shown.count))
        var wanted: [NSView] = []
        if !hiddenSegments.isEmpty { wanted.append(overflowButton) }
        wanted += shown as [NSView]
        if stack.arrangedSubviews != wanted {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            for view in wanted { stack.addArrangedSubview(view) }
        }
    }

    @objc private func segmentClicked(_ sender: PathSegmentButton) {
        if sender.isLast || sender.url == nil { delegate?.pathBarBeginEditing(); return }
        if let url = sender.url { delegate?.pathBarNavigate(to: url) }
    }
    override func mouseDown(with event: NSEvent) {
        if !editing { delegate?.pathBarBeginEditing() }
    }
    @objc private func showHidden(_ sender: NSButton) {
        let menu = NSMenu()
        for segment in hiddenSegments.reversed() {
            let item = NSMenuItem(title: segment.title, action: #selector(hiddenChosen(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = segment.url
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
    @objc private func hiddenChosen(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { delegate?.pathBarNavigate(to: url) }
    }
    private func menu(forSegment url: URL?) -> NSMenu? {
        guard let url else { return nil }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open in New Tab", action: #selector(openSegmentTab(_:)), keyEquivalent: "")
        open.target = self; open.representedObject = url
        menu.addItem(open)
        let copy = NSMenuItem(title: "Copy Path", action: #selector(copySegmentPath(_:)), keyEquivalent: "")
        copy.target = self; copy.representedObject = url
        menu.addItem(copy)
        return menu
    }
    @objc private func openSegmentTab(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { delegate?.pathBarOpenInNewTab(url) }
    }
    @objc private func copySegmentPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    // MARK: Typing

    func controlTextDidChange(_ notification: Notification) {
        guard !applyingText else { return }
        delegate?.pathBarAction(.textChanged(field.stringValue))
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        // Clicking away cancels, while Return is handled below.
        if editing { delegate?.pathBarAction(.cancel) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): delegate?.pathBarAction(.returnKey); return true
        case #selector(NSResponder.cancelOperation(_:)): delegate?.pathBarAction(.escape); return true
        case #selector(NSResponder.moveUp(_:)): delegate?.pathBarAction(.arrowUp); return true
        case #selector(NSResponder.moveDown(_:)): delegate?.pathBarAction(.arrowDown); return true
        case #selector(NSResponder.insertTab(_:)): delegate?.pathBarAction(.tab); return true
        case #selector(NSResponder.insertBacktab(_:)): delegate?.pathBarAction(.backtab); return true
        case #selector(NSResponder.moveRight(_:)):
            let range = textView.selectedRange()
            let atEnd = range.length == 0 && range.location == (textView.string as NSString).length
            if atEnd, !ghost.isHidden { delegate?.pathBarAction(.arrowRight); return true }
            return false
        default: return false
        }
    }

    // MARK: Drops onto the path

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        segmentUnder(sender)?.url == nil ? [] : .generic
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        segmentUnder(sender)?.url == nil ? [] : .generic
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let target = segmentUnder(sender)?.url,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        return delegate?.pathBarAcceptDrop(urls, into: target) ?? false
    }
    private func segmentUnder(_ sender: NSDraggingInfo) -> PathSegmentButton? {
        let point = convert(sender.draggingLocation, from: nil)
        return buttons.first { $0.superview != nil && $0.convert($0.bounds, to: self).contains(point) }
    }
}

/// One clickable piece of the path.
@MainActor final class PathSegmentButton: NSButton {
    let url: URL?
    let isLast: Bool
    var onMenu: ((URL?) -> NSMenu?)?
    init(title: String, url: URL?, isLast: Bool) {
        self.url = url; self.isLast = isLast
        super.init(frame: .zero)
        self.title = title
        isBordered = false; bezelStyle = .inline
        font = .systemFont(ofSize: 13, weight: isLast ? .semibold : .regular)
        contentTintColor = isLast ? .labelColor : .secondaryLabelColor
        lineBreakMode = .byTruncatingMiddle
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityLabel(isLast ? "\(title), current folder" : title)
        if !isLast {
            imagePosition = .imageTrailing
            image = NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)
            imageScaling = .scaleProportionallyDown
        }
    }
    required init?(coder: NSCoder) { nil }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?(url) }
}

/// Keeps caret-position reports flowing to the address reducer.
@MainActor final class LocationTextField: NSTextField {
    var onAction: ((AddressEditorAction) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { currentEditor()?.selectedRange = NSRange(location: (stringValue as NSString).length, length: 0) }
        return result
    }
}

/// The list of completions under the location bar.
@MainActor final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Int) -> Void)?
    private let panel: NSPanel
    private let table = NSTableView()
    private var rows: [CompletionRow] = []
    private var applying = false
    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.hasShadow = true; panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = true
        let effect = NSVisualEffectView()
        effect.material = .menu; effect.state = .active; effect.wantsLayer = true; effect.layer?.cornerRadius = 8; effect.layer?.masksToBounds = true
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: .init("name"))
        table.addTableColumn(column); table.headerView = nil; table.backgroundColor = .clear
        table.dataSource = self; table.delegate = self; table.rowHeight = 22
        table.target = self; table.action = #selector(clicked)
        table.style = .plain
        scroll.documentView = table
        scroll.frame = effect.bounds; scroll.autoresizingMask = [.width, .height]
        effect.addSubview(scroll)
        panel.contentView = effect
    }
    func show(rows: [CompletionRow], selected: Int?, below view: NSView) {
        self.rows = rows
        applying = true
        table.reloadData()
        if let selected { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false); table.scrollRowToVisible(selected) }
        else { table.deselectAll(nil) }
        applying = false
        guard let window = view.window else { return }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let height = min(CGFloat(rows.count) * 24 + 8, 300)
        panel.setFrame(NSRect(x: frame.minX, y: frame.minY - height - 4, width: max(frame.width, 320), height: height), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }
    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("completion")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CompletionCell) ?? CompletionCell(identifier: id)
        cell.apply(rows[row])
        return cell
    }
    @objc private func clicked() { if table.clickedRow >= 0 { onSelect?(table.clickedRow) } }
}

@MainActor private final class CompletionCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(icon); addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func apply(_ row: CompletionRow) {
        label.stringValue = row.name
        icon.image = NSImage(systemSymbolName: row.isParentLink ? "arrow.up" : (row.isDirectory ? "folder" : "doc"), accessibilityDescription: nil)
    }
}
#endif
