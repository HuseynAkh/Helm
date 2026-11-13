import XCTest
import HelmCore
import HelmTestKit
@testable import HelmAgent

/// The loop against a scripted model and a fake validator: its limits, turns that are dropped, plans that end a
/// request and are reported in the next, one request at a time, Stop, threads that start over, and Apply that
/// works once.
final class AgentSessionTests: XCTestCase {
    private let home = "/home/helm"

    private static let list = #"{"name":"list_folder","args":{"folder":"@root","depth":1,"after":""}}"#
    private static let propose = #"{"name":"propose_changes","args":{"new_folders":[{"key":"n1","parent":"@root","name":"Images"}],"moves":[{"items":["@name:a.png","@name:b.png"],"all_in":"","to":"n1"}],"copies":[],"renames":[],"trash":[]}}"#
    private static let script = """
    {"rules": [
      {"when": "organize", "turns": [{"calls": [\(list)]}, {"text": "Images go into a new Images folder.", "calls": [\(propose)]}]},
      {"when": "refuse", "turns": [{"text": "No.", "calls": [\(list)], "stop": "refusal"}]},
      {"when": "filtered", "turns": [{"calls": [\(list)], "stop": "content_filter"}]},
      {"when": "cutoff", "turns": [{"text": "Partly", "calls": [\(list)], "stop": "max_tokens"}]},
      {"when": "broken", "turns": [], "failure": "unreachable"},
      {"when": "*", "turns": [{"text": "Hello."}]}]}
    """

    private struct Rig {
        let session: AgentSession
        let client: ScriptedModelClient
        let validator: AgentLoopFakeValidator
        let disk: MemoryAgentDisk
        let root: String
    }

    private func rig(_ script: String = AgentSessionTests.script, isLocal: Bool = false, clock: FakeClock = FakeClock(),
                     listSeconds: Double? = nil, client wrap: ((ScriptedModelClient) -> any AgentModelClient)? = nil) async -> Rig {
        let disk = MemoryAgentDisk(home: home)
        for name in ["a.png", "b.png", "notes.txt"] { disk.addFile(home + "/" + name) }
        disk.addFolder(home + "/Work")
        let client = AgentLoopKit.client(script, isLocal: isLocal)
        let validator = AgentLoopFakeValidator()
        let session = AgentSession(parts: AgentLoopKit.parts(wrap?(client) ?? client, disk: disk, home: home, clock: clock,
                                                             listSeconds: listSeconds), validator: validator)
        guard case .root(let root) = await session.setTabFolder(AgentRootInput(fromPerson: home, origin: .tab)) else {
            XCTFail("no tab root")
            fatalError()
        }
        return Rig(session: session, client: client, validator: validator, disk: disk, root: root.alias)
    }

    private func send(_ rig: Rig, _ text: String, selected: [String] = []) async -> [String] {
        AgentLoopKit.words(await AgentLoopKit.events(rig.session, text, selected: selected))
    }

    /// The results sent in the last user turn of the model's last turn.
    private func lastResults(_ rig: Rig) -> [(id: String, json: AgentJSON)] {
        guard let item = rig.client.sentTurns.last?.history.last else { return [] }
        return AgentLoopKit.results(in: item)
    }

    private func hasModelCalls(_ history: [AgentJSON]) -> Bool {
        history.contains { AgentLoopKit.string($0, "role") == "model" && AgentLoopKit.member($0, "calls") != nil }
    }

    // MARK: A request

    func testAPlainReplyIsShownAndEndsTheRequest() async {
        let rig = await self.rig()
        let words = await send(rig, "hello")
        XCTAssertEqual(words, ["status thinking", "reply Hello.", "finished"])
        let first = rig.client.sentTurns.first
        XCTAssertEqual(first?.system, AgentPrompt.system)
        XCTAssertEqual(first?.tools, AgentToolCatalog.all)
        let text = first.flatMap { AgentLoopKit.text(of: $0.history[0]) } ?? ""
        XCTAssertEqual(text, "[Helm] Folders: \(rig.root) this_mac (on show).\nhello")
    }

