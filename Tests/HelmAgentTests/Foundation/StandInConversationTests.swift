import XCTest
import HelmCore
@testable import HelmAgent

/// The conversation with no model behind it: what it answers, what it keeps, and that a plan can be applied once.
final class StandInConversationTests: XCTestCase {
    private func item(_ name: String) -> AgentPlanItem {
        AgentPlanItem(handle: "f" + name, rootAlias: "r1", path: "/home/helm/Downloads/" + name, name: name, kind: .regular,
                      identity: nil, isDataless: false)
    }

    private func makePlan() -> AgentChangePlan {
        AgentChangePlan(title: .trash(2), steps: [.trash(item("a.tmp")), .rename(item("b.txt"), to: ValidFileName("c.txt")!)], groups: [
            AgentPlanGroup(id: 1, kind: .trash, steps: [0], guardedBy: .trash),
            AgentPlanGroup(id: 2, kind: .renames, steps: [1])
        ], notices: [], leftOut: [:])
    }

    private func answers(_ conversation: StandInConversation, to text: String) async -> [AgentSessionEvent] {
        var events: [AgentSessionEvent] = []
        for await event in conversation.send(AgentPersonInput(typedByPerson: text, selectedPaths: [])) { events.append(event) }
        return events
    }

    private func typed(_ text: String) -> AgentRootInput { AgentRootInput(fromPerson: text, origin: .typed) }

    private func firstNotice(_ conversation: StandInConversation) async -> AgentNotice? {
        for await notice in conversation.notices { return notice }
        return nil
    }

    // MARK: Messages

    func testEveryMessageGetsTheReplyAndThePlan() async {
        let plan = makePlan()
        let conversation = StandInConversation(plan: plan, reply: "Two changes.")
        for text in ["organize", "again"] {
            let events = await answers(conversation, to: text)
            XCTAssertEqual(events.count, 4, text)
            guard events.count == 4 else { continue }
            guard case .status(.thinking) = events[0], case .reply("Two changes.") = events[1], case .plan(let sent) = events[2],
                  case .finished = events[3] else { XCTFail("unexpected events for \(text)"); continue }
            XCTAssertEqual(sent, plan)
        }
        XCTAssertEqual(conversation.sent.map(\.text), ["organize", "again"])
    }

    func testWithNothingToSayItOnlyFinishes() async {
        let conversation = StandInConversation()
        let events = await answers(conversation, to: "hello")
        XCTAssertEqual(events.count, 2)
        guard events.count == 2, case .status(.thinking) = events[0], case .finished = events[1] else { return XCTFail("unexpected events") }
        XCTAssertEqual(conversation.sent.count, 1)
        XCTAssertEqual(conversation.outcomes, [])
    }

    // MARK: Folders

    func testTheTabsFolderIsARootThatFollowsTheTab() async {
        let conversation = StandInConversation()
        var roots = await conversation.roots()
        XCTAssertEqual(roots, [])
        guard case .root(let first) = await conversation.setTabFolder(AgentRootInput(fromPerson: "/home/helm/Downloads", origin: .tab)) else {
            return XCTFail("no root")
        }
        XCTAssertEqual([first.alias, first.path, first.label], ["r1", "/home/helm/Downloads", "Downloads"])
        XCTAssertTrue(first.isTabFolder)
        // The same folder again is the same root.
        guard case .root(let same) = await conversation.setTabFolder(AgentRootInput(fromPerson: "/home/helm/Downloads", origin: .tab)) else {
            return XCTFail("no root")
        }
        XCTAssertEqual(same, first)
        // Another folder is another root under a new alias, and the old one is gone.
        guard case .root(let second) = await conversation.setTabFolder(AgentRootInput(fromPerson: "/home/helm/Documents", origin: .tab)) else {
            return XCTFail("no root")
        }
        XCTAssertEqual(second.alias, "r2")
        roots = await conversation.roots()
        XCTAssertEqual(roots, [second])
        // No folder on show: Recent, the Trash, search results.
        let none = await conversation.setTabFolder(nil)
        XCTAssertEqual(none, AgentTabFolder.none)
        roots = await conversation.roots()
        XCTAssertEqual(roots, [])
        // Back to the first folder: an alias is never used twice.
        guard case .root(let third) = await conversation.setTabFolder(AgentRootInput(fromPerson: "/home/helm/Downloads", origin: .tab)) else {
            return XCTFail("no root")
        }
        XCTAssertEqual(third.alias, "r3")
    }

