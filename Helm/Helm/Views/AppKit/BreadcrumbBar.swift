import Cocoa

class BreadcrumbBar: NSView {

    var url: URL = FileManager.default.homeDirectoryForCurrentUser {
        didSet {
            if !isEditing {
                rebuildSegments()
            }
        }
    }

    var onSegmentClicked: ((URL) -> Void)?

    private let scrollView = NSScrollView()
    private let segmentsStack = BreadcrumbStackView()
    private let accessoryStack = NSStackView()
    private var copyButton: NSButton!
    private var editButton: NSButton!

    private var editField: NSTextField?
    private var isEditing = false

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
        layer?.cornerRadius = 8
        updateAppearance()

        // ---- Segments stack (scroll view's document view, frame-based) ----
        segmentsStack.orientation = .horizontal
        segmentsStack.alignment = .centerY
        segmentsStack.spacing = 2
        segmentsStack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        segmentsStack.breadcrumbBar = self
        // IMPORTANT: Use frame-based layout for NSScrollView document views
        segmentsStack.translatesAutoresizingMaskIntoConstraints = true

        // ---- Scroll view ----
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.documentView = segmentsStack

        // ---- Accessory buttons ----
        copyButton = makeAccessoryButton(
            symbolName: "doc.on.doc",
            tooltip: "Copy path",
            action: #selector(copyPath)
        )
        editButton = makeAccessoryButton(
            symbolName: "pencil.line",
            tooltip: "Edit path",
            action: #selector(editButtonTapped)
        )

        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.orientation = .horizontal
        accessoryStack.spacing = 2
        accessoryStack.alignment = .centerY
        accessoryStack.addArrangedSubview(copyButton)
        accessoryStack.addArrangedSubview(editButton)

