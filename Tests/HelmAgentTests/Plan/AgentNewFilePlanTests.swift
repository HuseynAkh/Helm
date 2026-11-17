import XCTest
import HelmCore
@testable import HelmAgent

/// New files in a plan: where they may go, what they may be called, how much text they may hold, their group, title
/// and counts, names already taken, the place rules, and a look again before Apply. Checking one changes nothing.
final class AgentNewFilePlanTests: XCTestCase {
    private typealias Kit = AgentPlanTestKit
    private let work = "/home/helm/Work"
    private var disk: MemoryAgentDisk!
    private var scope: AgentPlanTestScope!

    override func setUp() async throws {
        disk = MemoryAgentDisk()
        disk.addFile(work + "/doc.txt")
        disk.addFile(work + "/photo.png")
        disk.addFolder(work + "/Trip")
        disk.addFolder(work + "/Private")
        scope = AgentPlanTestScope(disk: disk)
        await scope.addRoot(work, isTab: true)
        await scope.protect(work + "/Private")
    }

    private func h(_ name: String) async -> String { await scope.handle(work + "/" + name) }

    private func validate(_ proposal: AgentProposedChanges, limits: AgentLimits = .cloudModel) async -> AgentPlanVerdict {
        let before = await Kit.snapshot(disk)
        let verdict = await AgentPlanValidator().validate(proposal, scope: scope, disk: disk, limits: limits)
        let after = await Kit.snapshot(disk)
        XCTAssertEqual(after, before, "checking a plan changed the disk")
        return verdict
    }

    private func checked(_ proposal: AgentProposedChanges, file: StaticString = #filePath, line: UInt = #line) async -> AgentChangePlan {
        Kit.plan(await validate(proposal), file: file, line: line)
    }

    private func refusal(_ verdict: AgentPlanVerdict) -> AgentToolCode? {
        if case .refused(let code) = verdict { return code }
        return nil
    }

    // MARK: The plan

    func testANewFileInTheFolderOnShowIsAPlanOfItsOwn() async throws {
        let text = "Passport\nCharger\nSocks\n"
        let plan = await checked(Kit.proposal(newFiles: [("r1", "Packing List.txt", text)]))
        XCTAssertEqual(Kit.names(plan), ["file Packing List.txt"])
        guard case .newFile(.existing(let folder), let name, let held) = plan.steps[0] else { return XCTFail("\(plan.steps)") }
        XCTAssertEqual(folder.path, work)
        XCTAssertEqual(name.value, "Packing List.txt")
        XCTAssertEqual(held, text, "the text is kept exactly as written")
        XCTAssertEqual(plan.title, .create(1))
        XCTAssertEqual(plan.title.text, "Create 1 File")
        XCTAssertEqual(plan.groups, [AgentPlanGroup(id: 1, kind: .newFiles(toLabel: "Work", isNew: false), steps: [0])])
        XCTAssertEqual(plan.defaultTicked, [1], "a new file starts ticked")
        XCTAssertEqual(plan.counts(ticked: [1]), AgentPlanCounts(newFiles: 1))
        XCTAssertEqual(plan.counts(ticked: []), AgentPlanCounts())
        XCTAssertEqual(plan.leftOut, [:])
        XCTAssertEqual(plan.notices, [])
    }

    func testNewFilesGoIntoANewFolderMadeForThem() async {
        let plan = await checked(Kit.proposal(newFolders: [("n1", "r1", "Notes")],
                                           newFiles: [("n1", "Packing List.md", "- Passport"), ("n1", "Budget.csv", "Item,Cost\nTrain,40")]))
        XCTAssertEqual(Kit.names(plan), ["new n1 Notes", "file Packing List.md", "file Budget.csv"])
        XCTAssertEqual(plan.title, .create(2))
        XCTAssertEqual(plan.groups, [AgentPlanGroup(id: 1, kind: .newFiles(toLabel: "Notes", isNew: true), steps: [0, 1, 2])])
        XCTAssertEqual(plan.counts(ticked: plan.defaultTicked), AgentPlanCounts(newFiles: 2, newFolders: 1))
        XCTAssertEqual(plan.counts(ticked: plan.defaultTicked).line, "2 new files · 1 new folder")
        // A key that names a folder already there is that folder, and nothing new is made.
        let existing = await checked(Kit.proposal(newFolders: [("n1", "r1", "trip")], newFiles: [("n1", "Day 1.txt", "Beach")]))
        XCTAssertEqual(Kit.names(existing), ["file Day 1.txt"])
        XCTAssertEqual(existing.groups.first?.kind, .newFiles(toLabel: "Trip", isNew: false))
        XCTAssertEqual(existing.title, .create(1))
    }

