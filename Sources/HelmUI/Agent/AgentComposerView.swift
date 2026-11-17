#if os(macOS)
import AppKit
import Combine
import HelmAgent
import HelmCore

/// The panel's composer, pinned to its bottom: a rounded field holding a plain text view of one to five lines and
/// Send at its trailing end, as Messages draws its field, then the model's name in quiet secondary text under it,
/// and at the trailing end of that line the Read contents switch, when this run can read inside files.
/// Send shows an arrow in the accent colour and becomes Stop while a request or an Apply runs; its title, which
/// VoiceOver reads and its tooltip shows, says which. With more than one model to choose
/// from, the name is a compact menu of every connected provider's models, the current one ticked, then AI Settings…;
/// with one, a press on the name opens Settings › AI. Return sends; Shift-Return or Option-Return starts a new line;
/// Command-Return presses Apply on the card that waits; Escape stops a request or gives the keys back to the files.
@MainActor final class AgentComposerView: NSView, NSTextViewDelegate {
    let textView = AgentComposerTextView()
    private let scrollView = NSScrollView()
    private let box = NSView()
    private let modelButton = NSButton(title: "", target: nil, action: nil)
    private let sendButton = NSButton(title: AgentText.send, target: nil, action: nil)
    /// The Read contents switch, under the field at its trailing end.
    let contentsToggle = AgentContentsToggle(height: 20, help: AgentText.readContentsHelp)
    private var boxHeight: NSLayoutConstraint?
    private var watch: AnyCancellable?
    private weak var model: AgentPanelModel?
    private var shownModel: String?
    private var shownAsMenu = false
    /// What Send shows now: Stop or Send, and whether it can be pressed.
    private var shownSend: (stop: Bool, enabled: Bool)? = (stop: false, enabled: false)
    /// The text view has the keys.
    private var hasKeys = false
    /// The window becoming key or giving it up, which shows or hides the field's accent edge, as a focus ring.
    private var keyObservers: [NSObjectProtocol] = []

