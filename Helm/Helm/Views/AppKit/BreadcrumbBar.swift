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

    private var editField: NSTextField?
    private var isEditing = false

    // Predictive completion
    private var completionController: PathCompletionWindowController?
    private let completionService = PathCompletionService()
    private var completionTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var ghostTextField: NSTextField?
    private var ghostLeadingConstraint: NSLayoutConstraint?
    private var currentGhostSuffix: String = ""
    private var suppressTextDidChange = false
    private var completionRequestID: Int = 0

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

        // ---- Layout ----
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scrollView.centerYAnchor.constraint(equalTo: centerYAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 26),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])

        rebuildSegments()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 34)
    }

    // MARK: - Segments

    private func rebuildSegments() {
        segmentsStack.arrangedSubviews.forEach { view in
            segmentsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if url.isHelmRecentsLocation {
            segmentsStack.addArrangedSubview(makeVirtualLabel("Recent"))
            resizeDocumentView()
            return
        }

        guard url.isFileURL else {
            segmentsStack.addArrangedSubview(makeVirtualLabel(url.absoluteString))
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
        let button = SegmentButton(title: title, target: self, action: #selector(segmentClicked(_:)))
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

    private func scrollToEnd() {
        guard let documentView = scrollView.documentView else { return }
        let maxX = max(0, documentView.bounds.width - scrollView.contentView.bounds.width)
        scrollView.contentView.scroll(to: NSPoint(x: maxX, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        startEditing()
    }

    // MARK: - Edit Mode

    /// Whether the delegate is fully wired and focus is stable.
    /// Prevents premature `controlTextDidEndEditing` during setup.
    private var editFieldReady = false

    func startEditing() {
        guard url.isFileURL else { return }
        guard !isEditing else { return }
        isEditing = true
        editFieldReady = false

        scrollView.isHidden = true

        let pathWithSlash = url.path.hasSuffix("/") ? url.path : url.path + "/"
        let field = NSTextField(string: pathWithSlash)
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
                // Position cursor at end (not select all) so user can
                // immediately see completions for the current directory.
                if let editor = field.currentEditor() {
                    let len = (editor.string as NSString).length
                    editor.selectedRange = NSRange(location: len, length: 0)
                }
                // Now that focus is stable, wire the delegate.
                field.delegate = self
                self.editFieldReady = true
                // Show directory contents immediately (like terminal).
                // Use the captured pathWithSlash — not editFieldText — because
                // the field editor may not have synced its string yet.
                self.showCompletionsForPath(pathWithSlash)
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
        teardownCompletion()

        let rawPath = editFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        if navigate {
            if rawPath.isEmpty {
                // Empty field + Enter → go home
                let home = FileManager.default.homeDirectoryForCurrentUser
                url = home
                onSegmentClicked?(home)
            } else {
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
        }

        editField?.removeFromSuperview()
        editField = nil
        scrollView.isHidden = false
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

    // MARK: - Edit Field Text Manipulation

    /// Update the edit field's text without disrupting the editing session.
    ///
    /// `NSControl.setStringValue:` calls `abortEditing()` when a field editor
    /// is active, which terminates the editing session and removes the field
    /// editor.  After that, `currentEditor()` returns nil, keyboard events
    /// no longer route through `doCommandBy:`, and the completion system
    /// breaks.  This helper sidesteps that by writing directly to the field
    /// editor's text storage.
    ///
    /// The suppress flag stays `true` until the *next* run-loop iteration so
    /// that both synchronous and asynchronous `controlTextDidChange`
    /// notifications triggered by the text-storage mutation are suppressed.
    private func setEditFieldText(_ newText: String) {
        guard let field = editField else { return }
        suppressTextDidChange = true
        if let editor = field.currentEditor() as? NSTextView,
           let textStorage = editor.textStorage {
            let range = NSRange(location: 0, length: textStorage.length)
            textStorage.replaceCharacters(in: range, with: newText)
            editor.selectedRange = NSRange(location: (newText as NSString).length, length: 0)
        } else {
            // No field editor — fall back to stringValue (calls abortEditing).
            field.stringValue = newText
        }
        // Reset suppress on the *next* run-loop pass.  This ensures that any
        // deferred controlTextDidChange fired by the text-storage change is
        // still suppressed.
        DispatchQueue.main.async { [weak self] in
            self?.suppressTextDidChange = false
        }
        // Verify the field editor survived the text change.  If it was
        // removed (e.g. abortEditing was called internally), re-establish
        // focus so keyboard events keep routing through doCommandBy.
        ensureFieldEditorActive()
    }

    /// Re-establish the field editor on the edit field if it was lost.
    private func ensureFieldEditorActive() {
        guard let field = editField, isEditing else { return }
        if field.currentEditor() == nil {
            if window?.makeFirstResponder(field) == true {
                if let editor = field.currentEditor() {
                    let len = (editor.string as NSString).length
                    editor.selectedRange = NSRange(location: len, length: 0)
                }
            }
        }
    }

    /// Read the current text from the field editor (authoritative while editing)
    /// with a fallback to the cell's stringValue.
    private var editFieldText: String {
        guard let field = editField else { return "" }
        if let editor = field.currentEditor() {
            return editor.string
        }
        return field.stringValue
    }

    // MARK: - Path Completion

    private func requestCompletions(for text: String) {
        completionTask?.cancel()

        guard !text.isEmpty else {
            completionController?.hide()
            clearGhostText()
            return
        }

        completionRequestID += 1
        let requestID = completionRequestID

        completionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.completionService.completions(for: text)

            // Use request ID instead of string comparison — the string
            // guard was fragile and caused multi-level drilling to silently
            // fail when field.stringValue diverged from the captured text.
            guard !Task.isCancelled,
                  self.isEditing,
                  self.editField != nil,
                  requestID == self.completionRequestID else { return }

            self.displayCompletions(result)
        }
    }

    /// Route to the right completion strategy based on whether the user has
    /// typed a prefix after the last "/".
    ///
    /// - Path ends with "/" → synchronous directory listing (no async hops).
    /// - Path has a partial name  → async filtered completion via the actor.
    private func showCompletionsForPath(_ text: String) {
        if text.hasSuffix("/") {
            showAllDirectoryContents(for: text)
        } else {
            requestCompletions(for: text)
        }
    }

    /// Directly enumerate and display all items in a directory.
    ///
    /// Used when the path ends with "/" — meaning the user wants to browse
    /// the full directory contents rather than filter by a typed prefix.
    /// This runs synchronously on the main thread, bypassing the async
    /// completion service, debouncing, and Task cancellation machinery
    /// that caused multi-level drilling to silently fail.
    private func showAllDirectoryContents(for directoryPath: String) {
        // Cancel any in-flight async work so it can't overwrite our results.
        completionTask?.cancel()
        completionTask = nil
        debounceTask?.cancel()
        debounceTask = nil

        let expanded = NSString(string: directoryPath).expandingTildeInPath
        let dirURL = URL(fileURLWithPath: expanded)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            completionController?.hide()
            clearGhostText()
            return
        }

        let items: [PathCompletionItem] = contents
            .compactMap { fileURL -> PathCompletionItem? in
                let isDir = (try? fileURL.resourceValues(
                    forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
                icon.size = NSSize(width: 16, height: 16)
                return PathCompletionItem(
                    name: fileURL.lastPathComponent,
                    fullPath: isDir ? fileURL.path + "/" : fileURL.path,
                    isDirectory: isDir,
                    icon: icon
                )
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

        var finalItems: [PathCompletionItem] = []

        // Prepend ".." (parent directory) unless we're already at root.
        if expanded != "/" {
            let parentURL = dirURL.deletingLastPathComponent()
            let parentIcon = NSWorkspace.shared.icon(forFile: parentURL.path)
            parentIcon.size = NSSize(width: 16, height: 16)
            finalItems.append(PathCompletionItem(
                name: "..",
                fullPath: parentURL.path + "/",
                isDirectory: true,
                icon: parentIcon
            ))
        }

        finalItems.append(contentsOf: items.prefix(50))

        if finalItems.isEmpty {
            completionController?.hide()
            clearGhostText()
            return
        }

        ensureCompletionController()
        completionController?.show(below: self, items: finalItems)
        // Don't show ghost text when ".." is the selected item — it
        // doesn't extend the current path so ghost text makes no sense.
        // Ghost text will naturally clear because ".." fullPath doesn't
        // have the typed path as a prefix.
        updateGhostTextFromSelection()
    }

    /// Lazily create the completion controller with the shared onAccept handler.
    private func ensureCompletionController() {
        guard completionController == nil else { return }
        completionController = PathCompletionWindowController()
        completionController?.onAccept = { [weak self] item in
            guard let self else { return }
            self.setEditFieldText(item.fullPath)
            self.clearGhostText()
            if item.isDirectory {
                self.showCompletionsForPath(item.fullPath)
            } else {
                self.completionController?.hide()
            }
        }
    }

    private func displayCompletions(_ result: PathCompletionService.CompletionResult) {
        guard editField != nil else { return }

        if result.items.isEmpty {
            completionController?.hide()
            clearGhostText()
            return
        }

        ensureCompletionController()
        completionController?.show(below: self, items: result.items)
        updateGhostTextFromSelection()
    }

    private func teardownCompletion() {
        debounceTask?.cancel()
        debounceTask = nil
        completionTask?.cancel()
        completionTask = nil
        completionController?.teardown()
        completionController = nil
        clearGhostText()
    }

    // MARK: - Ghost Text

    private func updateGhostText(with suffix: String) {
        guard let field = editField, !suffix.isEmpty else {
            clearGhostText()
            return
        }

        // Only show ghost text when cursor is at the end
        if let editor = field.currentEditor() {
            let selectedRange = editor.selectedRange
            let textLength = (editor.string as NSString).length
            if selectedRange.location + selectedRange.length < textLength {
                clearGhostText()
                return
            }
        }

        currentGhostSuffix = suffix

        let ghost: NSTextField
        if let existing = ghostTextField {
            ghost = existing
        } else {
            ghost = NSTextField(labelWithString: "")
            ghost.font = field.font
            ghost.textColor = .tertiaryLabelColor
            ghost.drawsBackground = false
            ghost.isBordered = false
            ghost.isEditable = false
            ghost.isSelectable = false
            ghost.translatesAutoresizingMaskIntoConstraints = false
            ghost.lineBreakMode = .byClipping
            addSubview(ghost)

            let leading = ghost.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 0)
            ghostLeadingConstraint = leading
            NSLayoutConstraint.activate([
                leading,
                ghost.centerYAnchor.constraint(equalTo: field.centerYAnchor),
                ghost.trailingAnchor.constraint(lessThanOrEqualTo: field.trailingAnchor)
            ])
            ghostTextField = ghost
        }

        ghost.stringValue = suffix

        // Calculate typed text width to position ghost after typed text
        let attrs: [NSAttributedString.Key: Any] = [.font: field.font ?? NSFont.systemFont(ofSize: 13)]
        let typedWidth = (editFieldText as NSString).size(withAttributes: attrs).width
        let fieldInset: CGFloat = field.cell?.titleRect(forBounds: field.bounds).origin.x ?? 2
        ghostLeadingConstraint?.constant = fieldInset + typedWidth
    }

    private func clearGhostText() {
        ghostTextField?.removeFromSuperview()
        ghostTextField = nil
        ghostLeadingConstraint = nil
        currentGhostSuffix = ""
    }

    private func acceptGhostCompletion() {
        guard !currentGhostSuffix.isEmpty else { return }
        let newText = editFieldText + currentGhostSuffix
        setEditFieldText(newText)
        clearGhostText()
        // Use captured newText — not editFieldText — because the field editor
        // may not have synced yet after setEditFieldText.
        showCompletionsForPath(newText)
    }

    private func updateGhostTextFromSelection() {
        guard editField != nil,
              let item = completionController?.selectedItem() else {
            clearGhostText()
            return
        }
        let typed = editFieldText
        let fullPath = item.fullPath
        if fullPath.lowercased().hasPrefix(typed.lowercased()), fullPath.count > typed.count {
            let suffix = String(fullPath.dropFirst(typed.count))
            updateGhostText(with: suffix)
        } else {
            clearGhostText()
        }
    }

    override func layout() {
        super.layout()
        if !isEditing {
            resizeDocumentView()
            // Keep the rightmost segments (current directory) visible
            // when the window is resized and the path is long.
            scrollToEnd()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // When the toolbar temporarily removes and re-adds our view
        // during relayout (e.g. window resize), re-establish the
        // field editor so editing survives the transition.
        if isEditing, editFieldReady, window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEditing else { return }
                self.ensureFieldEditorActive()
            }
        }
    }
}

// MARK: - NSTextFieldDelegate

extension BreadcrumbBar: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // When the user has typed a prefix (field text does NOT end
            // with "/"), accept the selected dropdown item — this is the
            // autocomplete-confirm gesture.  When the text ends with "/"
            // we're in browse mode (e.g. just drilled into a folder and
            // ".." is auto-selected), so Enter navigates to the path
            // already in the field.
            let currentText = editFieldText
            if !currentText.hasSuffix("/"),
               let controller = completionController, controller.isVisible,
               let item = controller.selectedItem() {
                setEditFieldText(item.fullPath)
                clearGhostText()
                controller.hide()
            } else {
                completionController?.hide()
                clearGhostText()
            }
            endEditing(navigate: true)
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if completionController?.isVisible == true {
                // First Escape: dismiss dropdown, stay in edit mode
                completionController?.hide()
                clearGhostText()
            } else {
                // Second Escape (or no dropdown): exit edit mode
                endEditing(navigate: false)
            }
            return true
        }

        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            if !currentGhostSuffix.isEmpty {
                // Accept ghost text inline completion
                acceptGhostCompletion()
            } else if completionController?.isVisible == true,
                      let item = completionController?.selectedItem() {
                // Accept the selected dropdown item (terminal-like drill)
                let path = item.fullPath
                setEditFieldText(path)
                clearGhostText()
                if item.isDirectory {
                    // Use captured path — not editFieldText — to avoid
                    // reading stale text from the field editor.
                    showCompletionsForPath(path)
                } else {
                    completionController?.hide()
                }
            } else {
                // Nothing visible — show completions for current path.
                // Read text before requesting so there's no ambiguity.
                let text = editFieldText
                if !text.isEmpty {
                    showCompletionsForPath(text)
                }
            }
            // Always consume Tab so focus never leaves the address bar.
            return true
        }

        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            // Consume Shift+Tab as well — never leave the address bar.
            return true
        }

        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            if completionController?.isVisible == true {
                completionController?.moveSelectionDown()
                updateGhostTextFromSelection()
                return true
            }
            return false
        }

        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            if completionController?.isVisible == true {
                completionController?.moveSelectionUp()
                updateGhostTextFromSelection()
                return true
            }
            return false
        }

        if commandSelector == #selector(NSResponder.moveRight(_:)) {
            let range = textView.selectedRange
            let textLength = (textView.string as NSString).length
            if range.location == textLength && range.length == 0 && !currentGhostSuffix.isEmpty {
                acceptGhostCompletion()
                return true
            }
            return false
        }

        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard editFieldReady, !suppressTextDidChange, editField != nil else { return }

        clearGhostText()
        debounceTask?.cancel()
        let currentText = editFieldText

        // Typing "/" means the user wants to see directory contents immediately.
        // Use the synchronous path — no async hops to get cancelled.
        if currentText.hasSuffix("/") {
            showAllDirectoryContents(for: currentText)
            return
        }

        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: AppSettings.completionDebounceNanoseconds)
            } catch { return }

            guard let self, self.editFieldText == currentText else { return }
            self.requestCompletions(for: currentText)
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        // Disabled — using custom completion dropdown instead
        return []
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditing, editFieldReady else { return }

        let movement = (obj.userInfo?["NSTextMovement"] as? Int)
            ?? NSTextMovement.other.rawValue
        let didPressReturn = movement == NSTextMovement.return.rawValue

        // Return → navigate to the path in the field.
        if didPressReturn {
            endEditing(navigate: true)
            return
        }

        // During a programmatic text change the suppress flag is still true.
        if suppressTextDidChange {
            ensureFieldEditorActive()
            return
        }

        // Distinguish "user clicked elsewhere" from "system stole focus"
        // (toolbar relayout on window resize, etc.).  If a mouse-down
        // occurred outside the breadcrumb bar, the user intentionally
        // dismissed editing.  Otherwise, try to keep editing alive.
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown || event.type == .rightMouseDown {
            let locationInBar = convert(event.locationInWindow, from: nil)
            if !bounds.contains(locationInBar) {
                endEditing(navigate: false)
                return
            }
        }

        // If the edit field was removed from the window (toolbar overflow
        // or relayout), the toolbar may re-add it shortly.  Defer the
        // decision — if the view comes back within 150ms, re-establish
        // editing; otherwise clean up.
        if editField?.window == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.isEditing else { return }
                if self.editField?.window != nil {
                    self.ensureFieldEditorActive()
                } else {
                    self.endEditing(navigate: false)
                }
            }
            return
        }

        // System-triggered focus loss (window resize, toolbar relayout,
        // etc.) — restore the field editor so editing continues.
        ensureFieldEditorActive()
    }
}

// MARK: - Segment Button with Hover

/// Breadcrumb segment button that highlights on hover to indicate clickability.
private class SegmentButton: NSButton {
    private var hoverArea: NSTrackingArea?

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
