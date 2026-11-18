#if os(macOS)
import AppKit
import HelmUI

/// The AI mode screen and Settings › AI, both drawn from one `AISetupModel`, made the first time either is needed.
extension AppController {
    /// The spark, or View › Show AI Panel, while no model is ready. Done, once AI mode is connected, opens the panel
    /// in the window that asked, or in the window in front when none did.
    public func showAIModeScreen(from window: BrowserWindowController?) {
        guard let model = aiSetupModel() else { return }
        access.showAIMode(model, from: window)
    }
    /// A window a browser window opened, such as Properties: in front as usual, or kept invisible and behind by a run
    /// that stays in the background, as its browser windows are.
    public func present(_ window: NSWindow) {
        if staysInBackground {
            SmokeBackground.hide(window)
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }
    /// Once at launch, after the first window, for someone who set Helm up before AI mode and got no onboarding now.
    /// Everyone else meets AI mode as a step of the onboarding. Never by itself in a fixture run.
    func showAIIntroIfNeeded() {
        access.showAIIntroIfNeeded { [weak self] in self?.aiSetupModel() }
    }
    /// Puts Settings › AI in its pane, as the Sidebar pane's rows are put in theirs. Once per Settings window.
    func installAISettingsPane(in window: SettingsWindowController) {
        guard window.aiSetupModel == nil, let model = aiSetupModel() else { return }
        window.showAI(model)
    }
    public var aiSetupModelForTesting: AISetupModel? { aiSetupModel() }

    /// The one model behind Settings › AI and the AI mode screen. Nil before launch has made the app's services.
    func aiSetupModel() -> AISetupModel? {
        if let model = access.aiSetup { return model }
        guard let environment, let agent = dependencies?.agent else { return nil }
        let model = AISetupModel(settings: environment.settings, services: agent)
        access.aiSetup = model
        return model
    }
}
#endif
