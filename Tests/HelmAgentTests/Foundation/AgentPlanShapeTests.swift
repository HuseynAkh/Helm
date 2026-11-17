import XCTest
import HelmCore
@testable import HelmAgent

/// What a plan's card reads from the plan: its words, its counts, which groups start ticked and which notes show.
final class AgentPlanShapeTests: XCTestCase {
    private func item(_ name: String, folder: Bool = false) -> AgentPlanItem {
        AgentPlanItem(handle: (folder ? "d" : "f") + name, rootAlias: "r1", path: "/home/helm/Downloads/" + name, name: name,
                      kind: folder ? .directory : .regular, identity: FileObjectIdentity(scope: "memory", object: name),
                      isDataless: false, holds: folder ? 3 : nil)
    }
    private func name(_ text: String) -> ValidFileName { ValidFileName(text)! }

    private func plan(steps: [AgentPlanStep], groups: [AgentPlanGroup], notices: [AgentPlanNotice] = [],
                      leftOut: [AgentToolCode: Int] = [:], title: AgentPlanTitle = .organize(rootLabel: "Downloads")) -> AgentChangePlan {
        AgentChangePlan(title: title, steps: steps, groups: groups, notices: notices, leftOut: leftOut)
    }

    /// Images go into a new Images folder, two files are renamed, one goes to the Trash, and a folder nothing goes
    /// into is made as well.
    private func organize() -> AgentChangePlan {
        let downloads = AgentPlanTarget.existing(item("Downloads", folder: true))
        return plan(steps: [
            .newFolder(key: "n1", parent: downloads, name: name("Images")),          // 0
            .move(item("a.png"), to: .new(key: "n1")),                               // 1
            .move(item("b.png"), to: .new(key: "n1")),                               // 2
            .rename(item("Scan 1.pdf"), to: name("Invoice.pdf")),                    // 3
            .rename(item("Scan 2.pdf"), to: name("Receipt.pdf")),                    // 4
            .trash(item("old.tmp")),                                                 // 5
            .newFolder(key: "n2", parent: downloads, name: name("Later")),           // 6
            .copy(item("c.txt"), to: .existing(item("Archive", folder: true)))       // 7
        ], groups: [
            AgentPlanGroup(id: 1, kind: .moves(toLabel: "Images", isNew: true), steps: [0, 1, 2]),
            AgentPlanGroup(id: 2, kind: .renames, steps: [3, 4]),
            AgentPlanGroup(id: 3, kind: .trash, steps: [5], guardedBy: .trash),
            AgentPlanGroup(id: 4, kind: .newFolders, steps: [6]),
            AgentPlanGroup(id: 5, kind: .copies(toLabel: "Archive", isNew: false), steps: [7])
        ])
    }

    // MARK: Ticks

    func testGuardedGroupsStartUnticked() {
        let plan = organize()
        XCTAssertEqual(plan.defaultTicked, [1, 2, 4, 5])
        XCTAssertEqual(plan.groups.map(\.startsOn), [true, true, false, true, true])
        for guardedBy in AgentPlanGuard.allCases {
            let group = AgentPlanGroup(id: 9, kind: .moves(toLabel: "Shared", isNew: false), steps: [0], guardedBy: guardedBy, place: "Google Drive")
            XCTAssertFalse(group.startsOn, guardedBy.rawValue)
            XCTAssertFalse(self.plan(steps: [.trash(item("x"))], groups: [group]).defaultTicked.contains(9))
        }
        XCTAssertEqual(AgentPlanGuard.allCases, [.trash, .leaves, .arrives, .reachesOthers, .code])
        XCTAssertEqual(self.plan(steps: [], groups: []).defaultTicked, [])
    }

