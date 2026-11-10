#if os(macOS)
import AppKit
import HelmCore

/// The header bar's button: flat until the pointer is over it, like a libadwaita header button.
/// Every one answers the same way: a faint fill under the pointer, a stronger one while it's held down, and the lit
/// fill while it's on. The fills fade in and out quickly, and change at once with Reduce Motion on.
@MainActor class FlatButton: NSButton {
    private var hovering = false { didSet { if hovering != oldValue { refresh(animated: true) } } }
    /// True while the mouse holds the button down. The cell reports it, so dragging off the button lets go.
    fileprivate(set) var isPressed = false { didSet { if isPressed != oldValue { refresh(animated: !isPressed) } } }
    private var trackingArea: NSTrackingArea?
    /// Lit, for a toggle that's on or a menu that's open.
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            refresh(animated: true)
            if isToggle { setAccessibilityValue(NSNumber(value: isOn)) }
        }
    }
    /// Off for a choice that's already made, such as the view you're in: it doesn't light up or press.
    var showsHover = true { didSet { if showsHover != oldValue { refresh(animated: false) } } }
    /// VoiceOver reads it as a toggle, with its on or off state.
    var isToggle = false {
        didSet {
            setAccessibilityRole(isToggle ? .checkBox : .button)
            setAccessibilitySubrole(isToggle ? .toggle : nil)
            setAccessibilityValue(isToggle ? NSNumber(value: isOn) : nil)
        }
    }
    /// The fill on show now, as a share of the label colour.
    private(set) var fillAlpha: CGFloat = 0
    /// The SF Symbol on show, and its size.
    private(set) var symbolName = ""
    private(set) var symbolPointSize: CGFloat = 15
    /// It's never narrower than this, so an icon alone still gets a comfortable fill.
    let minimumWidth: CGFloat
    /// The width it takes in a row of buttons: its minimum, or more for what it shows.
    var laidOutWidth: CGFloat { max(minimumWidth, intrinsicContentSize.width) }

    override class var cellClass: AnyClass? {
        get { FlatButtonCell.self }
        set {}
    }

    init(symbol: String, label: String, pointSize: CGFloat = 15, toolTip: String? = nil, minimumWidth: CGFloat = 34,
         height: CGFloat = 32, target: AnyObject?, action: Selector?) {
        self.minimumWidth = minimumWidth
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        self.target = target; self.action = action
        setSymbol(symbol, pointSize: pointSize, label: label, toolTip: toolTip)
        contentTintColor = .labelColor
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)
        heightAnchor.constraint(equalToConstant: height).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
    }
    required init?(coder: NSCoder) { nil }

    /// The tooltip can carry the shortcut, such as "Back (⌘[)", while VoiceOver hears just the name.
    func setSymbol(_ symbol: String, pointSize: CGFloat = 15, label: String, toolTip: String? = nil) {
        symbolName = symbol
        symbolPointSize = pointSize
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        self.toolTip = toolTip ?? label
        setAccessibilityLabel(label)
    }
    override var isEnabled: Bool {
        didSet {
            // Back and Forward are set on every render, so only a real change does any work.
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.35
            refresh(animated: false)
        }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    /// AppKit pads a symbol button's frame beyond its layout size by the symbol's own insets, so each button's fill
    /// came out a different height. With none, every fill is exactly the button's size, the same as the view switch's.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
    /// New words can be drawn before the button grows to fit them, so a new size always draws again.
    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { needsDisplay = true }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// A menu or popover can take the pointer away without an exit, so this looks where the pointer is now.
    func updateHover() {
        guard let window else { hovering = false; return }
        hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh(animated: false, force: true) }

    /// The focus ring follows the button's rounded fill rather than its square frame.
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }

    private var targetAlpha: CGFloat {
        guard isEnabled else { return isOn ? 0.14 : 0 }
        if isPressed && showsHover { return 0.20 }
        if isOn { return hovering && showsHover ? 0.17 : 0.14 }
        return hovering && showsHover ? 0.09 : 0
    }

    /// Fades the fill in over 0.12 seconds and out over 0.15. A press shows at once, so it feels immediate.
    /// `force` redraws the same fill, as a new appearance needs.
    func refresh(animated: Bool, force: Bool = false) {
        let alpha = targetAlpha
        guard force || alpha != fillAlpha else { return }
        let rising = alpha > fillAlpha
        fillAlpha = alpha
        guard let layer else { return }
        var color = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
        let from = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color
        CATransaction.commit()
        layer.removeAnimation(forKey: "fill")
        guard animated, window != nil, !HeaderMotion.isReduced else { return }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = from ?? NSColor.clear.cgColor
        fade.toValue = color
        fade.duration = rising ? 0.12 : 0.15
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fill")
    }
}