    func testNewFilesBesideOtherChangesOrganize() async {
        let doc = await h("doc.txt"), trip = await h("Trip")
        let plan = await checked(Kit.proposal(newFolders: [("n1", "r1", "Notes"), ("n2", "r1", "Empty")],
                                           newFiles: [("n1", "Index.md", "# Notes"), (trip, "Plan.txt", "Day 1")],
                                           moves: [([doc], "", "n1")]))
        XCTAssertEqual(Kit.names(plan), ["new n1 Notes", "new n2 Empty", "file Index.md", "file Plan.txt", "move doc.txt"])
        XCTAssertEqual(plan.title, .organize(rootLabel: "Work"))
        // The new folder joins the first group that goes into it: here its new file's.
        XCTAssertEqual(plan.groups.map(\.kind), [.newFolders, .newFiles(toLabel: "Notes", isNew: true),
                                                 .newFiles(toLabel: "Trip", isNew: false), .moves(toLabel: "Notes", isNew: true)])
        XCTAssertEqual(plan.groups.map(\.steps), [[1], [0, 2], [3], [4]])
        // Unticking the new files keeps the folder, which the move still needs.
        XCTAssertEqual(plan.counts(ticked: [4]), AgentPlanCounts(moves: 1, newFolders: 1))
        // An empty new folder beside new files is not a creation of files alone.
        let withEmpty = await checked(Kit.proposal(newFolders: [("n1", "r1", "Empty")], newFiles: [("r1", "a.txt", "")]))
        XCTAssertEqual(withEmpty.title, .organize(rootLabel: "Work"))
    }

    // MARK: Names

    func testOnlyTextCodeAndDocumentNamesAreKept() async {
        let plan = await checked(Kit.proposal(newFiles: [
            ("r1", "notes.md", "a"), ("r1", "Letter.docx", "Dear Sam"), ("r1", "Letter.rtf", "Dear Sam"),
            ("r1", "launch.command", "open -a Calculator"), ("r1", "Tool.app", ""), ("r1", "site.webloc", ""),
            ("r1", "Setup.pkg", ""), ("r1", "settings.plist", ""), ("r1", ".env", "KEY=1"), ("r1", "README", "hi"),
            ("r1", "photo copy.png", "")]))
        XCTAssertEqual(Kit.names(plan), ["file notes.md", "file Letter.docx", "file Letter.rtf"])
        XCTAssertEqual(plan.leftOut, [.name_not_allowed: 8])
        XCTAssertEqual(plan.cardNotes, [.notAllowed(8)])
    }

    func testANameAlreadyTakenKeepsBoth() async {
        let trip = await h("Trip")
        let plan = await checked(Kit.proposal(newFolders: [("n1", "r1", "Notes")], newFiles: [
            ("r1", "Doc.TXT", "new"),      // doc.txt is there
            ("r1", "Plan.md", "one"),
            ("r1", "plan.md", "two"),      // the one before it
            ("n1", "Plan.md", "three"),    // another folder
            (trip, "Plan.md", "four")]))
        XCTAssertEqual(Kit.names(plan), ["new n1 Notes", "file Doc.TXT", "file Plan.md", "file plan.md", "file Plan.md", "file Plan.md"])
        XCTAssertEqual(plan.keepsBoth, [1, 3])
    }

    // MARK: Where a file goes

    func testAParentMustBeAFolderOrADeclaredKey() async {
        let doc = await h("doc.txt"), privateFolder = await h("Private")
        let plan = await checked(Kit.proposal(newFolders: [("n1", "r1", "Bad/Name")], newFiles: [
            ("n9", "a.txt", ""),            // never declared
            ("n1", "b.txt", ""),            // its folder was left out
            (doc, "c.txt", ""),             // a file
            ("zz9", "d.txt", ""),           // no such id
            (privateFolder, "e.txt", ""),   // a folder macOS asks about
            ("r1", "f.txt", "")]))
        XCTAssertEqual(Kit.names(plan), ["file f.txt"])
        XCTAssertEqual(plan.leftOut, [.unknown_id: 2, .name_not_allowed: 2, .not_allowed: 2])
    }

    // MARK: Limits

    func testTwentyFilesAPlanAtMost() async {
        let twenty = (1...20).map { (parent: "r1", name: "Note \($0).txt", text: "x") }
        let plan = await checked(Kit.proposal(newFiles: twenty))
        XCTAssertEqual(plan.steps.count, 20)
        let refused = await validate(Kit.proposal(newFiles: twenty + [("r1", "Note 21.txt", "x")]))
        XCTAssertEqual(refusal(refused), .too_many)
    }

