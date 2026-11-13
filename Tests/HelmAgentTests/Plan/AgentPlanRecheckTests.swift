import XCTest
import HelmCore
@testable import HelmAgent

/// Looking at a plan again right before Apply: anything that changed since it was checked stops it.
final class AgentPlanRecheckTests: XCTestCase {
    private typealias Kit = AgentPlanTestKit
    private let work = "/home/helm/Work"
    private var disk: MemoryAgentDisk!
    private var scope: AgentPlanTestScope!

    override func setUp() async throws {
        disk = MemoryAgentDisk()
        disk.addFile(work + "/doc.txt")
        disk.addFile(work + "/photo.png")
        disk.addFile(work + "/old.tmp")
        disk.addFolder(work + "/Archive")
        scope = AgentPlanTestScope(disk: disk)
        await scope.addRoot(work, isTab: true)
    }

    private func h(_ name: String) async -> String { await scope.handle(work + "/" + name) }

    /// Move doc and photo to Archive, and old.tmp to the Trash.
    private func makePlan() async -> AgentChangePlan {
        let archive = await h("Archive")
        let plan = Kit.plan(await AgentPlanValidator().validate(
            Kit.proposal(moves: [([await h("doc.txt"), await h("photo.png")], "", archive)], trash: [await h("old.tmp")]),
            scope: scope, disk: disk, limits: .cloudModel))
        XCTAssertEqual(Kit.names(plan), ["move doc.txt", "move photo.png", "trash old.tmp"])
        return plan
    }

    private func recheck(_ plan: AgentChangePlan, ticked: Set<Int>? = nil) async -> AgentRecheck {
        await AgentPlanValidator().recheck(plan, ticked: ticked ?? Set(plan.groups.map(\.id)), scope: scope, disk: disk)
    }

    func testAnUnchangedPlanMayRun() async {
        let plan = await makePlan()
        let answer1 = await recheck(plan)
        XCTAssertEqual(answer1, .ok)
        let answer2 = await recheck(plan, ticked: plan.defaultTicked)
        XCTAssertEqual(answer2, .ok)
    }

    func testAChangedSourceStopsApplyAndTheNewPlanHasANewID() async {
        let plan = await makePlan()
        disk.replaceIdentity(at: work + "/doc.txt")
        guard case .changed(let fresh) = await recheck(plan) else { return XCTFail("a changed source ran") }
        XCTAssertNotEqual(fresh.id, plan.id)
        XCTAssertEqual(Kit.names(fresh), ["move photo.png", "trash old.tmp"])
        XCTAssertEqual(fresh.title, .organize(rootLabel: "Work"))
        // Its ticks start over: the Trash group is off again.
        XCTAssertEqual(fresh.defaultTicked, Set(fresh.groups.filter { $0.guardedBy == nil }.map(\.id)))
        XCTAssertFalse(fresh.defaultTicked.contains { id in fresh.groups.first { $0.id == id }?.kind == .trash })
    }

    func testASourceSwappedForAFolderOfTheSameNameStopsApply() async {
        let plan = await makePlan()
        disk.remove(work + "/photo.png")
        disk.addFolder(work + "/photo.png")
        guard case .changed(let fresh) = await recheck(plan) else { return XCTFail("a different kind of item ran") }
        XCTAssertEqual(Kit.names(fresh), ["move doc.txt", "trash old.tmp"])
    }

    func testOnlyTickedStepsAreLookedAtItemByItem() async {
        let plan = await makePlan()
        disk.replaceIdentity(at: work + "/old.tmp")
        let moves = Set(plan.groups.filter { $0.kind != .trash }.map(\.id))
        let answer3 = await recheck(plan, ticked: moves)
        XCTAssertEqual(answer3, .ok)
        guard case .changed(let fresh) = await recheck(plan) else { return XCTFail("a ticked changed step ran") }
        XCTAssertEqual(Kit.names(fresh), ["move doc.txt", "move photo.png"])
    }