    func testARefusedTabFolderLeavesNoTabRoot() async {
        let conversation = StandInConversation()
        conversation.folderAnswers = ["/Applications": .refused(.system)]
        _ = await conversation.setTabFolder(AgentRootInput(fromPerson: "/home/helm/Downloads", origin: .tab))
        let refused = await conversation.setTabFolder(AgentRootInput(fromPerson: "/Applications", origin: .tab))
        XCTAssertEqual(refused, .refused(.system))
        let roots = await conversation.roots()
        XCTAssertEqual(roots, [], "it never stays on the folder before")
    }

    func testAFolderIsAddedOnceAndAnswersCanBeSet() async {
        let conversation = StandInConversation()
        _ = await conversation.setTabFolder(AgentRootInput(fromPerson: "/home/helm/Downloads", origin: .tab))
        guard case .added(let pictures) = await conversation.folder(for: typed("/home/helm/Pictures")) else { return XCTFail("not added") }
        XCTAssertEqual([pictures.alias, pictures.label], ["r2", "Pictures"])
        XCTAssertFalse(pictures.isTabFolder)
        let again = await conversation.folder(for: AgentRootInput(fromPerson: "/home/helm/Pictures", origin: .dropped))
        XCTAssertEqual(again, .root(pictures))
        let tab = await conversation.folder(for: typed("/home/helm/Downloads"))
        XCTAssertEqual(tab.modelID, "r1")

        // Answers set by the typed text: a refusal, a folder inside a root, and a root of the test's own.
        let own = AgentScopeRoot(alias: "r9", path: "/Volumes/Share/Team", label: "Team", modelName: "Server", identity: nil,
                                 storage: StorageFacts(kind: .network, name: "Server", shared: .yes), isTabFolder: false)
        conversation.folderAnswers = ["/System": .refused(.system), "~/Pictures/2026": .inside(handle: "d7", name: "2026"),
                                      "/Volumes/Share/Team": .added(own)]
        XCTAssertEqual(conversation.folderAnswers.count, 3)
        var answer = await conversation.folder(for: typed("/System"))
        XCTAssertEqual(answer, .refused(.system))
        answer = await conversation.folder(for: typed("~/Pictures/2026"))
        XCTAssertEqual(answer, .inside(handle: "d7", name: "2026"))
        answer = await conversation.folder(for: typed("/Volumes/Share/Team"))
        XCTAssertEqual(answer, .added(own))
        var roots = await conversation.roots()
        XCTAssertEqual(roots.map(\.alias), ["r1", "r2", "r9"])

        await conversation.removeRoot(alias: "r2")
        roots = await conversation.roots()
        XCTAssertEqual(roots.map(\.alias), ["r1", "r9"])
        let notice = await firstNotice(conversation)
        XCTAssertEqual(notice, .startedOver, "removing a folder starts the thread over")
    }

    func testEightFoldersAtMost() async {
        let conversation = StandInConversation()
        _ = await conversation.setTabFolder(AgentRootInput(fromPerson: "/home/helm/Downloads", origin: .tab))
        for index in 1...7 {
            guard case .added = await conversation.folder(for: typed("/home/helm/Folder \(index)")) else { return XCTFail("folder \(index) not added") }
        }
        let full = await conversation.folder(for: typed("/home/helm/One Too Many"))
        XCTAssertEqual(full, .refused(.full))
        let roots = await conversation.roots()
        XCTAssertEqual(roots.count, AgentLimits.roots)
        XCTAssertEqual(Set(roots.map(\.alias)).count, 8)
    }

