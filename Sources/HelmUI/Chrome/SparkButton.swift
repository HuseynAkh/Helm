#if os(macOS)
import AppKit
import HelmAgent
import HelmCore

/// The header's spark, beside the main menu: it shows or hides the AI panel. It's a header button like the others,
/// 34 by 32 with the same fills, and draws Helm's spark itself: in the label colour at rest, in the gradient while the
/// panel is open, and with the gradient turning slowly while a request is open. Reduce Motion keeps the gradient
/// still, and Increase Contrast keeps the spark in the label colour, where the lit fill alone says it's open.
@MainActor final class SparkButton: FlatButton {
    /// The panel is open: the spark is in the gradient and the button has the lit fill.
    var isLit = false {
        didSet {
            guard isLit != oldValue else { return }
            isOn = isLit
            needsDisplay = true
        }
    }
    /// A request is open in the panel: the gradient turns slowly.
    var isWorking = false {
        didSet {
            guard isWorking != oldValue else { return }
            updateShimmer()
            needsDisplay = true
        }
    }
    /// How far the gradient has turned, 0 to 1.
    private(set) var shimmerTurn: CGFloat = 0
    private var shimmerTimer: Timer?
    private var shimmerStart = Date()
    /// One full turn of the gradient, in seconds: slow enough to read as a glow rather than a spinner.
    static let shimmerPeriod: TimeInterval = 3
    /// The mark's side. Its ink sits a little in from the square, so at 18 it's about 15.5 points across, the size of
    /// the header's 15-point symbols beside it.
    static let markSize: CGFloat = 18
    /// Tests set this to stand in for the system's Increase Contrast setting.
    static var increasesContrastForTesting: Bool?

    init(target: AnyObject?, action: Selector?) {
        super.init(symbol: "", label: AgentText.sparkTitle, toolTip: AgentText.sparkSetUp, target: target, action: action)
        isToggle = true
        // Reduce Motion or Increase Contrast can change while the panel is open or a request runs.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        updateShimmer()
        needsDisplay = true
    }

    /// Whether the spark is drawn in the gradient now.
    var drawsGradient: Bool {
        let contrast = Self.increasesContrastForTesting ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return (isLit || isWorking) && !contrast
    }
    /// Whether the gradient is turning now.
    var isShimmering: Bool { shimmerTimer != nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateShimmer()
    }

    /// The turn runs only while a request is open, the button is in a window and motion is allowed. Otherwise the
    /// gradient rests where a still mark has it.
    private func updateShimmer() {
        let runs = isWorking && window != nil && !HeaderMotion.isReduced
        if runs, shimmerTimer == nil {
            shimmerStart = Date()
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    self.stepShimmer()
                }
            }
            // The common modes keep it turning while a menu is open or the window is being resized.
            RunLoop.main.add(timer, forMode: .common)
            shimmerTimer = timer
        } else if !runs, let timer = shimmerTimer {
            timer.invalidate()
            shimmerTimer = nil
            shimmerTurn = 0
            needsDisplay = true
        }
    }
    private func stepShimmer() {
        let elapsed = Date().timeIntervalSince(shimmerStart)
        shimmerTurn = CGFloat((elapsed / Self.shimmerPeriod).truncatingRemainder(dividingBy: 1))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side = Self.markSize
        let rect = backingAlignedRect(NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side),
                                      options: .alignAllEdgesNearest)
        context.saveGState()
        // The spark's gradient runs from the top, so a flipped button draws it the right way up.
        if isFlipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        if drawsGradient {
            SparkMark.drawGradient(in: rect, context: context, turn: shimmerTurn)
        } else {
            SparkMark.fill(in: rect, context: context, color: contentTintColor ?? .labelColor)
        }
        context.restoreGState()
    }
}
#endif