    func testATickSetHoldsOnlyThePlansOwnGroups() {
        let plan = organize()
        XCTAssertTrue(plan.isTickSet([]))
        XCTAssertTrue(plan.isTickSet([1, 3]))
        XCTAssertTrue(plan.isTickSet([1, 2, 3, 4, 5]))
        XCTAssertFalse(plan.isTickSet([6]))
        XCTAssertFalse(plan.isTickSet([1, 2, 99]))
        XCTAssertFalse(plan.isTickSet([0]))
        XCTAssertFalse(plan.isTickSet([-1]))
    }

    // MARK: Counts

    func testCountsAreForTickedGroupsOnly() {
        let plan = organize()
        XCTAssertEqual(plan.counts(ticked: plan.defaultTicked), AgentPlanCounts(moves: 2, copies: 1, newFolders: 2, renames: 2, trash: 0))
        XCTAssertEqual(plan.counts(ticked: [1, 2, 3, 4, 5]), AgentPlanCounts(moves: 2, copies: 1, newFolders: 2, renames: 2, trash: 1))
        XCTAssertEqual(plan.counts(ticked: [3]), AgentPlanCounts(trash: 1))
        XCTAssertEqual(plan.counts(ticked: [2]), AgentPlanCounts(renames: 2))
        XCTAssertEqual(plan.counts(ticked: []), AgentPlanCounts())
        XCTAssertEqual(plan.counts(ticked: []).total, 0)
        XCTAssertEqual(plan.counts(ticked: [1, 2, 3, 4, 5]).total, 8)
        // An id that isn't a group of the plan counts nothing.
        XCTAssertEqual(plan.counts(ticked: [42]), AgentPlanCounts())
    }

    func testANewFolderCountsOnlyWhenATickedStepNeedsIt() {
        let plan = organize()
        // The moves into Images are unticked, so Images isn't made. Later has its own tick.
        XCTAssertEqual(plan.counts(ticked: [2, 4]), AgentPlanCounts(newFolders: 1, renames: 2))
        XCTAssertEqual(plan.counts(ticked: [1]), AgentPlanCounts(moves: 2, newFolders: 1))
        XCTAssertEqual(plan.counts(ticked: [5]), AgentPlanCounts(copies: 1))
        XCTAssertEqual(plan.counts(ticked: [4]), AgentPlanCounts(newFolders: 1))
    }

    func testANewFolderInsideANewFolderNeedsBoth() {
        let home = AgentPlanTarget.existing(item("Downloads", folder: true))
        let nested = plan(steps: [
            .newFolder(key: "n1", parent: home, name: name("2026")),                 // 0
            .newFolder(key: "n2", parent: .new(key: "n1"), name: name("March")),     // 1
            .newFolder(key: "n3", parent: .new(key: "n2"), name: name("Scans")),     // 2
            .move(item("a.pdf"), to: .new(key: "n3")),                               // 3
            .copy(item("b.pdf"), to: .new(key: "n1")),                               // 4
            .newFolder(key: "n4", parent: .new(key: "n1"), name: name("Empty"))      // 5
        ], groups: [
            AgentPlanGroup(id: 1, kind: .moves(toLabel: "Scans", isNew: true), steps: [0, 1, 2, 3]),
            AgentPlanGroup(id: 2, kind: .copies(toLabel: "2026", isNew: true), steps: [4]),
            AgentPlanGroup(id: 3, kind: .newFolders, steps: [5])
        ])
        XCTAssertEqual(nested.counts(ticked: [1]), AgentPlanCounts(moves: 1, newFolders: 3))
        // The copy needs only the first folder, wherever that folder's own step is grouped.
        XCTAssertEqual(nested.counts(ticked: [2]), AgentPlanCounts(copies: 1, newFolders: 1))
        // A new folder with its own tick needs the new folder it is made in.
        XCTAssertEqual(nested.counts(ticked: [3]), AgentPlanCounts(newFolders: 2))
        XCTAssertEqual(nested.counts(ticked: [1, 2, 3]), AgentPlanCounts(moves: 1, copies: 1, newFolders: 4))
        XCTAssertEqual(nested.counts(ticked: []), AgentPlanCounts())
    }

