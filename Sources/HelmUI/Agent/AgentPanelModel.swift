#if os(macOS)
import Foundation
import HelmAgent
import HelmCore

/// What the AI panel shows and what its controls do: the folders AI mode can use, the thread, the three suggestions,
/// the plan card and its result, and the composer's text. It talks to one conversation and asks the window for
/// everything that touches files. Only this file turns what the person typed into a message, so nothing but the
/// composer, a suggestion or a dropped folder can start a request.
@MainActor public final class AgentPanelModel: ObservableObject {
    public enum Phase: String, Sendable { case noFolder, idle, working, plan, applying, result, failed }
    @Published public private(set) var phase: Phase = .noFolder

    /// The model the requests go to, as the panel names it, and whether it runs on this Mac.
    struct Provider: Equatable {
        var name: String
        var destination: String
        var model: String
        var isLocal = false
    }

    /// What the tab in front shows: its folder, if it shows one, how many items are in it and which are selected.
    struct TabContext: Equatable {
        var folder: String?
        var itemCount: Int
        var selectedPaths: [String]
    }

    /// What the window does for the panel. Every change to a file, and every key that leaves the panel, goes
    /// through here.
    struct Actions {
        /// Applies an approved plan. Nil when nothing was allowed to run; the window has then said why through
        /// `applyAnswered`.
        var apply: @MainActor (AgentApprovedPlan) async -> AgentApplyReport? = { _ in nil }
        var undo: @MainActor (UUID) async -> Bool = { _ in false }
        var show: @MainActor ([URL]) -> Void = { _ in }
        var connect: @MainActor (ServerLocation) -> Bool = { _ in false }
        var openSettings: @MainActor () -> Void = {}
        /// A model chosen from the menu under the composer: requests go to it from the next one on.
        var chooseModel: @MainActor (AgentModelMenu.Choice) -> Void = { _ in }
        /// Escape with nothing running: the files take the keys.
        var giveKeysBack: @MainActor () -> Void = {}
        /// The caret goes to the composer, as after a suggestion fills it.
        var focusComposer: @MainActor () -> Void = {}
        /// The phase changed, so the header's spark can show whether a request is running.
        var phaseChanged: @MainActor (Phase) -> Void = { _ in }
    }

    /// One folder of the folders row.
    struct Chip: Identifiable, Equatable {
        let id: String
        let label: String
        let kind: StorageKind
        let symbol: String
        /// The path in words, then the place line when the folder isn't simply on this Mac.
        let tooltip: String
        let placeLine: String
        /// Shared, Read-only, Not responding.
        let marks: [String]
        /// Added folders can be taken off; the tab's folder can't.
        let removable: Bool
    }

    /// The button some of Helm's own lines carry.
    enum LineButton: Equatable {
        case openSettings, tryAgain, connect(ServerLocation)
        var title: String {
            switch self {
            case .openSettings: return AgentText.openSettings
            case .tryAgain: return AgentText.tryAgain
            case .connect: return AgentText.connect
            }
        }
    }

    /// What an applied plan did, with Undo and Show.
    struct Outcome: Equatable {
        var lines: [String]
        var group: HistoryGroup?
        var changed: [URL]
        var canUndo: Bool
        var undoLine: String?
    }

