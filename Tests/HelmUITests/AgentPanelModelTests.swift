#if os(macOS)
import XCTest
import HelmAgent
import HelmCore
@testable import HelmUI

/// The panel's model against a stand-in conversation: its seven phases, when the three suggestions show, what the
/// composer sends for each kind of text, folders added by typing and by a drop, the Connect line, the thread's
/// consent line, and the plan card's ticks, counts and notes.
@MainActor final class AgentPanelModelTests: XCTestCase {
    private let downloads = "/home/helm/Downloads"
    private var phases: [AgentPanelModel.Phase] = []
    private var applied: [Set<Int>] = []
    private var connected: [ServerLocation] = []
    private var keysGivenBack = 0
    private var applyGate = PanelTestGate()

    override func setUp() {
        super.setUp()
        phases = []; applied = []; connected = []; keysGivenBack = 0
        // Apply finishes at once unless a test holds it.
        applyGate = PanelTestGate()
        applyGate.open()
    }

    // MARK: Building

    private func name(_ text: String) -> ValidFileName { ValidFileName(text)! }
    private func item(_ path: String, kind: FileEntryKind = .regular, handle: String) -> AgentPlanItem {
        AgentPlanItem(handle: handle, rootAlias: "r1", path: path, name: (path as NSString).lastPathComponent, kind: kind,
                      identity: FileObjectIdentity(scope: "disk", object: handle), isDataless: false)
    }

    /// Two moves into a new Images folder, a rename, a Trash group and a guarded group of moves to Google Drive,
    /// with more notes than a card shows.
    private func plan(title: AgentPlanTitle = .organize(rootLabel: "Downloads")) -> AgentChangePlan {
        let root = item(downloads, kind: .directory, handle: "r1")
        let drive = item("/home/helm/Library/CloudStorage/GoogleDrive-test/Shared", kind: .directory, handle: "d9")
        let steps: [AgentPlanStep] = [
            .newFolder(key: "n1", parent: .existing(root), name: name("Images")),
            .move(item(downloads + "/a.png", handle: "f1"), to: .new(key: "n1")),
            .move(item(downloads + "/b.png", handle: "f2"), to: .new(key: "n1")),
            .rename(item(downloads + "/notes.txt", handle: "f3"), to: name("Notes.txt")),
            .trash(item(downloads + "/old.tmp", handle: "f4")),
            .move(item(downloads + "/c.pdf", handle: "f5"), to: .existing(drive))
        ]
        let groups = [
            AgentPlanGroup(id: 0, kind: .moves(toLabel: "Images", isNew: true), steps: [0, 1, 2]),
            AgentPlanGroup(id: 1, kind: .renames, steps: [3]),
            AgentPlanGroup(id: 2, kind: .trash, steps: [4], guardedBy: .trash),
            AgentPlanGroup(id: 3, kind: .moves(toLabel: "Shared", isNew: false), steps: [5], guardedBy: .arrives, place: "Google Drive")
        ]
        return AgentChangePlan(title: title, steps: steps, groups: groups,
                               notices: [.notAllowed(2), .notDownloaded(3), .cantUndo(place: "Server"), .syncs, .shared(place: "Server")],
                               leftOut: [.not_allowed: 2, .not_downloaded: 3])
    }

    private func model(_ conversation: PanelTestConversation, itemCount: Int = 5) async -> AgentPanelModel {
        var actions = AgentPanelModel.Actions()
        let stand = conversation.inner
        let gate = applyGate
        actions.phaseChanged = { [weak self] phase in self?.phases.append(phase) }
        actions.connect = { [weak self] location in self?.connected.append(location); return true }
        actions.giveKeysBack = { [weak self] in self?.keysGivenBack += 1 }
        let model = AgentPanelModel(session: conversation, home: "/home/helm",
                                    provider: AgentPanelModel.Provider(name: "Claude", destination: "Claude", model: "scripted-1"),
                                    actions: actions)
        // Apply as the window does it: the conversation is asked first, and only its go runs.
        model.actions.apply = { [weak self, weak model] approved in
            let ticket = await stand.beginApply(planID: approved.planID, ticked: approved.ticked)
            guard case .go(let plan) = ticket else {
                model?.applyAnswered(planID: approved.planID, ticket)
                return nil
            }
            self?.applied.append(approved.ticked)
            await gate.wait()
            let total = plan.counts(ticked: approved.ticked).total
            return AgentApplyReport(done: total, skipped: 0, total: total, stoppedEarly: false, trashFailed: [], changed: [],
                                    group: HistoryGroup(name: plan.title.text))
        }
        model.update(tab: AgentPanelModel.TabContext(folder: downloads, itemCount: itemCount, selectedPaths: []))
        let ready = await until { model.phase == .idle && !model.isWaitingForTesting }
        XCTAssertTrue(ready, "the tab's folder never arrived")
        return model
    }

