import XCTest
import HelmCore
import HelmTestKit
@testable import HelmAgent

/// A request for changes ends in a plan: when the model answers one with words alone, Helm asks once for the plan,
/// inside the request's own turns and time, and the words wait. A question is answered as it is.
final class AgentPlanNowTests: XCTestCase {
    private let home = "/home/helm"

    private static let list = #"{"calls": [{"name":"list_folder","args":{"folder":"@root","depth":1,"after":""}}]}"#
    private static let propose = #"{"text": "Images go into a new Images folder.", "calls": [{"name":"propose_changes","args":{"new_folders":[{"key":"n1","parent":"@root","name":"Images"}],"moves":[{"items":["@name:a.png","@name:b.png"],"all_in":"","to":"n1"}],"copies":[],"renames":[],"trash":[]}}]}"#

    private struct Rig {
        let session: AgentSession
        let client: ScriptedModelClient
        let root: String
    }

    /// A session whose model answers every message with these turns.
    private func rig(_ turns: [String], isLocal: Bool = false, clock: FakeClock = FakeClock(),
                     client wrap: ((ScriptedModelClient) -> any AgentModelClient)? = nil) async -> Rig {
        let disk = MemoryAgentDisk(home: home)
        for name in ["a.png", "b.png", "notes.txt"] { disk.addFile(home + "/" + name) }
        disk.addFolder(home + "/Work")
        let client = AgentLoopKit.client(#"{"rules": [{"when": "*", "turns": [\#(turns.joined(separator: ","))]}]}"#, isLocal: isLocal)
        let session = AgentSession(parts: AgentLoopKit.parts(wrap?(client) ?? client, disk: disk, home: home, clock: clock),
                                   validator: AgentLoopFakeValidator())
        guard case .root(let root) = await session.setTabFolder(AgentRootInput(fromPerson: home, origin: .tab)) else {
            XCTFail("no tab root")
            fatalError()
        }
        return Rig(session: session, client: client, root: root.alias)
    }

    private func send(_ rig: Rig, _ text: String, suggested: Bool = false) async -> [String] {
        var events: [AgentSessionEvent] = []
        let input = AgentPersonInput(typedByPerson: text, selectedPaths: [], asksForChanges: suggested)
        for await event in rig.session.send(input) { events.append(event) }
        return AgentLoopKit.words(events)
    }

    /// The text of the last item of each model turn's history: what the model was answering.
    private func lastTexts(_ rig: Rig) -> [String?] {
        rig.client.sentTurns.map { $0.history.last.flatMap(AgentLoopKit.text(of:)) }
    }

    private func timesAsked(_ rig: Rig) -> Int {
        (rig.client.sentTurns.last?.history ?? []).filter { AgentLoopKit.text(of: $0) == AgentPrompt.planNow }.count
    }

    // MARK: Asking for the plan

    func testWordsThenAPlanGiveThePlan() async {
        let rig = await self.rig([Self.list, #"{"text": "I see two images and a note."}"#, Self.propose])
        let message = AgentSuggestions.message(for: AgentSuggestion(kind: .organize, count: 4, isSelection: false),
                                               depth: .thisFolder, root: "r1")
        let words = await send(rig, message, suggested: true)
        XCTAssertEqual(words, ["status thinking", "status reading(count: 4)", "status thinking", "status thinking",
                               "reply Images go into a new Images folder.", "status checkingPlan", "plan",
                               "trace sent(names: 4, destination: \"Claude\")", "finished"],
                       "the words that came before the plan are never shown")
        XCTAssertEqual(rig.client.sentTurns.count, 3)
        XCTAssertEqual(lastTexts(rig).last, AgentPrompt.planNow, "the third turn answers Helm's ask")
        XCTAssertEqual(timesAsked(rig), 1)
    }

    func testWordsTwiceShowTheSecondAndAskNoMore() async {
        let rig = await self.rig([Self.list, #"{"text": "First."}"#, #"{"text": "Second."}"#, #"{"text": "Third."}"#])
        let words = await send(rig, "Can you organize them properly?")
        XCTAssertEqual(words, ["status thinking", "status reading(count: 4)", "status thinking", "status thinking",
                               "reply Second.", "trace sent(names: 4, destination: \"Claude\")", "finished"])
        XCTAssertEqual(rig.client.sentTurns.count, 3, "no third turn after the ask")
        XCTAssertEqual(timesAsked(rig), 1)
    }

    func testAQuestionIsAnsweredWithNoAsk() async {
        let rig = await self.rig([Self.list, #"{"text": "Two images, a note and a folder."}"#, #"{"text": "Never."}"#])
        let words = await send(rig, "what's in here?")
        XCTAssertEqual(words, ["status thinking", "status reading(count: 4)", "status thinking",
                               "reply Two images, a note and a folder.", "trace sent(names: 4, destination: \"Claude\")", "finished"])
        XCTAssertEqual(rig.client.sentTurns.count, 2)
        XCTAssertFalse(rig.client.allSentText().contains(AgentPrompt.planNow))
    }

    func testAnAskAnsweredWithNothingShowsTheFirstWords() async {
        let rig = await self.rig([#"{"text": "Only words."}"#])
        let words = await send(rig, "Organize the items", suggested: true)
        XCTAssertEqual(words, ["status thinking", "status thinking", "reply Only words.", "finished"])
        XCTAssertEqual(rig.client.sentTurns.count, 2)
    }

    func testTheAskGoesOnceEveryRequest() async {
        let rig = await self.rig([#"{"text": "Only words."}"#])
        _ = await send(rig, "move the photos")
        _ = await send(rig, "move the photos")
        XCTAssertEqual(rig.client.sentTurns.count, 4)
        XCTAssertEqual(timesAsked(rig), 2, "one ask in each of the two requests")
    }

    // MARK: Inside the request's limits

    func testNoAskOnTheRequestsLastTurn() async {
        let turns = AgentLimits.localModel.turns
        let rig = await self.rig(Array(repeating: Self.list, count: turns - 1) + [#"{"text": "Out of turns."}"#, #"{"text": "Never."}"#],
                                 isLocal: true)
        let words = await send(rig, "tidy this folder")
        XCTAssertEqual(rig.client.sentTurns.count, turns)
        XCTAssertTrue(words.contains("reply Out of turns."), "\(words)")
        XCTAssertFalse(words.contains("notice limitReached"), "\(words)")
        XCTAssertEqual(timesAsked(rig), 0)
    }

    func testNoAskOnceTheRequestsTimeIsUsed() async {
        let clock = FakeClock()
        let seconds = AgentLimits.cloudModel.requestSeconds / 2
        let rig = await self.rig([Self.list, #"{"text": "Out of time."}"#, #"{"text": "Never."}"#], clock: clock,
                                 client: { inner in AgentLoopSlowClient(inner: inner, clock: clock, seconds: seconds) })
        let words = await send(rig, "organize this")
        XCTAssertEqual(rig.client.sentTurns.count, 2)
        XCTAssertTrue(words.contains("reply Out of time."), "\(words)")
        XCTAssertEqual(timesAsked(rig), 0)
    }

    func testTheAskHoldsNoPathAndNoName() {
        XCTAssertTrue(AgentPrompt.planNow.hasPrefix("[Helm] "), "it reads as Helm's, like the note about the folders")
        XCTAssertFalse(AgentPrompt.planNow.contains("/"))
        XCTAssertTrue(AgentPrompt.planNow.contains("propose_changes"))
        XCTAssertTrue(AgentPrompt.system.contains("answer with one propose_changes call, not a description"))
    }

    // MARK: What asks for changes

    func testTypedWordsThatAskForChanges() {
        for text in ["Can you organize them properly?", "organise these", "Sort by year", "tidy up", "Move the photos to r2",
                     "copy everything in this folder to r3", "rename the scans by date", "delete the old drafts",
                     "Put the PDFs in a folder", "make a folder for receipts", "Create folders by month", "clean up Downloads"] {
            XCTAssertTrue(AgentChangeAsk.asksForChanges(text), text)
        }
    }

    func testTypedWordsThatOnlyAsk() {
        for text in ["what's in here?", "What sort of files are these?", "how big is this folder", "hello",
                     "which files are the newest?", "make sense of this", "Is anything moved?", ""] {
            XCTAssertFalse(AgentChangeAsk.asksForChanges(text), text)
        }
    }
}