    func testAHundredThousandCharactersAFileAndHalfAMillionInAll() async {
        let full = String(repeating: "a", count: AgentLimits.newFileCharacters)
        let one = await checked(Kit.proposal(newFiles: [("r1", "full.txt", full)]))
        XCTAssertEqual(one.steps.count, 1)
        let over = await validate(Kit.proposal(newFiles: [("r1", "over.txt", full + "a")]))
        XCTAssertEqual(refusal(over), .too_many)
        // Characters, not bytes: a hundred thousand of these is four hundred thousand bytes.
        let wide = String(repeating: "🎒", count: AgentLimits.newFileCharacters)
        let wideFile = await checked(Kit.proposal(newFiles: [("r1", "wide.txt", wide)]))
        XCTAssertEqual(wideFile.steps.count, 1)

        let five = (1...5).map { (parent: "r1", name: "Part \($0).txt", text: full) }
        let halfAMillion = await checked(Kit.proposal(newFiles: five))
        XCTAssertEqual(halfAMillion.steps.count, 5, "exactly half a million")
        let six = (1...6).map { (parent: "r1", name: "Part \($0).txt", text: String(repeating: "b", count: 90_000)) }
        let tooMuch = await validate(Kit.proposal(newFiles: six))
        XCTAssertEqual(refusal(tooMuch), .too_many)
        XCTAssertEqual(AgentLimits.newFiles, 20)
        XCTAssertEqual(AgentLimits.newFilesCharacters, 500_000)
    }

    func testTheTextMustBePlainText() async {
        for text in ["a\u{0}b", "\u{1B}[31mred", "bell\u{7}", "broken \u{FFFD}", "\u{7F}"] {
            let verdict = await validate(Kit.proposal(newFiles: [("r1", "bad.txt", text)]))
            XCTAssertEqual(refusal(verdict), .bad_arguments, text.debugDescription)
        }
        let fine = "Tab\there\r\nNew page\u{0C}é 🎒 \u{202E}quoted"
        let plan = await checked(Kit.proposal(newFiles: [("r1", "fine.txt", fine)]))
        guard case .newFile(_, _, let text)? = plan.steps.first else { return XCTFail("\(plan.steps)") }
        XCTAssertEqual(text, fine)
    }

    // MARK: Places

    func testThePlaceRulesHoldAsForNewFolders() async {
        let share = "/Volumes/nas/Team", viewOnly = "/Volumes/ro/Docs", documents = "/home/helm/Documents"
        disk.addFolder(share)
        disk.addFolder(viewOnly)
        disk.addFolder(documents)
        disk.setProbe(StorageProbe(isLocal: false, hasTrash: false, volumeRoot: "/Volumes/nas"), under: "/Volumes/nas")
        disk.setProbe(StorageProbe(isLocal: false, isReadOnly: true, volumeRoot: "/Volumes/ro"), under: "/Volumes/ro")
        disk.setProbe(StorageProbe(isUbiquitous: true), under: documents)
        let team = await scope.addRoot(share, label: "Team")
        let docs = await scope.addRoot(viewOnly, label: "Docs")
        let cloud = await scope.addRoot(documents, label: "Documents")

        let onShare = await checked(Kit.proposal(newFiles: [(team.alias, "minutes.md", "Agenda")]))
        XCTAssertEqual(Kit.names(onShare), ["file minutes.md"])
        XCTAssertEqual(onShare.cardNotes, [.cantUndo(place: "Team"), .shared(place: "Team")])
        let viewed = await checked(Kit.proposal(newFiles: [(docs.alias, "notes.txt", "x")]))
        XCTAssertTrue(viewed.steps.isEmpty)
        XCTAssertEqual(viewed.leftOut, [.read_only: 1])
        XCTAssertEqual(viewed.cardNotes, [.readOnly(place: "Docs")])
        let synced = await checked(Kit.proposal(newFiles: [(cloud.alias, "list.txt", "x")]))
        XCTAssertEqual(synced.cardNotes, [.syncs])
        XCTAssertNil(synced.groups.first?.guardedBy, "a new file in iCloud Drive starts ticked, as a new folder does")
    }

    // MARK: Before Apply

    func testAFolderThatChangedBeforeApplyTakesItsNewFilesAlong() async {
        let trip = await h("Trip")
        let plan = await checked(Kit.proposal(newFiles: [(trip, "Plan.txt", "Day 1"), ("r1", "Index.md", "Hi")]))
        let unchanged = await AgentPlanValidator().recheck(plan, ticked: plan.defaultTicked, scope: scope, disk: disk)
        XCTAssertEqual(unchanged, .ok)
        disk.remove(work + "/Trip")
        disk.addFolder(work + "/Trip")
        guard case .changed(let fresh) = await AgentPlanValidator().recheck(plan, ticked: plan.defaultTicked, scope: scope,
                                                                            disk: disk) else { return XCTFail("a replaced folder ran") }
        XCTAssertEqual(Kit.names(fresh), ["file Index.md"])
    }
}