    private func until(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }
    private func settle(_ model: AgentPanelModel) async {
        _ = await until { !model.isWaitingForTesting }
    }
    private func say(_ model: AgentPanelModel, _ text: String) async {
        model.type(text)
        model.send()
        await settle(model)
    }

    private let organize = "Organize 5 items", move = "Move everything to…", copy = "Copy everything to…"

    // MARK: Phases and suggestions

    func testEverySevenPhasesIsReachedAndNamed() async {
        applyGate = PanelTestGate()
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        XCTAssertEqual(model.phaseForTesting, "idle")

        // A request that waits: working.
        conversation.gate = PanelTestGate()
        model.type("tidy up")
        model.send()
        let working = await until { model.phase == .working }
        XCTAssertTrue(working)
        XCTAssertEqual(model.phaseForTesting, "working")
        conversation.gate?.open()
        let plan = await until { model.phase == .plan }
        XCTAssertTrue(plan)
        XCTAssertEqual(model.phaseForTesting, "plan")

        // Apply that waits: applying, then result.
        model.press(AgentText.apply)
        let applying = await until { model.phase == .applying }
        XCTAssertTrue(applying)
        XCTAssertEqual(model.phaseForTesting, "applying")
        applyGate.open()
        let result = await until { model.phase == .result }
        XCTAssertTrue(result)
        XCTAssertEqual(model.phaseForTesting, "result")

        // A request that fails.
        conversation.gate = nil
        conversation.failure = .unreachable
        await say(model, "again")
        XCTAssertEqual(model.phaseForTesting, "failed")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.failUnreachable("Claude")))

        // A tab with no folder.
        model.update(tab: AgentPanelModel.TabContext(folder: nil, itemCount: 0, selectedPaths: []))
        await settle(model)
        XCTAssertEqual(model.phaseForTesting, "noFolder")
        XCTAssertEqual(Set(phases), Set([.noFolder, .idle, .working, .plan, .applying, .result, .failed]))
    }

    func testTheSuggestionsShowOnlyWhileNothingRuns() async {
        applyGate = PanelTestGate()
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        XCTAssertEqual(model.suggestionsForTesting, [organize, move, copy], "idle")

        conversation.gate = PanelTestGate()
        model.type("tidy up")
        model.send()
        _ = await until { model.phase == .working }
        XCTAssertEqual(model.suggestionsForTesting, [], "hidden while a request is open")
        conversation.gate?.open()
        _ = await until { model.phase == .plan }
        XCTAssertEqual(model.suggestionsForTesting, [], "hidden while a plan card waits")

        model.press(AgentText.apply)
        _ = await until { model.phase == .applying }
        XCTAssertEqual(model.suggestionsForTesting, [], "hidden during Apply")
        applyGate.open()
        _ = await until { model.phase == .result }
        XCTAssertEqual(model.suggestionsForTesting, [organize, move, copy], "back with the result")

        conversation.failure = .overloaded
        await say(model, "once more")
        XCTAssertEqual(model.phaseForTesting, "failed")
        XCTAssertEqual(model.suggestionsForTesting, [organize, move, copy], "on show after a failure")

        // A plain request with no plan: back to idle with the same three.
        conversation.failure = nil
        conversation.withoutPlan = true
        await say(model, "what can you do")
        XCTAssertEqual(model.phaseForTesting, "idle")
        XCTAssertEqual(model.suggestionsForTesting, [organize, move, copy], "still there after a request")

        // They follow the selection.
        model.update(tab: AgentPanelModel.TabContext(folder: downloads, itemCount: 5, selectedPaths: [downloads + "/a.png", downloads + "/b.png"]))
        XCTAssertEqual(model.suggestionsForTesting, ["Organize 2 selected", "Move 2 selected to…", "Copy 2 selected to…"])

        // A search-results tab has no folder: no suggestions.
        model.update(tab: AgentPanelModel.TabContext(folder: nil, itemCount: 0, selectedPaths: []))
        await settle(model)
        XCTAssertEqual(model.phaseForTesting, "noFolder")
        XCTAssertEqual(model.suggestionsForTesting, [])
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.noFolder))
    }

    func testAnEmptyFolderSaysSoAndOffersNothing() async {
        let model = await model(PanelTestConversation(), itemCount: 0)
        XCTAssertEqual(model.suggestionsForTesting, [])
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.emptyFolder))
    }

    func testAFolderTheConversationRefusesShowsTheRefusedLine() async {
        let conversation = PanelTestConversation()
        conversation.inner.folderAnswers = ["/Applications": .refused(.system)]
        let model = await model(conversation)
        model.update(tab: AgentPanelModel.TabContext(folder: "/Applications", itemCount: 30, selectedPaths: []))
        await settle(model)
        XCTAssertEqual(model.phaseForTesting, "noFolder")
        XCTAssertEqual(model.suggestionsForTesting, [])
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.folderRefused))
        XCTAssertEqual(model.chipsForTesting, [], "a refused folder is no chip")
    }

    func testAPlainPressOfOrganizeSendsThisFolderAndTheMenuSendsItsDepth() async {
        let conversation = PanelTestConversation()
        let model = await model(conversation)
        model.press(organize)
        await settle(model)
        XCTAssertEqual(conversation.inner.sent.map(\.text), ["Organize the items in r1 into folders by kind. Depth: this folder."])
        XCTAssertTrue(model.threadTextForTesting.contains(organize), "the chip's title is the request in the thread")
        model.press(AgentText.depthTwoLevels)
        await settle(model)
        XCTAssertEqual(conversation.inner.sent.last?.text, "Organize the items in r1 into folders by kind. Depth: 2 levels.")
        model.press(AgentText.depthAllLevels)
        await settle(model)
        XCTAssertEqual(conversation.inner.sent.last?.text, "Organize the items in r1 into folders by kind. Depth: all levels.")
    }

    func testMoveAndCopyFillTheComposerAndSendNothing() async {
        let conversation = PanelTestConversation()
        let model = await model(conversation)
        model.press(move)
        XCTAssertEqual(model.composerTextForTesting, AgentText.fillMoveAll)
        model.press(copy)
        XCTAssertEqual(model.composerTextForTesting, AgentText.fillCopyAll)
        await settle(model)
        XCTAssertEqual(conversation.inner.sent.count, 0)
    }

    // MARK: The composer

    func testTheFirstLineOfAThreadIsTheConsentLine() async {
        let model = await model(PanelTestConversation())
        XCTAssertEqual(model.threadTextForTesting.components(separatedBy: "\n").first, AgentText.consent("Claude"))
        await say(model, "/clear")
        let lines = model.threadTextForTesting.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, AgentText.consent("Claude"), "a thread that starts over starts with it too")
        XCTAssertEqual(lines.filter { $0 == AgentText.noticeStartedOver }.count, 1, "said once")
    }

    func testAddABarePathClearAndAnUnknownCommand() async {
        let conversation = PanelTestConversation()
        let model = await model(conversation)
        XCTAssertEqual(model.chipsForTesting, ["Downloads:thisMac"])

        await say(model, "/add /home/helm/Music")
        XCTAssertEqual(model.chipsForTesting, ["Downloads:thisMac", "Music:thisMac"])
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.addAdded("Music")))

        await say(model, "/home/helm/Desktop")
        XCTAssertEqual(model.chipsForTesting, ["Downloads:thisMac", "Music:thisMac", "Desktop:thisMac"], "a path alone is /add")
        await say(model, "/add /home/helm/Music")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.addAlready("Music")))
        XCTAssertEqual(model.composerTextForTesting, "")

        await say(model, "/help")
        XCTAssertTrue(model.threadTextForTesting.hasSuffix(AgentText.addNotFound) || model.threadTextForTesting.contains(AgentText.addNotFound))

        await say(model, "/clear")
        XCTAssertEqual(model.chipsForTesting, ["Downloads:thisMac"], "the added folders went")
        XCTAssertEqual(model.threadTextForTesting.components(separatedBy: "\n").prefix(2),
                       [AgentText.consent("Claude"), AgentText.noticeStartedOver][...])
        XCTAssertEqual(conversation.inner.sent.count, 0, "no command reached the model")
    }

    func testAMessageEndingInAPathAddsTheFolderAndSendsItsID() async {
        let conversation = PanelTestConversation()
        let model = await model(conversation)
        await say(model, "Move everything in this folder to /home/helm/Pictures/2026")
        XCTAssertEqual(conversation.inner.sent.map(\.text), ["Move everything in this folder to r2"])
        XCTAssertFalse(conversation.inner.sent.contains { $0.text.contains("/home/helm") }, "the path was never sent")
        XCTAssertTrue(model.chipsForTesting.contains("2026:thisMac"))
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.addAdded("2026")))
    }

    func testARefusedPathShowsItsLineAndSendsNothing() async {
        let conversation = PanelTestConversation()
        conversation.inner.folderAnswers = ["/System/Library": .refused(.system)]
        let model = await model(conversation)
        await say(model, "Copy everything in this folder to /System/Library")
        XCTAssertEqual(conversation.inner.sent.count, 0)
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.addRefused))
        XCTAssertEqual(model.composerTextForTesting, "Copy everything in this folder to /System/Library", "what was typed comes back")
        XCTAssertEqual(model.phaseForTesting, "idle")
    }

    func testADroppedFolderIsAddedNeverMovedAndGoesInAtTheCaret() async {
        let conversation = PanelTestConversation()
        let model = await model(conversation)
        // With nothing typed, the folder is only added.
        model.drop(URL(fileURLWithPath: "/home/helm/Archive", isDirectory: true))
        await settle(model)
        XCTAssertTrue(model.chipsForTesting.contains("Archive:thisMac"))
        XCTAssertEqual(model.composerTextForTesting, "")

        // With a sentence waiting, its path goes in at the caret.
        model.press(move)
        model.drop(URL(fileURLWithPath: "/home/helm/Old Stuff", isDirectory: true))
        await settle(model)
        XCTAssertEqual(model.composerTextForTesting, AgentText.fillMoveAll + "/home/helm/Old Stuff")
        XCTAssertTrue(model.chipsForTesting.contains("Old Stuff:thisMac"))
        // The caret in the middle: the path goes there.
        model.composerEdited("Copy  please", caret: 5)
        model.drop(URL(fileURLWithPath: "/home/helm/Archive", isDirectory: true))
        await settle(model)
        XCTAssertEqual(model.composerTextForTesting, "Copy /home/helm/Archive please")

        XCTAssertEqual(applied, [], "nothing was applied")
        XCTAssertEqual(conversation.inner.sent.count, 0, "a drop sends nothing")
        model.type(AgentText.fillMoveAll + "/home/helm/Old Stuff")
        model.send()
        await settle(model)
        XCTAssertEqual(conversation.inner.sent.map(\.text), ["Move everything in this folder to r3"])
    }

    func testAServerAddressShowsTheConnectLineAndAddsNothing() async {
        let conversation = PanelTestConversation()
        let model = await model(conversation)
        await say(model, "smb://nas.local/share")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.serverConfirm("nas.local")))
        XCTAssertEqual(model.chipsForTesting, ["Downloads:thisMac"])
        XCTAssertEqual(connected, [], "nothing goes to macOS before Connect")
        model.press(AgentText.connect)
        XCTAssertEqual(connected.map(\.host), ["nas.local"])
        model.press(AgentText.connect)
        XCTAssertEqual(connected.count, 1, "Connect works once")
        await settle(model)
        XCTAssertEqual(model.chipsForTesting, ["Downloads:thisMac"], "Helm added nothing afterwards")
        await say(model, "/add afp://mac.local/Files")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.serverConfirm("mac.local")))
        XCTAssertEqual(conversation.inner.sent.count, 0)
    }

    func testAKeyShapedMessageIsNotSent() async {
        let conversation = PanelTestConversation()
        let model = await model(conversation)
        await say(model, "use sk-ant-api03-test-fake-000000000000000000 please")
        XCTAssertEqual(conversation.inner.sent.count, 0)
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.composerLooksLikeKey))
        XCTAssertFalse(model.threadTextForTesting.contains("sk-ant"), "the key isn't kept in the thread")
        XCTAssertEqual(model.composerTextForTesting, "", "nor in the composer")
    }

    func testReturnSendsAndNeverAppliesAndEscapeGivesTheKeysBack() async {
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        await say(model, "tidy up")
        XCTAssertEqual(model.phaseForTesting, "plan")
        model.key("return")
        model.key("return")
        await settle(model)
        XCTAssertEqual(applied, [], "plain Return never presses Apply")
        model.key("escape")
        XCTAssertEqual(keysGivenBack, 1)
        model.commandReturn()
        await settle(model)
        XCTAssertEqual(applied, [plan().defaultTicked], "Command-Return does")
    }

    // MARK: The plan card

    func testTickingAGuardedGroupChangesTheCountsLine() async {
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        await say(model, "tidy up")
        XCTAssertEqual(model.groupsForTesting, ["Move 2 items to “Images”:on", "Rename 1 item:on", "Move 1 item to the Trash:off",
                                                "Move 1 item to “Shared”:off:Goes to Google Drive"])
        XCTAssertEqual(model.planCountsForTesting, "2 moves · 1 new folder · 1 rename")
        model.tick("Move 1 item to the Trash")
        XCTAssertEqual(model.planCountsForTesting, "2 moves · 1 new folder · 1 rename · 1 to Trash")
        model.tick("Move 1 item to “Shared”")
        XCTAssertEqual(model.planCountsForTesting, "3 moves · 1 new folder · 1 rename · 1 to Trash")
        model.tick("Move 2 items to “Images”")
        XCTAssertEqual(model.planCountsForTesting, "1 move · 1 rename · 1 to Trash", "the new folder goes with the moves into it")
        model.press(AgentText.apply)
        await settle(model)
        XCTAssertEqual(applied, [[1, 2, 3]], "Apply sends exactly what is ticked")
    }

    func testARefreshedCardStartsFromTheDefaultTicks() async {
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        await say(model, "tidy up")
        model.tick("Move 1 item to the Trash")
        model.tick("Rename 1 item")
        let changed = plan(title: .move(3))
        conversation.inner.nextTicket = .changed(changed)
        model.press(AgentText.apply)
        await settle(model)
        XCTAssertEqual(applied, [], "a stale plan runs nothing")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.planChanged))
        XCTAssertEqual(model.phaseForTesting, "plan")
        XCTAssertEqual(model.groupsForTesting, ["Move 2 items to “Images”:on", "Rename 1 item:on", "Move 1 item to the Trash:off",
                                                "Move 1 item to “Shared”:off:Goes to Google Drive"])
        model.press(AgentText.apply)
        await settle(model)
        XCTAssertEqual(applied, [changed.defaultTicked])
    }

    func testACardShowsAtMostThreeNotes() async {
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        await say(model, "tidy up")
        XCTAssertEqual(model.notesForTesting, [AgentText.noteLeftOutSeveral(5), AgentText.noteCantUndo("Server"), AgentText.noteShared("Server")])
        let empty = AgentChangePlan(title: .organize(rootLabel: "Downloads"), steps: [], groups: [], notices: [], leftOut: [:])
        conversation.answerPlan = empty
        await say(model, "again")
        XCTAssertEqual(model.notesForTesting, [AgentText.planNothing])
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.planReplaced), "the older card says it was replaced")
    }

    func testApplyPressedTwiceRunsOnceAndCancelDismisses() async {
        applyGate = PanelTestGate()
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        await say(model, "tidy up")
        model.press(AgentText.apply)
        model.press(AgentText.apply)
        applyGate.open()
        await settle(model)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(model.phaseForTesting, "result")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.resultOrganized(items: 2, folders: 1)))

        await say(model, "tidy again")
        model.press(AgentText.cancel)
        await settle(model)
        XCTAssertEqual(model.phaseForTesting, "idle")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.planDismissed))
        XCTAssertEqual(conversation.inner.outcomes, [.dismissed])
    }

    func testAReplyIsShownEscapedAsPlainText() async {
        let conversation = PanelTestConversation(reply: "[Done](https://example.test)\u{202E}txt.exe")
        let model = await model(conversation)
        await say(model, "hello")
        XCTAssertTrue(model.threadTextForTesting.contains("[Done](https://example.test)\\u{202E}txt.exe"))
    }
}

