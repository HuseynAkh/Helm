#if os(macOS)
import AppKit
import HelmAgent
import HelmCore

/// The AI search's kind row: Any, Photo, Video, Document, Folder, Code, Audio and Archive, one chosen at a time, as
/// Finder's search scope bar offers its places. The window shows it under the header, and under the tabs when there
/// are several, only while the search field's spark is on; the choice is the window's.
///
/// A click chooses and leaves the caret where it was, so an empty search stays open. Tab in the search field brings
/// the keys here: Left and Right then choose the one before or after, and Tab, Shift-Tab or Escape give the keys back
/// to the field. VoiceOver reads a radio group named "File type", each choice a radio button with its word.
@MainActor final class SearchKindBar: NSView {
    /// The choices in order: nil for Any, then `AISearchKind.searchChoices`.
    static let choices: [AISearchKind?] = [nil] + AISearchKind.searchChoices.map { Optional($0) }
    static let height: CGFloat = 32
    /// The row's height while it is shown, and zero while it isn't.
    private(set) lazy var heightConstraint: NSLayoutConstraint = heightAnchor.constraint(equalToConstant: 0)
    private let row = NSStackView()
    private(set) var chips: [SearchKindChip] = []
    /// The choice on show: nil for Any.
    private(set) var kind: AISearchKind?
    /// A choice was made, by a click, an arrow key or VoiceOver. Choosing the one on show again says nothing.
    var onChoose: ((AISearchKind?) -> Void)?
    /// Tab, Shift-Tab or Escape while the row has the keys: they go back to the search field.
    var onLeave: (() -> Void)?
    /// The keys left the row, for the search field or anywhere else. Called on the next turn of the run loop, once
    /// the new holder has them.
    var onResign: (() -> Void)?

    /// Room at the row's ends, between two choices, and either side of a choice's word: as much as there's room for,
    /// down to the least, so every choice shows whole in the narrowest window.
    private static let edge: CGFloat = 8
    private static let gap: CGFloat = 2
    private static let mostPadding: CGFloat = 9
    private static let leastPadding: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        // A row too wide for the window is cut at its edge rather than making the window wider.
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(AgentText.searchKindRow)
        chips = Self.choices.map { SearchKindChip(choice: $0, target: self, action: #selector(choose(_:))) }
        chips.first?.isChosen = true
        row.orientation = .horizontal
        row.spacing = Self.gap
        row.translatesAutoresizingMaskIntoConstraints = false
        for chip in chips { row.addArrangedSubview(chip) }
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(separator)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.edge),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }

    /// Shows the row at its height, or hides it with none.
    func setShown(_ shown: Bool) {
        isHidden = !shown
        heightConstraint.constant = shown ? Self.height : 0
    }

    /// Shows `kind` as the choice, without saying it was made.
    func show(_ kind: AISearchKind?) {
        guard kind != self.kind else { return }
        self.kind = kind
        for chip in chips { chip.isChosen = chip.choice == kind }
        noteFocusRingMaskChanged()
    }

    @objc private func choose(_ sender: SearchKindChip) { pick(sender.choice) }
    private func pick(_ choice: AISearchKind?) {
        guard choice != kind else { return }
        show(choice)
        onChoose?(choice)
    }

