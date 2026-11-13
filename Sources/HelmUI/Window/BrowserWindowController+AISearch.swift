#if os(macOS)
import AppKit
import HelmAgent
import HelmCore

/// The window's side of searching with a model's help.
///
/// The window holds whether the search field's spark is on. It is off at launch, goes off when the search closes
/// or AI mode stops being ready, and while it is on, typing still searches names at once and only Return asks the
/// model. The runner it installs does the searching; the window shows how it went in the status bar and each
/// result's reason as its tooltip.
extension BrowserWindowController {
    /// Installs the window's AI search runner, and keeps the spark in step with the tab and with AI mode.
    func installAISearch() {
        let runner = AISearchRunner(dependencies: dependencies)
        effects.aiSearch = runner
        let runtime = dependencies.agent.runtime
        let watch = AISearchWatch(runtime: runtime)
        watch.runtimeToken = runtime.changes.subscribe { [weak self] _ in self?.followAISearchReadiness() }
        watch.storeToken = store.snapshots.subscribe { [weak self] _ in self?.followAISearchReadiness() }
        runner.watch = watch
        watch.shown = (isAISearchReady, false)
        header.setAISearch(available: isAISearchReady, on: false)
    }

    /// Return in the search field. With the spark on and a model ready, the words are sent; otherwise nothing
    /// changes, since typing already searched them.
    func headerSearchSubmitted(_ text: String) {
        guard let runner = aiSearchRunner, runner.isOn, isAISearchReady,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelPendingSearch()
        search(text, usesAI: true)
    }

    /// File › Find with AI (⌥⌘F): the search opens if it isn't open, and the spark turns over, as a press on it does.
    func toggleAISearchFromMenu() {
        guard isAISearchReady, let runner = aiSearchRunner else { return }
        if !header.isSearching { header.beginSearch() }
        headerSearchAIToggled(!runner.isOn)
    }

    /// The search field's spark. It stays off while no model is ready.
    func headerSearchAIToggled(_ on: Bool) {
        guard let runner = aiSearchRunner else { return }
        runner.isOn = on && isAISearchReady
        showAISearchState()
    }

    /// The status bar's line during and after an AI search, and the hint while the spark is on; nil leaves the
    /// usual words.
    func aiSearchStatus(for tab: TabState) -> AISearchStatus? {
        guard let runner = aiSearchRunner, case .ready(_, let destination, _, _) = dependencies.agent.runtime.state else { return nil }
        if let search = tab.search, search.query.usesAI, let assist = search.assist {
            switch assist.phase {
            case .thinking: return AISearchStatus(text: AgentText.searchThinking)
            case .failed: return AISearchStatus(text: AgentText.searchFailed)
            case .done:
                let coverage: String?
                switch assist.coverage {
                case .full: coverage = nil
                case .onThisMacOnly: coverage = AgentText.searchOnThisMac
                case .namesOnly: coverage = AgentText.searchNamesOnly
                }
                // Inside the dot list the coverage is one part of it, not a sentence: "… · Names only here".
                let readAs = assist.readAs ?? ""
                let part = readAs.isEmpty ? coverage : coverage.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
                let words = [assist.readAs, part].compactMap { $0 }.filter { !$0.isEmpty }
                return AISearchStatus(text: words.joined(separator: " · "), queries: assist.queriesRead)
            }
        }
        guard runner.isOn, tab.id == activeTabID else { return nil }
        return AISearchStatus(text: AgentText.searchHint(destination))
    }

    /// "Find with AI" on the no-results page: the spark goes on and the same words are sent at once.
    func findWithAI() {
        guard isAISearchReady, let text = activeTab?.search?.query.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        headerSearchAIToggled(true)
        cancelPendingSearch()
        search(text, usesAI: true)
    }

    // MARK: State

    var aiSearchRunner: AISearchRunner? { effects.aiSearch as? AISearchRunner }

    /// A model is ready to help.
    var isAISearchReady: Bool {
        if case .ready = dependencies.agent.runtime.state { return true }
        return false
    }

    /// Turns the spark off once the search has closed or no model is ready, and shows the field and the status
    /// bar as they now are.
    private func followAISearchReadiness() {
        guard let runner = aiSearchRunner else { return }
        let ready = isAISearchReady
        let closed = !header.isSearching && activeTab?.search == nil
        if runner.isOn, closed || !ready { runner.isOn = false }
        // Each snapshot renders the status bar already; the field and the bar change here only when the spark does.
        guard runner.watch?.shown.map({ $0 != (ready, runner.isOn) }) ?? true else { return }
        showAISearchState()
    }

    private func showAISearchState() {
        let shown = (available: isAISearchReady, on: aiSearchRunner?.isOn ?? false)
        aiSearchRunner?.watch?.shown = shown
        header.setAISearch(available: shown.available, on: shown.on)
        if let tab = activeTab { renderStatus(tab) }
    }

    // MARK: Test support

    /// Presses the search field's spark. The spark sits in the field, so the field opens first.
    public func setAISearchForTesting(_ on: Bool) {
        if on, !header.isSearching { header.beginSearch() }
        headerSearchAIToggled(on)
    }
    public var isAISearchOnForTesting: Bool { aiSearchRunner?.isOn ?? false }
    /// Return in the search field, with the words it holds, or the tab's search's words when it holds none.
    public func submitSearchForTesting() {
        let typed = header.searchText
        headerSearchSubmitted(typed.isEmpty ? (activeTab?.search?.query.text ?? "") : typed)
    }
    /// A result's tooltip, saying why it matched, read from the list or the grid on show.
    public func matchReasonForTesting(named name: String) -> String? {
        guard let entry = activeTab?.snapshot.sortedEntries.first(where: { $0.name == name }) else { return nil }
        if let list = shownContent as? FileListController { return list.toolTipForTesting(entry.id) }
        if let grid = shownContent as? FileGridController { return grid.toolTipForTesting(entry.id) }
        return nil
    }
    public var aiSearchStatusForTesting: AISearchStatus? { activeTab.flatMap { aiSearchStatus(for: $0) } }
}

/// What the window's AI search listens to. The runtime outlives the window, so its subscription ends with this.
@MainActor final class AISearchWatch {
    private let runtime: AgentRuntime
    var runtimeToken: Broadcast<AgentRuntimeState>.Token?
    var storeToken: Broadcast<WindowStoreSnapshot>.Token?
    /// What the search field was last told: whether the spark is available, and whether it is on.
    var shown: (available: Bool, on: Bool)?

    init(runtime: AgentRuntime) { self.runtime = runtime }

    deinit {
        guard let token = runtimeToken else { return }
        let runtime = self.runtime
        Task { @MainActor in runtime.changes.cancel(token) }
    }
}
#endif