    func testAReplacedDestinationStopsApply() async {
        let plan = await makePlan()
        disk.replaceIdentity(at: work + "/Archive")
        guard case .changed(let fresh) = await recheck(plan) else { return XCTFail("a replaced destination ran") }
        XCTAssertEqual(Kit.names(fresh), ["trash old.tmp"])
        XCTAssertNotEqual(fresh.id, plan.id)
    }

    func testAReplacedRootStopsApply() async {
        let plan = await makePlan()
        disk.replaceIdentity(at: work)
        guard case .changed(let fresh) = await recheck(plan) else { return XCTFail("a replaced root ran") }
        XCTAssertTrue(fresh.steps.isEmpty)
        XCTAssertTrue(fresh.groups.isEmpty)
        XCTAssertNotEqual(fresh.id, plan.id)
    }

    func testAPlaceThatChangedRulesStopsApply() async {
        let plan = await makePlan()
        // Work turns out to be a server share that can only be viewed.
        disk.setProbe(StorageProbe(isLocal: false, isReadOnly: true), under: work)
        guard case .changed(let fresh) = await recheck(plan) else { return XCTFail("a read-only place ran") }
        XCTAssertTrue(fresh.steps.isEmpty)
        XCTAssertEqual(fresh.leftOut, [.read_only: 3])
        XCTAssertEqual(fresh.cardNotes, [.readOnly(place: "Server")])
    }

    func testASilentPlaceStopsApply() async {
        let share = "/Volumes/share/Team"
        disk.addFile(share + "/notes.txt")
        disk.setProbe(StorageProbe(isLocal: false, hasTrash: true, volumeRoot: "/Volumes/share"), under: "/Volumes/share")
        let root = await scope.addRoot(share, label: "Team")
        let notes = await scope.handle(share + "/notes.txt", under: root.alias)
        let plan = Kit.plan(await AgentPlanValidator().validate(Kit.proposal(renames: [(notes, "minutes.txt")]),
                                                                scope: scope, disk: disk, limits: .cloudModel))
        XCTAssertEqual(Kit.names(plan), ["rename notes.txt minutes.txt"])
        let answer4 = await recheck(plan)
        XCTAssertEqual(answer4, .ok)
        disk.setDelay(5, under: "/Volumes/share")
        let answer5 = await recheck(plan)
        XCTAssertEqual(answer5, .notResponding(label: "Team"))
    }

    func testADiskThatWentAwayIsDisconnected() async {
        let volume = "/Volumes/Backup"
        disk.addFile(volume + "/Photos/one.jpg")
        disk.setProbe(StorageProbe(isInternal: false, hasTrash: true, volumeRoot: volume), under: volume)
        let root = await scope.addRoot(volume + "/Photos", label: "Photos")
        XCTAssertEqual(root.storage.kind, .external)
        let one = await scope.handle(volume + "/Photos/one.jpg", under: root.alias)
        let plan = Kit.plan(await AgentPlanValidator().validate(Kit.proposal(trash: [one]),
                                                                scope: scope, disk: disk, limits: .cloudModel))
        XCTAssertEqual(Kit.names(plan), ["trash one.jpg"])
        disk.remove(volume)
        let answer6 = await recheck(plan)
        XCTAssertEqual(answer6, .disconnected(label: "Photos"))
    }

    func testANewFolderWhoseParentChangedTakesItsStepsAlong() async {
        let plan = Kit.plan(await AgentPlanValidator().validate(
            Kit.proposal(newFolders: [("n1", await h("Archive"), "2026")], moves: [([await h("doc.txt")], "", "n1")],
                         trash: [await h("old.tmp")]),
            scope: scope, disk: disk, limits: .cloudModel))
        XCTAssertEqual(Kit.names(plan), ["new n1 2026", "move doc.txt", "trash old.tmp"])
        disk.replaceIdentity(at: work + "/Archive")
        guard case .changed(let fresh) = await recheck(plan) else { return XCTFail("a replaced parent ran") }
        XCTAssertEqual(Kit.names(fresh), ["trash old.tmp"])
    }
}
