import XCTest
import HelmCore
@testable import HelmAgent

/// Place facts belong to a folder, not to a root: one This Mac root can hold an iCloud Documents, and the rules
/// follow each step's own folders.
final class AgentPlacePerFolderTests: XCTestCase {
    private typealias Kit = AgentPlanTestKit
    private let home = "/home/helm"
    private var disk: MemoryAgentDisk!
    private var scope: AgentPlanTestScope!

    override func setUp() async throws {
        disk = MemoryAgentDisk()
        disk.addFile(home + "/Documents/cloud.pdf")
        disk.markCloudOnly(home + "/Documents/cloud.pdf")
        disk.addFile(home + "/Documents/local.pdf")
        disk.addFile(home + "/Documents/notes.txt")
        disk.addFile(home + "/Documents/Mixed/here.txt")
        disk.addFile(home + "/Documents/Mixed/Deep/away.mov")
        disk.markCloudOnly(home + "/Documents/Mixed/Deep/away.mov")
        disk.addFile(home + "/Downloads/get.zip")
        disk.addFile(home + "/Downloads/setup.dmg")
        // iCloud keeps Documents: injected by prefix, as a fixture run does.
        disk.setProbe(StorageProbe(isUbiquitous: true), under: home + "/Documents")
        scope = AgentPlanTestScope(disk: disk)
        let root = await scope.addRoot(home, label: "Home", isTab: true)
        XCTAssertEqual(root.storage.kind, .thisMac)
    }

    private func h(_ path: String) async -> String { await scope.handle(home + "/" + path) }

    func testEachStepIsRuledByItsOwnFolders() async {
        let documents = await h("Documents"), downloads = await h("Downloads")
        let cloud = await h("Documents/cloud.pdf"), local = await h("Documents/local.pdf"), get = await h("Downloads/get.zip")
        let plan = Kit.plan(await AgentPlanValidator().validate(
            Kit.proposal(moves: [([cloud, local], "", downloads), ([get], "", documents)]),
            scope: scope, disk: disk, limits: .cloudModel))

        // The file that isn't downloaded can't leave iCloud without its bytes.
        XCTAssertEqual(plan.leftOut, [.not_downloaded: 1])
        XCTAssertEqual(Kit.names(plan), ["move local.pdf", "move get.zip"])
        let leaving = Kit.group(plan, holding: 0), arriving = Kit.group(plan, holding: 1)
        XCTAssertEqual(leaving?.kind, .moves(toLabel: "Downloads", isNew: false))
        XCTAssertEqual(leaving?.guardedBy, .leaves)
        XCTAssertEqual(leaving?.place, "iCloud Drive")
        XCTAssertEqual(arriving?.kind, .moves(toLabel: "Documents", isNew: false))
        XCTAssertEqual(arriving?.guardedBy, .arrives)
        XCTAssertEqual(arriving?.place, "iCloud Drive")
        XCTAssertEqual(plan.defaultTicked, [])
        XCTAssertEqual(plan.cardNotes, [.notDownloaded(1), .syncs])
    }

    func testFactsAreAskedOncePerFolder() async {
        let documents = await h("Documents"), downloads = await h("Downloads")
        let local = await h("Documents/local.pdf"), notes = await h("Documents/notes.txt")
        let get = await h("Downloads/get.zip"), setup = await h("Downloads/setup.dmg")
        _ = await AgentPlanValidator().validate(
            Kit.proposal(moves: [([local, notes], "", downloads), ([get, setup], "", documents)],
                         renames: [(await h("Documents/Mixed/here.txt"), "there.txt")]),
            scope: scope, disk: disk, limits: .cloudModel)
        let asked = await scope.factsAsked
        XCTAssertEqual(Set(asked), [home + "/Documents", home + "/Downloads", home + "/Documents/Mixed"])
        XCTAssertEqual(asked.count, Set(asked).count, "a folder was asked twice: \(asked)")
    }

    func testAFolderHoldingAFileThatIsntDownloadedStaysWhereItIs() async {
        let downloads = await h("Downloads"), mixed = await h("Documents/Mixed"), documents = await h("Documents")
        let plan = Kit.plan(await AgentPlanValidator().validate(
            Kit.proposal(moves: [([mixed], "", downloads)]), scope: scope, disk: disk, limits: .cloudModel))
        XCTAssertEqual(plan.leftOut, [.not_downloaded: 1])
        XCTAssertTrue(plan.steps.isEmpty)
        // Inside iCloud the same folder needs no bytes, so it moves.
        let inPlace = Kit.plan(await AgentPlanValidator().validate(
            Kit.proposal(newFolders: [("n1", documents, "Archive")], moves: [([mixed], "", "n1")]),
            scope: scope, disk: disk, limits: .cloudModel))
        XCTAssertEqual(Kit.names(inPlace), ["new n1 Archive", "move Mixed"])
        XCTAssertEqual(inPlace.leftOut, [:])
        XCTAssertNil(inPlace.groups.first?.guardedBy)
        XCTAssertEqual(inPlace.cardNotes, [.syncs])
    }
}
