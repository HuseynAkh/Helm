#if os(macOS)
import AppKit
import HelmCore

/// The window's side of searching with a model's help. No runner is installed, so every search runs as it always
/// has, the toggle stays off and the status bar keeps its usual words.
extension BrowserWindowController {
    /// Installs the window's AI search runner, if there is one. There's none, so `effects.aiSearch` stays nil.
    func installAISearch() {}
    /// Return in the search field.
    func headerSearchSubmitted(_ text: String) {}
    /// The search field's spark. The window holds whether AI search is on: off at launch and off when a search closes.
    func headerSearchAIToggled(_ on: Bool) {}
    /// The status bar's line during and after an AI search; nil leaves the usual words.
    func aiSearchStatus(for tab: TabState) -> AISearchStatus? { nil }

    public func setAISearchForTesting(_ on: Bool) {}
    public var isAISearchOnForTesting: Bool { false }
    public func submitSearchForTesting() {}
    /// A result's tooltip, saying why it matched.
    public func matchReasonForTesting(named name: String) -> String? { nil }
    public var aiSearchStatusForTesting: AISearchStatus? { activeTab.flatMap { aiSearchStatus(for: $0) } }
}
#endif