    func testTheCountsLineJoinsWhatIsNotZero() {
        XCTAssertEqual(AgentPlanCounts(moves: 214, newFolders: 6, renames: 3).line, "214 moves · 6 new folders · 3 renames")
        XCTAssertEqual(AgentPlanCounts(moves: 1, copies: 1, newFolders: 1, renames: 1, trash: 1).line,
                       "1 move · 1 copy · 1 new folder · 1 rename · 1 to Trash")
        XCTAssertEqual(AgentPlanCounts(copies: 5, trash: 2).line, "5 copies · 2 to Trash")
        XCTAssertEqual(AgentPlanCounts(renames: 30).line, "30 renames")
        XCTAssertEqual(AgentPlanCounts().line, "")
        XCTAssertEqual(AgentPlanCounts(moves: 214, newFolders: 6, renames: 3).total, 223)
        XCTAssertEqual(organize().counts(ticked: [1, 2]).line, "2 moves · 1 new folder · 2 renames")
        XCTAssertEqual(AgentPlanCounts(moves: 3, newFiles: 2, newFolders: 1).line, "3 moves · 2 new files · 1 new folder")
        XCTAssertEqual(AgentPlanCounts(newFiles: 1).line, "1 new file")
        XCTAssertEqual(AgentPlanCounts(newFiles: 2, newFolders: 1).total, 3)
    }

    /// A new file counts in a ticked group, and so does the new folder it is made in, which is in that group too.
    func testANewFileCountsWithTheNewFolderItIsMadeIn() {
        let downloads = AgentPlanTarget.existing(item("Downloads", folder: true))
        let plan = plan(steps: [
            .newFolder(key: "n1", parent: downloads, name: name("Trip")),                       // 0
            .newFile(parent: .new(key: "n1"), name: name("Packing List.md"), text: "- Passport"),  // 1
            .newFile(parent: downloads, name: name("Budget.csv"), text: "Item,Cost"),             // 2
            .move(item("a.png"), to: .new(key: "n1"))                                            // 3
        ], groups: [
            AgentPlanGroup(id: 1, kind: .newFiles(toLabel: "Trip", isNew: true), steps: [0, 1]),
            AgentPlanGroup(id: 2, kind: .newFiles(toLabel: "Downloads", isNew: false), steps: [2]),
            AgentPlanGroup(id: 3, kind: .moves(toLabel: "Trip", isNew: true), steps: [3])
        ], title: .organize(rootLabel: "Downloads"))
        XCTAssertEqual(plan.counts(ticked: [1, 2, 3]), AgentPlanCounts(moves: 1, newFiles: 2, newFolders: 1))
        XCTAssertEqual(plan.counts(ticked: [2]), AgentPlanCounts(newFiles: 1))
        XCTAssertEqual(plan.counts(ticked: [3]), AgentPlanCounts(moves: 1, newFolders: 1), "the move still needs the folder")
        XCTAssertEqual(plan.counts(ticked: [1]), AgentPlanCounts(newFiles: 1, newFolders: 1))
    }

    // MARK: Words

    func testThePlansTitle() {
        XCTAssertEqual(AgentPlanTitle.organize(rootLabel: "Downloads").text, "Organize “Downloads”")
        XCTAssertEqual(AgentPlanTitle.move(12).text, "Move 12 Items")
        XCTAssertEqual(AgentPlanTitle.copy(3).text, "Copy 3 Items")
        XCTAssertEqual(AgentPlanTitle.rename(30).text, "Rename 30 Items")
        XCTAssertEqual(AgentPlanTitle.trash(2).text, "Move 2 Items to Trash")
        XCTAssertEqual(AgentPlanTitle.move(1).text, "Move 1 Item")
        XCTAssertEqual(AgentPlanTitle.create(2).text, "Create 2 Files")
        XCTAssertEqual(AgentPlanTitle.create(1).text, "Create 1 File")
        // A folder's name can't hide anything in the Edit menu, where the title is the Undo's name.
        XCTAssertEqual(AgentPlanTitle.organize(rootLabel: "Down\u{202E}loads").text, "Organize “Down\\u{202E}loads”")
    }

