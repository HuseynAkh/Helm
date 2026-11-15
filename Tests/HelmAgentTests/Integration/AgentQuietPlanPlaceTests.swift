import XCTest
import HelmCore
@testable import HelmAgent

/// A plan whose folder stops answering while the real validator checks it ends the request with one line, naming
/// the folder, and the model gets no second turn to try again.
final class AgentQuietPlanPlaceTests: XCTestCase {
    func testAPlanInAPlaceThatStopsAnsweringEndsTheRequestWithTheNotRespondingLine() async throws {
        let home = "/home/helm", folder = "/home/helm/Mess"
        let disk = MemoryAgentDisk(home: home)
        disk.addFile(folder + "/a.png")
        let scripted = ScriptedModelClient()
        try scripted.load(Data("""
            {"rules": [{"when": "*", "turns": [
              {"calls": [{"name": "propose_changes", "args": {
                "new_folders": [{"key": "n1", "parent": "@root", "name": "Images"}],
                "moves": [{"items": [], "all_in": "@root", "to": "n1"}], "copies": [], "renames": [], "trash": []}}]},
              {"text": "Trying again."}]}]}
            """.utf8))
        let parts = AgentSessionParts(client: { .success(scripted) }, disk: disk, home: home, supportFolder: home + "/.helm-support",
                                      clock: SystemHelmClock(), listSecondsOverride: { 0.2 })
        let session = AgentSession(parts: parts, validator: AgentPlanValidator())
        guard case .root = await session.setTabFolder(AgentRootInput(fromPerson: folder, origin: .tab)) else {
            return XCTFail("the folder is a root")
        }
        // From now on every question about the folder takes longer than a listing may wait.
        disk.setDelay(1, under: folder)

        var events: [AgentSessionEvent] = []
        for await event in session.send(AgentPersonInput(typedByPerson: "organize", selectedPaths: [])) { events.append(event) }
        XCTAssertTrue(events.contains { if case .notice(.notResponding(label: "Mess")) = $0 { return true }; return false }, "\(events)")
        XCTAssertFalse(events.contains { if case .plan = $0 { return true }; return false }, "no card for a plan that couldn't be checked")
        XCTAssertEqual(scripted.sentTurns.count, 1, "the model isn't asked again")
    }
}
