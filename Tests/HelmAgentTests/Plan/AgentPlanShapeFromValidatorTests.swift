import XCTest
import HelmCore
@testable import HelmAgent

/// The plan Helm builds from checked steps: its title, groups, marks, taken names and folder counts.
final class AgentPlanShapeFromValidatorTests: XCTestCase {
    private typealias Kit = AgentPlanTestKit
    private let work = "/home/helm/Work"
    private var disk: MemoryAgentDisk!
    private var scope: AgentPlanTestScope!

    override func setUp() async throws {
        disk = MemoryAgentDisk()
        disk.addFile(work + "/photo.png")
        disk.addFile(work + "/shot.jpg")
        disk.addFile(work + "/doc.txt")
        disk.addFile(work + "/Notes")
        disk.addFolder(work + "/Images")
        disk.addFile(work + "/A/doc.txt")
        disk.addFile(work + "/A/inner.txt")
        disk.addFolder(work + "/A/B")
        disk.addFile(work + "/A/.DS_Store")
        disk.addFolder(work + "/Empty")
        scope = AgentPlanTestScope(disk: disk)
        await scope.addRoot(work, isTab: true)
    }

    private func h(_ name: String) async -> String { await scope.handle(work + "/" + name) }

    private func validate(_ proposal: AgentProposedChanges) async -> AgentChangePlan {
        Kit.plan(await AgentPlanValidator().validate(proposal, scope: scope, disk: disk, limits: .cloudModel))
    }

    func testTitles() async {
        let photo = await h("photo.png"), doc = await h("doc.txt"), empty = await h("Empty"), a = await h("A")
        let organize = await validate(Kit.proposal(
            newFolders: [("n1", "r1", "Pictures"), ("n2", "r1", "Text")], moves: [([photo], "", "n1"), ([doc], "", "n2")]))
        XCTAssertEqual(organize.title, .organize(rootLabel: "Work"))
        XCTAssertEqual(organize.title.text, "Organize “Work”")
        let mixed = await validate(Kit.proposal(moves: [([photo], "", empty)], renames: [(doc, "Read Me.txt")]))
        XCTAssertEqual(mixed.title, .organize(rootLabel: "Work"))
        let moved = await validate(Kit.proposal(moves: [([photo, doc], "", empty)]))
        XCTAssertEqual(moved.title, .move(2))
        let movedIntoNew = await validate(Kit.proposal(newFolders: [("n1", "r1", "Later"), ("n2", "n1", "Inside")],
                                                       moves: [([photo, doc], "", "n2")]))
        XCTAssertEqual(movedIntoNew.title, .move(2))
        let copied = await validate(Kit.proposal(copies: [([photo], "", a)]))
        XCTAssertEqual(copied.title, .copy(1))
        let renamed = await validate(Kit.proposal(renames: [(doc, "Read Me.txt"), (photo, "Holiday.png")]))
        XCTAssertEqual(renamed.title, .rename(2))
        let trashed = await validate(Kit.proposal(trash: [doc]))
        XCTAssertEqual(trashed.title, .trash(1))
    }

