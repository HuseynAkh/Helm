#if os(macOS)
import AppKit

/// The header bar's button: flat until the pointer is over it, like a libadwaita header button.
@MainActor class FlatButton: NSButton {
    private var hovering = false { didSet { refresh() } }
    private var trackingArea: NSTrackingArea?
    var isOn = false { didSet { refresh() } }

    init(symbol: String, label: String, pointSize: CGFloat = 15, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        self.target = target; self.action = action
        setSymbol(symbol, pointSize: pointSize, label: label)
        toolTip = label
        setAccessibilityLabel(label)
        contentTintColor = .labelColor
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
    }
    required init?(coder: NSCoder) { nil }

    func setSymbol(_ symbol: String, pointSize: CGFloat = 15, label: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        toolTip = label
        setAccessibilityLabel(label)
    }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.35 } }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let alpha: CGFloat = isOn ? 0.14 : (hovering && isEnabled ? 0.09 : 0)
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }
}

/// A flat button that opens a menu, which is built when it opens so it always shows the current state.
@MainActor final class FlatMenuButton: FlatButton {
    var menuProvider: (() -> NSMenu?)?
    /// Opens something other than a menu, such as a popover, instead.
    var openHandler: ((FlatMenuButton) -> Void)?
    init(symbol: String, label: String, title: String = "") {
        super.init(symbol: symbol, label: label, target: nil, action: nil)
        self.title = title
        font = .systemFont(ofSize: 13)
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        imageHugsTitle = true
        target = self; action = #selector(open)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func open() {
        if let openHandler { openHandler(self); return }
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}
#endif
