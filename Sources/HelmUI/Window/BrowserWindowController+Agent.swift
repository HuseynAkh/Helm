#if os(macOS)
import AppKit
import HelmAgent
import HelmCore

/// The window's side of the AI panel. The panel has nothing in it, so it never opens: the spark and View › Show AI
/// Panel only ask the app for the AI mode screen while no model is ready.
extension BrowserWindowController {
    /// Puts the panel's column in the window. Called once, after the window's own set-up.
    func installAgentPanel() { agentPanelHost.install(in: self) }

    /// Opens or shuts the panel when a model is ready; otherwise asks for the AI mode screen.
    public func toggleAgentPanel() {
        guard case .ready = dependencies.agent.runtime.state else { host?.showAIModeScreen(from: self); return }
        agentPanelHost.setOpen(!agentPanelHost.isOpen, animated: true)
    }
    /// What Done on the AI mode screen calls when this window's spark opened it.
    public func openAgentPanel() { agentPanelHost.setOpen(true, animated: true) }
    public var isAgentPanelOpen: Bool { agentPanelHost.isOpen }
    /// Each render: the tab, its folder or its selection may have changed.
    func agentWindowDidRender() { agentPanelHost.windowDidRender() }

    /// Applies an approved plan. Nil when nothing was allowed to run.
    func applyAgentPlan(_ approved: AgentApprovedPlan) async -> AgentApplyReport? { nil }
    /// Hands a server address to macOS once the person agreed. Helm adds no folder afterwards.
    func connectAgentServer(_ location: ServerLocation) -> Bool { dependencies.agent.connector.connect(location) }

    public var agentPanelModelForTesting: AgentPanelModel? { nil }
}
#endif
