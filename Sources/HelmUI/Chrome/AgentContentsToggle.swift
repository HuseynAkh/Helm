#if os(macOS)
import AppKit
import HelmAgent
import HelmCore

/// The Read contents switch: a small toggle with a magnifier over a page and the words "Read contents", as the AI
/// panel shows it beside the composer and AI search at the end of its kind row. Off, it is quiet, in the secondary
/// label colour; on, it sits on the header's lit fill with its symbol in the accent colour. VoiceOver reads it as a
/// toggle named Read contents, with its state. It never takes the keys from the field beside it.
@MainActor final class AgentContentsToggle: FlatButton {
    static let font = NSFont.systemFont(ofSize: 12)
    static let symbol = "doc.text.magnifyingglass"
    static let cornerRadius: CGFloat = 6
    private static let padding: CGFloat = 8, gap: CGFloat = 4, symbolSize: CGFloat = 12
    let word = AgentText.readContents
    private let wordWidth: CGFloat
    private let height: CGFloat
    private var widthConstraint: NSLayoutConstraint?
    /// The words beside the symbol. Off, where a row has no room for them, it shows the symbol alone; its tooltip and
    /// VoiceOver still say Read contents.
    var showsWord = true {
        didSet {
            guard showsWord != oldValue else { return }
            widthConstraint?.constant = width
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    /// The person turned it over: the new state.
    var onToggle: ((Bool) -> Void)?

    init(height: CGFloat = 22, help: String) {
        self.height = height
        wordWidth = ceil(NSAttributedString(string: AgentText.readContents, attributes: [.font: Self.font]).size().width)
        super.init(symbol: Self.symbol, label: AgentText.readContents, pointSize: Self.symbolSize, toolTip: help, minimumWidth: 0,
                   height: height, target: nil, action: nil)
        target = self
        action = #selector(pressed)
        image = nil
        imagePosition = .noImage
        isToggle = true
        layer?.cornerRadius = Self.cornerRadius
        refusesFirstResponder = true
        setAccessibilityLabel(AgentText.readContents)
        let constraint = widthAnchor.constraint(equalToConstant: Self.width(wordWidth: wordWidth))
        constraint.isActive = true
        widthConstraint = constraint
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }

    /// Its width: the symbol, the gap and the words, with room either side, or the symbol alone.
    var width: CGFloat { showsWord ? Self.width(wordWidth: wordWidth) : Self.symbolOnlyWidth }
    /// Its width with the words, whether or not they show.
    var fullWidth: CGFloat { Self.width(wordWidth: wordWidth) }
    static let symbolOnlyWidth: CGFloat = ceil(2 * 7 + symbolSize + 3)
    private static func width(wordWidth: CGFloat) -> CGFloat { ceil(2 * padding + symbolSize + 3 + gap + wordWidth) }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: height) }

    /// Shows a state without saying it was chosen.
    func show(on: Bool, enabled: Bool) {
        if isOn != on { isOn = on }
        if isEnabled != enabled { isEnabled = enabled }
        needsDisplay = true
    }

    @objc private func pressed() {
        isOn.toggle()
        onToggle?(isOn)
    }

    /// The symbol, then the words, centred as one: the label colour and the accent while on, a step quieter while off,
    /// and fainter still while it can't be pressed.
    override func draw(_ dirtyRect: NSRect) {
        var words = NSColor.secondaryLabelColor, mark = NSColor.secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            words = isOn ? .labelColor : .secondaryLabelColor
            mark = isOn ? .controlAccentColor : .secondaryLabelColor
            if !isEnabled { words = .tertiaryLabelColor; mark = .tertiaryLabelColor }
        }
        let text = NSAttributedString(string: word, attributes: [.font: Self.font, .foregroundColor: words])
        let textSize = text.size()
        let symbol = NSImage(systemSymbolName: Self.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Self.symbolSize, weight: .regular))
        let symbolSize = symbol?.size ?? .zero
        let total = showsWord ? symbolSize.width + Self.gap + ceil(textSize.width) : symbolSize.width
        var x = ((bounds.width - total) / 2).rounded()
        if let symbol {
            let rect = backingAlignedRect(NSRect(x: x, y: (bounds.height - symbolSize.height) / 2, width: symbolSize.width,
                                                 height: symbolSize.height), options: .alignAllEdgesNearest)
            Self.draw(symbol, in: rect, color: mark, appearance: effectiveAppearance)
            x += symbolSize.width + Self.gap
        }
        guard showsWord else { return }
        text.draw(in: NSRect(x: x, y: ((bounds.height - textSize.height) / 2).rounded(), width: ceil(textSize.width),
                             height: ceil(textSize.height)))
    }

    /// A template's shape filled with `color`, resolved for `appearance`.
    private static func draw(_ template: NSImage, in rect: NSRect, color: NSColor, appearance: NSAppearance) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var fill = color.cgColor
        appearance.performAsCurrentDrawingAppearance { fill = color.cgColor }
        context.saveGState()
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        template.draw(in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(fill)
        context.fill(rect)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
#endif
