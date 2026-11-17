#if os(macOS)
import AppKit
import HelmAgent
import HelmCore

/// The window's side of searching with a model's help.
///
/// The window holds whether the search field's spark is on. The field shows the spark whenever AI mode is on, as
/// the header's spark does; while no model is ready, pressing it opens the AI mode screen and it stays off. It is off
/// at launch, goes off when the search closes or AI mode stops being ready, and while it is on, typing still searches
/// names at once and only Return asks the model. The runner it installs does the searching; the window shows how it
/// went in the status bar and each result's reason as its tooltip.
///
/// The kind row under the header is the search's, spark on or off (`headerSearchKindChanged`): its kind limits every
/// search, typed or sent, and the plan a model answers. Choosing another kind searches the words again by name, and
/// Return asks the model again; nothing is sent by the choice itself. Turning the spark on or off keeps the kind; it
/// goes back to Any when the search closes.
///
/// While the spark is on, the row's trailing end holds the Read contents switch, in a run that can read inside files.
/// On, it hands the runner the person's permit, and Return then also reads inside files on this Mac and has the model
/// look at the best of them. It lasts while the spark does: it goes off, and what was read is forgotten, whenever the
/// spark goes off, as it does when the search closes.
extension BrowserWindowController {
    /// Installs the window's AI search runner, and keeps the spark in step with the tab and with AI mode.
    func installAISearch() {
        let runner = AISearchRunner(dependencies: dependencies)
        effects.aiSearch = runner
        let runtime = dependencies.agent.runtime
        let watch = AISearchWatch(runtime: runtime)
        watch.runtimeToken = runtime.changes.subscribe { [weak self] _ in
            // AI mode, the provider or the model changed: a look may carry pictures again.
            self?.aiSearchRunner?.runtimeChanged()
            self?.followAISearchReadiness()
        }
        watch.storeToken = store.snapshots.subscribe { [weak self] _ in self?.followAISearchReadiness() }
        runner.watch = watch
        watch.shown = (isAISearchAvailable, false)
        header.setAISearch(available: isAISearchAvailable, on: false)
        header.kindBar.onContents = { [weak self] on in self?.chooseAISearchContents(on) }
    }

    /// The kind row's Read contents switch. Nothing is sent or read by the press itself; Return then reads.
    func chooseAISearchContents(_ on: Bool) {
        guard let runner = aiSearchRunner, runner.isOn, dependencies.agent.contents != nil else {
            header.kindBar.showContents(offered: false, on: false)
            return
        }
        runner.contentPermit = on ? AgentContentPermit(switchedOnByPerson: .search) : nil
        showAISearchState()
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
    /// While no model is ready, it opens the AI mode screen instead.
    func toggleAISearchFromMenu() {
        guard isAISearchAvailable, let runner = aiSearchRunner else { return }
        guard isAISearchReady else { askForAIModeScreen(); return }
        if !header.isSearching { header.beginSearch() }
        headerSearchAIToggled(!runner.isOn)
    }

    /// The search field's spark. While no model is ready it stays off, and a press asks for the AI mode screen, as
    /// the header's spark does.
    func headerSearchAIToggled(_ on: Bool) {
        guard let runner = aiSearchRunner else { return }
        if on, isAISearchAvailable, !isAISearchReady { askForAIModeScreen() }
        runner.isOn = on && isAISearchReady
        showAISearchState()
    }

    /// The AI mode screen, through the same call the header's spark makes.
    private func askForAIModeScreen() { host?.showAIModeScreen(from: self) }

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
        return AISearchStatus(text: runner.readsContents ? AgentText.searchHintContents(destination) : AgentText.searchHint(destination))
    }

    /// "Find with AI" on the no-results page: the spark goes on and the same words are sent at once. While no model
    /// is ready, it opens the AI mode screen instead.
    func findWithAI() {
        guard isAISearchAvailable else { return }
        guard isAISearchReady else { askForAIModeScreen(); return }
        guard let text = activeTab?.search?.query.text,
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
    /// AI mode is on, ready or not: the search field shows its spark.
    var isAISearchAvailable: Bool { dependencies.agent.runtime.isOn }

    /// Turns the spark off once the search has closed or no model is ready, and shows the field and the status
    /// bar as they now are.
    private func followAISearchReadiness() {
        guard let runner = aiSearchRunner else { return }
        let closed = !header.isSearching && activeTab?.search == nil
        if runner.isOn, closed || !isAISearchReady { runner.isOn = false }
        // Each snapshot renders the status bar already; the field and the bar change here only when the spark does.
        guard runner.watch?.shown.map({ $0 != (isAISearchAvailable, runner.isOn) }) ?? true else { return }
        showAISearchState()
    }

    private func showAISearchState() {
        let shown = (available: isAISearchAvailable, on: aiSearchRunner?.isOn ?? false)
        aiSearchRunner?.watch?.shown = shown
        header.setAISearch(available: shown.available, on: shown.on)
        // The kind row shows with the search, and keeps its choice; the Read contents switch at its end, with the spark.
        header.kindBar.showContents(offered: shown.on && dependencies.agent.contents != nil, on: aiSearchRunner?.readsContents ?? false)
        if let tab = activeTab { renderStatus(tab) }
    }

    // MARK: Test support

    /// Presses the search field's spark. The spark sits in the field, so the field opens first.
    public func setAISearchForTesting(_ on: Bool) {
        if on, !header.isSearching { header.beginSearch() }
        headerSearchAIToggled(on)
    }
    public var isAISearchOnForTesting: Bool { aiSearchRunner?.isOn ?? false }
    /// A press on the search field's spark, as a click on it, opening the field first. False while the field shows no
    /// spark, as with AI mode off.
    @discardableResult public func pressSearchSparkForTesting() -> Bool {
        if !header.isSearching { header.beginSearch() }
        guard header.searchField.leadingMark != "magnifier" else { return false }
        header.searchField.pressAIToggleForTesting()
        return true
    }
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
    /// The Read contents switch at the end of the kind row: whether it shows and whether it is on.
    public var aiSearchContentsForTesting: (shown: Bool, on: Bool) {
        let shown = header.kindBar.contentsForTesting
        return (shown.shown && !header.kindBar.isHidden, aiSearchRunner?.readsContents ?? false)
    }
    /// A click on the kind row's Read contents switch, as a person makes it. False while it doesn't show.
    @discardableResult public func clickAISearchContentsForTesting() -> Bool { header.kindBar.clickContentsForTesting() }
    /// How many pictures and videos this search session has read inside.
    public var aiSearchContentsReadForTesting: Int { aiSearchRunner?.memo.count ?? 0 }
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