    // MARK: Width

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitChips(to: newSize.width)
    }
    /// Each choice's padding, the same for all: the most there's room for, between the least and the most.
    private func fitChips(to width: CGFloat) {
        guard width > 0, !chips.isEmpty else { return }
        let words = chips.reduce(0) { $0 + $1.wordWidth }
        let room = width - 2 * Self.edge - Self.gap * CGFloat(chips.count - 1) - words
        let padding = min(Self.mostPadding, max(Self.leastPadding, floor(room / CGFloat(2 * chips.count))))
        for chip in chips { chip.padding = padding }
    }

    // MARK: Keys

    /// The keyboard brings the keys here; a click never does, so it leaves the caret in the search field.
    override var acceptsFirstResponder: Bool {
        guard !isHiddenOrHasHiddenAncestor else { return false }
        guard let event = NSApp.currentEvent else { return true }
        return ![.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
    }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }
    /// True while the row has the keys.
    var hasKeys: Bool { window?.firstResponder === self }
    override func becomeFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return true
    }
    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.onResign?() }
        return true
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: step(-1)
        case 124: step(1)
        case 48, 53: onLeave?()
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { onLeave?() }
    /// The choice before or after the one on show. The ends don't wrap round.
    private func step(_ offset: Int) {
        guard let index = Self.choices.firstIndex(where: { $0 == kind }) else { return }
        let next = min(max(0, index + offset), Self.choices.count - 1)
        guard next != index else { NSSound.beep(); return }
        pick(Self.choices[next])
    }

    /// The focus ring goes round the choice on show.
    override var focusRingMaskBounds: NSRect { chosenFrame }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: chosenFrame, xRadius: SearchKindChip.cornerRadius, yRadius: SearchKindChip.cornerRadius).fill()
    }
    private var chosenFrame: NSRect {
        guard let chip = chips.first(where: { $0.isChosen }) else { return .zero }
        return chip.convert(chip.bounds, to: self)
    }

    // MARK: Test support

    /// The words of the choices, in order.
    var wordsForTesting: [String] { chips.map(\.word) }
    /// A click on the choice with these words. False when there's none.
    @discardableResult func clickForTesting(_ word: String) -> Bool {
        guard let chip = chips.first(where: { $0.word == word }) else { return false }
        chip.performClick(nil)
        return true
    }
    /// A key while the row has the keys, by name: left, right, tab or escape. False for any other name.
    @discardableResult func keyForTesting(_ name: String) -> Bool {
        let codes: [String: (UInt16, String)] = ["left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "tab": (48, "\t"),
                                                 "escape": (53, "\u{1b}")]
        guard let (code, characters) = codes[name],
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return false }
        keyDown(with: event)
        return true
    }
}

/// One choice in the kind row: its word, on the header's lit fill while chosen, with the header buttons' fills
/// under the pointer and while pressed. It never takes the keys; the row does.
@MainActor final class SearchKindChip: FlatButton {
    /// The kind it chooses: nil for Any.
    let choice: AISearchKind?
    let word: String
    static let font = NSFont.systemFont(ofSize: 12)
    static let chipHeight: CGFloat = 24
    /// The search field's spark sits on a lit fill with these corners, at this height.
    static let cornerRadius: CGFloat = 6
    /// The word's own width.
    let wordWidth: CGFloat
    private var widthConstraint: NSLayoutConstraint?
    /// Room either side of the word. The row sets it to fit its width.
    var padding: CGFloat = 9 {
        didSet { if padding != oldValue { widthConstraint?.constant = wordWidth + 2 * padding } }
    }
    var isChosen: Bool {
        get { isOn }
        set {
            isOn = newValue
            setAccessibilityValue(NSNumber(value: newValue))
            needsDisplay = true
        }
    }

    init(choice: AISearchKind?, target: AnyObject?, action: Selector?) {
        self.choice = choice
        word = choice.map(AgentText.searchKind) ?? AgentText.searchKindAny
        wordWidth = ceil(NSAttributedString(string: word, attributes: [.font: Self.font]).size().width)
        super.init(symbol: "circle", label: word, pointSize: 12, minimumWidth: 0, height: Self.chipHeight, target: target,
                   action: action)
        image = nil
        imagePosition = .noImage
        toolTip = nil
        layer?.cornerRadius = Self.cornerRadius
        refusesFirstResponder = true
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(word)
        setAccessibilityValue(NSNumber(value: false))
        let width = widthAnchor.constraint(equalToConstant: wordWidth + 2 * padding)
        width.isActive = true
        widthConstraint = width
    }
    required init?(coder: NSCoder) { nil }

    /// The word, centred: in the label colour while chosen, a step quieter otherwise.
    override func draw(_ dirtyRect: NSRect) {
        let words = NSAttributedString(string: word, attributes: [
            .font: Self.font, .foregroundColor: isChosen ? NSColor.labelColor : NSColor.secondaryLabelColor])
        let size = words.size()
        let rect = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                          width: ceil(size.width), height: ceil(size.height))
        words.draw(in: rect)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: wordWidth + 2 * padding, height: Self.chipHeight) }
}
#endif
