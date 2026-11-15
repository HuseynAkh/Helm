#if os(macOS)
import AppKit
import Combine
import HelmAgent
import HelmCore

/// The panel's composer, pinned to its bottom: a plain text view of one to five lines, the model's name in quiet
/// secondary text, and Send, which becomes Stop while a request or an Apply runs. With more than one model to choose
/// from, the name is a compact menu of every connected provider's models, the current one ticked, then AI Settings…;
/// with one, a press on the name opens Settings › AI. Return sends; Shift-Return or Option-Return starts a new line;
/// Command-Return presses Apply on the card that waits; Escape stops a request or gives the keys back to the files.
@MainActor final class AgentComposerView: NSView, NSTextViewDelegate {
    let textView = AgentComposerTextView()
    private let scrollView = NSScrollView()
    private let box = NSView()
    private let modelButton = NSButton(title: "", target: nil, action: nil)
    private let sendButton = NSButton(title: AgentText.send, target: nil, action: nil)
    private var boxHeight: NSLayoutConstraint?
    private var watch: AnyCancellable?
    private weak var model: AgentPanelModel?
    private var shownModel: String?
    private var shownAsMenu = false

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

        modelButton.isBordered = false
        modelButton.setButtonType(.momentaryChange)
        modelButton.lineBreakMode = .byTruncatingMiddle
        modelButton.toolTip = AgentText.modelMenuSettings
        modelButton.target = self
        modelButton.action = #selector(pressModelName)
        modelButton.imagePosition = .noImage
        modelButton.imageHugsTitle = true
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
        let running = model.showsStop
        sendButton.title = running ? AgentText.stop : AgentText.send
        sendButton.isEnabled = running || model.canSend
        textView.needsDisplay = true
        // The model's id, or the provider's name when it has none, as the disk's and the model's words are: escaped.
        let name = AgentTextEscaper.escape(model.provider.model.isEmpty ? model.provider.name : model.provider.model)
        let asMenu = model.modelMenu.isMenu
        guard name != shownModel || asMenu != shownAsMenu else { return }
        shownModel = name
        shownAsMenu = asMenu
        modelButton.attributedTitle = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        modelButton.setAccessibilityLabel(name)
        if asMenu {
            // A small up-and-down chevron after the name, as a pop-up button shows, says it's a menu.
            modelButton.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
            modelButton.imagePosition = .imageTrailing
            modelButton.contentTintColor = .secondaryLabelColor
            modelButton.toolTip = AgentText.modelLabel
            modelButton.setAccessibilityRole(.popUpButton)
            modelButton.setAccessibilityHelp(AgentText.modelLabel)
        } else {
            modelButton.image = nil
            modelButton.imagePosition = .noImage
            modelButton.toolTip = AgentText.modelMenuSettings
            modelButton.setAccessibilityRole(.button)
            modelButton.setAccessibilityHelp(AgentText.modelMenuSettings)
        }
    }

    /// The name under the composer: the menu when there's a choice to make, Settings › AI otherwise.
    @objc private func pressModelName() {
        guard let menu = makeModelMenu() else { openSettings(); return }
        let ticked = menu.items.first { $0.state == .on }
        let below = NSPoint(x: 0, y: modelButton.isFlipped ? modelButton.bounds.maxY : modelButton.bounds.minY)
        menu.popUp(positioning: ticked, at: below, in: modelButton)
    }

    /// The menu under the composer: each connected provider's name over its models, the one in use ticked, then
    /// AI Settings…. Nil when there's no choice to make. Model names are drawn as the disk's and the model's words
    /// are: escaped, and only ever as plain titles.
    func makeModelMenu() -> NSMenu? {
        guard let model, model.modelMenu.isMenu else { return nil }
        let offered = model.modelMenu
        let menu = NSMenu()
        menu.autoenablesItems = false
        for group in offered.providers {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: AgentTextEscaper.escape(group.name)))
            for id in group.models {
                let choice = AgentModelMenu.Choice(provider: group.provider, model: id)
                let item = NSMenuItem(title: AgentTextEscaper.escape(id), action: #selector(chooseModelItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ModelChoiceBox(choice)
                item.state = offered.current == choice ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: AgentText.modelMenuSettings, action: #selector(openSettingsItem(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    @objc private func chooseModelItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ModelChoiceBox else { return }
        model?.chooseModel(box.choice)
    }
    @objc private func openSettingsItem(_ sender: NSMenuItem) { openSettings() }

    /// Carries a menu row's choice, since a menu item holds an object.
    private final class ModelChoiceBox: NSObject {
        let choice: AgentModelMenu.Choice
        init(_ choice: AgentModelMenu.Choice) { self.choice = choice }
    }

    @objc private func pressSend() {
        guard let model else { return }
        if model.showsStop { model.press(AgentText.stop) } else { model.send() }
    }

    /// For tests: the name under the composer, whether it shows as a menu, and a press on it.
    var modelNameForTesting: String { modelButton.attributedTitle.string }
    var modelNameIsMenuForTesting: Bool { shownAsMenu && modelButton.image != nil }
    var sendTitleForTesting: (title: String, enabled: Bool) { (sendButton.title, sendButton.isEnabled) }
    func pressModelNameForTesting() { modelButton.performClick(nil) }
    /// Picks a row of the menu under the composer by its title, as a click on it would: the first such row, or the
    /// first under the section named `section`. False when there's no such row.
    @discardableResult func pickModelMenuRowForTesting(_ title: String, under section: String? = nil) -> Bool {
        guard let menu = makeModelMenu() else { return false }
        var inSection = section == nil
        for item in menu.items {
            if item.isSectionHeader { inSection = section == nil || item.title == section; continue }
            guard inSection, item.title == title, let action = item.action else { continue }
            return NSApp.sendAction(action, to: item.target, from: item)
        }
        return false
    }

    private func openSettings() { model?.press(AgentText.modelMenuSettings) }

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
            // A held Command-Return presses Apply once, never again on the card that follows.
            if flags == [.command] {
                if !event.isARepeat { onCommandReturn?() }
                return
            }
            if flags == [.shift] || flags == [.option] { insertNewlineIgnoringFieldEditor(nil); return }
        case 53: // Escape
            if flags.isEmpty { onEscape?(); return }
        default:
            break
        }
        super.keyDown(with: event)
    }

    /// Command-Return reaches a text view as a key equivalent first. A repeat of a held key is taken and does nothing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .keyDown, window?.firstResponder === self, [36, 76].contains(Int(event.keyCode)), flags == [.command] {
            if !event.isARepeat { onCommandReturn?() }
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