    func testEveryNoticeHasItsSlotAndItsLine() {
        let slotOne: [AgentPlanNotice] = [.notAllowed(5), .notDownloaded(12), .foldersNotLoaded(3), .noTrash(place: "Server"),
                                          .readOnly(place: "Server"), .leftOutSeveral(17)]
        XCTAssertEqual(slotOne.map(\.slot), [1, 1, 1, 1, 1, 1])
        XCTAssertEqual(slotOne.map(\.text), [
            "5 changes weren't allowed, so Helm left them out.", "12 items aren't downloaded, so Helm left them out.",
            "3 folders aren't loaded, so Helm skipped them.", "“Server” has no Trash, so Helm won't remove anything from it.",
            "You can only view “Server”.", "Helm left out 17 changes."
        ])
        XCTAssertEqual(AgentPlanNotice.cantUndo(place: "Server").slot, 2)
        XCTAssertEqual(AgentPlanNotice.cantUndo(place: "Server").text, "Copies on “Server” can't be undone.")
        let slotThree: [AgentPlanNotice] = [.syncs, .shared(place: "Google Drive"), .syncsMaybeShared]
        XCTAssertEqual(slotThree.map(\.slot), [3, 3, 3])
        XCTAssertEqual(slotThree.map(\.text), [
            "Changes sync to your other devices.", "Changes reach everyone who uses “Google Drive”.",
            "Changes sync to your devices and to anyone this is shared with."
        ])
    }

    // MARK: Notes

    func testACardShowsAtMostThreeNotesOneASlot() {
        let notices: [AgentPlanNotice] = [.syncs, .cantUndo(place: "Server"), .notDownloaded(12), .cantUndo(place: "Backup"),
                                          .shared(place: "Server"), .notAllowed(5), .syncsMaybeShared, .noTrash(place: "Server")]
        let card = plan(steps: [.trash(item("x"))], groups: [AgentPlanGroup(id: 1, kind: .trash, steps: [0], guardedBy: .trash)],
                        notices: notices, leftOut: [.not_downloaded: 12, .not_allowed: 5, .no_trash: 2])
        let notes = card.cardNotes
        XCTAssertEqual(notes, [.leftOutSeveral(19), .cantUndo(place: "Server"), .shared(place: "Server")])
        XCTAssertEqual(notes.map(\.slot), [1, 2, 3])
        XCTAssertLessThanOrEqual(notes.count, 3)
        XCTAssertEqual(notes.first?.text, "Helm left out 19 changes.")
        // The plan keeps every notice, so the folded line's tooltip can list them.
        XCTAssertEqual(card.notices, notices)
    }

    func testOneLeftOutNoticeShowsAsItself() {
        let only = plan(steps: [], groups: [], notices: [.notDownloaded(12)], leftOut: [.not_downloaded: 12])
        XCTAssertEqual(only.cardNotes, [.notDownloaded(12)])
        let place = plan(steps: [], groups: [], notices: [.syncs, .noTrash(place: "Server")], leftOut: [.no_trash: 4])
        XCTAssertEqual(place.cardNotes, [.noTrash(place: "Server"), .syncs])
    }

    func testSeveralLeftOutNoticesFoldIntoOne() {
        let counted = plan(steps: [], groups: [], notices: [.notAllowed(2), .foldersNotLoaded(3)], leftOut: [.not_allowed: 2])
        XCTAssertEqual(counted.cardNotes, [.leftOutSeveral(2)])
        // With no count by code, the notices' own counts are added up, and a place counts once.
        let uncounted = plan(steps: [], groups: [], notices: [.notAllowed(2), .notDownloaded(3), .readOnly(place: "Server")], leftOut: [:])
        XCTAssertEqual(uncounted.cardNotes, [.leftOutSeveral(6)])
    }