    func testAnExistingFolderIsUsedForANewFolderKey() async {
        let photo = await h("photo.png"), shot = await h("shot.jpg"), doc = await h("doc.txt")
        let plan = await validate(Kit.proposal(
            newFolders: [("n1", "r1", "images"), ("n2", "r1", "notes"), ("n3", "r1", "IMAGES")],
            moves: [([photo], "", "n1"), ([shot], "", "n3"), ([doc], "", "n2")]))
        // "images" is the folder Images; "notes" is a file there, so it is taken; n3 is the same folder as n1.
        XCTAssertEqual(Kit.names(plan), ["move photo.png", "move shot.jpg"])
        XCTAssertEqual(plan.leftOut, [.name_taken: 2])
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.groups[0].kind, .moves(toLabel: "Images", isNew: false))
        guard case .move(_, .existing(let target)) = plan.steps[0] else { return XCTFail("\(plan.steps[0])") }
        XCTAssertEqual(target.path, work + "/Images")
        XCTAssertEqual(plan.counts(ticked: plan.defaultTicked), AgentPlanCounts(moves: 2))
    }

    func testStepsThatWouldDoNothingAreDropped() async {
        let doc = await h("doc.txt"), photo = await h("photo.png")
        let plan = await validate(Kit.proposal(moves: [([doc], "", "r1")], renames: [(photo, "photo.png")]))
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.leftOut, [:])
        XCTAssertTrue(plan.showsNothingToDo)
        // A change of case alone is a change.
        let cased = await validate(Kit.proposal(renames: [(photo, "Photo.PNG")]))
        XCTAssertEqual(Kit.names(cased), ["rename photo.png Photo.PNG"])
        XCTAssertEqual(cased.keepsBoth, [], "its own name doesn't count as taken")
    }

    func testANewFolderLeftEmptyByALeftOutCopyGoesToo() async {
        let photo = await h("photo.png")
        let plan = await validate(Kit.proposal(newFolders: [("n1", "r1", "Copies")], copies: [(["f999"], "", "n1")]))
        XCTAssertTrue(plan.steps.isEmpty, "no empty folder in place of the copy: \(Kit.names(plan))")
        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(plan.leftOut.isEmpty)
        XCTAssertFalse(plan.showsNothingToDo, "the left-out line says what happened")
        // A folder something still goes into stays, and so does one asked for with nothing left out.
        let kept = await validate(Kit.proposal(newFolders: [("n1", "r1", "Copies")], copies: [(["f999", photo], "", "n1")]))
        XCTAssertEqual(Kit.names(kept), ["new n1 Copies", "copy photo.png"])
        let asked = await validate(Kit.proposal(newFolders: [("n1", "r1", "Later")]))
        XCTAssertEqual(Kit.names(asked), ["new n1 Later"])
    }

    func testEveryStepIsInExactlyOneGroupInTheCardsOrder() async {
        let photo = await h("photo.png"), shot = await h("shot.jpg"), doc = await h("doc.txt"), a = await h("A")
        let inner = await h("A/inner.txt")
        let plan = await validate(Kit.proposal(
            newFolders: [("n1", "r1", "Pictures"), ("n2", "r1", "Spare"), ("n3", "n1", "Holiday")],
            moves: [([photo], "", "n3"), ([shot], "", "n1")], copies: [([doc], "", a)],
            renames: [(inner, "Inner.txt")], trash: [await h("Notes")]))
        let all = plan.groups.flatMap(\.steps).sorted()
        XCTAssertEqual(all, Array(plan.steps.indices))
        XCTAssertEqual(plan.groups.map(\.id), Array(1...plan.groups.count))
        XCTAssertEqual(plan.groups.map(\.kind), [
            .newFolders, .renames, .moves(toLabel: "Holiday", isNew: true), .moves(toLabel: "Pictures", isNew: true),
            .copies(toLabel: "A", isNew: false), .trash])
        // n1 and n3 go with the first moves into them; n2, which nothing goes into, has a group of its own.
        let names = Kit.names(plan)
        XCTAssertEqual(plan.groups[0].steps.map { names[$0] }, ["new n2 Spare"])
        XCTAssertEqual(plan.groups[2].steps.map { names[$0] }, ["new n1 Pictures", "new n3 Holiday", "move photo.png"])
        XCTAssertEqual(plan.groups[3].steps.map { names[$0] }, ["move shot.jpg"])
        XCTAssertEqual(plan.defaultTicked, [1, 2, 3, 4, 5])
        XCTAssertEqual(plan.counts(ticked: [4]), AgentPlanCounts(moves: 1, newFolders: 1))
    }

    func testStepsToOneDestinationWithDifferentGuardsAreSeparateGroups() async {
        disk.addFile("/home/helm/Documents/report.pdf")
        disk.addFolder("/home/helm/Downloads")
        disk.setProbe(StorageProbe(isUbiquitous: true), under: "/home/helm/Documents")
        await scope.addRoot("/home/helm", label: "Home")
        let report = await scope.handle("/home/helm/Documents/report.pdf"), downloads = await scope.handle("/home/helm/Downloads")
        let doc = await h("doc.txt")
        let plan = await validate(Kit.proposal(moves: [([report, doc], "", downloads)]))
        XCTAssertEqual(Kit.names(plan), ["move report.pdf", "move doc.txt"])
        XCTAssertEqual(plan.groups.count, 2)
        XCTAssertEqual(plan.groups.map(\.kind), [.moves(toLabel: "Downloads", isNew: false), .moves(toLabel: "Downloads", isNew: false)])
        XCTAssertEqual(plan.groups.map(\.guardedBy), [.leaves, nil])
        XCTAssertEqual(plan.groups.map(\.place), ["iCloud Drive", nil])
        XCTAssertEqual(plan.defaultTicked, [2])
    }

    func testANameTakenWhereAStepGoesIsMarkedToKeepBoth() async {
        let doc = await h("doc.txt"), photo = await h("photo.png"), a = await h("A"), shot = await h("shot.jpg")
        let innerDoc = await h("A/doc.txt")
        let plan = await validate(Kit.proposal(
            newFolders: [("n1", "r1", "Pile")],
            moves: [([doc, photo], "", a)], copies: [([innerDoc], "", "n1"), ([shot], "", "n1")],
            renames: [(await h("A/inner.txt"), "DOC.txt")]))
        let names = Kit.names(plan)
        let taken = Set(plan.keepsBoth.map { names[$0] })
        // A already holds doc.txt; inner.txt renamed to DOC.txt clashes with it too. Nothing in Pile clashes.
        XCTAssertEqual(taken, ["move doc.txt", "rename inner.txt DOC.txt"])
        let twice = await validate(Kit.proposal(copies: [([doc], "", "r1"), ([innerDoc], "", "r1")]))
        // A copy into its own folder takes a name already there; so does a second doc.txt.
        XCTAssertEqual(twice.keepsBoth, [0, 1])
    }

    func testAFolderSourceCarriesHowManyItemsItHolds() async {
        let a = await h("A"), empty = await h("Empty"), photo = await h("photo.png")
        let plan = await validate(Kit.proposal(moves: [([a, empty, photo], "", await h("Images"))]))
        let holds = plan.steps.map { step -> Int? in
            guard case .move(let item, _) = step else { return -1 }
            return item.holds
        }
        // A holds doc.txt, inner.txt and B; .DS_Store isn't counted.
        XCTAssertEqual(holds, [3, 0, nil])
    }

    func testAFolderInASyncingPlaceHoldsAFileThatIsntDownloadedWhenTheWalkRunsOut() async {
        let drive = "/home/helm/Library/CloudStorage/GoogleDrive-test@example.com/My Drive"
        for index in 1...2_001 { disk.addFile(drive + "/Big/Sub/file \(index).txt") }
        for index in 1...1_998 { disk.addFile(drive + "/Small/file \(index).txt") }
        let root = await scope.addRoot(drive, label: "My Drive")
        XCTAssertEqual(root.storage.kind, .cloud)
        let big = await scope.handle(drive + "/Big"), small = await scope.handle(drive + "/Small")
        let plan = await validate(Kit.proposal(copies: [([big, small], "", "r1")]))
        // Big holds 2,002 entries, past the walk's 2,000; Small's 1,998 are all looked at and all downloaded.
        XCTAssertEqual(plan.leftOut, [.not_downloaded: 1])
        XCTAssertEqual(Kit.names(plan), ["copy Small"])
        XCTAssertNil(plan.groups.first?.guardedBy)
        // Inside its own place a move needs no bytes, so the walk isn't needed and Big moves.
        let moved = await validate(Kit.proposal(newFolders: [("n1", root.alias, "Old")], moves: [([big], "", "n1")]))
        XCTAssertEqual(Kit.names(moved), ["new n1 Old", "move Big"])
    }
}