/// A gate a test opens once.
final class PanelTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.withLock { isOpen = true } }
    func wait() async {
        while !lock.withLock({ isOpen }) { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

/// A stand-in conversation whose requests can be held open or fail, and whose answer can carry another plan or none.
final class PanelTestConversation: AgentConversing, @unchecked Sendable {
    let inner: StandInConversation
    private let lock = NSLock()
    private var heldBy: PanelTestGate?
    private var failing: AgentFailure?
    private var otherPlan: AgentChangePlan?
    private var noPlan = false

    init(plan: AgentChangePlan? = nil, reply: String = "") { inner = StandInConversation(plan: plan, reply: reply) }

    /// While set, a request says it is thinking and waits for the gate.
    var gate: PanelTestGate? {
        get { lock.withLock { heldBy } }
        set { lock.withLock { heldBy = newValue } }
    }
    /// While set, a request ends with this failure.
    var failure: AgentFailure? {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    /// While set, a request answers with this plan in place of the stand-in's.
    var answerPlan: AgentChangePlan? {
        get { lock.withLock { otherPlan } }
        set { lock.withLock { otherPlan = newValue } }
    }
    /// While true, a request answers with no plan.
    var withoutPlan: Bool {
        get { lock.withLock { noPlan } }
        set { lock.withLock { noPlan = newValue } }
    }

    var notices: AsyncStream<AgentNotice> { inner.notices }
    func roots() async -> [AgentScopeRoot] { await inner.roots() }
    func setTabFolder(_ input: AgentRootInput?) async -> AgentTabFolder { await inner.setTabFolder(input) }
    func folder(for input: AgentRootInput) async -> AgentFolderRef { await inner.folder(for: input) }
    func removeRoot(alias: String) async { await inner.removeRoot(alias: alias) }
    func beginApply(planID: UUID, ticked: Set<Int>) async -> AgentApplyTicket { await inner.beginApply(planID: planID, ticked: ticked) }
    func settle(planID: UUID, _ outcome: AgentPlanOutcome) async { await inner.settle(planID: planID, outcome) }
    func stop() async { await inner.stop() }
    func startOver() async { await inner.startOver() }
    func clear() async { await inner.clear() }

    func send(_ input: AgentPersonInput) -> AsyncStream<AgentSessionEvent> {
        let events = inner.send(input)
        let (gate, failure, other, none) = lock.withLock { (heldBy, failing, otherPlan, noPlan) }
        return AsyncStream { continuation in
            Task {
                continuation.yield(.status(.thinking))
                await gate?.wait()
                if let failure {
                    continuation.yield(.failed(failure))
                    continuation.yield(.finished)
                } else {
                    for await event in events {
                        switch event {
                        case .status: continue
                        case .plan(let plan): if !none { continuation.yield(.plan(other ?? plan)) }
                        default: continuation.yield(event)
                        }
                    }
                }
                continuation.finish()
            }
        }
    }
}
#endif
