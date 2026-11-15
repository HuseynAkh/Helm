#if os(macOS)
import AppKit
import HelmCore

/// One button for Grid and List. It shows the view you'd switch to, the way a toggle names what pressing it does:
/// in the grid it shows the list's icon and "List (⌘2)", and the other way round. VoiceOver hears what it does,
/// "Show as List", and the view you're in as its value.
@MainActor final class ViewModeButton: FlatButton {
    /// A view was picked here. The button already shows the next one on offer.
    var onChoose: ((ViewMode) -> Void)?
    /// The view on show now.
    private(set) var mode: ViewMode = .grid
    /// The view a press switches to.
    var offered: ViewMode { Self.other(than: mode) }
    static let showAsGrid = "Show as Grid"
    static let showAsList = "Show as List"

    init() {
        super.init(symbol: ViewMode.list.systemImageName, label: Self.showAsList, target: nil, action: nil)
        target = self
        action = #selector(choose)
        apply(animated: false)
    }
    required init?(coder: NSCoder) { nil }

    /// Shows a view as the current one. Animated, the old icon fades into the new one.
    func setMode(_ mode: ViewMode, animated: Bool) {
        guard mode != self.mode else { return }
        self.mode = mode
        apply(animated: animated)
    }

    private static func other(than mode: ViewMode) -> ViewMode { mode == .grid ? .list : .grid }

    private func apply(animated: Bool) {
        if animated, window != nil, !HeaderMotion.isReduced, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            layer.add(fade, forKey: "icon")
        }
        let next = offered
        setSymbol(next.systemImageName, label: next == .list ? Self.showAsList : Self.showAsGrid,
                  toolTip: HeaderShortcuts.tip(next.displayName, next == .grid ? .grid : .list))
        setAccessibilityValue(mode.displayName)
    }

    @objc private func choose() {
        let chosen = offered
        setMode(chosen, animated: true)
        onChoose?(chosen)
    }
    /// For tests: a click on the button, which picks the view on offer.
    func clickForTesting() { choose() }
}
#endif
