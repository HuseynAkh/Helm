#if os(macOS)
import AppKit
import HelmUI

/// The AI mode screen and Settings › AI. Neither has anything to show, so nothing opens and the AI pane stays empty.
extension AppController {
    /// The spark, or View › Show AI Panel, while no model is ready.
    public func showAIModeScreen(from window: BrowserWindowController?) {}
    /// Once at launch for someone who hasn't seen the AI mode screen. Never by itself in a fixture run.
    func showAIIntroIfNeeded() {}
    /// Puts Settings › AI in its pane, as the Sidebar pane's rows are put in theirs.
    func installAISettingsPane(in window: SettingsWindowController) {}
    public var aiSetupModelForTesting: AISetupModel? { nil }
}
#endif
