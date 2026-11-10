#if os(macOS)
import AppKit
import HelmCore

@MainActor protocol PathBarDelegate: AnyObject {
    func pathBarNavigate(to url: URL)
    func pathBarOpenInNewTab(_ url: URL)
    /// Copy Path from a piece's menu: the window's pasteboard, which a fixture run keeps to itself.
    func pathBarCopyPath(_ url: URL)
    func pathBarBeginEditing()
    func pathBarAction(_ action: AddressEditorAction)
    func pathBarDropOperation(_ info: NSDraggingInfo, into url: URL?) -> NSDragOperation
    func pathBarPerformDrop(_ info: NSDraggingInfo, into url: URL) -> Bool
    func pathBarDragEnded()
    func pathBarFolderMenu() -> NSMenu?
}

/// One piece of the path as it's shown.
struct PathBarSegment: Equatable {
    let title: String
    let url: URL?
    let symbol: String?
}

/// The Nautilus path bar: one rounded field holding `Home / Documents / Reports`, with the current folder in bold.
/// A parent navigates, the current folder or empty space switches to typing (Q1), and typing accepts paths and URLs
/// (balance document, section 3).
@MainActor final class PathBarView: NSView, NSTextFieldDelegate {
    weak var delegate: PathBarDelegate?
    private var segments: [PathBarSegment] = []
    private var buttons: [PathSegmentButton] = []
    private var separators: [NSTextField] = []
    private let overflowButton = NSButton(title: "…", target: nil, action: nil)
    private var hiddenSegments: [PathBarSegment] = []
    private var stack = NSStackView()
    private let field = LocationTextField()
    private let ghost = NSTextField(labelWithString: "")
    private let popup = CompletionPopup()
    /// As tall as the path's own pieces, so it sits inside the field like one of them.
    private let folderMenuButton = FlatMenuButton(symbol: "ellipsis", label: "Folder Menu", height: 26)
    private var editing = false
    private var applyingText = false
    private var fieldTrailing: NSLayoutConstraint?
    private static let textSize: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        setAccessibilityRole(.group)
        setAccessibilityLabel("Location")
        stack.orientation = .horizontal; stack.spacing = 0; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.init(1), for: .horizontal)
        addSubview(stack)
        overflowButton.isBordered = false
        overflowButton.font = .systemFont(ofSize: Self.textSize)
        overflowButton.target = self; overflowButton.action = #selector(showHidden(_:))
        overflowButton.setAccessibilityLabel("Show enclosing folders")
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: Self.textSize); field.delegate = self; field.isHidden = true
        field.cell?.isScrollable = true; field.cell?.wraps = false; field.lineBreakMode = .byClipping
        field.setAccessibilityLabel("Location path")
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        ghost.textColor = .tertiaryLabelColor; ghost.font = .systemFont(ofSize: Self.textSize); ghost.isHidden = true
        ghost.lineBreakMode = .byClipping
        addSubview(ghost)
        folderMenuButton.menuProvider = { [weak self] in self?.delegate?.pathBarFolderMenu() }
        // It sits at the field's end, so its menu opens inwards, under the path.
        folderMenuButton.alignsMenuToTrailingEdge = true
        addSubview(folderMenuButton)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: folderMenuButton.leadingAnchor, constant: -2),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            folderMenuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            folderMenuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 34)
        ])
        registerForDraggedTypes(FileDrag.acceptedTypes)
        field.onAction = { [weak self] action in self?.delegate?.pathBarAction(action) }
        popup.onSelect = { [weak self] index in
            self?.delegate?.pathBarAction(.select(index))
            self?.delegate?.pathBarAction(.acceptSelection)
            self?.window?.makeFirstResponder(self?.field)
        }
        updateBackground()
    }
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    var isEditingLocation: Bool { editing }
    /// The ⋯ at the field's end, for tests.
    var folderMenuButtonForTesting: FlatMenuButton { folderMenuButton }
    /// The path's pieces, as rendered.
    var segmentTitles: [String] { segments.map(\.title) }
    /// The narrowest the bar can be with the whole name of the folder you're in: the folder, after the … that stands
    /// for the folders before it, and the ⋯, as the constraints in `init` place them. Narrower still, the folder's name
    /// shortens in the middle rather than make the window wider.
    var minimumWidth: CGFloat {
        guard let last = buttons.last else { return 0 }
        var pieces = last.intrinsicContentSize.width
        if let separator = separators.last { pieces += overflowButton.intrinsicContentSize.width + separator.intrinsicContentSize.width }
        return 6 + pieces + 2 + folderMenuButton.laidOutWidth + 1
    }
    /// Puts the caret in the location field while it's being typed in, for when the bar comes back into view.
    func focusLocationField() {
        guard editing, !isHidden, window?.firstResponder !== field.currentEditor() else { return }
        window?.makeFirstResponder(field)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBackground() }
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let alpha: CGFloat = editing ? 0.14 : 0.08
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }

    /// Applies the tab's state. Rebuilds segments only when the location actually changed.
    func render(location: Location, home: URL, editor: AddressEditorState) {
        let next = Self.segments(for: location, home: home)
        if next != segments {
            segments = next
            rebuild()
            let actions = "Actions for “\(next.last?.title ?? "This Folder")”"
            folderMenuButton.toolTip = actions
            folderMenuButton.setAccessibilityLabel(actions)
        }
        if editor.isEditing != editing {
            editing = editor.isEditing
            stack.isHidden = editing; field.isHidden = !editing
            ghost.isHidden = !editing; folderMenuButton.isHidden = editing
            updateBackground()
            if editing {
                // Under an open search the bar is hidden, and a hidden field would lose the caret at once and cancel
                // the typing. The header gives it the caret when the search makes way.
                if !isHiddenOrHasHiddenAncestor { window?.makeFirstResponder(field) }
            } else {
                popup.hide()
                if window?.firstResponder === field.currentEditor() { window?.makeFirstResponder(nil) }
            }
        }
        guard editing else { return }
        if field.stringValue != editor.text {
            applyingText = true
            field.stringValue = editor.text
            let end = NSRange(location: (editor.text as NSString).length, length: 0)
            field.currentEditor()?.selectedRange = end
            // A long path shows its end, where you're typing, not its start.
            (field.currentEditor() as? NSTextView)?.scrollRangeToVisible(end)
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
        let attributes: [NSAttributedString.Key: Any] = [.font: field.font ?? NSFont.systemFont(ofSize: Self.textSize)]
        let width = (editor.text as NSString).size(withAttributes: attributes).width
        ghost.stringValue = suffix
        ghost.sizeToFit()
        let origin = NSPoint(x: 12 + ceil(width) + 2, y: (bounds.height - ghost.frame.height) / 2)
        ghost.frame = NSRect(origin: origin, size: NSSize(width: min(ghost.frame.width, max(0, bounds.width - origin.x - 10)), height: ghost.frame.height))
        ghost.isHidden = false
    }

    /// Paths read the way Nautilus shows them: from Home or the drive you're on, not from `/Users/you`.
    static func segments(for location: Location, home: URL) -> [PathBarSegment] {
        switch location {
        case .recent: return [PathBarSegment(title: "Recent", url: nil, symbol: "clock")]
        case .trash: return [PathBarSegment(title: "Trash", url: nil, symbol: "trash")]
        case .directory(let url):
            let parts = url.standardizedFileURL.pathComponents
            let homeParts = home.standardizedFileURL.pathComponents
            var result: [PathBarSegment] = []
            var consumed = 1
            if parts.count >= homeParts.count, Array(parts.prefix(homeParts.count)) == homeParts {
                consumed = homeParts.count
                if parts.count > consumed + 2, parts[consumed] == "Library", parts[consumed + 1] == "CloudStorage" {
                    consumed += 3
                    result.append(PathBarSegment(title: CloudDriveNaming.provider(ofFolder: parts[consumed - 1]),
                                                 url: Self.url(parts, count: consumed), symbol: "cloud"))
                } else if parts.count > consumed + 2, parts[consumed] == "Library", parts[consumed + 1] == "Mobile Documents", parts[consumed + 2] == "com~apple~CloudDocs" {
                    consumed += 3
                    result.append(PathBarSegment(title: "iCloud Drive", url: Self.url(parts, count: consumed), symbol: "cloud"))
                } else {
                    result.append(PathBarSegment(title: "Home", url: home, symbol: "house"))
                }
            } else if parts.count > 2, parts[1] == "Volumes" {
                consumed = 3
                result.append(PathBarSegment(title: parts[2], url: Self.url(parts, count: 3), symbol: "externaldrive"))
            } else {
                result.append(PathBarSegment(title: "Computer", url: URL(fileURLWithPath: "/", isDirectory: true), symbol: "internaldrive"))
            }
            if consumed < parts.count {
                for index in consumed..<parts.count {
                    result.append(PathBarSegment(title: parts[index], url: Self.url(parts, count: index + 1), symbol: nil))
                }
            }
            return result
        }
    }
    private static func url(_ parts: [String], count: Int) -> URL {
        URL(fileURLWithPath: "/" + parts.prefix(count).dropFirst().joined(separator: "/"), isDirectory: true)
    }

    private func rebuild() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        buttons = segments.enumerated().map { index, segment in
            let button = PathSegmentButton(segment: segment, isLast: index == segments.count - 1, textSize: Self.textSize)
            button.target = self; button.action = #selector(segmentClicked(_:))
            button.onMenu = { [weak self] url in self?.menu(forSegment: url) }
            return button
        }
        separators = segments.dropLast().map { _ in
            let label = NSTextField(labelWithString: "/")
            label.font = .systemFont(ofSize: Self.textSize)
            label.textColor = .tertiaryLabelColor
            return label
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Keep the current folder and as many parents as fit, like Nautilus does when it's narrow.
        let available = bounds.width - 12 - 36
        let overflowWidth: CGFloat = 40
        var used: CGFloat = 0
        var shown = 0
        for button in buttons.reversed() {
            let width = button.intrinsicContentSize.width + 14
            if used + width > available - (shown + 1 < buttons.count ? overflowWidth : 0), shown > 0 { break }
            used += width; shown += 1
        }
        hiddenSegments = Array(segments.prefix(buttons.count - shown))
        var wanted: [NSView] = []
        if !hiddenSegments.isEmpty { wanted.append(overflowButton) }
        let first = buttons.count - shown
        for index in first..<buttons.count {
            if index > first || !hiddenSegments.isEmpty, index > 0 { wanted.append(separators[index - 1]) }
            wanted.append(buttons[index])
        }
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
        if let url = sender.representedObject as? URL { delegate?.pathBarCopyPath(url) }
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdate(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdate(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight(nil); delegate?.pathBarDragEnded() }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlight(nil); delegate?.pathBarDragEnded() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight(nil)
        guard let target = segmentUnder(sender)?.url else { return false }
        return delegate?.pathBarPerformDrop(sender, into: target) ?? false
    }
    /// The folder under the pointer lights up, and the pointer shows what the drop will do there.
    private func dragUpdate(_ sender: NSDraggingInfo) -> NSDragOperation {
        let segment = segmentUnder(sender)
        let operation = delegate?.pathBarDropOperation(sender, into: segment?.url) ?? []
        highlight(operation == [] ? nil : segment)
        return operation
    }
    private func highlight(_ segment: PathSegmentButton?) {
        for button in buttons { button.isDropTarget = button === segment }
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
    private var trackingArea: NSTrackingArea?
    init(segment: PathBarSegment, isLast: Bool, textSize: CGFloat) {
        self.url = segment.url; self.isLast = isLast
        super.init(frame: .zero)
        title = segment.title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        font = .systemFont(ofSize: textSize, weight: isLast ? .semibold : .regular)
        contentTintColor = isLast ? .labelColor : .secondaryLabelColor
        attributedTitle = NSAttributedString(string: segment.title, attributes: [
            .font: NSFont.systemFont(ofSize: textSize, weight: isLast ? .semibold : .regular),
            .foregroundColor: isLast ? NSColor.labelColor : NSColor.secondaryLabelColor])
        lineBreakMode = .byTruncatingMiddle
        setContentHuggingPriority(.required, for: .horizontal)
        // Below the sidebar's hold on its width (260) and the window's on its size (500 and up): a name too long for the
        // room shortens in the middle rather than push the window wider or squeeze the sidebar.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityLabel(isLast ? "\(segment.title), current folder" : segment.title)
        if let symbol = segment.symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: textSize, weight: .regular))
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 12, height: size.height)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?(url) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        }
    }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = isDropTarget ? Self.dropFill : nil }
    var isDropTarget = false {
        didSet { if isDropTarget != oldValue { layer?.backgroundColor = isDropTarget ? Self.dropFill : nil } }
    }
    private static var dropFill: CGColor { NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor }
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
        table.dataSource = self; table.delegate = self; table.rowHeight = 28
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
        let height = min(CGFloat(rows.count) * 30 + 8, 340)
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
        label.font = .systemFont(ofSize: 14)
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
