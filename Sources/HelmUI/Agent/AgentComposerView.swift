#if os(macOS)
import AppKit
import Combine
import HelmAgent
import HelmCore

/// The panel's composer, pinned to its bottom: a plain text view of one to five lines, a small menu naming the model,
/// and Send, which becomes Stop while a request runs. Return sends; Shift-Return or Option-Return starts a new line;
/// Command-Return presses Apply on the card that waits; Escape stops a request or gives the keys back to the files.
@MainActor final class AgentComposerView: NSView, NSTextViewDelegate {
    let textView = AgentComposerTextView()
    private let scrollView = NSScrollView()
    private let box = NSView()
    private let modelButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let sendButton = NSButton(title: AgentText.send, target: nil, action: nil)
    private var boxHeight: NSLayoutConstraint?
    private var watch: AnyCancellable?
    private weak var model: AgentPanelModel?
    private var shownModel: String?

    static let lineHeight: CGFloat = 17, maximumLines: CGFloat = 5, textInset: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { nil }

    /// Hooks the composer to a panel's model: what is typed goes to it, and text it puts here shows.
    func attach(_ model: AgentPanelModel, dropTarget: AgentPanelHost) {
        self.model = model
        textView.dropTarget = dropTarget
        textView.string = model.composerText
        model.composerSet = { [weak self] text, caret in self?.show(text, caret: caret) }
        textView.onReturn = { [weak model] in model?.key("return") }
        textView.onEscape = { [weak model] in model?.key("escape") }
        textView.onCommandReturn = { [weak model] in model?.commandReturn() }
        watch = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
        fitHeight()
    }

    /// The caret goes to the end of what is typed.
    func focus() {
        guard let window else { return }
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    // MARK: Building

    private func build() {
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        AgentComposerTextView.makePlain(textView)
        textView.delegate = self
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 2, height: Self.textInset)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityPlaceholderValue(AgentText.composerPlaceholder)
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // A fixed inset of its own: the composer never takes one from the title bar.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        modelButton.controlSize = .small
        modelButton.font = .systemFont(ofSize: 11)
        modelButton.isBordered = false
        (modelButton.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .small
        sendButton.target = self
        sendButton.action = #selector(pressSend)

        for view in [box, modelButton, sendButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scrollView)
        let height = box.heightAnchor.constraint(equalToConstant: Self.lineHeight + Self.textInset * 2 + 2)
        boxHeight = height
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            height,
            scrollView.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            scrollView.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
            modelButton.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 6),
            modelButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            modelButton.trailingAnchor.constraint(lessThanOrEqualTo: sendButton.leadingAnchor, constant: -8),
            modelButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            sendButton.centerYAnchor.constraint(equalTo: modelButton.centerYAnchor),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        ])
        // A long model name gives way before Send does, and never widens the panel.
        modelButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintBox()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paintBox()
    }
    private func paintBox() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            box.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            box.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
    }

    // MARK: State

    private func refresh() {
        guard let model else { return }
        let running = model.phase == .working
        sendButton.title = running ? AgentText.stop : AgentText.send
        sendButton.isEnabled = running || model.canSend
        let name = model.provider.model.isEmpty ? model.provider.name : model.provider.model
        textView.needsDisplay = true
        // The menu is made again only when the model it names changes, so it never changes under the pointer.
        guard name != shownModel else { return }
        shownModel = name
        modelButton.removeAllItems()
        modelButton.addItem(withTitle: name)
        let current = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        current.state = .on
        current.isEnabled = false
        modelButton.menu?.addItem(current)
        modelButton.menu?.addItem(.separator())
        let settings = NSMenuItem(title: AgentText.modelMenuSettings, action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        modelButton.menu?.addItem(settings)
    }

    @objc private func pressSend() {
        guard let model else { return }
        if model.phase == .working { model.press(AgentText.stop) } else { model.send() }
    }

    @objc private func openSettings() { model?.press(AgentText.modelMenuSettings) }

    private func show(_ text: String, caret: Int) {
        if textView.string != text { textView.string = text }
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(max(0, caret), length), length: 0))
        fitHeight()
        refresh()
    }

    /// One to five lines tall, as the text needs.
    private func fitHeight() {
        guard let container = textView.textContainer, let layout = textView.layoutManager else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        let lines = max(1, min(Self.maximumLines, (used / Self.lineHeight).rounded(.up)))
        boxHeight?.constant = lines * Self.lineHeight + Self.textInset * 2 + 2
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        model?.composerEdited(textView.string, caret: textView.selectedRange().location)
        fitHeight()
        refresh()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        model?.caretMoved(to: textView.selectedRange().location)
    }
}

/// The composer's text view. It takes plain text only, with every automatic change and every detector off, so a
/// typed path stays the path the person typed and nothing is handed to another service. Its keys go to the panel,
/// and a folder dropped on it goes to the panel too, never in as text.
@MainActor final class AgentComposerTextView: NSTextView {
    var onReturn: (() -> Void)?
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    weak var dropTarget: AgentPanelHost?

    /// Turns off everything that would change what is typed, read meaning into it, or offer it to another app.
    static func makePlain(_ textView: NSTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.displaysLinkToolTips = false
        textView.usesFindBar = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.inlinePredictionType = .no
        if #available(macOS 15.0, *) { textView.writingToolsBehavior = .none }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch Int(event.keyCode) {
        case 36, 76: // Return and Enter
            if flags.isEmpty { onReturn?(); return }
            if flags == [.command] { onCommandReturn?(); return }
            if flags == [.shift] || flags == [.option] { insertNewlineIgnoringFieldEditor(nil); return }
        case 53: // Escape
            if flags.isEmpty { onEscape?(); return }
        default:
            break
        }
        super.keyDown(with: event)
    }

    /// Command-Return reaches a text view as a key equivalent first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .keyDown, window?.firstResponder === self, [36, 76].contains(Int(event.keyCode)), flags == [.command] {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// No context menu: nothing that looks a word up, shares it or hands it to a service. The usual editing keys work.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    /// The Services menu never gets the composer's text.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? { nil }

    /// Paste always pastes plain text.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    /// The placeholder, while nothing is typed.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13),
                                                         .foregroundColor: NSColor.placeholderTextColor]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (AgentText.composerPlaceholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    // A folder dropped here is the panel's to add.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropTarget?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropTarget?.draggingUpdated(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) {}
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dropTarget != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { dropTarget?.performDragOperation(sender) ?? false }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {}
}
#endif