    func testAnOrganizeRequestListsThenEndsWithAPlan() async {
        let rig = await self.rig()
        let events = await AgentLoopKit.events(rig.session, "organize this")
        let words = AgentLoopKit.words(events)
        XCTAssertEqual(words, ["status thinking", "status reading(count: 4)", "status thinking", "reply Images go into a new Images folder.",
                               "status checkingPlan", "plan", "trace sent(names: 4, destination: \"Claude\")", "finished"])
        XCTAssertEqual(rig.client.sentTurns.count, 2, "the plan ended the request")
        let moves = rig.validator.proposed.first?.moves.first?.items ?? []
        XCTAssertEqual(moves.count, 2)
        XCTAssertTrue(moves.allSatisfy { $0.hasPrefix("f") }, "\(moves)")
        XCTAssertEqual(rig.validator.proposed.first?.newFolders.first?.parent, rig.root)
    }

    func testAPlanIsHeldBackAndItsResultIsTheFirstItemOfTheNextRequest() async {
        let rig = await self.rig()
        let plan = AgentLoopKit.plans(await AgentLoopKit.events(rig.session, "organize")).first!
        // While the card is open the plan is pending.
        _ = await send(rig, "hello")
        let next = rig.client.sentTurns[2].history
        let item = next.last!
        let results = AgentLoopKit.results(in: item)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.json, .object(["source": .string("plan"), "status": .string("pending")]))
        XCTAssertTrue(AgentLoopKit.text(of: item)?.hasPrefix("[Helm] Folders:") == true)
        XCTAssertEqual(rig.client.userItems(text: "x", toolResults: [AgentToolResult(callID: "c", name: "n", json: "{}")]).first?.objectValue?.keys.sorted(),
                       ["results", "role", "text"], "results and text go in one user turn")
        // Its outcome then rides in the next note.
        await rig.session.settle(planID: plan.id, .applied(done: 2, skipped: 1))
        _ = await send(rig, "hello")
        let note = AgentLoopKit.text(of: rig.client.sentTurns[3].history.last!) ?? ""
        XCTAssertTrue(note.contains(" Last plan: applied 2, skipped 1.\n"), note)
        _ = await send(rig, "hello")
        let later = AgentLoopKit.text(of: rig.client.sentTurns[4].history.last!) ?? ""
        XCTAssertFalse(later.contains("Last plan"), "an outcome is told once")
    }

    func testAPlanSettledBeforeTheNextRequestReportsItsOutcomeInItsResult() async {
        let rig = await self.rig()
        rig.validator.answer(.plan(AgentLoopFakeValidator.plan(leftOut: [.outside_scope: 5])))
        let plan = AgentLoopKit.plans(await AgentLoopKit.events(rig.session, "organize")).first!
        await rig.session.settle(planID: plan.id, .applied(done: 210, skipped: 4))
        _ = await send(rig, "hello")
        let json = AgentLoopKit.results(in: rig.client.sentTurns[2].history.last!).first?.json
        XCTAssertEqual(json, .object(["source": .string("plan"), "status": .string("applied"), "done": .number(210), "skipped": .number(4),
                                      "left_out": .array([.object(["code": .string("outside_scope"), "count": .number(5)])])]))
        XCTAssertFalse((AgentLoopKit.text(of: rig.client.sentTurns[2].history.last!) ?? "").contains("Last plan"))

        let second = AgentLoopKit.plans(await AgentLoopKit.events(rig.session, "organize")).first!
        await rig.session.settle(planID: second.id, .dismissed)
        _ = await send(rig, "hello")
        let dismissed = AgentLoopKit.results(in: rig.client.sentTurns.last!.history.last!).first?.json
        XCTAssertEqual(dismissed, .object(["source": .string("plan"), "status": .string("dismissed")]))
    }

    // MARK: Turns that are dropped

    func testARefusalAndAMaxTokensStopRunNoTool() async {
        for (message, expected) in [("refuse", "failed declined"), ("filtered", "failed declined"),
                                    ("cutoff", "failed tooLarge")] {
            let rig = await self.rig()
            let words = await send(rig, message)
            XCTAssertEqual(words, ["status thinking", expected, "finished"], message)
            XCTAssertFalse(words.contains { $0.hasPrefix("status reading") || $0.hasPrefix("trace") }, message)
            XCTAssertEqual(rig.client.sentTurns.count, 1, message)
            // The dropped turn is not in the thread: the next request carries no model turn with calls, and no results.
            _ = await send(rig, "hello")
            let history = rig.client.sentTurns.last!.history
            XCTAssertFalse(hasModelCalls(history), message)
            XCTAssertTrue(history.allSatisfy { AgentLoopKit.member($0, "results") == nil }, message)
            XCTAssertFalse(rig.client.allSentText().contains("Partly"), message)
        }
    }

    func testAFailedModelEndsTheRequestWithItsFailure() async {
        let rig = await self.rig()
        agentEqual(await send(rig, "broken"), ["status thinking", "failed unreachable", "finished"])
        let disk = MemoryAgentDisk(home: home)
        let session = AgentSession(parts: AgentSessionParts(client: { .failure(.notReady) }, disk: disk, home: home,
                                                            supportFolder: AgentLoopKit.support, clock: FakeClock()),
                                   validator: AgentLoopFakeValidator())
        let words = AgentLoopKit.words(await AgentLoopKit.events(session, "hello"))
        XCTAssertEqual(words, ["failed notReady", "finished"])
    }

    func testARepeatedOrOverlongCallIDDropsTheTurn() async {
        let script = """
        {"rules": [{"when": "*", "turns": [{"calls": [\(Self.list)]}]}]}
        """
        for ids in [["same", "same"], ["call_1", String(repeating: "c", count: 129)], [""]] {
            let rig = await self.rig(script, client: { inner in AgentLoopIDClient(inner: inner, ids: ids) })
            agentEqual(await send(rig, "hello"), ["status thinking", "failed unreadable", "finished"], "\(ids)")
        }
    }

    // MARK: Limits

    func testTheTurnLimit() async {
        let turns = Array(repeating: #"{"calls": [\#(Self.list)]}"#, count: 13).joined(separator: ",")
        let script = #"{"rules": [{"when": "*", "turns": [\#(turns)]}]}"#
        let cloud = await self.rig(script)
        let words = await send(cloud, "loop")
        XCTAssertEqual(words.suffix(3), ["notice limitReached", "trace sent(names: 48, destination: \"Claude\")", "finished"])
        XCTAssertEqual(cloud.client.sentTurns.count, 12)
        let local = await self.rig(script, isLocal: true)
        _ = await send(local, "loop")
        XCTAssertEqual(local.client.sentTurns.count, 8)
    }

    func testCallsBeyondATurnsLimitAreToldTheLimitAndTheRequestGoesOn() async {
        let nine = Array(repeating: Self.list, count: 9).joined(separator: ",")
        let script = #"{"rules": [{"when": "*", "turns": [{"calls": [\#(nine)]}, {"text": "Done."}]}]}"#
        let rig = await self.rig(script)
        let words = await send(rig, "many")
        XCTAssertTrue(words.contains("reply Done."), "\(words)")
        let results = lastResults(rig)
        XCTAssertEqual(results.count, 9)
        XCTAssertEqual(results.filter { AgentLoopKit.string($0.json, "source") == "folder_listing" }.count, 8)
        XCTAssertEqual(results.last?.json, .object(["source": .string("error"), "code": .string("limit_reached")]))
    }

    func testTheCallLimitOfARequestEndsIt() async {
        let eight = Array(repeating: Self.list, count: 8).joined(separator: ",")
        let turns = Array(repeating: #"{"calls": [\#(eight)]}"#, count: 5).joined(separator: ",")
        let rig = await self.rig(#"{"rules": [{"when": "*", "turns": [\#(turns)]}]}"#)
        let words = await send(rig, "flood")
        XCTAssertTrue(words.contains("notice limitReached"), "\(words)")
        XCTAssertEqual(rig.client.sentTurns.count, 4, "24 calls in three turns, and the fourth is told the limit")
        _ = await send(rig, "hello")
        let thread = rig.client.sentTurns[4].history
        let fourth = AgentLoopKit.results(in: thread[thread.count - 2])
        XCTAssertEqual(fourth.count, 8)
        XCTAssertTrue(fourth.allSatisfy { AgentLoopKit.string($0.json, "code") == "limit_reached" })
    }

    func testTheRequestTimeLimit() async {
        let turns = Array(repeating: #"{"calls": [\#(Self.list)]}"#, count: 5).joined(separator: ",")
        let clock = FakeClock()
        let rig = await self.rig(#"{"rules": [{"when": "*", "turns": [\#(turns)]}]}"#, clock: clock,
                                 client: { inner in AgentLoopSlowClient(inner: inner, clock: clock, seconds: 250) })
        let words = await send(rig, "slow")
        XCTAssertTrue(words.contains("notice limitReached"), "\(words)")
        XCTAssertEqual(rig.client.sentTurns.count, 3, "ten minutes a request")
    }

    func testATurnThatEndsPastTheRequestsTimeRunsNoneOfItsCalls() async {
        let clock = FakeClock()
        let rig = await self.rig(#"{"rules": [{"when": "*", "turns": [{"calls": [\#(Self.list)]}, {"text": "never"}]}]}"#, clock: clock,
                                 client: { inner in AgentLoopSlowClient(inner: inner, clock: clock, seconds: 660) })
        let words = await send(rig, "slow")
        XCTAssertEqual(words, ["status thinking", "notice limitReached", "finished"])
        XCTAssertEqual(rig.client.sentTurns.count, 1)
        _ = await send(rig, "hello")
        let results = AgentLoopKit.results(in: rig.client.sentTurns[1].history[2])
        XCTAssertEqual(results.map { AgentLoopKit.string($0.json, "code") }, ["limit_reached"], "the call was told the limit and never ran")
    }

    func testAStreamThatOutlastsTheRequestIsCut() async {
        let clock = FakeClock()
        var stalling: AgentLoopStallingClient?
        let rig = await self.rig(#"{"rules": [{"when": "*", "turns": [{"calls": [\#(Self.list)]}, {"text": "never"}]}]}"#, clock: clock,
                                 client: { inner in
                                     let made = AgentLoopStallingClient(inner: inner, clock: clock, seconds: 599.5)
                                     stalling = made
                                     return made
                                 })
        // Should the cut never come, Stop ends the request and the words below say so.
        let session = rig.session
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            await session.stop()
        }
        let words = await send(rig, "slow")
        watchdog.cancel()
        XCTAssertTrue(words.contains("notice limitReached"), "\(words)")
        XCTAssertFalse(words.contains("notice stopped"), "\(words)")
        XCTAssertEqual(words.last, "finished")
        XCTAssertEqual(stalling?.turnsStarted, 2)
    }

    func testTwoBadCallsInARowEndTheRequest() async {
        let bad = #"{"name":"list_folder","args":{"folder":"/home/helm"}}"#
        let unknown = #"{"name":"delete_everything","args":{}}"#
        let rig = await self.rig(#"{"rules": [{"when": "*", "turns": [{"calls": [\#(bad)]}, {"calls": [\#(unknown)]}, {"text": "never"}]}]}"#)
        let words = await send(rig, "go")
        XCTAssertEqual(words.suffix(2), ["failed noTools", "finished"])
        XCTAssertEqual(rig.client.sentTurns.count, 2)
    }

    func testEveryToolErrorIsACodeAndNothingElse() async {
        let byPath = #"{"name":"list_folder","args":{"folder":"/home/helm","depth":1,"after":""}}"#
        let rig = await self.rig(#"{"rules": [{"when": "*", "turns": [{"calls": [\#(byPath)]}, {"text": "Stopped."}]}]}"#)
        _ = await send(rig, "go")
        let history = rig.client.sentTurns.last!.history
        let results = AgentLoopKit.results(in: history.last!)
        XCTAssertEqual(results.first?.json, .object(["source": .string("error"), "code": .string("unknown_id")]))
        guard case .object(let fields) = history.last!, case .array(let raw)? = fields["results"] else { return XCTFail("no results") }
        XCTAssertEqual(AgentLoopKit.member(raw.first, "error"), .bool(true))
        for code in AgentToolCode.allCases {
            let json = AgentSession.errorResult(AgentToolCall(id: "c", name: "list_folder", arguments: Data()), code).json
            XCTAssertEqual(json, #"{"code":"\#(code.rawValue)","source":"error"}"#)
        }
    }

    func testASecondOversizedPlanEndsTheRequest() async {
        let propose = Self.propose
        let rig = await self.rig(#"{"rules": [{"when": "*", "turns": [{"calls": [\#(propose)]}, {"calls": [\#(propose)]}, {"text": "never"}]}]}"#)
        rig.validator.answer(.refused(.too_many), .refused(.too_many))
        let words = await send(rig, "big plan")
        XCTAssertEqual(words.suffix(2), ["failed tooLarge", "finished"])
        XCTAssertEqual(rig.client.sentTurns.count, 2)
    }

    func testASlowPlaceEndsTheRequestWithItsLine() async {
        let rig = await self.rig(listSeconds: 0.2)
        rig.disk.setDelay(0.5, under: home)
        let words = await send(rig, "organize")
        XCTAssertTrue(words.contains("notice notResponding(label: \"helm\")"), "\(words)")
        XCTAssertEqual(rig.client.sentTurns.count, 1)
    }

    // MARK: One request at a time, and Stop

    func testASecondRequestIsRefusedWhileOneIsOpenAndStopEndsIt() async throws {
        let hanging = AgentLoopHangingClient()
        let rig = await self.rig(client: { _ in hanging })
        let first = rig.session.send(AgentPersonInput(typedByPerson: "hello", selectedPaths: []))
        for _ in 0..<500 where hanging.turnsStarted == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(hanging.turnsStarted, 1)
        let second = AgentLoopKit.words(await AgentLoopKit.events(rig.session, "again"))
        XCTAssertEqual(second, ["finished"])
        XCTAssertEqual(hanging.turnsStarted, 1)

        await rig.session.stop()
        var words: [String] = []
        for await event in first { words += AgentLoopKit.words([event]) }
        XCTAssertEqual(words, ["status thinking", "status stopping", "notice stopped", "finished"])
        // After Stop a new request may start.
        let third = rig.session.send(AgentPersonInput(typedByPerson: "again", selectedPaths: []))
        for _ in 0..<500 where hanging.turnsStarted == 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(hanging.turnsStarted, 2)
        await rig.session.stop()
        for await _ in third {}
    }

    // MARK: Starting over

    func testTheThreadStartsOverAfterThirtyRequests() async {
        let rig = await self.rig()
        for _ in 0..<30 { _ = await send(rig, "hello") }
        XCTAssertEqual(rig.client.sentTurns[29].history.count, 59)
        let words = await send(rig, "hello")
        XCTAssertEqual(words.first, "notice startedOver")
        XCTAssertEqual(rig.client.sentTurns[30].history.count, 1)
    }

    func testTheThreadStartsOverAfterEightMegabytesOfHistory() async {
        let long = String(repeating: "x", count: 4_100_000)
        let rig = await self.rig(#"{"rules": [{"when": "*", "turns": [{"text": "\#(long)"}]}]}"#)
        let first = await send(rig, "one")
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first[1].count, "reply ".count + AgentLimits.cloudModel.replyCharacters, "the reply is cut")
        let second = await send(rig, "two")
        XCTAssertNotEqual(second.first, "notice startedOver")
        agentEqual(await send(rig, "three").first, "notice startedOver")
        XCTAssertEqual(rig.client.sentTurns[2].history.count, 1)
    }

    func testRemovingARootStartsTheThreadOver() async {
        let rig = await self.rig()
        var notices = rig.session.notices.makeAsyncIterator()
        rig.disk.addFolder("/Volumes/Disk/Work")
        guard case .added(let work) = await rig.session.folder(for: AgentRootInput(fromPerson: "/Volumes/Disk/Work", origin: .typed)) else {
            return XCTFail("not added")
        }
        _ = await send(rig, "organize")
        _ = await send(rig, "hello")
        XCTAssertGreaterThan(rig.client.sentTurns.last!.history.count, 1)
        await rig.session.removeRoot(alias: work.alias)
        agentEqual(await notices.next(), .startedOver)
        let roots = await rig.session.roots()
        XCTAssertEqual(roots.map(\.alias), [rig.root])
        _ = await send(rig, "hello")
        let history = rig.client.sentTurns.last!.history
        XCTAssertEqual(history.count, 1)
        XCTAssertTrue(AgentLoopKit.results(in: history[0]).isEmpty, "the held plan went with the thread")
        XCTAssertFalse((AgentLoopKit.text(of: history[0]) ?? "").contains(work.alias))
    }

    func testStartOverAndClearAnnounceAndRetireHandles() async {
        let rig = await self.rig()
        var notices = rig.session.notices.makeAsyncIterator()
        let plan = AgentLoopKit.plans(await AgentLoopKit.events(rig.session, "organize")).first!
        let handle = rig.validator.proposed.first!.moves.first!.items.first!
        await rig.session.startOver()
        agentEqual(await notices.next(), .startedOver)
        agentEqual(await rig.session.beginApply(planID: plan.id, ticked: plan.defaultTicked), .refused, "the plan went with the thread")
        _ = await send(rig, "organize")
        let fresh = rig.validator.proposed.last!.moves.first!.items.first!
        XCTAssertNotEqual(fresh, handle, "a handle is never issued twice")
        await rig.session.clear()
        agentEqual(await notices.next(), .startedOver)
        let roots = await rig.session.roots()
        XCTAssertEqual(roots.count, 1)
        XCTAssertNotEqual(roots.first?.alias, rig.root, "the tab's folder comes back under a new alias")
    }

    // MARK: Apply

    func testBeginApplyWorksOnceForThePendingPlanAndItsOwnTicks() async {
        let rig = await self.rig()
        let plan = AgentLoopKit.plans(await AgentLoopKit.events(rig.session, "organize")).first!
        agentEqual(await rig.session.beginApply(planID: UUID(), ticked: plan.defaultTicked), .refused)
        agentEqual(await rig.session.beginApply(planID: plan.id, ticked: [1, 99]), .refused, "a tick that isn't one of its groups")
        XCTAssertEqual(rig.validator.rechecked, 0)
        agentEqual(await rig.session.beginApply(planID: plan.id, ticked: plan.defaultTicked), .go(plan))
        agentEqual(await rig.session.beginApply(planID: plan.id, ticked: plan.defaultTicked), .refused, "a second time")
        XCTAssertEqual(rig.validator.rechecked, 1)
    }

    func testAChangedRecheckMakesTheNewPlanThePendingOne() async {
        let rig = await self.rig()
        let plan = AgentLoopKit.plans(await AgentLoopKit.events(rig.session, "organize")).first!
        let changed = AgentLoopFakeValidator.plan()
        rig.validator.recheckAnswers(.changed(changed), .notResponding(label: "helm"))
        agentEqual(await rig.session.beginApply(planID: plan.id, ticked: [1, 2]), .changed(changed))
        agentEqual(await rig.session.beginApply(planID: plan.id, ticked: plan.defaultTicked), .refused, "the old id is spent")
        agentEqual(await rig.session.beginApply(planID: changed.id, ticked: changed.defaultTicked), .notResponding(label: "helm"))
        agentEqual(await rig.session.beginApply(planID: changed.id, ticked: changed.defaultTicked), .go(changed), "a place that answers again")
        // The new plan's outcome is the one reported.
        await rig.session.settle(planID: changed.id, .applied(done: 1, skipped: 0))
        _ = await send(rig, "hello")
        let json = AgentLoopKit.results(in: rig.client.sentTurns.last!.history.last!).first?.json
        XCTAssertEqual(AgentLoopKit.string(json, "status"), "applied")
    }

    func testANewPlanReplacesThePendingOne() async {
        let rig = await self.rig()
        let first = AgentLoopKit.plans(await AgentLoopKit.events(rig.session, "organize")).first!
        let second = AgentLoopKit.plans(await AgentLoopKit.events(rig.session, "organize")).first!
        agentEqual(await rig.session.beginApply(planID: first.id, ticked: first.defaultTicked), .refused)
        agentEqual(await rig.session.beginApply(planID: second.id, ticked: second.defaultTicked), .go(second))
    }
}

/// A scripted model whose calls all carry one id, as a confused provider might send them.
final class AgentLoopIDClient: AgentModelClient, @unchecked Sendable {
    let inner: ScriptedModelClient
    let ids: [String]
    init(inner: ScriptedModelClient, ids: [String]) { self.inner = inner; self.ids = ids }
    var providerName: String { inner.providerName }
    var destination: String { inner.destination }
    var isLocal: Bool { inner.isLocal }
    func turn(_ input: AgentTurnInput) -> AsyncThrowingStream<AgentModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let calls = self.ids.map { AgentToolCall(id: $0, name: "list_folder", arguments: Data()) }
            continuation.yield(.finished(AgentTurnResult(rawItems: [], calls: calls, stop: .toolUse)))
            continuation.finish()
        }
    }
    func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] { inner.userItems(text: text, toolResults: toolResults) }
    func structured(_ ask: AgentStructuredAsk) async throws -> Data { try await inner.structured(ask) }
    func models() async throws -> [AgentModelInfo] { try await inner.models() }
}