    /// One entry of the thread.
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable {
            /// What is sent and where: always the thread's first line.
            case consent(String)
            /// What the person asked, as they typed it or as the suggestion read.
            case request(String)
            /// The model's words, escaped and shown as plain text.
            case reply(String)
            /// One of Helm's own lines, drawn with the spark and in a style a reply never gets.
            case helm(String, button: LineButton?)
            case plan(AgentPlanCard)
            case outcome(Outcome)
        }
        let id: Int
        var kind: Kind
    }

    @Published private(set) var chips: [Chip] = []
    @Published private(set) var suggestions: [AgentSuggestion] = []
    /// What the panel says in place of the suggestions: no folder, a refused folder, or an empty folder.
    @Published private(set) var restingLine: String?
    @Published private(set) var lines: [Line] = []
    /// What a running request is doing now. It goes away when the request ends.
    @Published private(set) var status: String?
    @Published private(set) var composerText = ""
    @Published private(set) var provider: Provider
    /// What the model's name under the composer offers, as the window last worked it out.
    @Published private(set) var modelMenu = AgentModelMenu.empty
    /// This Folder or Whole Mac, for the thread on show. A new thread starts in This Folder.
    @Published private(set) var scopeMode: AgentScopeMode = .thisFolder
    /// The switch is changing the thread's folders. Nothing is sent until it has.
    @Published private(set) var scopeChanging = false
    /// Read contents, for the thread on show. A new thread starts with it off.
    @Published private(set) var readsContents = false
    /// The switch beside the composer is changing the thread. Nothing is sent until it has.
    @Published private(set) var contentsChanging = false
    /// Whether this run can read inside files, so the switch beside the composer shows.
    let offersReadContents: Bool

    let session: any AgentConversing
    var actions: Actions
    /// Tells the composer's text view about text the panel put there itself, and where the caret goes.
    var composerSet: ((String, Int) -> Void)?

    private let home: String
    /// The home folder the panel was given, for the place test on a dragged item's path.
    var homePath: String { home }
    private var caret = 0
    private var tab = TabContext(folder: nil, itemCount: 0, selectedPaths: [])
    private var tabRoot: AgentScopeRoot?
    private var tabRefused = false
    private var tabGeneration = 0
    private var requestOpen = false
    private var applying = false
    private var undoing = false
    private var pendingWork = 0
    private var settled: Phase = .idle
    private var stopAsked = false
    /// Stop was pressed while a plan applied. The applier looks before each command and stops there.
    private(set) var applyStopAsked = false
    /// The request line of the request that is open, so its trace line can follow it.
    private var requestLineID: Int?
    /// The last message sent, for Try Again.
    private var lastInput: AgentPersonInput?
    private var lastShown: String?
    private var nextLineID = 0
    private var noticeTask: Task<Void, Never>?

    init(session: any AgentConversing, home: String, provider: Provider, actions: Actions = Actions(),
         offersReadContents: Bool = false) {
        self.session = session
        self.home = home
        self.provider = provider
        self.actions = actions
        self.offersReadContents = offersReadContents
        lines = [Line(id: 0, kind: .consent(Self.consentLine(provider, .thisFolder, readsContents: false)))]
        nextLineID = 1
        noticeTask = Task { [weak self, notices = session.notices] in
            for await notice in notices {
                guard let self else { return }
                self.handle(notice)
            }
        }
    }

    /// A panel over a conversation with no model behind it.
    public convenience init() {
        self.init(session: StandInConversation(), home: "/home/helm",
                  provider: Provider(name: "Claude", destination: "Claude", model: ""))
    }

    /// The panel is going away: the window closed, or AI mode turned off. A running request stops.
    func close() {
        noticeTask?.cancel()
        if requestOpen { Task { [session] in await session.stop() } }
    }

    // MARK: What the person does

    /// Puts text in the composer, as typing it would, with the caret at its end.
    public func type(_ text: String) { setComposer(text, caret: (text as NSString).length) }

    /// Sends what the composer holds.
    public func send() { submit() }

    /// A button, a suggestion, a depth of the Organize menu, a slash row, or a chip's remove button, by its title.
    public func press(_ title: String) {
        if let suggestion = suggestions.first(where: { $0.title == title }) {
            choose(suggestion, depth: .thisFolder)
            return
        }
        if let depth = Self.depths.first(where: { $0.title == title })?.depth,
           let organize = suggestions.first(where: { $0.kind == .organize }) {
            choose(organize, depth: depth)
            return
        }
        if let chip = chips.first(where: { $0.removable && AgentText.chipRemove($0.label) == title }) {
            remove(chip)
            return
        }
        if let row = slashRows.first(where: { $0.title == title }) {
            type(row.fill)
            return
        }
        switch title {
        case AgentText.apply: applyOpenCard()
        case AgentText.cancel: dismissOpenCard()
        case AgentText.undo: undoLatest()
        case AgentText.show: showLatest()
        case AgentText.send: send()
        case AgentText.stop: stop()
        case AgentText.modelMenuSettings: actions.openSettings()
        default: pressLineButton(title)
        }
    }

    /// Ticks or unticks a group of the card that waits, by its title.
    public func tick(_ groupTitle: String) {
        guard let index = openCardIndex, case .plan(var card) = lines[index].kind,
              let group = card.groupRows.first(where: { $0.title == groupTitle }) else { return }
        card.toggle(group.id)
        lines[index].kind = .plan(card)
    }

    /// Opens or shuts a group of the card that waits, by its title, as its chevron does.
    public func toggleOpen(_ groupTitle: String) {
        guard let index = openCardIndex, case .plan(var card) = lines[index].kind,
              let group = card.groupRows.first(where: { $0.title == groupTitle }) else { return }
        card.toggleOpen(group.id)
        lines[index].kind = .plan(card)
    }

    func tick(group id: Int, card lineID: Int) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }), case .plan(var card) = lines[index].kind else { return }
        card.toggle(id)
        lines[index].kind = .plan(card)
    }

    func toggleOpen(group id: Int, card lineID: Int) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }), case .plan(var card) = lines[index].kind else { return }
        card.toggleOpen(id)
        lines[index].kind = .plan(card)
    }

    /// A folder dropped on the panel. It is added to the folders AI mode can use and is never moved. When the
    /// composer holds a sentence, the folder's path goes in at the caret, so the sentence can end in it.
    public func drop(_ folder: URL) {
        let path = folder.path
        if !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = composerText as NSString
            let at = min(max(0, caret), text.length)
            setComposer(text.replacingCharacters(in: NSRange(location: at, length: 0), with: path),
                        caret: at + (path as NSString).length)
        }
        addFolder(path, origin: .dropped)
    }

    /// "escape" or "return", as the composer would get it. Return sends and never presses Apply; Escape stops a
    /// request, cancels a plan that waits, as a sheet's Cancel does, or gives the keys back to the files.
    public func key(_ name: String) {
        switch name {
        case "return": send()
        case "escape":
            if requestOpen { stop() } else if openCardIndex != nil { dismissOpenCard() } else { actions.giveKeysBack() }
        default: break
        }
    }

    /// Command-Return: Apply on the card that waits, unless it was refreshed and nobody has looked at it since.
    func commandReturn() {
        guard openCard?.holdsKeyedApply != true else { return }
        applyOpenCard()
    }

    /// The composer's text changed as the person typed.
    func composerEdited(_ text: String, caret: Int) {
        composerText = text
        self.caret = caret
    }

    func caretMoved(to location: Int) { caret = location }

    func pressButton(_ button: LineButton, line id: Int) {
        guard let index = lines.firstIndex(where: { $0.id == id }), case .helm(let text, let current) = lines[index].kind,
              current == button else { return }
        run(button, line: index, text: text)
    }

    func remove(_ chip: Chip) {
        guard chip.removable else { return }
        work { model in
            await model.session.removeRoot(alias: chip.id)
            await model.followScope()
        }
    }

    func choose(_ suggestion: AgentSuggestion, depth: AgentOrganizeDepth) {
        guard !requestOpen, !applying, !scopeChanging, !contentsChanging, suggestions.contains(suggestion), let root = tabRoot else { return }
        if suggestion.runsAtOnce {
            let message = AgentSuggestions.message(for: suggestion, depth: depth, root: root.alias)
            begin(AgentPersonInput(typedByPerson: message, selectedPaths: tab.selectedPaths, asksForChanges: true), shown: suggestion.title)
        } else {
            type(AgentSuggestions.composerText(for: suggestion))
            actions.focusComposer()
        }
    }

    /// The switch at the end of the folders row. Either half starts a new thread, as a change of provider does, so
    /// names listed under one scope are never sent under the other. Never while a request, an Apply or an Undo runs.
    public func chooseScope(_ next: AgentScopeMode) {
        guard next != scopeMode, canChooseScope else { return }
        scopeMode = next
        scopeChanging = true
        work { model in
            await model.session.setScopeMode(next)
            await model.followScope()
            model.scopeChanging = false
        }
    }

    /// Whether the switch can be pressed now.
    var canChooseScope: Bool { !requestOpen && !applying && !undoing && !scopeChanging && !contentsChanging }

    /// The Read contents switch beside the composer. On hands the conversation the person's permit; either way the
    /// thread starts over, as the scope switch does, so a thread's tools never change inside it. Never while a
    /// request, an Apply or an Undo runs.
    public func chooseReadsContents(_ on: Bool) {
        guard offersReadContents, on != readsContents, canChooseScope else { return }
        readsContents = on
        contentsChanging = true
        let permit = on ? AgentContentPermit(switchedOnByPerson: .panel) : nil
        work { model in
            await model.session.setReadsContents(permit)
            await model.followScope()
            model.contentsChanging = false
        }
    }

    func applyCard(line id: Int) {
        guard openCardIndex.map({ lines[$0].id }) == id else { return }
        applyOpenCard()
    }

    func dismissCard(line id: Int) {
        guard openCardIndex.map({ lines[$0].id }) == id else { return }
        dismissOpenCard()
    }

    func undo(line id: Int) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        undo(at: index)
    }

    func show(line id: Int) {
        guard let index = lines.firstIndex(where: { $0.id == id }), case .outcome(let outcome) = lines[index].kind else { return }
        actions.show(outcome.changed)
    }

    // MARK: What the window tells the panel

    /// The tab in front, after every render. A new folder is handed to the conversation, which says whether it can
    /// be used; a new selection or item count only changes the suggestions.
    func update(tab next: TabContext) {
        guard next != tab else { return }
        let folderChanged = next.folder != tab.folder
        tab = next
        if folderChanged { refreshTabFolder() } else { recomputePhase() }
    }

    func providerChanged(_ next: Provider) { provider = next }

    /// The providers and models on offer changed: a check answered, a key went, or another model was chosen.
    func modelMenuChanged(_ next: AgentModelMenu) {
        if next != modelMenu { modelMenu = next }
    }

    /// A model from the menu under the composer. Another provider starts a new thread, as any change of provider does.
    func chooseModel(_ choice: AgentModelMenu.Choice) {
        guard choice != modelMenu.current else { return }
        actions.chooseModel(choice)
    }

    /// What the conversation answered when Apply asked to go ahead, when it wasn't a go.
    func applyAnswered(planID: UUID, _ ticket: AgentApplyTicket) {
        guard let index = cardIndex(of: planID), case .plan(var card) = lines[index].kind else { return }
        switch ticket {
        case .go:
            return
        case .changed(let plan):
            card.refresh(with: plan)
        case .notResponding(let label):
            card.stage = .open
            append(.helm(AgentText.noticeNotResponding(label), button: nil))
        case .disconnected(let label):
            card.stage = .open
            append(.helm(AgentText.noticeDisconnected(label), button: nil))
        case .refused:
            card.stage = .dismissed
        }
        lines[index].kind = .plan(card)
    }

    /// How far Apply has got.
    func applyProgress(planID: UUID, done: Int, total: Int, name: String) {
        guard !applyStopAsked, let index = cardIndex(of: planID), case .plan(var card) = lines[index].kind,
              case .applying = card.stage else { return }
        let step = min(total, done + 1)
        let line: String
        switch card.plan.title {
        case .copy: line = AgentText.applyCopying(done: step, total: total, name: name)
        case .rename: line = AgentText.applyRenaming(done: step, total: total, name: name)
        case .organize, .move, .trash: line = AgentText.applyMoving(done: step, total: total, name: name)
        }
        card.stage = .applying(line)
        lines[index].kind = .plan(card)
    }

    // MARK: Readers

    public var phaseForTesting: String { phase.rawValue }
    /// The conversation the panel talks to.
    public var sessionForTesting: any AgentConversing { session }
    /// The folders row, each as "label:kind", such as "Documents:thisMac". The places Whole Mac adds are one chip,
    /// "Whole Mac:thisMac".
    public var chipsForTesting: [String] { chips.map { "\($0.label):\($0.kind.rawValue)" } }
    /// "thisFolder" or "wholeMac", as the switch shows it.
    public var scopeForTesting: String { scopeMode.rawValue }
    /// "on" or "off", as the Read contents switch shows it.
    public var readsContentsForTesting: String { readsContents ? "on" : "off" }
    /// Each chip's place line, by its label. A folder on this Mac has none.
    public var chipKindsForTesting: [String: String] {
        Dictionary(chips.map { ($0.label, $0.placeLine) }, uniquingKeysWith: { first, _ in first })
    }
    public var suggestionsForTesting: [String] { suggestions.map(\.title) }
    /// The menu under the composer as words: "Claude: *claude-opus-5-5,claude-haiku-5 | LM Studio: qwen-9b", or
    /// "none" when the name is a plain name that opens Settings.
    public var modelMenuForTesting: String { modelMenu.isMenu ? modelMenu.summaryForTesting : "none" }
    /// Chooses a model from the menu under the composer by its provider's name and its own: "LM Studio/qwen-9b".
    /// False when the menu has no such row.
    @discardableResult public func chooseModelForTesting(_ row: String) -> Bool {
        let bits = row.split(separator: "/", maxSplits: 1).map(String.init)
        guard bits.count == 2, let group = modelMenu.providers.first(where: { $0.name == bits[0] }),
              group.models.contains(bits[1]) else { return false }
        chooseModel(AgentModelMenu.Choice(provider: group.provider, model: bits[1]))
        return true
    }
    /// Every line of the thread, and what a running request is doing, one per line.
    public var threadTextForTesting: String {
        var text: [String] = []
        for line in lines {
            switch line.kind {
            case .consent(let words), .request(let words), .reply(let words): text.append(words)
            case .helm(let words, _): text.append(words)
            case .plan(let card): text += card.textLines
            case .outcome(let outcome): text += outcome.lines + [outcome.undoLine].compactMap { $0 }
            }
        }
        if let restingLine { text.append(restingLine) }
        if let status { text.append(status) }
        return text.joined(separator: "\n")
    }
    public var planCountsForTesting: String? { openCard?.countsLine }
    /// Each group as "title:on" or "title:off", with its mark after another colon when it has one.
    public var groupsForTesting: [String] {
        (openCard ?? latestCard)?.groupRows.map { group in
            "\(group.title):\(group.isOn ? "on" : "off")" + (group.mark.map { ":\($0)" } ?? "")
        } ?? []
    }
    /// Where each group of moves or copies goes, as its title, "=", the whole path and " new folder" when the plan
    /// makes it: "Move 2 items to “Images”=~/AgentMess/Images new folder".
    public var groupPathsForTesting: [String] {
        (openCard ?? latestCard)?.groupRows.compactMap { group in
            group.destination.map { "\(group.title)=\($0.whole)" + ($0.isNew ? " " + AgentText.pathNewFolder : "") }
        } ?? []
    }
    /// Whether a request, an Apply or an Undo is still running, or the panel is still asking about a folder.
    public var isWaitingForTesting: Bool { requestOpen || applying || undoing || pendingWork > 0 }

    /// The notes of the card that waits, or of the latest card.
    var notesForTesting: [String] { (openCard ?? latestCard)?.notes.map(\.text) ?? [] }
    var composerTextForTesting: String { composerText }

    var isWorking: Bool { requestOpen || applying }
    /// Send reads Stop and stays pressable while a request or an Apply runs.
    var showsStop: Bool { phase == .working || phase == .applying }
    var canSend: Bool { !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !applying }

    /// A command offered while the composer holds only the start of one, and what choosing it types.
    struct SlashRow: Hashable {
        let title: String
        let fill: String
    }

    /// A row of the Organize suggestion's menu.
    struct DepthRow: Hashable {
        let title: String
        let depth: AgentOrganizeDepth
    }

    var slashRows: [SlashRow] {
        guard composerText.hasPrefix("/"), !composerText.contains(where: { $0.isWhitespace }) else { return [] }
        let typed = composerText.lowercased()
        return [SlashRow(title: AgentText.slashAdd, fill: "/add "), SlashRow(title: AgentText.slashClear, fill: "/clear")]
            .filter { $0.fill.hasPrefix(typed) }
    }

    static let depths = [DepthRow(title: AgentText.depthThisFolder, depth: .thisFolder),
                         DepthRow(title: AgentText.depthTwoLevels, depth: .twoLevels),
                         DepthRow(title: AgentText.depthAllLevels, depth: .allLevels)]

    // MARK: Sending

    private func submit() {
        guard !requestOpen, !applying, !scopeChanging, !contentsChanging else { return }
        let typed = composerText
        switch AgentComposerIntent.parse(typed) {
        case .empty:
            return
        case .looksLikeKey:
            // A key is never sent and never kept in the thread.
            setComposer("", caret: 0)
            append(.helm(AgentText.composerLooksLikeKey, button: .openSettings))
        case .unknownCommand:
            setComposer("", caret: 0)
            append(.helm(AgentText.addNotFound, button: nil))
        case .clear:
            setComposer("", caret: 0)
            work { model in
                await model.session.clear()
                model.startOver()
                await model.followScope()
            }
        case .add(let path):
            setComposer("", caret: 0)
            addFolder(path, origin: .typed, typed: typed)
        case .connect(let location):
            // Helm only offers the address to macOS, and only once the person presses Connect. Nothing is added.
            setComposer("", caret: 0)
            append(.helm(AgentText.serverConfirm(location.host), button: .connect(location)))
        case .message(let message, let candidates):
            setComposer("", caret: 0)
            send(message, typed: typed, candidates: candidates)
        }
    }

    /// A message that may end in a folder. The folder is added first, through the same rules as /add, and the
    /// message goes with the folder's id in place of its path. A full stop or the like after the path is tried
    /// without it too. When the message ends in a path and no reading of it is a folder that can be used, the usual
    /// line says why and nothing is sent. A path typed mid-sentence that names nothing Helm could add is part of the
    /// sentence, so the message goes as typed; one that reaches a folder Helm refuses still stops it.
    private func send(_ message: String, typed: String, candidates: [AgentTrailingPath]) {
        guard !candidates.isEmpty else {
            begin(AgentPersonInput(typedByPerson: message, selectedPaths: tab.selectedPaths), shown: message)
            return
        }
        requestOpen = true
        stopAsked = false
        recomputePhase()
        Task { [weak self] in
            guard let self else { return }
            var missing: AgentScopeRefusal?
            var refused: AgentScopeRefusal?
            for candidate in candidates {
                for path in Self.readings(of: candidate.path) {
                    let answer = await self.session.folder(for: AgentRootInput(fromPerson: path, origin: .typed))
                    if let id = answer.modelID {
                        if case .added(let root) = answer { self.append(.helm(AgentText.addAdded(root.label), button: nil)) }
                        await self.refreshRoots()
                        // Stop or Escape while the folder was looked up: the message never goes.
                        if self.stopAsked { self.endStoppedLookup(); return }
                        let input = AgentPersonInput(typedByPerson: candidate.prefix + id, selectedPaths: self.tab.selectedPaths)
                        self.requestOpen = false
                        self.begin(input, shown: message)
                        return
                    }
                    if case .refused(let reason) = answer {
                        if Self.namesNothing(reason) { missing = missing ?? reason } else { refused = refused ?? reason }
                    }
                    if self.stopAsked { self.endStoppedLookup(); return }
                }
            }
            let endsInPath = candidates.last.map { !$0.path.contains(where: \.isWhitespace) } ?? false
            if refused == nil, !endsInPath {
                self.requestOpen = false
                self.begin(AgentPersonInput(typedByPerson: message, selectedPaths: self.tab.selectedPaths), shown: message)
                return
            }
            self.append(.helm(Self.refusalLine(refused ?? missing), button: nil))
            // What they typed comes back, so the path can be put right.
            if self.composerText.isEmpty { self.setComposer(typed, caret: (typed as NSString).length) }
            self.requestOpen = false
            self.recomputePhase()
        }
    }

    /// A path as typed, then without the full stop, comma or the like that ends a sentence after it.
    private static func readings(of path: String) -> [String] {
        var trimmed = Substring(path)
        while let last = trimmed.last, sentenceEnds.contains(last) { trimmed = trimmed.dropLast() }
        return trimmed.isEmpty || trimmed.count == path.count ? [path] : [path, String(trimmed)]
    }
    private static let sentenceEnds: Set<Character> = [".", ",", ";", ":", "!", "?", "\u{2026}"]

    /// Nothing Helm could add is at the path: it isn't there, it isn't a folder, or it isn't a path at all.
    private static func namesNothing(_ reason: AgentScopeRefusal) -> Bool {
        switch reason {
        case .notFound, .badText, .notAFolder: return true
        case .system, .hidden, .insidePackage, .full, .notResponding: return false
        }
    }

    /// A message stopped before it was sent, while the folder it ends in was looked up.
    private func endStoppedLookup() {
        status = nil
        append(.helm(AgentText.noticeStopped, button: nil))
        requestOpen = false
        settled = .idle
        recomputePhase()
    }

    /// Starts a request and follows it to its end.
    private func begin(_ input: AgentPersonInput, shown: String) {
        guard !requestOpen else { return }
        requestOpen = true
        stopAsked = false
        lastInput = input
        lastShown = shown
        append(.request(shown))
        requestLineID = lines.last?.id
        recomputePhase()
        Task { [weak self] in
            guard let self else { return }
            var failure: AgentFailure?
            var saidStopped = false
            for await event in self.session.send(input) {
                switch event {
                case .status(let status):
                    self.status = Self.words(for: status)
                case .trace(.sent(let names, let destination)):
                    // Right under its request, so it never reads as something sent after the plan.
                    self.insertAfterRequest(.helm(AgentText.traceSent(names: names, destination: destination), button: nil))
                case .trace(.sentWithSummaries(let names, let summaries, let destination)):
                    self.insertAfterRequest(.helm(AgentText.traceSentSummaries(names: names, summaries: summaries,
                                                                               destination: destination), button: nil))
                case .reply(let text):
                    self.append(.reply(Self.shownReply(text)))
                case .plan(let plan):
                    let roots = await self.session.roots()
                    let card = AgentPlanCard(plan: plan, roots: roots, home: self.home)
                    for index in self.lines.indices {
                        if case .plan(var older) = self.lines[index].kind, older.stage == .open {
                            older.stage = plan.isEmpty ? .dismissed : .replaced
                            self.lines[index].kind = .plan(older)
                        }
                    }
                    if plan.isEmpty {
                        // Nothing to apply: what the plan would say shows alone, as Helm's own line, with no card.
                        for note in card.notes { self.append(.helm(note.text, button: nil)) }
                        let id = plan.id
                        self.work { model in await model.session.settle(planID: id, .dismissed) }
                    } else {
                        self.append(.plan(card))
                    }
                case .notice(let notice):
                    if notice == .stopped { saidStopped = true }
                    self.handle(notice)
                case .failed(let reason):
                    if reason == .cancelled {
                        if !saidStopped { self.append(.helm(AgentText.noticeStopped, button: nil)) }
                        saidStopped = true
                    } else if let line = self.failureLine(reason) {
                        failure = reason
                        self.append(.helm(line.text, button: line.button))
                    }
                case .finished:
                    break
                }
            }
            self.status = nil
            if self.stopAsked, !saidStopped { self.append(.helm(AgentText.noticeStopped, button: nil)) }
            self.requestOpen = false
            self.requestLineID = nil
            self.settled = failure == nil ? .idle : .failed
            self.recomputePhase()
            await self.refreshRoots()
        }
    }

    /// Stops the request, or the Apply, that is running. An Apply stops before its next command, so what is done
    /// stays done and the result says how far it got.
    private func stop() {
        if applying {
            guard !applyStopAsked else { return }
            applyStopAsked = true
            if let index = lines.lastIndex(where: { if case .plan(let card) = $0.kind, case .applying = card.stage { return true }; return false }),
               case .plan(var card) = lines[index].kind {
                card.stage = .applying(AgentText.statusStopping)
                lines[index].kind = .plan(card)
            }
            return
        }
        guard requestOpen, !stopAsked else { return }
        stopAsked = true
        status = AgentText.statusStopping
        Task { [session] in await session.stop() }
    }

    /// `typed` is what the person typed for a /add: a folder Helm turns away gives it back, so a typo can be put right.
    private func addFolder(_ text: String, origin: AgentRootInput.Origin, typed: String? = nil) {
        work { model in
            let answer = await model.session.folder(for: AgentRootInput(fromPerson: text, origin: origin))
            switch answer {
            case .added(let root): model.append(.helm(AgentText.addAdded(root.label), button: nil))
            case .root(let root): model.append(.helm(AgentText.addAlready(root.label), button: nil))
            case .inside(_, let name): model.append(.helm(AgentText.addAlready(name), button: nil))
            case .refused(let reason):
                model.append(.helm(Self.refusalLine(reason), button: nil))
                if let typed, model.composerText.isEmpty { model.setComposer(typed, caret: (typed as NSString).length) }
            }
            await model.refreshRoots()
        }
    }

    private func pressLineButton(_ title: String) {
        guard let index = lines.lastIndex(where: {
            if case .helm(_, let button?) = $0.kind { return button.title == title }
            return false
        }), case .helm(let text, let button?) = lines[index].kind else { return }
        run(button, line: index, text: text)
    }

    private func run(_ button: LineButton, line index: Int, text: String) {
        switch button {
        case .openSettings:
            actions.openSettings()
        case .tryAgain:
            // As Send is: never while a request, an Apply or an Undo runs.
            guard let input = lastInput, let shown = lastShown, !requestOpen, !applying, !undoing else { return }
            lines[index].kind = .helm(text, button: nil)
            begin(input, shown: shown)
        case .connect(let location):
            // Once only: the address goes to macOS, and Helm adds nothing afterwards.
            lines[index].kind = .helm(text, button: nil)
            _ = actions.connect(location)
        }
    }

    // MARK: Plans

    private var openCardIndex: Int? {
        lines.lastIndex { if case .plan(let card) = $0.kind { return card.stage == .open }; return false }
    }
    private var openCard: AgentPlanCard? {
        guard let index = openCardIndex, case .plan(let card) = lines[index].kind else { return nil }
        return card
    }
    private var latestCard: AgentPlanCard? {
        for line in lines.reversed() { if case .plan(let card) = line.kind { return card } }
        return nil
    }
    private func cardIndex(of planID: UUID) -> Int? {
        lines.lastIndex { if case .plan(let card) = $0.kind { return card.plan.id == planID }; return false }
    }

    private func applyOpenCard() {
        guard !requestOpen, !applying, let index = openCardIndex, case .plan(var card) = lines[index].kind, card.canApply else { return }
        let approval = card.approval()
        let plan = card.plan, ticked = card.ticked
        // A line at once, before the first change reports in.
        card.stage = .applying(AgentText.statusCheckingPlan)
        lines[index].kind = .plan(card)
        applying = true
        applyStopAsked = false
        recomputePhase()
        Task { [weak self] in
            guard let self else { return }
            let report = await self.actions.apply(approval)
            self.applying = false
            self.applyStopAsked = false
            if let report { self.finish(plan, ticked: ticked, report: report) }
            self.recomputePhase()
        }
    }

    private func finish(_ plan: AgentChangePlan, ticked: Set<Int>, report: AgentApplyReport) {
        if let index = cardIndex(of: plan.id), case .plan(var card) = lines[index].kind {
            card.stage = .applied
            lines[index].kind = .plan(card)
        }
        var words = [Self.summary(of: plan, ticked: ticked, report: report)]
        words += report.trashFailed.map(AgentText.trashFailed)
        append(.outcome(Outcome(lines: words, group: report.group, changed: report.changed,
                                canUndo: report.group != nil && report.done > 0, undoLine: nil)))
        settled = .result
    }

    private static func summary(of plan: AgentChangePlan, ticked: Set<Int>, report: AgentApplyReport) -> String {
        if report.stoppedEarly { return AgentText.resultStopped(done: report.done, total: report.total) }
        if report.skipped > 0 { return AgentText.resultPartial(done: report.done, total: report.total, skipped: report.skipped) }
        let counts = plan.counts(ticked: ticked)
        switch plan.title {
        case .organize:
            if counts.moves > 0 { return AgentText.resultOrganized(items: counts.moves, folders: destinations(of: plan, ticked: ticked)) }
            if counts.renames > 0 { return AgentText.resultRenamed(counts.renames) }
            if counts.copies > 0 { return AgentText.resultCopied(counts.copies) }
            if counts.trash == 0, counts.newFolders > 0 { return AgentText.resultMadeFolders(counts.newFolders) }
            return AgentText.resultTrashed(counts.trash)
        case .move: return AgentText.resultMoved(counts.moves)
        case .copy: return AgentText.resultCopied(counts.copies)
        case .rename: return AgentText.resultRenamed(counts.renames)
        case .trash: return AgentText.resultTrashed(counts.trash)
        }
    }

    /// The folders the ticked moves go into.
    private static func destinations(of plan: AgentChangePlan, ticked: Set<Int>) -> Int {
        var targets: Set<AgentPlanTarget> = []
        for group in plan.groups where ticked.contains(group.id) {
            for index in group.steps where plan.steps.indices.contains(index) {
                if case .move(_, let target) = plan.steps[index] { targets.insert(target) }
            }
        }
        return targets.count
    }

    private func dismissOpenCard() {
        guard !applying, let index = openCardIndex, case .plan(var card) = lines[index].kind else { return }
        card.stage = .dismissed
        lines[index].kind = .plan(card)
        settled = .idle
        recomputePhase()
        let id = card.plan.id
        work { model in await model.session.settle(planID: id, .dismissed) }
    }

    private func undoLatest() {
        guard let index = lines.lastIndex(where: { if case .outcome(let outcome) = $0.kind { return outcome.canUndo }; return false })
        else { return }
        undo(at: index)
    }

    private func undo(at index: Int) {
        guard !undoing, !applying, !requestOpen, case .outcome(var outcome) = lines[index].kind, outcome.canUndo,
              let group = outcome.group else { return }
        undoing = true
        outcome.canUndo = false
        lines[index].kind = .outcome(outcome)
        let id = lines[index].id
        Task { [weak self] in
            guard let self else { return }
            let undone = await self.actions.undo(group.id)
            self.undoing = false
            if let at = self.lines.firstIndex(where: { $0.id == id }), case .outcome(var outcome) = self.lines[at].kind {
                outcome.undoLine = undone ? AgentText.undoDone : AgentText.undoRefused
                // What changed is back where it was, so there is nothing left to show.
                if undone { outcome.changed = [] }
                self.lines[at].kind = .outcome(outcome)
            }
            self.recomputePhase()
        }
    }

    private func showLatest() {
        guard let line = lines.last(where: { if case .outcome = $0.kind { return true }; return false }),
              case .outcome(let outcome) = line.kind, !outcome.changed.isEmpty else { return }
        actions.show(outcome.changed)
    }

    // MARK: Folders

    private func refreshTabFolder() {
        tabGeneration += 1
        let generation = tabGeneration
        let input = tab.folder.map { AgentRootInput(fromPerson: $0, origin: .tab) }
        work { model in
            let answer = await model.session.setTabFolder(input)
            guard model.tabGeneration == generation else { return }
            switch answer {
            case .none: model.tabRoot = nil; model.tabRefused = false
            case .root(let root): model.tabRoot = root; model.tabRefused = false
            case .refused: model.tabRoot = nil; model.tabRefused = true
            }
            await model.refreshRoots()
        }
    }

    /// One chip a folder, but the places Whole Mac adds share one chip, where the first of them is.
    private func refreshRoots() async {
        let roots = await session.roots()
        var next: [Chip] = []
        for root in roots {
            if !root.isWholeMac {
                next.append(chip(root))
            } else if !next.contains(where: { $0.id == Self.wholeMacChipID }) {
                next.append(Chip(id: Self.wholeMacChipID, label: AgentText.scopeWholeMac, kind: .thisMac, symbol: "laptopcomputer",
                                 tooltip: AgentText.chipWholeMac, placeLine: "", marks: [], removable: false))
            }
        }
        chips = next
        recomputePhase()
    }

    /// The Whole Mac chip's id, which no root's alias can be.
    private static let wholeMacChipID = "whole-mac"

    /// After a new thread: the switches show the conversation's scope and whether it reads contents, the consent
    /// line says what it sends, and the folders row shows its folders.
    private func followScope() async {
        let mode = await session.scopeMode()
        if mode != scopeMode { scopeMode = mode }
        let reads = await session.readsContents()
        if reads != readsContents { readsContents = reads }
        if let first = lines.first, case .consent = first.kind {
            let line = Self.consentLine(provider, scopeMode, readsContents: readsContents)
            if first.kind != .consent(line) { lines[0].kind = .consent(line) }
        }
        await refreshRoots()
    }

    /// The thread's first line: what is sent and where, and, in Whole Mac, that it comes from the home folder. With
    /// Read contents on it says that contents are read: for a model on this Mac, that nothing leaves the Mac, and for
    /// any other, that short summaries of them are sent.
    static func consentLine(_ provider: Provider, _ mode: AgentScopeMode, readsContents: Bool) -> String {
        switch (readsContents, mode, provider.isLocal) {
        case (false, .wholeMac, _): return AgentText.consentWholeMac(provider.destination)
        case (false, .thisFolder, _): return AgentText.consent(provider.destination)
        case (true, .thisFolder, true): return AgentText.consentContentsOnThisMac
        case (true, .thisFolder, false): return AgentText.consentContents(provider.destination)
        case (true, .wholeMac, true): return AgentText.consentContentsWholeMacOnThisMac
        case (true, .wholeMac, false): return AgentText.consentContentsWholeMac(provider.destination)
        }
    }

    private func chip(_ root: AgentScopeRoot) -> Chip {
        let words = AgentItemFilter.placeWords(path: root.path, home: home, storage: root.storage)
        let path = words.isEmpty ? root.label : words.joined(separator: " / ")
        let place = Self.placeLine(root.storage)
        var marks: [String] = []
        if root.storage.shared == .yes || root.storage.kind == .network { marks.append(AgentText.chipShared) }
        if root.storage.isReadOnly { marks.append(AgentText.chipReadOnly) }
        if !root.storage.isResponding { marks.append(AgentText.chipNotResponding) }
        let tooltip = ([AgentTextEscaper.escape(path), place] + marks).filter { !$0.isEmpty }.joined(separator: "\n")
        // The label is the folder's own name from the disk, so it is shown escaped, as every other disk name is.
        return Chip(id: root.alias, label: AgentTextEscaper.escape(root.label), kind: root.storage.kind, symbol: root.storage.symbolName,
                    tooltip: tooltip, placeLine: place, marks: marks, removable: !root.isTabFolder)
    }

    /// The second line of a chip's tooltip: the kind of place, from fixed words.
    static func placeLine(_ storage: StorageFacts) -> String {
        switch storage.kind {
        case .thisMac: return ""
        case .iCloud: return AgentText.chipInICloud
        case .cloud:
            return StorageClassifier.knownProviders.contains(storage.name) ? AgentText.chipInProvider(storage.name) : AgentText.chipInCloudFolder
        case .network: return AgentText.chipOnServer
        case .external: return AgentText.chipOnExternal
        }
    }

    private static func refusalLine(_ reason: AgentScopeRefusal?) -> String {
        switch reason {
        case .full?: return AgentText.addFull
        case .notFound?, .badText?, nil: return AgentText.addNotFound
        case .notAFolder?, .system?, .hidden?, .insidePackage?, .notResponding?: return AgentText.addRefused
        }
    }

    // MARK: Notices and failures

    private func handle(_ notice: AgentNotice) {
        switch notice {
        case .startedOver:
            startOver()
            // A new thread is in This Folder unless the switch made it, or a long one carried on in Whole Mac.
            work { model in await model.followScope() }
        case .stopped: append(.helm(AgentText.noticeStopped, button: nil))
        case .limitReached: append(.helm(AgentText.failTooLarge, button: nil))
        case .foldersNotLoaded(let count): append(.helm(AgentText.noticeFoldersNotLoaded(count), button: nil))
        case .notResponding(let label): append(.helm(AgentText.noticeNotResponding(label), button: nil))
        case .disconnected(let label): append(.helm(AgentText.noticeDisconnected(label), button: nil))
        case .notDownloadedNotRead(let count): append(.helm(AgentText.noticeNotDownloadedNotRead(count), button: nil))
        }
    }

    /// A new thread: the consent line, naming where requests go now, and one line saying the old one ended. A
    /// request that is running stays on show under them.
    private func startOver() {
        var fresh = [Line.Kind.consent(Self.consentLine(provider, scopeMode, readsContents: readsContents)),
                     .helm(AgentText.noticeStartedOver, button: nil)]
        if requestOpen, let lastShown { fresh.append(.request(lastShown)) }
        // Said once, however many parts of Helm report the same start.
        guard lines.map(\.kind) != fresh else { return }
        lines = []
        for kind in fresh { append(kind) }
        settled = .idle
        recomputePhase()
    }

    private func failureLine(_ failure: AgentFailure) -> (text: String, button: LineButton?)? {
        let name = provider.name
        switch failure {
        case .noKey: return (AgentText.failNoKey(name), .openSettings)
        case .keyDenied: return (AgentText.failKeyDenied, .tryAgain)
        case .wrongKey: return (AgentText.failWrongKey, .openSettings)
        case .outOfCredit: return (AgentText.failOutOfCredit(name), nil)
        case .rateLimited, .overloaded: return (AgentText.failBusy(name), .tryAgain)
        case .noSuchModel: return (AgentText.failNoSuchModel(name), .openSettings)
        case .noTools: return (AgentText.failNoTools, nil)
        case .badRequest, .unreadable: return (AgentText.failUnreadable, .tryAgain)
        case .tooLarge: return (AgentText.failTooLarge, nil)
        case .unreachable, .timedOut: return (AgentText.failUnreachable(name), .tryAgain)
        case .notRunning:
            let isOllama = name == AgentProviderCatalog.name(.ollama)
            return (isOllama ? AgentText.failOllamaNotRunning : AgentText.failLMStudioNotRunning, .tryAgain)
        case .cancelled: return (AgentText.noticeStopped, nil)
        case .declined: return (AgentText.failDeclined, nil)
        // No model was ready when the request went: the same line as a missing key, so it never hangs unanswered.
        case .notReady: return (AgentText.failNoKey(name), .openSettings)
        // The panel shuts when AI mode turns off, so there is no one to tell.
        case .off: return nil
        }
    }

    private static func words(for status: AgentStatus) -> String {
        switch status {
        case .reading(let count): return AgentText.statusReading(count)
        case .readingContents(let count): return AgentText.statusReadingContents(count)
        case .thinking: return AgentText.statusThinking
        case .checkingPlan: return AgentText.statusCheckingPlan
        case .stopping: return AgentText.statusStopping
        }
    }

    /// The model's words as the thread shows them: hidden and control characters written out, line by line, and no
    /// longer than a reply may be.
    static func shownReply(_ text: String) -> String {
        let cut = String(text.prefix(AgentLimits.cloudModel.replyCharacters))
        return cut.components(separatedBy: "\n").map(AgentTextEscaper.escape).joined(separator: "\n")
    }

    // MARK: State

    private func append(_ kind: Line.Kind) {
        lines.append(Line(id: nextLineID, kind: kind))
        nextLineID += 1
    }

    /// Puts a line right after the open request's own line, or at the end when there is none.
    private func insertAfterRequest(_ kind: Line.Kind) {
        guard let requestLineID, let index = lines.firstIndex(where: { $0.id == requestLineID }) else { return append(kind) }
        lines.insert(Line(id: nextLineID, kind: kind), at: index + 1)
        nextLineID += 1
    }

    private func setComposer(_ text: String, caret: Int) {
        composerText = text
        self.caret = caret
        composerSet?(text, caret)
    }

    /// Runs a piece of work on the conversation, counted while it runs.
    private func work(_ body: @escaping @MainActor (AgentPanelModel) async -> Void) {
        pendingWork += 1
        Task { [weak self] in
            guard let self else { return }
            await body(self)
            self.pendingWork -= 1
        }
    }

    /// The phase follows from what is running, the card that waits and the tab's folder. The suggestions show only
    /// while nothing runs, and only where the tab shows a folder AI mode can use.
    private func recomputePhase() {
        let next: Phase
        if requestOpen { next = .working }
        else if applying { next = .applying }
        else if openCardIndex != nil { next = .plan }
        else if tabRoot == nil { next = .noFolder }
        else { next = settled }
        if next != phase { phase = next }

        let resting = [Phase.idle, .result, .failed].contains(next)
        if let root = tabRoot, resting {
            let offered = AgentSuggestions.make(itemCount: tab.itemCount, selectedCount: tab.selectedPaths.count, storage: root.storage)
            if suggestions != offered { suggestions = offered }
            let line = tab.itemCount == 0 && !root.storage.isReadOnly ? AgentText.emptyFolder : nil
            if restingLine != line { restingLine = line }
        } else {
            if !suggestions.isEmpty { suggestions = [] }
            let line: String? = next == .noFolder ? (tabRefused ? AgentText.folderRefused : AgentText.noFolder) : nil
            if restingLine != line { restingLine = line }
        }
        actions.phaseChanged(next)
    }
}
#endif
