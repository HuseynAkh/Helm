#if os(macOS)
import AppKit
import HelmCore

/// Grid | List, with both always on show and the current one on a lit thumb, the way Finder's view control shows
/// the view you're in. It's drawn flat like the rest of the header: the thumb is a lit button's fill and corners,
/// and it slides across when the view changes.
@MainActor final class ViewModeSwitch: NSView {
    /// A view was picked here. The switch has already moved.
    var onChoose: ((ViewMode) -> Void)?
    private(set) var mode: ViewMode = .grid
    private let thumb = NSView()
    private(set) var segments: [FlatButton] = []
    static let segmentSize = NSSize(width: 32, height: 32)

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        addSubview(thumb)
        var previous: NSView?
        for (index, mode) in ViewMode.allCases.enumerated() {
            let command: CommandID = mode == .grid ? .grid : .list
            let button = FlatButton(symbol: mode.systemImageName, label: mode.displayName,
                                    toolTip: HeaderShortcuts.tip(mode.displayName, command),
                                    minimumWidth: Self.segmentSize.width, target: self, action: #selector(choose(_:)))
            button.tag = index
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityHelp(mode == .grid ? "Show items as icons" : "Show items in a list")
            addSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.segmentSize.width),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.leadingAnchor.constraint(equalTo: previous?.trailingAnchor ?? leadingAnchor)
            ])
            previous = button
            segments.append(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("View")
        updateThumb()
        apply(animated: false)
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.segmentSize.width * CGFloat(ViewMode.allCases.count), height: Self.segmentSize.height)
    }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows a view as the current one. Animated, the thumb slides over 0.18 seconds and the icons' colours cross-fade.
    func setMode(_ mode: ViewMode, animated: Bool) {
        guard mode != self.mode else { return }
        self.mode = mode
        apply(animated: animated)
    }

    /// Where the thumb sits for the current view: exactly over its segment.
    var thumbTarget: NSRect {
        let index = CGFloat(ViewMode.allCases.firstIndex(of: mode) ?? 0)
        // Before its first layout the switch has no height, and the thumb still belongs at the top.
        let y = max(0, ((bounds.height - Self.segmentSize.height) / 2).rounded())
        return NSRect(x: index * Self.segmentSize.width, y: y, width: Self.segmentSize.width, height: Self.segmentSize.height)
    }

    private func apply(animated: Bool) {
        let motion = animated && window != nil && !HeaderMotion.isReduced
        for (index, button) in segments.enumerated() {
            let current = ViewMode.allCases[index] == mode
            if motion, let layer = button.layer {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.15
                layer.add(fade, forKey: "tint")
            }
            // The current view reads in full colour and doesn't react to the pointer; the other is the one to press.
            button.contentTintColor = current ? .labelColor : .secondaryLabelColor
            button.showsHover = !current
            button.setAccessibilityValue(NSNumber(value: current))
        }
        let target = thumbTarget
        if motion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                thumb.animator().frame = target
            }
        } else {
            thumb.frame = target
        }
    }

    override func layout() {
        super.layout()
        let target = thumbTarget
        if thumb.frame != target { thumb.frame = target }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThumb()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateThumb()
    }
    /// The lit fill of a header button that's on.
    private func updateThumb() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            thumb.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        }
    }

    @objc private func choose(_ sender: FlatButton) {
        guard ViewMode.allCases.indices.contains(sender.tag) else { return }
        let chosen = ViewMode.allCases[sender.tag]
        guard chosen != mode else { return }
        setMode(chosen, animated: true)
        onChoose?(chosen)
    }
    /// For tests: where the thumb is now.
    var thumbFrameForTesting: NSRect { thumb.frame }
    /// For tests: a click on one of the two segments.
    func clickForTesting(_ mode: ViewMode) {
        guard let index = ViewMode.allCases.firstIndex(of: mode) else { return }
        choose(segments[index])
    }
}
#endif
