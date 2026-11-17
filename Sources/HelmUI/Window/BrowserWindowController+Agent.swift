#if os(macOS)
import AppKit
import HelmAgent
import HelmCore

/// The window's side of the AI panel: opening and shutting it, telling it what the tab in front shows, and doing
/// for it everything that touches files. A plan runs only from the card's Apply, in this window's turn, after the
/// conversation has checked it once more.
extension BrowserWindowController {
    /// Puts the panel's column in the window. Called once, after the window's own set-up.
    func installAgentPanel() { agentPanelHost.install(in: self) }

    /// Opens or shuts the panel when a model is ready; otherwise asks for the AI mode screen.
    public func toggleAgentPanel() {
        guard case .ready = dependencies.agent.runtime.state else { host?.showAIModeScreen(from: self); return }
        agentPanelHost.setOpen(!agentPanelHost.isOpen, animated: true)
    }
    /// What Done on the AI mode screen calls when this window's spark opened it.
    public func openAgentPanel() {
        guard case .ready = dependencies.agent.runtime.state else { return }
        agentPanelHost.setOpen(true, animated: true)
    }
    public var isAgentPanelOpen: Bool { agentPanelHost.isOpen }
    /// Each render: the tab, its folder or its selection may have changed.
    func agentWindowDidRender() { agentPanelHost.windowDidRender() }
    /// The room the files on show need beside the panel: the list's, for every column's words; nothing for the grid.
    var filesRoomNeeded: CGFloat { (shownContent as? FileListController)?.roomNeeded ?? 0 }

    /// Applies an approved plan. The conversation checks its own copy of the plan again first; the plan it hands
    /// back is the one that runs, and only the groups that were ticked. Nil when nothing was allowed to run.
    func applyAgentPlan(_ approved: AgentApprovedPlan) async -> AgentApplyReport? {
        guard let model = agentPanelHost.model else { return nil }
        let session = model.session
        return await enqueueOperationAwaiting { [weak self, weak model] () -> AgentApplyReport? in
            let ticket = await session.beginApply(planID: approved.planID, ticked: approved.ticked)
            guard case .go(let plan) = ticket, let self else {
                model?.applyAnswered(planID: approved.planID, ticket)
                return nil
            }
            let report = await AgentPlanApplier(window: self).apply(plan, ticked: approved.ticked,
                                                                    shouldStop: { model?.applyStopAsked ?? true },
                                                                    pauseBetween: self.agentApplyPauseForTesting) { done, total, name in
                model?.applyProgress(planID: plan.id, done: done, total: total, name: name)
            }
            await session.settle(planID: plan.id, .applied(done: report.done, skipped: report.skipped))
            return report
        }
    }
    /// Hands a server address to macOS once the person agreed. Helm adds no folder afterwards.
    func connectAgentServer(_ location: ServerLocation) -> Bool { dependencies.agent.connector.connect(location) }

    public var agentPanelModelForTesting: AgentPanelModel? { agentPanelHost.model }
    /// How wide the AI panel is: what it shows while open, and zero while shut.
    public var agentPanelWidthForTesting: CGFloat { agentPanelHost.isOpen ? agentPanelHost.frame.width : 0 }
    /// A drag of the AI panel's leading edge, `distance` points towards the leading side (negative goes back), as a
    /// person makes one: a press, moves and a release sent to the window. False when the press missed the edge.
    @discardableResult public func dragAgentPanelEdgeForTesting(by distance: CGFloat) -> Bool {
        agentPanelHost.sendEdgeDragForTesting(by: distance)
    }
    /// A double click on the AI panel's leading edge, sent to the window as two clicks. False when either missed it.
    @discardableResult public func doubleClickAgentPanelEdgeForTesting() -> Bool {
        agentPanelHost.sendEdgeDragForTesting(by: 0) && agentPanelHost.sendEdgeDragForTesting(by: 0, clicks: 2)
    }
    /// The model's name under the composer, and "menu" or "plain" for whether a press on it shows the model menu.
    public var agentModelNameForTesting: String {
        let shown = agentPanelHost.modelNameForTesting
        return "\(shown.name) \(shown.isMenu ? "menu" : "plain")"
    }
    /// Picks a row of the menu under the composer by its title, as a click on it would, under one provider if named.
    @discardableResult public func pickAgentModelMenuRowForTesting(_ title: String, under provider: String? = nil) -> Bool {
        agentPanelHost.pickModelMenuRowForTesting(title, under: provider)
    }
    /// The rows of the menu under the composer, by title. Empty while the name is a plain name.
    public var agentModelMenuTitlesForTesting: [String] { agentPanelHost.modelMenuTitlesForTesting }

