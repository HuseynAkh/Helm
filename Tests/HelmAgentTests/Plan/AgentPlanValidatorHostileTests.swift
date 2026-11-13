import XCTest
import HelmCore
@testable import HelmAgent

/// A model that proposes what it shouldn't. Every hostile step is left out with its code, or the whole call is
/// refused, and the disk is the same afterwards.
final class AgentPlanValidatorHostileTests: XCTestCase {
    private typealias Kit = AgentPlanTestKit
    private let work = "/home/helm/Work"
    private var disk: MemoryAgentDisk!
    private var scope: AgentPlanTestScope!
    private var before: [String] = []

    override func setUp() async throws {
        disk = MemoryAgentDisk()
        disk.addFile(work + "/A/inner.txt")
        disk.addFolder(work + "/A/B")
        disk.addFile(work + "/doc.txt")
        disk.addFile(work + "/photo.png")
        disk.addPackage(work + "/Tool.app")
        disk.addLink(work + "/shortcut", to: work + "/A")
        disk.addFolder(work + "/Private")
        disk.addFile("/home/helm/Secret/secret.txt")
        disk.addFolder("/home/helm/Other/Inside")
        scope = AgentPlanTestScope(disk: disk)
        await scope.addRoot(work, isTab: true)              // r1
        await scope.addRoot("/home/helm", label: "Home")    // r2, which holds r1 too
        await scope.protect(work + "/Private")
        before = await Kit.snapshot(disk)
    }

    private func h(_ name: String, under alias: String? = nil) async -> String {
        await scope.handle(name.hasPrefix("/") ? name : work + "/" + name, under: alias)
    }

    private func validate(_ proposal: AgentProposedChanges, limits: AgentLimits = .cloudModel) async -> AgentPlanVerdict {
        let verdict = await AgentPlanValidator().validate(proposal, scope: scope, disk: disk, limits: limits)
        let after = await Kit.snapshot(disk)
        XCTAssertEqual(after, before, "the disk changed")
        return verdict
    }

    func testUnknownIdsAndPathsWhereAnIdBelongsAreLeftOut() async {
        let doc = await h("doc.txt")
        let plan = Kit.plan(await validate(Kit.proposal(
            moves: [(["zz9", "/home/helm/Secret/secret.txt", "~/Secret", "f999", doc], "", "r1x")],
            trash: ["../Secret", "file:///home/helm/Secret"])))
        // The destination is unknown, so all five sources go with it; the two Trash entries are unknown too.
        XCTAssertEqual(plan.leftOut, [.unknown_id: 7])
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.notices, [.notAllowed(7)])
        XCTAssertFalse(plan.showsNothingToDo)