    static let lineHeight: CGFloat = 17, maximumLines: CGFloat = 5, textInset: CGFloat = 6.5
    /// Send's circle, inside the field's trailing end.
    static let sendSize: CGFloat = 22

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
        // Round at the ends for one line, as Messages' field is, and kept as it grows.
        box.layer?.cornerRadius = (Self.lineHeight + Self.textInset * 2 + 2) / 2
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 1
        AgentComposerTextView.makePlain(textView)
        textView.delegate = self
        textView.onFocus = { [weak self] focused in
            self?.hasKeys = focused
            self?.paintBox()
        }
        textView.font = .systemFont(ofSize: AgentPanelStyle.body)
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
        // An arrow in a circle, inside the field. The title stays the word, for VoiceOver, the tooltip and tests.
        sendButton.isBordered = false
        sendButton.setButtonType(.momentaryChange)
        sendButton.imagePosition = .imageOnly
        sendButton.imageScaling = .scaleProportionallyUpOrDown
        // The circle is grey while there's nothing to send; AppKit's own dimming would fade it twice.
        (sendButton.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        sendButton.target = self
        sendButton.action = #selector(pressSend)

        contentsToggle.onToggle = { [weak self] on in self?.model?.chooseReadsContents(on) }
        contentsToggle.isHidden = true
        for view in [box, modelButton, contentsToggle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [scrollView, sendButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(view)
        }
        let height = box.heightAnchor.constraint(equalToConstant: Self.lineHeight + Self.textInset * 2 + 2)
        boxHeight = height
        let margin = AgentPanelStyle.margin
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            height,
            scrollView.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            scrollView.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 7),
            scrollView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -2),
            // At the field's trailing end, level with the last line as the field grows.
            sendButton.widthAnchor.constraint(equalToConstant: Self.sendSize),
            sendButton.heightAnchor.constraint(equalToConstant: Self.sendSize),
            sendButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -5),
            sendButton.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -5),
            modelButton.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 6),
            modelButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin + 6),
            modelButton.trailingAnchor.constraint(lessThanOrEqualTo: contentsToggle.leadingAnchor, constant: -8),
            modelButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            // Level with the model's name, at the field's trailing edge.
            contentsToggle.centerYAnchor.constraint(equalTo: modelButton.centerYAnchor),
            contentsToggle.trailingAnchor.constraint(equalTo: box.trailingAnchor)
        ])
        // A long model name gives way, and never widens the panel.
        modelButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintBox()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers = []
        guard let newWindow else { return }
        keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.paintBox() }
            }
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paintBox()
    }
    /// The field's fill and edge for the window's appearance. The edge takes the accent colour while the field has the
    /// keys in the key window, where a focus ring would show.
    private func paintBox() {
        let focused = hasKeys && window?.isKeyWindow == true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            box.layer?.backgroundColor = AgentPanelStyle.fieldFill.cgColor
            box.layer?.borderColor = (focused ? AgentPanelStyle.fieldFocusBorder : AgentPanelStyle.fieldBorder).cgColor
        }
        paintSend()
    }

    /// Send's circle: the accent colour while it can be pressed, a quiet grey while there's nothing to send. The grey
    /// is the plain appearance's, as the hint's is, and painted again when the appearance changes: the panel's
    /// vibrant grey drew a dark circle on the dark field under a bright arrow. The accent stays the system's, so it
    /// follows a change of accent colour.
    private func paintSend() {
        guard let shown = shownSend else { return }
        let symbol = shown.stop ? "stop.circle.fill" : "arrow.up.circle.fill"
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let circle: NSColor = shown.enabled ? .controlAccentColor
                : AgentPanelStyle.plain(.tertiaryLabelColor, for: effectiveAppearance)
            let configuration = NSImage.SymbolConfiguration(pointSize: Self.sendSize - 2, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, circle]))
            sendButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        }
    }

    // MARK: State

    private func refresh() {
        guard let model else { return }
        let running = model.showsStop
        let title = running ? AgentText.stop : AgentText.send
        if sendButton.title != title { sendButton.title = title }
        // A new title puts itself beside the image; Send draws the image alone.
        sendButton.imagePosition = .imageOnly
        sendButton.toolTip = title
        sendButton.isEnabled = running || model.canSend
        if shownSend?.stop != running || shownSend?.enabled != sendButton.isEnabled {
            shownSend = (running, sendButton.isEnabled)
            paintSend()
        }
        textView.needsDisplay = true
        contentsToggle.isHidden = !model.offersReadContents
        contentsToggle.show(on: model.readsContents, enabled: model.canChooseScope)
        // The model's id, or the provider's name when it has none, as the disk's and the model's words are: escaped.
        let name = AgentTextEscaper.escape(model.provider.model.isEmpty ? model.provider.name : model.provider.model)
        let asMenu = model.modelMenu.isMenu
        guard name != shownModel || asMenu != shownAsMenu else { return }
        shownModel = name
        shownAsMenu = asMenu
        modelButton.attributedTitle = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: AgentPanelStyle.small), .foregroundColor: NSColor.secondaryLabelColor])
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

    /// For tests: the Read contents switch as it is drawn, whether it shows, is on and can be pressed, and a press on it.
    var contentsToggleForTesting: (shown: Bool, on: Bool, enabled: Bool) {
        (!contentsToggle.isHidden, contentsToggle.isOn, contentsToggle.isEnabled)
    }
    func pressContentsToggleForTesting() { contentsToggle.performClick(nil) }

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
    /// The keys came to the composer (true) or left it (false), so its field can show which.
    var onFocus: ((Bool) -> Void)?
    weak var dropTarget: AgentPanelHost?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus?(false) }
        return resigned
    }

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

    /// The placeholder, while nothing is typed, in the placeholder grey of the plain light or dark appearance. The
    /// panel's vibrant appearance has an opaque mid grey for it, which drew dark on the dark field, hardly readable.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let ink = AgentPanelStyle.plain(.placeholderTextColor, for: effectiveAppearance)
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: ink]
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