    func testOnlyOneLineSaysWhatSyncsOrIsShared() {
        func notes(_ notices: [AgentPlanNotice]) -> [AgentPlanNotice] { plan(steps: [], groups: [], notices: notices).cardNotes }
        XCTAssertEqual(notes([.syncs]), [.syncs])
        XCTAssertEqual(notes([.syncs, .syncsMaybeShared]), [.syncsMaybeShared])
        XCTAssertEqual(notes([.syncsMaybeShared, .syncs, .shared(place: "Server")]), [.shared(place: "Server")])
        XCTAssertEqual(notes([.shared(place: "Server"), .shared(place: "Google Drive"), .syncs]), [.shared(place: "Server")])
        XCTAssertEqual(notes([]), [])
        XCTAssertEqual(notes([.cantUndo(place: "Server")]), [.cantUndo(place: "Server")])
    }

    // MARK: Nothing to do

    func testNothingToDoShowsOnlyWhenNothingWasLeftOut() {
        let empty = plan(steps: [], groups: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.showsNothingToDo)

        let leftOut = plan(steps: [], groups: [], notices: [.notDownloaded(12)], leftOut: [.not_downloaded: 12])
        XCTAssertTrue(leftOut.isEmpty)
        XCTAssertFalse(leftOut.showsNothingToDo)
        // A count with no notice, and a notice with no count, each say something was left out.
        XCTAssertFalse(plan(steps: [], groups: [], leftOut: [.outside_scope: 1]).showsNothingToDo)
        XCTAssertFalse(plan(steps: [], groups: [], notices: [.readOnly(place: "Server")]).showsNothingToDo)
        XCTAssertFalse(plan(steps: [], groups: [], notices: [.foldersNotLoaded(2)]).showsNothingToDo)
        // A line about syncing leaves nothing out.
        XCTAssertTrue(plan(steps: [], groups: [], notices: [.syncs], leftOut: [.not_allowed: 0]).showsNothingToDo)

        let full = organize()
        XCTAssertFalse(full.isEmpty)
        XCTAssertFalse(full.showsNothingToDo)
    }

    // MARK: A proposal's arguments

    private let proposal = """
    {"new_folders": [{"key": "n1", "parent": "r1", "name": "Images"}],
     "new_files": [{"parent": "n1", "name": "Read Me.md", "text": "Line one\\nLine two"}],
     "moves": [{"items": ["f1", "f2"], "all_in": "", "to": "n1"}],
     "copies": [{"items": [], "all_in": "d7", "to": "r2"}],
     "renames": [{"item": "f3", "name": "Invoice.pdf"}],
     "trash": ["f4"]}
    """

    func testAProposalIsDecodedExactly() {
        XCTAssertEqual(AgentProposedChanges.decodeStrictly(Data(proposal.utf8)), AgentProposedChanges(
            newFolders: [.init(key: "n1", parent: "r1", name: "Images")],
            newFiles: [.init(parent: "n1", name: "Read Me.md", text: "Line one\nLine two")],
            moves: [.init(items: ["f1", "f2"], allIn: "", to: "n1")],
            copies: [.init(items: [], allIn: "d7", to: "r2")],
            renames: [.init(item: "f3", name: "Invoice.pdf")],
            trash: ["f4"]))
        let empty = #"{"new_folders": [], "new_files": [], "moves": [], "copies": [], "renames": [], "trash": []}"#
        XCTAssertEqual(AgentProposedChanges.decodeStrictly(Data(empty.utf8)),
                       AgentProposedChanges(newFolders: [], moves: [], copies: [], renames: [], trash: []))
    }