        // ---- Layout ----
        addSubview(scrollView)
        addSubview(accessoryStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scrollView.centerYAnchor.constraint(equalTo: centerYAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 26),
            scrollView.trailingAnchor.constraint(equalTo: accessoryStack.leadingAnchor, constant: -2),

            accessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            accessoryStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        rebuildSegments()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 34)
    }

    // MARK: - Accessory Buttons

    private func makeAccessoryButton(symbolName: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(frame: .zero)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    // MARK: - Segments

    private func rebuildSegments() {
        segmentsStack.arrangedSubviews.forEach { view in
            segmentsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if url.isHelmRecentsLocation {
            segmentsStack.addArrangedSubview(makeVirtualLabel("Recent"))
            applyButtonState(isFileLocation: false)
            resizeDocumentView()
            return
        }

        guard url.isFileURL else {
            segmentsStack.addArrangedSubview(makeVirtualLabel(url.absoluteString))
            applyButtonState(isFileLocation: false)
            resizeDocumentView()
            return
        }

        let ancestors = url.ancestorURLs()
        for (index, ancestor) in ancestors.enumerated() {
            if index > 0 {
                segmentsStack.addArrangedSubview(makeSeparator())
            }

            let button = makeSegmentButton(
                title: displayTitle(for: ancestor),
                isCurrent: index == ancestors.count - 1
            )
            objc_setAssociatedObject(button, &AssociatedKeys.urlKey, ancestor, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            segmentsStack.addArrangedSubview(button)
        }

        applyButtonState(isFileLocation: true)
        resizeDocumentView()

        DispatchQueue.main.async { [weak self] in
            self?.scrollToEnd()
        }
    }

    /// Manually size the document view (frame-based) to fit its content or fill the visible area.
    private func resizeDocumentView() {
        segmentsStack.layoutSubtreeIfNeeded()
        let fittingSize = segmentsStack.fittingSize
        let clipBounds = scrollView.contentView.bounds
        let height = clipBounds.height > 0 ? clipBounds.height : 26
        segmentsStack.frame = NSRect(
            x: 0,
            y: 0,
            width: max(fittingSize.width, clipBounds.width),
            height: height
        )
    }

    private func makeSegmentButton(title: String, isCurrent: Bool) -> SegmentButton {
        let button = SegmentButton(title: title, target: self, action: #selector(segmentTapped(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = isCurrent ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        button.contentTintColor = isCurrent ? .labelColor : .secondaryLabelColor
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func makeSeparator() -> NSTextField {
        let label = NSTextField(labelWithString: "\u{203A}")
        label.font = .systemFont(ofSize: 11, weight: .light)
        label.textColor = .tertiaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func makeVirtualLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        return label
    }

    private func applyButtonState(isFileLocation: Bool) {
        copyButton.isEnabled = isFileLocation
        editButton.isEnabled = isFileLocation
        copyButton.contentTintColor = isFileLocation ? .secondaryLabelColor : .quaternaryLabelColor
        editButton.contentTintColor = isFileLocation ? .secondaryLabelColor : .quaternaryLabelColor
    }

    private func scrollToEnd() {
        guard let documentView = scrollView.documentView else { return }
        let maxX = max(0, documentView.bounds.width - scrollView.contentView.bounds.width)
        scrollView.contentView.scroll(to: NSPoint(x: maxX, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func segmentTapped(_ sender: NSButton) {
        guard let targetURL = objc_getAssociatedObject(sender, &AssociatedKeys.urlKey) as? URL else { return }
        onSegmentClicked?(targetURL)
    }

    // MARK: - Edit Mode

    @objc private func editButtonTapped() {
        startEditing()
    }

    /// Whether the delegate is fully wired and focus is stable.
    /// Prevents premature `controlTextDidEndEditing` during setup.
    private var editFieldReady = false

    func startEditing() {
        guard url.isFileURL else { return }
        guard !isEditing else { return }
        isEditing = true
        editFieldReady = false

        scrollView.isHidden = true
        accessoryStack.isHidden = true

        let field = NSTextField(string: url.path)
        field.font = NSFont.systemFont(ofSize: 13)
        field.focusRingType = .none
        field.drawsBackground = false
        field.isBordered = false
        // Do NOT set delegate here — defer until focus is stable to avoid
        // premature controlTextDidEndEditing from focus negotiation.
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        editField = field
        updateAppearance()

        // Use a short delay to let the toolbar and window settle after
        // hiding views mid-click, then establish focus and wire delegate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak field] in
            guard let self, let field, self.isEditing else { return }
            if self.window?.makeFirstResponder(field) == true {
                field.currentEditor()?.selectAll(nil)
                // Now that focus is stable, wire the delegate.
                field.delegate = self
                self.editFieldReady = true
            } else {
                // Focus failed — fall back to normal breadcrumb view.
                self.endEditing(navigate: false)
            }
        }
    }

    private func endEditing(navigate: Bool) {
        guard isEditing else { return }
        isEditing = false
        editFieldReady = false

        if navigate, let rawPath = editField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty {
            let expanded = NSString(string: rawPath).expandingTildeInPath
            let targetURL = URL(fileURLWithPath: expanded).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                url = targetURL
                onSegmentClicked?(targetURL)
            } else {
                NSSound.beep()
                shakeAnimation()
                showTemporaryError("Invalid path or folder not accessible")
            }
        }

        editField?.removeFromSuperview()
        editField = nil
        scrollView.isHidden = false
        accessoryStack.isHidden = false
        updateAppearance()
        rebuildSegments()
    }

    private func updateAppearance() {
        if isEditing {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderWidth = 1.5
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
        } else {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.1).cgColor
            layer?.borderWidth = 0
            layer?.borderColor = nil
        }
    }

    // MARK: - Error Feedback

    private func shakeAnimation() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = 0.4
        animation.values = [-6, 6, -4, 4, -2, 2, 0]
        layer?.add(animation, forKey: "shake")
    }

    private func showTemporaryError(_ message: String) {
        guard let superview = self.superview else { return }

        let errorLabel = NSTextField(labelWithString: message)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.alphaValue = 0
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        superview.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            errorLabel.topAnchor.constraint(equalTo: bottomAnchor, constant: 2),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        ])

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            errorLabel.animator().alphaValue = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                errorLabel.animator().alphaValue = 0
            }, completionHandler: {
                errorLabel.removeFromSuperview()
            })
        }
    }

    // MARK: - Mouse Events

    override func menu(for event: NSEvent) -> NSMenu? {
        guard url.isFileURL else { return nil }
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: "Copy Path", action: #selector(copyPath), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let editItem = NSMenuItem(title: "Edit Path", action: #selector(editButtonTapped), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)

        return menu
    }

    @objc private func copyPath() {
        guard url.isFileURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    // MARK: - Helpers

    private func displayTitle(for url: URL) -> String {
        if url.path == "/" {
            return "/"
        }
        if url.path == FileManager.default.homeDirectoryForCurrentUser.path {
            return "Home"
        }
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    private func completions(for partialPath: String) -> [String] {
        let expanded = NSString(string: partialPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        let parent: URL
        let prefix: String
        if expanded.hasSuffix("/") {
            parent = url
            prefix = ""
        } else {
            parent = url.deletingLastPathComponent()
            prefix = url.lastPathComponent
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .filter { candidate in
                candidate.lastPathComponent.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { candidate in
                let path = candidate.path
                if (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    return "\(path)/"
                }
                return path
            }
    }

    override func layout() {
        super.layout()
        if !isEditing {
            resizeDocumentView()
        }
    }
}

// MARK: - NSTextFieldDelegate

extension BreadcrumbBar: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            endEditing(navigate: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing(navigate: false)
            return true
        }
        return false
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        guard let field = control as? NSTextField else { return words }
        return completions(for: field.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditing, editFieldReady else { return }
        // Only navigate if the user pressed Return. Focus-loss (clicking
        // away, Tab, window switching) should cancel editing without
        // navigating to the partially typed path.
        let movement = (obj.userInfo?["NSTextMovement"] as? Int)
            ?? NSTextMovement.other.rawValue
        let didPressReturn = movement == NSTextMovement.return.rawValue
        endEditing(navigate: didPressReturn)
    }
}

// MARK: - Segment Button with Hover

/// Breadcrumb segment button that highlights on hover to indicate clickability.
private class SegmentButton: NSButton {
    private var hoverArea: NSTrackingArea?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            var ancestor: NSView? = superview
            while let view = ancestor {
                if let bar = view as? BreadcrumbBar {
                    bar.startEditing()
                    return
                }
                ancestor = view.superview
            }
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverArea { removeTrackingArea(existing) }
        hoverArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(hoverArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}

/// Stack view that detects clicks on empty space (not on any segment button)
/// and starts editing the breadcrumb bar.
private class BreadcrumbStackView: NSStackView {
    weak var breadcrumbBar: BreadcrumbBar?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for subview in arrangedSubviews {
            if subview.frame.contains(point) {
                super.mouseDown(with: event)
                return
            }
        }
        // Click was on empty space — start editing
        breadcrumbBar?.startEditing()
    }
}

private enum AssociatedKeys {
    nonisolated(unsafe) static var urlKey: UInt8 = 0
}