    // MARK: For the panel

    /// A panel's model over a new conversation, with what this window does for it. Nil unless a model is ready.
    func makeAgentPanelModel() -> AgentPanelModel? {
        guard let provider = agentProvider, let session = dependencies.agent.runtime.makeSession() else { return nil }
        var actions = AgentPanelModel.Actions()
        actions.apply = { [weak self] approved in await self?.applyAgentPlan(approved) }
        actions.undo = { [weak self] group in await self?.undoAgentPlan(group) ?? false }
        actions.show = { [weak self] urls in self?.showAgentChanges(urls) }
        actions.connect = { [weak self] location in self?.connectAgentServer(location) ?? false }
        actions.openSettings = { [weak self] in self?.host?.showSettings(pane: .ai) }
        actions.chooseModel = { [weak self] choice in self?.chooseAgentModel(choice) }
        actions.giveKeysBack = { [weak self] in self?.focusContent() }
        actions.focusComposer = { [weak self] in self?.agentPanelHost.focusComposer() }
        actions.phaseChanged = { [weak self] _ in self?.agentPanelHost.updateSpark() }
        return AgentPanelModel(session: session, home: dependencies.home.path, provider: provider, actions: actions)
    }

    /// What the model's name under the composer offers, from what ai.json keeps and which keys are saved. Nothing is
    /// asked of any provider to work it out.
    var agentModelMenu: AgentModelMenu {
        let agent = dependencies.agent
        return AgentModelMenu.make(config: agent.config.config, hasKey: { agent.secrets.has($0) },
                                   hasChatGPTSignIn: { agent.secrets.hasSignIn(.chatGPTTokens) })
    }

    /// A model chosen under the composer: the provider and its model are saved, as Settings › AI saves them, and the
    /// next request goes there. The runtime starts every thread over when the provider changes.
    func chooseAgentModel(_ choice: AgentModelMenu.Choice) {
        guard let model = AgentModelInfo(id: choice.model) else { return }
        dependencies.agent.config.update { saved in
            saved.provider = choice.provider.rawValue
            saved.models[choice.provider.rawValue] = model.id
        }
    }

    /// Ollama and LM Studio, when their last check answered, are asked for their models again as the panel opens, so
    /// the menu lists what their servers have now. Cloud providers keep the list of their last check, and nothing at
    /// all is asked while no model is ready.
    func refreshLocalModelLists() {
        let agent = dependencies.agent
        guard case .ready = agent.runtime.state else { return }
        let config = agent.config.config
        for id in AgentProviderID.allCases {
            var draft = config
            draft.provider = id.rawValue
            guard let profile = try? AgentProviderCatalog.profile(for: draft).get(), profile.isLocal,
                  config.modelLists[profile.secretID.account]?.isEmpty == false else { continue }
            Task { [runtime = agent.runtime, draft] in await runtime.relistLocal(draft) }
        }
    }

    /// The model requests go to, while one is ready.
    var agentProvider: AgentPanelModel.Provider? {
        guard case .ready(let provider, let destination, let model, _) = dependencies.agent.runtime.state else { return nil }
        return AgentPanelModel.Provider(name: provider, destination: destination, model: model)
    }

    /// What the tab in front shows. Recent, the Trash and search results show no folder.
    var agentTabContext: AgentPanelModel.TabContext {
        guard let tab = activeTab else { return AgentPanelModel.TabContext(folder: nil, itemCount: 0, selectedPaths: []) }
        var folder: String?
        if case .directory(let url) = tab.location, tab.search == nil { folder = url.standardizedFileURL.path }
        let selected = tab.selection.compactMap { tab.snapshot.entry($0)?.url.path }.sorted()
        return AgentPanelModel.TabContext(folder: folder, itemCount: folder == nil ? 0 : tab.snapshot.rootCount,
                                          selectedPaths: folder == nil ? [] : selected)
    }

    /// Show on a result card: the folder of the first changed item, with every changed item there selected.
    private func showAgentChanges(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let folder = first.deletingLastPathComponent()
        let inFolder = urls.filter { $0.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path }
        show(folder: folder, selecting: inFolder)
    }
}
#endif