        let a = await h("A")
        let sourcesOnly = Kit.plan(await validate(Kit.proposal(moves: [(["zz9", "~/Secret/secret.txt", doc], "", a)])))
        XCTAssertEqual(sourcesOnly.leftOut, [.unknown_id: 2])
        XCTAssertEqual(Kit.names(sourcesOnly), ["move doc.txt"])
    }

    func testIdsFromARetiredRootAreStale() async {
        let other = await scope.addRoot("/home/helm/Other")
        let inside = await scope.handle("/home/helm/Other/Inside", under: other.alias)
        let doc = await h("doc.txt")
        await scope.retireRoot(other.alias)
        let plan = Kit.plan(await validate(Kit.proposal(moves: [([doc], "", inside)], trash: [inside, other.alias])))
        XCTAssertEqual(plan.leftOut, [.stale_id: 3])
        XCTAssertTrue(plan.steps.isEmpty)
    }

    func testAKeyUsedBeforeItIsDeclaredIsUnknown() async {
        let doc = await h("doc.txt")
        let plan = Kit.plan(await validate(Kit.proposal(
            newFolders: [("n2", "n1", "Inner"), ("n1", "r1", "Outer")],
            moves: [([doc], "", "n3")])))
        XCTAssertEqual(plan.leftOut, [.unknown_id: 2])
        XCTAssertEqual(Kit.names(plan), ["new n1 Outer"])
        // A step into a key whose folder was left out is left out with it.
        let chained = Kit.plan(await validate(Kit.proposal(
            newFolders: [("n1", "r1", "Bad/Name"), ("n2", "n1", "Inner")], moves: [([doc], "", "n2")])))
        XCTAssertEqual(chained.leftOut, [.name_not_allowed: 3])
        XCTAssertTrue(chained.steps.isEmpty)
    }

    func testMalformedOrRepeatedKeysRefuseTheCall() async {
        for keys in [["x1"], ["n0"], ["n01"], ["n"], ["n1", "n1"], ["n1 "]] {
            let verdict = await validate(Kit.proposal(newFolders: keys.map { ($0, "r1", "Folder " + $0) }))
            guard case .refused(let code) = verdict else { return XCTFail("\(keys) wasn't refused") }
            XCTAssertEqual(code, .bad_arguments, "\(keys)")
        }
    }

    func testARootIsNeverASourceUnderItsOwnAliasOrASecondHandle() async {
        let a = await h("A")
        let workUnderHome = await scope.handle(work, under: "r2")
        XCTAssertNotEqual(workUnderHome, "r1")
        let plan = Kit.plan(await validate(Kit.proposal(
            moves: [(["r1"], "", a)], copies: [([workUnderHome], "", a)],
            renames: [("r1", "Renamed"), (workUnderHome, "Renamed Too")], trash: ["r2"])))
        XCTAssertEqual(plan.leftOut, [.not_allowed: 5])
        XCTAssertTrue(plan.steps.isEmpty)
    }

    func testAFolderCantGoIntoItselfOrAnythingBelowIt() async {
        let a = await h("A"), b = await h("A/B")
        let plan = Kit.plan(await validate(Kit.proposal(
            newFolders: [("n1", b, "Deeper")],
            moves: [([a], "", a), ([a], "", b)], copies: [([a], "", "n1")])))
        // n1 is made; the three ways of putting A inside itself are not.
        XCTAssertEqual(plan.leftOut, [.not_allowed: 3])
        XCTAssertEqual(Kit.names(plan), ["new n1 Deeper"])
    }

    func testTheSameItemTwiceUnderTwoHandlesIsLeftOutEveryTime() async {
        let docHere = await h("doc.txt", under: "r1"), docThere = await h("doc.txt", under: "r2")
        XCTAssertNotEqual(docHere, docThere)
        let a = await h("A"), photo = await h("photo.png")
        let plan = Kit.plan(await validate(Kit.proposal(moves: [([docHere, photo], "", a)], trash: [docThere])))
        XCTAssertEqual(plan.leftOut, [.listed_twice: 2])
        XCTAssertEqual(Kit.names(plan), ["move photo.png"])
    }

    func testAFileAPackageAndALinkCantStandWhereAFolderBelongs() async {
        let doc = await h("doc.txt"), tool = await h("Tool.app"), link = await h("shortcut"), photo = await h("photo.png")
        let a = await h("A")
        for wrong in [doc, tool, link] {
            let plan = Kit.plan(await validate(Kit.proposal(
                newFolders: [("n1", wrong, "Made")],
                moves: [([photo], "", wrong), ([], wrong, a)], copies: [([photo], "", wrong)])))
            XCTAssertEqual(plan.leftOut, [.not_allowed: 4], wrong)
            XCTAssertTrue(plan.steps.isEmpty, wrong)
        }
    }

    func testAProtectedFolderIsNeitherASourceNorADestination() async {
        let secret = await h("Private"), photo = await h("photo.png"), a = await h("A")
        let plan = Kit.plan(await validate(Kit.proposal(
            newFolders: [("n1", secret, "In There")],
            moves: [([secret], "", a), ([photo], "", secret), ([], secret, a)], trash: [secret])))
        XCTAssertEqual(plan.leftOut, [.not_allowed: 5])
        XCTAssertTrue(plan.steps.isEmpty)
    }

    func testTrashOfEverythingIsOneGuardedGroupThatStartsUnticked() async {
        let everything = [await h("A"), await h("doc.txt"), await h("photo.png"), await h("Tool.app"), await h("shortcut"),
                          await h("Private"), "r1"]
        let plan = Kit.plan(await validate(Kit.proposal(trash: everything)))
        XCTAssertEqual(plan.leftOut, [.not_allowed: 2])
        XCTAssertEqual(Kit.names(plan), ["trash A", "trash doc.txt", "trash photo.png", "trash Tool.app", "trash shortcut"])
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.groups.first?.kind, .trash)
        XCTAssertEqual(plan.groups.first?.guardedBy, .trash)
        XCTAssertEqual(plan.groups.first?.steps, [0, 1, 2, 3, 4])
        XCTAssertEqual(plan.defaultTicked, [])
        XCTAssertEqual(plan.counts(ticked: plan.defaultTicked).total, 0)
        XCTAssertEqual(plan.title, .trash(5))
    }

    func testTooManyStepsRefuseTheWholeCallBeforeAnythingIsLookedUp() async {
        let asked = disk.asked.count
        let verdict = await AgentPlanValidator().validate(Kit.proposal(trash: (1...1_001).map { "f\($0)" }), scope: scope,
                                                          disk: disk, limits: .cloudModel)
        guard case .refused(.too_many) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertEqual(disk.asked.count, asked, "nothing was looked up")
        let atTheLimit = await validate(Kit.proposal(trash: (1...1_000).map { "f\($0)" }))
        guard case .plan(let plan) = atTheLimit else { return XCTFail("\(atTheLimit)") }
        XCTAssertEqual(plan.leftOut, [.unknown_id: 1_000])

        var small = AgentLimits.cloudModel
        small.planNewFolders = 2
        let folders = await validate(Kit.proposal(newFolders: [("n1", "r1", "A1"), ("n2", "r1", "A2"), ("n3", "r1", "A3")]),
                                     limits: small)
        guard case .refused(.too_many) = folders else { return XCTFail("\(folders)") }
    }

    func testAllInThatExpandsPastTheLimitRefusesTheCall() async {
        var small = AgentLimits.cloudModel
        small.planSteps = 3
        let a = await h("A")
        let verdict = await validate(Kit.proposal(moves: [([], "r1", a)]), limits: small)
        guard case .refused(.too_many) = verdict else { return XCTFail("\(verdict)") }
    }

    func testNamesWithASlashOrHiddenCharactersAreRefused() async {
        let doc = await h("doc.txt"), a = await h("A")
        let plan = Kit.plan(await validate(Kit.proposal(
            newFolders: [("n1", "r1", "a/b"), ("n2", "r1", "Pics\u{200B}"), ("n3", "r1", "X.app"), ("n4", "r1", "../up")],
            renames: [(doc, "x/y.txt"), (doc, "inv\u{202E}fdp.txt"), (a, "Folder.command")])))
        XCTAssertEqual(plan.leftOut, [.name_not_allowed: 7])
        XCTAssertTrue(plan.steps.isEmpty)
    }

    func testAPackageKeepsItsExtensionWhenRenamed() async {
        let tool = await h("Tool.app")
        for name in ["Tool", "Tool.zip", "Tool.app.txt"] {
            let plan = Kit.plan(await validate(Kit.proposal(renames: [(tool, name)])))
            XCTAssertEqual(plan.leftOut, [.name_not_allowed: 1], name)
            XCTAssertTrue(plan.steps.isEmpty, name)
        }
        let plan = Kit.plan(await validate(Kit.proposal(renames: [(tool, "Helper.APP")])))
        XCTAssertEqual(Kit.names(plan), ["rename Tool.app Helper.APP"])
    }

    func testOnlyTheHonestStepsOfAMixedProposalSurvive() async {
        let doc = await h("doc.txt"), photo = await h("photo.png"), a = await h("A"), tool = await h("Tool.app")
        let plan = Kit.plan(await validate(Kit.proposal(
            newFolders: [("n1", "r1", "Images")],
            moves: [([photo, "r1", "zz"], "", "n1"), ([doc], "", tool)],
            renames: [(doc, "Doc.app")])))
        XCTAssertEqual(Kit.names(plan), ["new n1 Images", "move photo.png"])
        XCTAssertEqual(plan.leftOut, [.not_allowed: 2, .unknown_id: 1, .name_not_allowed: 1])
        XCTAssertEqual(plan.cardNotes, [.notAllowed(4)])
    }
}