/// Tells its button when it's held down, so the button can draw the pressed fill itself.
@MainActor private final class FlatButtonCell: NSButtonCell {
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        super.highlight(flag, withFrame: cellFrame, in: controlView)
        (controlView as? FlatButton)?.isPressed = flag
    }
}

/// A flat button that opens a menu, which is built when it opens so it always shows the current state.
/// It stays lit while its menu is open.
@MainActor final class FlatMenuButton: FlatButton {
    var menuProvider: (() -> NSMenu?)? {
        didSet { setAccessibilityRole(menuProvider == nil ? .button : .menuButton) }
    }
    /// Opens something other than a menu, such as a popover, instead.
    var openHandler: ((FlatMenuButton) -> Void)?
    /// The menu hangs from the button's trailing edge, so at the window's edge it opens inwards.
    var alignsMenuToTrailingEdge = false
    /// A small chevron after the title, the same one the search field's scope pill uses.
    var showsDisclosure = false { didSet { if showsDisclosure != oldValue { applyTitle(animated: false) } } }
    /// Narrow windows show only the icon and the chevron. The title stays in the tooltip and for VoiceOver.
    var isCompact = false { didSet { if isCompact != oldValue { applyTitle(animated: false) } } }
    /// The words can be squeezed for a moment rather than make the window wider or the sidebar narrower. Whoever
    /// sets this drops the words as soon as it sees there's no room for them; the icon and chevron always keep theirs.
    var wordsGiveWay = false { didSet { if wordsGiveWay != oldValue { applyTitle(animated: false) } } }
    /// The title's words, whether or not they're on show.
    private(set) var text = ""
    /// How the menu is shown. `NSMenu.popUp` waits until the menu closes, which tests can't do.
    var presentMenu: @MainActor (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        _ = menu.popUp(positioning: nil, at: point, in: view)
    }
    private static let titleFont = NSFont.systemFont(ofSize: 13)
    /// Room either side of the icon and words, so the fill doesn't hug them.
    private static let sidePadding: CGFloat = 8
    /// Between the icon, the words and the chevron.
    private static let gap: CGFloat = 4
    /// chevron.down at 9 points, semibold, in the secondary label colour: the search field's scope pill's glyph.
    private static let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])))

    init(symbol: String, label: String, title: String = "", toolTip: String? = nil, height: CGFloat = 32) {
        super.init(symbol: symbol, label: label, toolTip: toolTip, height: height, target: nil, action: nil)
        // While its width animates to fit new words, the drawing stays centred rather than stretching.
        layerContentsPlacement = .center
        text = title
        applyTitle(animated: false)
        target = self; action = #selector(open)
    }
    required init?(coder: NSCoder) { nil }

    /// Changes the words. Animated, the old words fade into the new ones.
    func setTitle(_ words: String, animated: Bool) {
        guard words != text else { return }
        text = words
        applyTitle(animated: animated)
    }
    /// The words on show: none in a narrow window.
    var shownWords: String { isCompact ? "" : text }

    private func applyTitle(animated: Bool) {
        if animated, !HeaderMotion.isReduced, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            layer.add(fade, forKey: "title")
        }
        if drawsOwnContent {
            // A set width rather than an intrinsic one: the stack view holding the button only took up a new
            // intrinsic width at the window's next display, so new words spilled out of the old width meanwhile.
            let priority = wordsGiveWay ? Self.givingWay : .required
            if let fittingConstraint, fittingConstraint.priority == priority {
                fittingConstraint.constant = fittingWidth
            } else {
                // A constraint can't change between required and not while it's active, so it's made again.
                fittingConstraint?.isActive = false
                let constraint = widthAnchor.constraint(equalToConstant: fittingWidth)
                constraint.priority = priority
                constraint.isActive = true
                fittingConstraint = constraint
            }
            if wordsGiveWay {
                if let compactConstraint {
                    compactConstraint.constant = compactWidth
                } else {
                    let constraint = widthAnchor.constraint(greaterThanOrEqualToConstant: compactWidth)
                    constraint.isActive = true
                    compactConstraint = constraint
                }
            } else {
                compactConstraint?.isActive = false
                compactConstraint = nil
            }
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
    private var fittingConstraint: NSLayoutConstraint?
    private var compactConstraint: NSLayoutConstraint?
    /// Above a stack view's pull towards its content (250), so the words keep their room in the row, and below the
    /// sidebar's hold on its width (260) and the window's on its size (500 and up). So a window made narrower squeezes
    /// the words, for the moment before they're dropped, rather than the sidebar or its own size giving way.
    private static let givingWay = NSLayoutConstraint.Priority(255)
    /// The width the icon, the words and the chevron need, with the padding either side.
    var fittingWidth: CGFloat { width(showing: shownWords) }
    /// The width with the words on show, even while a narrow window has dropped them.
    var widthWithWords: CGFloat { width(showing: text) }
    /// The width with just the icon and the chevron.
    var compactWidth: CGFloat { width(showing: "") }
    private func width(showing words: String) -> CGFloat {
        let wordsWidth = words.isEmpty ? 0 : ceil(Self.attributed(words).size().width)
        let width = Self.contentWidth(icon: drawnIcon?.size.width ?? 0, words: wordsWidth,
                                      chevron: showsDisclosure ? (Self.chevron?.size.width ?? 0) : 0)
        return max(minimumWidth, ceil(width) + Self.sidePadding * 2)
    }
    override var laidOutWidth: CGFloat { drawsOwnContent ? fittingWidth : super.laidOutWidth }

    /// A button with words or a chevron draws them itself, with its icon, on one line. AppKit's button cell kept
    /// laying the words out for the first title it was given, so a longer one wrapped out of sight.
    private var drawsOwnContent: Bool { showsDisclosure || !text.isEmpty }

    /// Where the icon, the words and the chevron go: one centred line, 4 points apart.
    struct Parts: Equatable {
        var icon: NSRect
        var words: NSRect?
        var chevron: NSRect?
    }
    func parts(in bounds: NSRect) -> Parts {
        let iconSize = drawnIcon?.size ?? .zero
        let words = shownWords
        let wordsSize = words.isEmpty ? NSSize.zero : Self.attributed(words).size()
        let wordsWidth = ceil(wordsSize.width)
        let chevronSize = showsDisclosure ? (Self.chevron?.size ?? .zero) : .zero
        var x = ((bounds.width - Self.contentWidth(icon: iconSize.width, words: wordsWidth, chevron: chevronSize.width)) / 2).rounded()
        func place(_ size: NSSize) -> NSRect {
            let rect = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + Self.gap
            return rect
        }
        let icon = place(iconSize)
        let wordsRect = wordsWidth > 0 ? place(NSSize(width: wordsWidth, height: ceil(wordsSize.height))) : nil
        let chevronRect = chevronSize.width > 0 ? place(chevronSize) : nil
        return Parts(icon: icon, words: wordsRect, chevron: chevronRect)
    }
    /// The pieces on show side by side, with a gap between each two.
    private static func contentWidth(icon: CGFloat, words: CGFloat, chevron: CGFloat) -> CGFloat {
        let pieces = [icon, words, chevron].filter { $0 > 0 }
        return pieces.reduce(0, +) + gap * CGFloat(max(0, pieces.count - 1))
    }
    private static func attributed(_ words: String) -> NSAttributedString {
        NSAttributedString(string: words, attributes: [.font: titleFont, .foregroundColor: NSColor.labelColor])
    }
    /// The icon in the button's tint, for drawing it alongside the words.
    private var drawnIcon: NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [contentTintColor ?? .labelColor])))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard drawsOwnContent else { super.draw(dirtyRect); return }
        let parts = parts(in: bounds)
        drawnIcon?.draw(in: parts.icon)
        if let rect = parts.words { Self.attributed(shownWords).draw(in: rect) }
        if let rect = parts.chevron { Self.chevron?.draw(in: rect) }
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        // The width constraint sets the width of a button that draws its own words.
        return drawsOwnContent ? NSSize(width: NSView.noIntrinsicMetric, height: size.height) : size
    }

    @objc private func open() {
        if let openHandler { openHandler(self); return }
        guard let menu = menuProvider?() else { return }
        isOn = true
        // Draw the lit state before the menu takes over the event loop.
        CATransaction.flush()
        let x = alignsMenuToTrailingEdge ? bounds.width - menu.size.width : 0
        presentMenu(menu, NSPoint(x: x, y: bounds.height + 4), self)
        isOn = false
        updateHover()
    }
    /// For tests: opens the menu as a click does.
    func openForTesting() { open() }
}

/// Header animations are short, and none at all with Reduce Motion on.
@MainActor enum HeaderMotion {
    /// Tests turn motion off so they see final states at once.
    static var isDisabledForTesting = false
    static var isReduced: Bool {
        isDisabledForTesting || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// Header tooltips name the shortcut from the menu bar, so they always agree with it.
enum HeaderShortcuts {
    /// "Back" becomes "Back (⌘[)". A command with no shortcut keeps its words.
    static func tip(_ words: String, _ command: CommandID) -> String {
        guard let key = key(for: command) else { return words }
        return "\(words) (\(key))"
    }
    static func key(for command: CommandID) -> String? {
        MenuModel.defaultBindings.first { $0.command == command }.map(\.displayString)
    }
}
#endif
