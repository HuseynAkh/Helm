#if os(macOS)
import AppKit
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
        XCTAssertEqual(conversation.inner.sent.map(\.text), ["Organize the items in r1 into folders by kind. Depth: this folder. List them, then call propose_changes."])
        XCTAssertTrue(model.threadTextForTesting.contains(organize), "the chip's title is the request in the thread")
        XCTAssertEqual(conversation.inner.sent.map(\.asksForChanges), [true], "a suggestion is answered with a plan")
        model.press(AgentText.depthTwoLevels)
        await settle(model)
        XCTAssertEqual(conversation.inner.sent.last?.text, "Organize the items in r1 into folders by kind. Depth: 2 levels. List them, then call propose_changes.")
        model.press(AgentText.depthAllLevels)
        await settle(model)
        XCTAssertEqual(conversation.inner.sent.last?.text, "Organize the items in r1 into folders by kind. Depth: all levels. List them, then call propose_changes.")
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

    func testAPathTypedMidSentenceThatNamesNoFolderIsSentAsTyped() async {
        let conversation = PanelTestConversation()
        conversation.inner.folderAnswers = ["/home/helm/Projects by date": .refused(.notFound),
                                            "~/Downloads/report.pdf to old.pdf": .refused(.notFound)]
        let model = await model(conversation)
        await say(model, "Sort the files in /home/helm/Projects by date")
        await say(model, "Rename ~/Downloads/report.pdf to old.pdf")
        XCTAssertEqual(conversation.inner.sent.map(\.text),
                       ["Sort the files in /home/helm/Projects by date", "Rename ~/Downloads/report.pdf to old.pdf"])
        XCTAssertFalse(model.threadTextForTesting.contains(AgentText.addNotFound))
        XCTAssertEqual(model.chipsForTesting, ["Downloads:thisMac"], "nothing was added")
    }

    func testAFullStopAfterAPathIsTriedWithoutIt() async {
        let conversation = PanelTestConversation()
        conversation.inner.folderAnswers = ["/home/helm/Pictures.": .refused(.notFound)]
        let model = await model(conversation)
        await say(model, "Move everything to /home/helm/Pictures.")
        XCTAssertEqual(conversation.inner.sent.map(\.text), ["Move everything to r2"])
        XCTAssertTrue(model.chipsForTesting.contains("Pictures:thisMac"))
    }

    func testAMessageEndingInAMissingPathOrReachingARefusedFolderSendsNothing() async {
        let conversation = PanelTestConversation()
        conversation.inner.folderAnswers = ["/home/helm/Nope": .refused(.notFound),
                                            "/System/Library files here": .refused(.system)]
        let model = await model(conversation)
        await say(model, "Move everything to /home/helm/Nope")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.addNotFound))
        XCTAssertEqual(model.composerTextForTesting, "Move everything to /home/helm/Nope")
        await say(model, "Copy /System/Library files here")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.addRefused))
        XCTAssertEqual(conversation.inner.sent.count, 0)
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

    func testADraggedItemOutsideTheAllowedPlacesIsNeverLookedUp() {
        var lookedUp: [String] = []
        let urls = [URL(string: "file:///net/host.example/x")!, URL(string: "file:///System/Library")!,
                    URL(string: "file:///home/helm/Projects")!, URL(string: "file:///home/helm/notes.txt")!,
                    URL(string: "file:///Volumes/Backup/Photos/")!, URL(string: "https://example.test/folder/")!]
        let kept = AgentPanelHost.folders(urls, home: "/home/helm") { url in
            lookedUp.append(url.path)
            return url.lastPathComponent == "Projects"
        }
        XCTAssertEqual(lookedUp, ["/home/helm/Projects", "/home/helm/notes.txt"], "only items in an allowed place are looked up")
        XCTAssertEqual(kept.map(\.path), ["/home/helm/Projects", "/Volumes/Backup/Photos"])
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
        model.commandReturn()
        await settle(model)
        XCTAssertEqual(applied, [plan().defaultTicked], "Command-Return does")
        model.key("escape")
        XCTAssertEqual(keysGivenBack, 1, "with nothing waiting, Escape gives the keys back")
    }

    func testEscapeCancelsAWaitingPlanThenGivesTheKeysBack() async {
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        await say(model, "tidy up")
        XCTAssertEqual(model.phaseForTesting, "plan")
        model.key("escape")
        await settle(model)
        XCTAssertEqual(model.phaseForTesting, "idle")
        XCTAssertTrue(model.threadTextForTesting.hasSuffix(AgentText.planDismissed))
        XCTAssertEqual(conversation.inner.outcomes, [.dismissed])
        XCTAssertEqual(keysGivenBack, 0, "the first Escape only cancels the plan")
        model.key("escape")
        XCTAssertEqual(keysGivenBack, 1)
    }

    // MARK: Apply, Stop and Undo

    func testApplyShowsALineAtOnceAndStopReachesTheApplier() async {
        applyGate = PanelTestGate()
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        await say(model, "tidy up")
        // An Apply that stops between commands when asked, as the window's applier does.
        model.actions.apply = { [weak model] approved in
            let ticket = await conversation.inner.beginApply(planID: approved.planID, ticked: approved.ticked)
            guard case .go = ticket else { return nil }
            model?.applyProgress(planID: approved.planID, done: 0, total: 2, name: "a.png")
            while model?.applyStopAsked != true { try? await Task.sleep(nanoseconds: 5_000_000) }
            return AgentApplyReport(done: 1, skipped: 0, total: 2, stoppedEarly: true, trashFailed: [], changed: [],
                                    group: HistoryGroup(name: "Organize"))
        }
        model.press(AgentText.apply)
        XCTAssertEqual(model.phaseForTesting, "applying")
        XCTAssertTrue(model.threadTextForTesting.hasSuffix(AgentText.statusCheckingPlan), "a line at once")
        XCTAssertTrue(model.showsStop, "Send reads Stop while a plan applies")
        let moving = await until { model.threadTextForTesting.hasSuffix(AgentText.applyMoving(done: 1, total: 2, name: "a.png")) }
        XCTAssertTrue(moving, model.threadTextForTesting)
        model.press(AgentText.stop)
        XCTAssertTrue(model.applyStopAsked, "Stop reached the applier")
        await settle(model)
        XCTAssertEqual(model.phaseForTesting, "result")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.resultStopped(done: 1, total: 2)), model.threadTextForTesting)
        XCTAssertEqual(AgentText.resultStopped(done: 1, total: 2), "Stopped after 1 of 2.")
        XCTAssertFalse(model.showsStop)
    }

    func testAnUndoThatWorkedTakesShowAwayAndQuietsTheLine() async {
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        await say(model, "tidy up")
        model.actions.apply = { approved in
            guard case .go = await conversation.inner.beginApply(planID: approved.planID, ticked: approved.ticked) else { return nil }
            return AgentApplyReport(done: 2, skipped: 0, total: 2, stoppedEarly: false, trashFailed: [],
                                    changed: [URL(fileURLWithPath: "/home/helm/Downloads/Images/a.png")], group: HistoryGroup(name: "Organize"))
        }
        model.actions.undo = { _ in true }
        model.press(AgentText.apply)
        await settle(model)
        func outcome() -> AgentPanelModel.Outcome? {
            for line in model.lines.reversed() { if case .outcome(let outcome) = line.kind { return outcome } }
            return nil
        }
        XCTAssertEqual(outcome()?.changed.count, 1, "Show is offered")
        model.press(AgentText.undo)
        await settle(model)
        XCTAssertEqual(outcome()?.undoLine, AgentText.undoDone)
        XCTAssertEqual(outcome()?.changed, [], "nothing left to show")
    }

    // MARK: Lines

    func testARefusalIsHelmsOwnLineAndNoModelSaysWhy() async {
        let conversation = PanelTestConversation()
        let model = await model(conversation)
        conversation.failure = .declined
        await say(model, "something")
        guard case .helm(let words, nil)? = model.lines.last?.kind else { return XCTFail("not Helm's own line") }
        XCTAssertEqual(words, AgentText.failDeclined)
        conversation.failure = .notReady
        await say(model, "again")
        guard case .helm(let why, .openSettings?)? = model.lines.last?.kind else { return XCTFail("no line for notReady") }
        XCTAssertEqual(why, AgentText.failNoKey("Claude"))
        XCTAssertEqual(model.phaseForTesting, "failed")
    }

    func testTheTraceLineFollowsItsRequestAndTheCardStaysLast() async {
        let conversation = PanelTestConversation(plan: plan())
        conversation.traceAfter = (names: 6, destination: "Claude")
        let model = await model(conversation)
        await say(model, "tidy up")
        let kinds = model.lines.map(\.kind)
        guard let request = kinds.firstIndex(of: .request("tidy up")) else { return XCTFail("no request") }
        XCTAssertEqual(kinds[request + 1], .helm(AgentText.traceSent(names: 6, destination: "Claude"), button: nil))
        guard case .plan? = kinds.last else { return XCTFail("the card isn't last") }
    }

    func testARefusedAddGivesBackWhatWasTyped() async {
        let conversation = PanelTestConversation()
        conversation.inner.folderAnswers = ["~/Dowloads": .refused(.notFound)]
        let model = await model(conversation)
        await say(model, "/add ~/Dowloads")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.addNotFound))
        XCTAssertEqual(model.composerTextForTesting, "/add ~/Dowloads", "the typo can be put right")
        await say(model, "/add /home/helm/Music")
        XCTAssertEqual(model.composerTextForTesting, "", "a folder that was added leaves the composer empty")
    }

    // MARK: The composer

    func testTheModelsNameOpensSettingsAndStopStaysPressableWhileAPlanApplies() async throws {
        applyGate = PanelTestGate()
        var opened = 0
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        model.actions.openSettings = { opened += 1 }
        let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 340, height: 80))
        composer.attach(model, dropTarget: AgentPanelHost())
        XCTAssertEqual(composer.modelNameForTesting, "scripted-1", "the model's id, quietly, with no menu")
        composer.pressModelNameForTesting()
        XCTAssertEqual(opened, 1, "pressing the name opens Settings › AI")
        await say(model, "tidy up")
        model.press(AgentText.apply)
        let stop = await until { composer.sendTitleForTesting == (AgentText.stop, true) }
        XCTAssertTrue(stop, "\(composer.sendTitleForTesting)")
        applyGate.open()
        await settle(model)
        let send = await until { composer.sendTitleForTesting.title == AgentText.send }
        XCTAssertTrue(send)
    }

    func testTheFoldersRowFadesOnlyWhenItsChipsOverflow() {
        XCTAssertFalse(AgentFoldersRow.fades(chips: 300, row: 339))
        XCTAssertFalse(AgentFoldersRow.fades(chips: 339, row: 339))
        XCTAssertTrue(AgentFoldersRow.fades(chips: 520, row: 339))
        XCTAssertFalse(AgentFoldersRow.fades(chips: 520, row: 0), "a row not laid out yet doesn't fade")
    }

    // MARK: The card's words

    private func movePlan(_ count: Int, guarded: Bool = false) -> AgentChangePlan {
        let target = item("/home/helm/Documents", kind: .directory, handle: "d1")
        let steps = (0..<count).map { AgentPlanStep.move(item(downloads + "/file-\($0).txt", handle: "f\($0)"), to: .existing(target)) }
        return AgentChangePlan(title: .move(count), steps: steps,
                               groups: [AgentPlanGroup(id: 1, kind: .moves(toLabel: "Documents", isNew: false), steps: Array(0..<count),
                                                       guardedBy: guarded ? .leaves : nil, place: guarded ? "iCloud Drive" : nil)],
                               notices: [], leftOut: [:])
    }

    func testTheCountsLineShowsOnlyWhenItSaysMoreThanTheTitle() {
        let single = AgentPlanCard(plan: movePlan(1), roots: [])
        XCTAssertEqual(single.title, "Move 1 Item")
        XCTAssertEqual(single.shownCountsLine, "", "1 move under Move 1 Item says nothing new")
        XCTAssertFalse(single.textLines.contains(AgentText.countMoves(1)))
        let mixed = AgentPlanCard(plan: plan(), roots: [])
        XCTAssertEqual(mixed.shownCountsLine, "2 moves · 1 new folder · 1 rename")
        var unticked = AgentPlanCard(plan: movePlan(3), roots: [])
        XCTAssertEqual(unticked.shownCountsLine, "")
        unticked.toggle(1)
        XCTAssertEqual(unticked.shownCountsLine, "", "nothing ticked counts nothing")
    }

    func testAGuardedGroupStartsOpenOnlyWhenItIsShort() {
        let short = AgentPlanCard(plan: movePlan(10, guarded: true), roots: [])
        XCTAssertEqual(short.groupRows.map(\.isOpen), [true])
        let long = AgentPlanCard(plan: movePlan(11, guarded: true), roots: [])
        XCTAssertEqual(long.groupRows.map(\.isOpen), [false], "Cancel and Apply stay in reach")
        XCTAssertEqual(long.groupRows.map(\.mark), [AgentText.markLeaves("iCloud Drive")], "the mark still says why it is unticked")
    }

    func testARowLeavesOutWordsItsGroupAlreadySays() {
        let share = AgentScopeRoot(alias: "r1", path: "/Volumes/share/Team", label: "Share", modelName: "Share", identity: nil,
                                   storage: .thisMac, isTabFolder: true)
        let renames = (0..<3).map { AgentPlanStep.rename(item("/Volumes/share/Team/share-0\($0).txt", handle: "f\($0)"), to: name("shared-0\($0).txt")) }
        let plan = AgentChangePlan(title: .rename(3), steps: renames, groups: [AgentPlanGroup(id: 1, kind: .renames, steps: [0, 1, 2])],
                                   notices: [], leftOut: [:])
        let rows = AgentPlanCard(plan: plan, roots: [share]).groupRows[0].rows
        XCTAssertEqual(rows.map(\.name), ["share-00.txt → shared-00.txt", "share-01.txt → shared-01.txt", "share-02.txt → shared-02.txt"])
        XCTAssertEqual(rows.map(\.detail), ["", "", ""], "every row is in Share, the folder its chip names")
        XCTAssertEqual(rows.flatMap(\.tags), [], "Renamed is the group's own kind")
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

    func testACommandReturnStraightAfterARefreshAppliesNothing() async {
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        await say(model, "tidy up")
        model.tick("Rename 1 item")
        conversation.inner.nextTicket = .changed(plan(title: .move(3)))
        // A double press, or a key held down: the second lands on the refreshed card.
        model.commandReturn()
        await settle(model)
        model.commandReturn()
        await settle(model)
        XCTAssertEqual(applied, [], "the refreshed card, with the rename ticked again, was not applied by a key")
        XCTAssertEqual(model.phaseForTesting, "plan")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.planChanged))

        // Once the person has acted on it, the key works again, with exactly what is ticked.
        model.tick("Rename 1 item")
        model.commandReturn()
        await settle(model)
        XCTAssertEqual(applied, [[0]])
    }

    func testStopWhileTheEndingFolderIsLookedUpSendsNothing() async {
        let conversation = PanelTestConversation()
        let model = await model(conversation)
        let lookup = PanelTestGate()
        conversation.folderGate = lookup
        model.type("Move everything in this folder to /home/helm/Pictures")
        model.press(AgentText.send)
        let working = await until { model.phase == .working }
        XCTAssertTrue(working)
        model.key("escape")
        model.press(AgentText.stop)
        lookup.open()
        await settle(model)
        XCTAssertEqual(conversation.inner.sent.count, 0, "nothing was sent after Stop")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.noticeStopped))
        XCTAssertEqual(model.phaseForTesting, "idle")
        XCTAssertEqual(keysGivenBack, 0, "Escape stopped the request and kept the keys")

        // The next message goes as usual.
        conversation.folderGate = nil
        await say(model, "Move everything in this folder to /home/helm/Pictures")
        XCTAssertEqual(conversation.inner.sent.count, 1)
    }

    func testTryAgainDoesNothingWhileAPlanIsApplied() async {
        applyGate = PanelTestGate()
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        conversation.failure = .unreachable
        await say(model, "tidy up")
        conversation.failure = nil
        await say(model, "tidy up")
        XCTAssertEqual(model.phaseForTesting, "plan")
        model.press(AgentText.apply)
        let applying = await until { model.phase == .applying }
        XCTAssertTrue(applying)
        model.press(AgentText.tryAgain)
        XCTAssertEqual(model.phaseForTesting, "applying")
        XCTAssertEqual(conversation.inner.sent.count, 2, "no request starts during Apply")
        applyGate.open()
        await settle(model)
        XCTAssertEqual(model.phaseForTesting, "result")
    }

    func testAChipShowsAFolderNameEscaped() async {
        let conversation = PanelTestConversation()
        let model = await model(conversation)
        let hostile = "Invoices\u{202E}fdp.exe"
        await say(model, "/add /home/helm/" + hostile)
        let label = AgentTextEscaper.escape(hostile)
        XCTAssertNotEqual(label, hostile)
        XCTAssertTrue(model.chipsForTesting.contains(label + ":thisMac"), "\(model.chipsForTesting)")
        XCTAssertFalse(model.chipsForTesting.joined().unicodeScalars.contains { $0.value == 0x202E }, "no reading-order control on show")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.addAdded(hostile)))
        model.press(AgentText.chipRemove(label))
        await settle(model)
        XCTAssertEqual(model.chipsForTesting, ["Downloads:thisMac"], "its remove button still finds it")
    }

    func testACardShowsAtMostThreeNotes() async {
        let conversation = PanelTestConversation(plan: plan())
        let model = await model(conversation)
        await say(model, "tidy up")
        XCTAssertEqual(model.notesForTesting, [AgentText.noteLeftOutSeveral(5), AgentText.noteCantUndo("Server"), AgentText.noteShared("Server")])
        let empty = AgentChangePlan(title: .organize(rootLabel: "Downloads"), steps: [], groups: [], notices: [], leftOut: [:])
        conversation.answerPlan = empty
        await say(model, "again")
        // Nothing to apply: the line shows alone as Helm's own, with no card, and the older card can't run.
        XCTAssertTrue(model.threadTextForTesting.hasSuffix(AgentText.planNothing), model.threadTextForTesting)
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.planDismissed), "the older card can't be applied any more")
        XCTAssertEqual(model.phaseForTesting, "idle")
    }

    func testAPlanWhoseChangesWereAllLeftOutShowsItsLineAloneAndOffersNoApply() async {
        let leftOver = AgentChangePlan(title: .organize(rootLabel: "Downloads"), steps: [], groups: [],
                                       notices: [.notDownloaded(1)], leftOut: [.not_downloaded: 1])
        let conversation = PanelTestConversation(plan: leftOver)
        let model = await model(conversation)
        await say(model, "copy it")
        XCTAssertTrue(model.threadTextForTesting.hasSuffix(AgentText.noteNotDownloaded(1)), model.threadTextForTesting)
        XCTAssertEqual(AgentText.noteNotDownloaded(1), "1 item isn't downloaded, so Helm left it out.")
        XCTAssertFalse(model.lines.contains { if case .plan = $0.kind { return true }; return false }, "no card")
        guard let last = model.lines.last, case .helm(_, nil) = last.kind else { return XCTFail("not Helm's own line") }
        XCTAssertEqual(model.phaseForTesting, "idle")
        model.press(AgentText.apply)
        await settle(model)
        XCTAssertEqual(applied, [], "nothing to apply")
        XCTAssertEqual(conversation.inner.outcomes, [.dismissed], "the plan is settled as dismissed")
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

    func testAPlanThatOnlyMakesNewFoldersSaysSo() async {
        let root = item(downloads, kind: .directory, handle: "r1")
        let steps: [AgentPlanStep] = [.newFolder(key: "n1", parent: .existing(root), name: name("Images")),
                                      .newFolder(key: "n2", parent: .existing(root), name: name("Notes"))]
        let folders = AgentChangePlan(title: .organize(rootLabel: "Downloads"), steps: steps,
                                      groups: [AgentPlanGroup(id: 0, kind: .newFolders, steps: [0, 1])], notices: [], leftOut: [:])
        let model = await model(PanelTestConversation(plan: folders))
        await say(model, "make two folders")
        model.press(AgentText.apply)
        await settle(model)
        XCTAssertEqual(model.phaseForTesting, "result")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.resultMadeFolders(2)))
        XCTAssertFalse(model.threadTextForTesting.contains("Trash"), "nothing went to the Trash")
    }

    /// Two new files in a new Trip folder and one in Downloads, the second Trip file's name already taken.
    private func creationPlan() -> AgentChangePlan {
        let root = item(downloads, kind: .directory, handle: "r1")
        let steps: [AgentPlanStep] = [
            .newFolder(key: "n1", parent: .existing(root), name: name("Trip")),
            .newFile(parent: .new(key: "n1"), name: name("Packing List.txt"), text: "Passport\nCharger\n"),
            .newFile(parent: .new(key: "n1"), name: name("Budget.csv"), text: String(repeating: "x", count: 1_500)),
            .newFile(parent: .existing(root), name: name("Letter\u{202E}fdp.docx"), text: "Dear Sam")
        ]
        return AgentChangePlan(title: .create(3), steps: steps, groups: [
            AgentPlanGroup(id: 1, kind: .newFiles(toLabel: "Trip", isNew: true), steps: [0, 1, 2]),
            AgentPlanGroup(id: 2, kind: .newFiles(toLabel: "Downloads", isNew: false), steps: [3])
        ], notices: [], keepsBoth: [2], leftOut: [:])
    }

    func testNewFilesShowTheirNamesSizesAndWhereTheyAreMade() {
        let card = AgentPlanCard(plan: creationPlan(), roots: [], home: "/home/helm")
        XCTAssertEqual(card.title, "Create 3 Files")
        XCTAssertEqual(card.countsLine, "3 new files · 1 new folder")
        XCTAssertEqual(card.shownCountsLine, "3 new files · 1 new folder", "the folder is news the title doesn't give")
        let groups = card.groupRows
        XCTAssertEqual(groups.map(\.title), ["Create 2 files in “Trip”", "Create 1 file in “Downloads”"])
        XCTAssertEqual(groups.map(\.isOn), [true, true])
        XCTAssertEqual(groups.map { $0.destination?.whole }, ["~/Downloads/Trip", "~/Downloads"])
        XCTAssertEqual(groups.map { $0.destination?.isNew }, [true, false])
        XCTAssertEqual(groups[0].rows.map(\.name), ["Trip", "Packing List.txt", "Budget.csv"])
        XCTAssertEqual(groups[0].rows.map(\.tags), [[AgentText.tagNew], ["17 bytes"], ["1.5 KB", AgentText.tagKeepsBoth]])
        XCTAssertEqual(groups[0].rows.map { $0.destination?.whole }, ["~/Downloads", "~/Downloads/Trip", "~/Downloads/Trip"])
        // A name is drawn escaped, and nothing the file holds is on the card.
        XCTAssertEqual(groups[1].rows.map(\.name), ["Letter\\u{202E}fdp.docx"])
        XCTAssertFalse(card.textLines.joined().contains("Dear Sam"))
        XCTAssertFalse(groups.flatMap(\.rows).contains { $0.name.contains("Passport") || $0.detail.contains("Passport") })

        let one = AgentPlanCard(plan: AgentChangePlan(title: .create(1), steps: [creationPlan().steps[3]],
                                                      groups: [AgentPlanGroup(id: 1, kind: .newFiles(toLabel: "Downloads", isNew: false), steps: [0])],
                                                      notices: [], leftOut: [:]), roots: [])
        XCTAssertEqual(one.shownCountsLine, "", "1 new file under Create 1 File says nothing new")
    }

    func testAPlanThatMakesFilesSaysSo() async {
        let model = await model(PanelTestConversation(plan: creationPlan()))
        await say(model, "write a packing list and a budget")
        XCTAssertEqual(model.groupsForTesting, ["Create 2 files in “Trip”:on", "Create 1 file in “Downloads”:on"])
        XCTAssertEqual(model.groupPathsForTesting, ["Create 2 files in “Trip”=~/Downloads/Trip new folder",
                                                    "Create 1 file in “Downloads”=~/Downloads"])
        model.tick("Create 1 file in “Downloads”")
        XCTAssertEqual(model.planCountsForTesting, "2 new files · 1 new folder")
        model.press(AgentText.apply)
        await settle(model)
        XCTAssertEqual(applied, [[1]])
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.resultMadeFiles(2)))
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
    private var lookupHeldBy: PanelTestGate?

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
    /// While set, a request says how many names went where, after the rest of its answer, as a real one does.
    var traceAfter: (names: Int, destination: String)? {
        get { lock.withLock { tracing } }
        set { lock.withLock { tracing = newValue } }
    }
    private var tracing: (names: Int, destination: String)?

    /// While true, a request answers with no plan.
    var withoutPlan: Bool {
        get { lock.withLock { noPlan } }
        set { lock.withLock { noPlan = newValue } }
    }

    /// While set, looking up a folder the person typed waits for the gate.
    var folderGate: PanelTestGate? {
        get { lock.withLock { lookupHeldBy } }
        set { lock.withLock { lookupHeldBy = newValue } }
    }

    var notices: AsyncStream<AgentNotice> { inner.notices }
    func roots() async -> [AgentScopeRoot] { await inner.roots() }
    func setTabFolder(_ input: AgentRootInput?) async -> AgentTabFolder { await inner.setTabFolder(input) }
    func folder(for input: AgentRootInput) async -> AgentFolderRef {
        await folderGate?.wait()
        return await inner.folder(for: input)
    }
    func removeRoot(alias: String) async { await inner.removeRoot(alias: alias) }
    func beginApply(planID: UUID, ticked: Set<Int>) async -> AgentApplyTicket { await inner.beginApply(planID: planID, ticked: ticked) }
    func settle(planID: UUID, _ outcome: AgentPlanOutcome) async { await inner.settle(planID: planID, outcome) }
    func stop() async { await inner.stop() }
    func startOver() async { await inner.startOver() }
    func clear() async { await inner.clear() }

    func send(_ input: AgentPersonInput) -> AsyncStream<AgentSessionEvent> {
        let events = inner.send(input)
        let (gate, failure, other, none, trace) = lock.withLock { (heldBy, failing, otherPlan, noPlan, tracing) }
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
                        case .finished:
                            if let trace { continuation.yield(.trace(.sent(names: trace.names, destination: trace.destination))) }
                            continuation.yield(event)
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