    func testClearDropsTheAddedFoldersAndStartOverKeepsThem() async {
        let conversation = StandInConversation()
        _ = await conversation.setTabFolder(AgentRootInput(fromPerson: "/home/helm/Downloads", origin: .tab))
        _ = await conversation.folder(for: typed("/home/helm/Pictures"))
        await conversation.startOver()
        var roots = await conversation.roots()
        XCTAssertEqual(roots.map(\.alias), ["r1", "r2"])
        await conversation.clear()
        roots = await conversation.roots()
        XCTAssertEqual(roots.map(\.alias), ["r1"], "the tab's folder stays")
        // Each one said that the thread started over.
        var heard: [AgentNotice] = []
        for await notice in conversation.notices {
            heard.append(notice)
            if heard.count == 2 { break }
        }
        XCTAssertEqual(heard, [.startedOver, .startedOver])
        await conversation.stop()
    }

    // MARK: Applying

    func testAPlanIsAppliedOnce() async {
        let plan = makePlan()
        let conversation = StandInConversation(plan: plan)
        var ticket = await conversation.beginApply(planID: plan.id, ticked: plan.defaultTicked)
        XCTAssertEqual(ticket, .go(plan))
        ticket = await conversation.beginApply(planID: plan.id, ticked: plan.defaultTicked)
        XCTAssertEqual(ticket, .refused, "a second press, or an older card, gets nothing")

        await conversation.settle(planID: plan.id, .applied(done: 1, skipped: 0))
        await conversation.settle(planID: plan.id, .dismissed)
        XCTAssertEqual(conversation.outcomes, [.applied(done: 1, skipped: 0), .dismissed])
    }

    func testOnlyThePendingPlanWithItsOwnTicksIsApplied() async {
        let plan = makePlan()
        let conversation = StandInConversation(plan: plan)
        var ticket = await conversation.beginApply(planID: UUID(), ticked: [2])
        XCTAssertEqual(ticket, .refused, "another plan's id")
        ticket = await conversation.beginApply(planID: plan.id, ticked: [2, 7])
        XCTAssertEqual(ticket, .refused, "a tick that isn't one of its groups")
        ticket = await conversation.beginApply(planID: plan.id, ticked: [1, 2])
        XCTAssertEqual(ticket, .go(plan), "a refusal uses nothing up")
        let none = StandInConversation()
        ticket = await none.beginApply(planID: plan.id, ticked: [])
        XCTAssertEqual(ticket, .refused, "no plan at all")
    }

    func testTheNextTicketIsAnsweredOnce() async {
        let plan = makePlan()
        let changed = AgentChangePlan(title: .rename(1), steps: [plan.steps[1]], groups: [AgentPlanGroup(id: 1, kind: .renames, steps: [0])],
                                      notices: [], leftOut: [:])
        let conversation = StandInConversation(plan: plan)
        XCTAssertNil(conversation.nextTicket)

        conversation.nextTicket = .notResponding(label: "Server")
        XCTAssertEqual(conversation.nextTicket, .notResponding(label: "Server"))
        var ticket = await conversation.beginApply(planID: plan.id, ticked: [2])
        XCTAssertEqual(ticket, .notResponding(label: "Server"))
        XCTAssertNil(conversation.nextTicket)

        // A changed plan takes the old one's place: the old id is refused and the new one goes.
        conversation.nextTicket = .changed(changed)
        ticket = await conversation.beginApply(planID: plan.id, ticked: [2])
        XCTAssertEqual(ticket, .changed(changed))
        ticket = await conversation.beginApply(planID: plan.id, ticked: [2])
        XCTAssertEqual(ticket, .refused)
        ticket = await conversation.beginApply(planID: changed.id, ticked: changed.defaultTicked)
        XCTAssertEqual(ticket, .go(changed))
        ticket = await conversation.beginApply(planID: changed.id, ticked: changed.defaultTicked)
        XCTAssertEqual(ticket, .refused)
    }
}