    func testAProposalWithAMissingOrUnknownFieldIsRefused() {
        func refused(_ change: (String) -> String, _ why: String, line: UInt = #line) {
            XCTAssertNil(AgentProposedChanges.decodeStrictly(Data(change(proposal).utf8)), why, line: line)
        }
        refused({ $0.replacingOccurrences(of: #""trash": ["f4"]"#, with: #""trash": ["f4"], "delete": ["f5"]"#) }, "an unknown field")
        refused({ $0.replacingOccurrences(of: #", "name": "Images""#, with: "") }, "a new folder with no name")
        refused({ $0.replacingOccurrences(of: #""new_files": [{"parent": "n1", "name": "Read Me.md", "text": "Line one\nLine two"}],"#, with: "") },
                "no new files at all, as a proposal from before new files")
        refused({ $0.replacingOccurrences(of: #", "text": "Line one\nLine two""#, with: "") }, "a new file with no text")
        refused({ $0.replacingOccurrences(of: #""text": "Line one\nLine two""#, with: #""text": "x", "mode": "755""#) },
                "an unknown field in a new file")
        refused({ $0.replacingOccurrences(of: #""text": "Line one\nLine two""#, with: #""text": ["x"]"#) }, "a text that isn't text")
        refused({ $0.replacingOccurrences(of: #""all_in": "", "#, with: "") }, "a move with no all_in")
        refused({ $0.replacingOccurrences(of: #""to": "n1""#, with: #""to": "n1", "replace": true"#) }, "an unknown field in a move")
        refused({ $0.replacingOccurrences(of: #""item": "f3""#, with: #""item": "f3", "path": "/etc""#) }, "an unknown field in a rename")
        refused({ $0.replacingOccurrences(of: #""trash": ["f4"]"#, with: #""trash": "f4""#) }, "trash that isn't a list")
        refused({ $0.replacingOccurrences(of: #"["f1", "f2"]"#, with: #"["f1", 2]"#) }, "an item that isn't text")
        refused({ $0.replacingOccurrences(of: #""name": "Invoice.pdf""#, with: #""name": null"#) }, "a name that is null")
        refused({ $0.replacingOccurrences(of: #""renames": [{"item": "f3", "name": "Invoice.pdf"}],"#, with: "") }, "no renames at all")
        refused({ $0.replacingOccurrences(of: #""copies": [{"items": [], "all_in": "d7", "to": "r2"}]"#, with: #""copies": {}"#) }, "copies that aren't a list")
        refused({ "[" + $0 + "]" }, "a list where an object belongs")
        refused({ _ in "" }, "nothing")
        refused({ _ in "not json" }, "not JSON")
        refused({ _ in "null" }, "null")
        refused({ _ in String(repeating: "[", count: 100) }, "nested without end")
    }

    // MARK: Small values

    func testAFolderRefSaysWhatToPutInTheMessage() {
        let root = AgentScopeRoot(alias: "r2", path: "/home/helm/Pictures", label: "Pictures", modelName: "Pictures", identity: nil,
                                  storage: .thisMac, isTabFolder: false)
        XCTAssertEqual(AgentFolderRef.added(root).modelID, "r2")
        XCTAssertEqual(AgentFolderRef.root(root).modelID, "r2")
        XCTAssertEqual(AgentFolderRef.inside(handle: "d7", name: "2026").modelID, "d7")
        XCTAssertNil(AgentFolderRef.refused(.system).modelID)
        XCTAssertEqual(root.id, "r2")
    }

    func testAPlanIsItsOwnValue() {
        let plan = organize()
        XCTAssertEqual(plan, plan)
        XCTAssertNotEqual(plan.id, organize().id)
        XCTAssertEqual(plan.keepsBoth, [])
        XCTAssertEqual(plan.title.text, "Organize “Downloads”")
        XCTAssertEqual(AgentChangePlan(id: plan.id, title: .move(1), steps: [], groups: [], notices: [], keepsBoth: [2], leftOut: [:]).keepsBoth, [2])
    }
}
