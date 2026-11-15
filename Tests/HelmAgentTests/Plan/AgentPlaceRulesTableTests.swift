import XCTest
import HelmCore
@testable import HelmAgent

/// Every row of the rules table for remote and cloud folders (DESIGN.md 8.2), from injected place facts.
final class AgentPlaceRulesTableTests: XCTestCase {
    private typealias Kit = AgentPlanTestKit

    // MARK: Places

    private let mac = StorageFacts.thisMac
    private let iCloud = StorageFacts(kind: .iCloud, name: "iCloud Drive", syncs: true, shared: .no,
                                      cloudRoot: "/home/helm/Library/Mobile Documents")
    private let iCloudShared = StorageFacts(kind: .iCloud, name: "iCloud Drive", syncs: true, shared: .yes,
                                            cloudRoot: "/home/helm/Library/Mobile Documents")
    private let drive = StorageFacts(kind: .cloud, name: "Google Drive", syncs: true, shared: .unknown,
                                     cloudRoot: "/home/helm/Library/CloudStorage/GoogleDrive-test")
    private let server = StorageFacts(kind: .network, name: "Server", shared: .yes, trash: .yes, volumeRoot: "/Volumes/share")
    private let serverNoTrash = StorageFacts(kind: .network, name: "Server", shared: .yes, trash: .no, volumeRoot: "/Volumes/nas")
    private let serverUnknownTrash = StorageFacts(kind: .network, name: "Server", shared: .yes, trash: .unknown,
                                                  volumeRoot: "/Volumes/old")
    private let disk = StorageFacts(kind: .external, name: "External disk", trash: .yes, volumeRoot: "/Volumes/Disk")
    private var readOnly: StorageFacts { var facts = server; facts.isReadOnly = true; return facts }
    private var quiet: StorageFacts { var facts = server; facts.isResponding = false; return facts }

    private func file(_ name: String = "a.pdf", dataless: Bool = false) -> AgentPlanItem {
        AgentPlanItem(handle: "f1", rootAlias: "r1", path: "/x/" + name, name: name, kind: .regular,
                      identity: FileObjectIdentity(scope: "t", object: name), isDataless: dataless)
    }
    private func folder(_ name: String = "Folder", dataless: Bool = false) -> AgentPlanItem {
        AgentPlanItem(handle: "d1", rootAlias: "r1", path: "/x/" + name, name: name, kind: .directory,
                      identity: FileObjectIdentity(scope: "t", object: name), isDataless: dataless, holds: 3)
    }
    private var into: AgentPlanTarget { .existing(folder("Into")) }
    private let newName = ValidFileName("New")!

    private func rule(_ step: AgentPlanStep, _ source: StorageFacts, _ destination: StorageFacts? = nil,
                      holds: Bool = false) -> AgentPlaceRules.Ruling {
        AgentPlaceRules.rule(for: step, source: source, destination: destination, holdsDataless: holds)
    }

    // MARK: Rows

    func testAnyChangeInAReadOnlyPlaceIsLeftOut() {
        let leftOut = AgentPlaceRules.Ruling(leftOut: .read_only, notices: [.readOnly(place: "Server")])
        XCTAssertEqual(rule(.rename(file(), to: newName), readOnly), leftOut)
        XCTAssertEqual(rule(.trash(file()), readOnly), leftOut)
        XCTAssertEqual(rule(.move(file(), to: into), readOnly, mac), leftOut, "out of it")
        XCTAssertEqual(rule(.move(file(), to: into), mac, readOnly), leftOut, "into it")
        XCTAssertEqual(rule(.copy(file(), to: into), mac, readOnly), leftOut, "a copy into it")
        XCTAssertEqual(rule(.newFolder(key: "n1", parent: into, name: newName), readOnly, readOnly), leftOut)
        // A copy out of it changes nothing there.
        XCTAssertNil(rule(.copy(file(), to: into), readOnly, mac).leftOut)
    }

    func testTrashWhereThereIsNoTrashIsLeftOut() {
        XCTAssertEqual(rule(.trash(file()), serverNoTrash), AgentPlaceRules.Ruling(leftOut: .no_trash, notices: [.noTrash(place: "Server")]))
        XCTAssertEqual(rule(.trash(file()), serverUnknownTrash).leftOut, .no_trash, "unknown is not yes")
    }

    func testTrashAnywhereElseIsGuarded() {
        XCTAssertEqual(rule(.trash(file()), mac), AgentPlaceRules.Ruling(guardedBy: .trash))
        XCTAssertEqual(rule(.trash(folder()), drive), AgentPlaceRules.Ruling(guardedBy: .trash, notices: [.syncsMaybeShared]))
        XCTAssertEqual(rule(.trash(file()), server).guardedBy, .trash)
    }

    func testStepsThatNeedTheBytesOfWhatIsntDownloadedAreLeftOut() {
        XCTAssertEqual(rule(.copy(file(dataless: true), to: into), drive, mac).leftOut, .not_downloaded)
        XCTAssertEqual(rule(.copy(file(dataless: true), to: into), drive, drive).leftOut, .not_downloaded, "a copy always")
        XCTAssertEqual(rule(.copy(folder(), to: into), drive, mac, holds: true).leftOut, .not_downloaded, "a folder holding one")
        XCTAssertEqual(rule(.move(file(dataless: true), to: into), drive, mac).leftOut, .not_downloaded, "out of the provider")
        XCTAssertEqual(rule(.move(folder(), to: into), iCloud, disk, holds: true).leftOut, .not_downloaded, "to another disk")
        // Inside its own place a move needs no bytes.
        let inPlace = rule(.move(file(dataless: true), to: into), drive, drive)
        XCTAssertNil(inPlace.leftOut)
        XCTAssertNil(inPlace.guardedBy)
        XCTAssertEqual(inPlace.notices, [.syncsMaybeShared])
        XCTAssertNil(rule(.rename(file(dataless: true), to: newName), drive).leftOut)
        XCTAssertEqual(rule(.trash(file(dataless: true)), iCloud).guardedBy, .trash)
    }

    func testNeedsBytes() {
        XCTAssertTrue(AgentPlaceRules.needsBytes(.copy(file(), to: into), source: mac, destination: mac))
        XCTAssertFalse(AgentPlaceRules.needsBytes(.move(file(), to: into), source: drive, destination: drive))
        XCTAssertTrue(AgentPlaceRules.needsBytes(.move(file(), to: into), source: drive, destination: mac))
        XCTAssertTrue(AgentPlaceRules.needsBytes(.move(file(), to: into), source: mac, destination: disk))
        XCTAssertTrue(AgentPlaceRules.needsBytes(.move(file(), to: into), source: iCloud, destination: drive))
        XCTAssertFalse(AgentPlaceRules.needsBytes(.rename(file(), to: newName), source: drive, destination: nil))
        XCTAssertFalse(AgentPlaceRules.needsBytes(.trash(file()), source: drive, destination: nil))
        XCTAssertFalse(AgentPlaceRules.needsBytes(.newFolder(key: "n1", parent: into, name: newName), source: drive, destination: drive))
    }

    func testAMoveOffAPlaceWithNoTrashToAnotherDiskIsLeftOut() {
        XCTAssertEqual(rule(.move(file(), to: into), serverNoTrash, mac),
                       AgentPlaceRules.Ruling(leftOut: .no_trash, notices: [.noTrash(place: "Server")]))
        XCTAssertEqual(rule(.move(file(), to: into), serverNoTrash, server).leftOut, .no_trash, "another server")
        // Inside the same share nothing is taken away.
        XCTAssertNil(rule(.move(file(), to: into), serverNoTrash, serverNoTrash).leftOut)
    }

    func testNewFoldersAndCopiesWhereThereIsNoTrashAreAllowedAndCantBeUndone() {
        let made = rule(.newFolder(key: "n1", parent: into, name: newName), serverNoTrash, serverNoTrash)
        XCTAssertNil(made.leftOut)
        XCTAssertEqual(made.notices, [.cantUndo(place: "Server"), .shared(place: "Server")])
        let copied = rule(.copy(file(), to: into), mac, serverNoTrash)
        XCTAssertNil(copied.leftOut)
        XCTAssertEqual(copied.notices, [.cantUndo(place: "Server"), .shared(place: "Server")])
        XCTAssertEqual(rule(.newFolder(key: "n1", parent: into, name: newName), mac, mac).notices, [])
    }

    func testAMoveOutOfAPlaceOthersSeeLeavesIt() {
        XCTAssertEqual(rule(.move(file(), to: into), iCloud, mac),
                       AgentPlaceRules.Ruling(guardedBy: .leaves, place: "iCloud Drive", notices: [.syncs]))
        XCTAssertEqual(rule(.move(file(), to: into), server, mac).place, "Server")
        XCTAssertEqual(rule(.move(file(), to: into), server, mac).guardedBy, .leaves)
        // Leaving one place for another that syncs: leaving comes first.
        let across = rule(.move(file(), to: into), drive, iCloud)
        XCTAssertEqual(across.guardedBy, .leaves)
        XCTAssertEqual(across.place, "Google Drive")
        XCTAssertEqual(across.notices, [.syncsMaybeShared, .syncs])
        // A copy leaves the item where it was.
        XCTAssertNil(rule(.copy(file(), to: into), iCloud, mac).guardedBy)
        // Inside one place nothing leaves.
        XCTAssertNil(rule(.move(file(), to: into), iCloud, iCloud).guardedBy)
        // A shared folder inside the same place still says it is shared.
        let intoShared = rule(.move(file(), to: into), iCloud, iCloudShared)
        XCTAssertNil(intoShared.guardedBy)
        XCTAssertEqual(intoShared.notices, [.syncs, .shared(place: "iCloud Drive")])
    }

    func testAnythingArrivingInAPlaceOthersSeeIsGuarded() {
        XCTAssertEqual(rule(.move(file(), to: into), mac, drive),
                       AgentPlaceRules.Ruling(guardedBy: .arrives, place: "Google Drive", notices: [.syncsMaybeShared]))
        let copied = rule(.copy(file(), to: into), mac, server)
        XCTAssertEqual(copied.guardedBy, .arrives)
        XCTAssertEqual(copied.place, "Server")
        XCTAssertEqual(rule(.copy(file(), to: into), disk, iCloud).place, "iCloud Drive")
        XCTAssertNil(rule(.move(file(), to: into), mac, disk).guardedBy, "an external disk is seen by no one else")
    }

    func testEveryChangeWherePlacesSyncOrAreSharedSaysSo() {
        XCTAssertEqual(rule(.rename(file(), to: newName), iCloud).notices, [.syncs])
        XCTAssertEqual(rule(.rename(file(), to: newName), drive).notices, [.syncsMaybeShared])
        XCTAssertEqual(rule(.rename(file(), to: newName), server).notices, [.shared(place: "Server")])
        XCTAssertEqual(rule(.rename(file(), to: newName), iCloudShared).notices, [.shared(place: "iCloud Drive")])
        XCTAssertEqual(rule(.rename(file(), to: newName), mac).notices, [])
        XCTAssertEqual(rule(.rename(file(), to: newName), disk).notices, [])
        XCTAssertEqual(rule(.copy(file(), to: into), iCloud, mac).notices, [], "a copy changes only where it lands")
    }

    func testAPlaceThatStopsAnsweringPlansNothing() {
        XCTAssertEqual(rule(.rename(file(), to: newName), quiet).leftOut, .not_responding)
        XCTAssertEqual(rule(.move(file(), to: into), mac, quiet).leftOut, .not_responding)
    }

    func testTheBulkGuardCountsChangesInAPlaceKnownToBeShared() {
        func changes(_ count: Int, in place: StorageFacts, folders: Int = 0) -> [AgentPlaceRules.PlaceChange] {
            (0..<count).map { AgentPlaceRules.PlaceChange(step: $0, place: place, isFolder: $0 < folders) }
        }
        XCTAssertEqual(AgentPlaceRules.bulkGuarded(changes(25, in: server)), [:])
        XCTAssertEqual(AgentPlaceRules.bulkGuarded(changes(26, in: server)).count, 26)
        XCTAssertEqual(Set(AgentPlaceRules.bulkGuarded(changes(26, in: server)).values), ["Server"])
        XCTAssertEqual(AgentPlaceRules.bulkGuarded(changes(1, in: server, folders: 1)), [0: "Server"])
        XCTAssertEqual(AgentPlaceRules.bulkGuarded(changes(26, in: iCloudShared)).count, 26)
        XCTAssertEqual(AgentPlaceRules.bulkGuarded(changes(300, in: drive, folders: 3)), [:], "sharing unknown")
        XCTAssertEqual(AgentPlaceRules.bulkGuarded(changes(300, in: iCloud, folders: 3)), [:], "not shared")
        // Two shares are counted apart.
        let split = changes(20, in: server) + (20..<40).map { AgentPlaceRules.PlaceChange(step: $0, place: serverNoTrash, isFolder: false) }
        XCTAssertEqual(AgentPlaceRules.bulkGuarded(split), [:])
    }

    // MARK: Through the validator

    private func shareRig(files: Int, folder: Bool = false) async -> (AgentPlanTestScope, MemoryAgentDisk) {
        let memory = MemoryAgentDisk()
        memory.addFolder("/Volumes/share/Team/Sorted")
        for index in 1...files { memory.addFile("/Volumes/share/Team/report \(index).pdf") }
        if folder { memory.addFolder("/Volumes/share/Team/Old") }
        memory.setProbe(StorageProbe(isLocal: false, hasTrash: true, volumeRoot: "/Volumes/share"), under: "/Volumes/share")
        let scope = AgentPlanTestScope(disk: memory)
        await scope.addRoot("/Volumes/share/Team", label: "Team", isTab: true)
        return (scope, memory)
    }

    func testTwentySixItemsInASharePutTheirGroupBehindATick() async {
        let (scope, memory) = await shareRig(files: 26)
        let sorted = await scope.handle("/Volumes/share/Team/Sorted")
        let plan = Kit.plan(await AgentPlanValidator().validate(Kit.proposal(moves: [([], "r1", sorted)]),
                                                                scope: scope, disk: memory, limits: .cloudModel))
        // Everything in r1 includes Sorted, the destination itself, which is left out; 26 files remain.
        XCTAssertEqual(plan.leftOut, [.not_allowed: 1])
        XCTAssertEqual(plan.steps.count, 26)
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.groups[0].guardedBy, .reachesOthers)
        XCTAssertEqual(plan.groups[0].place, "Server")
        XCTAssertEqual(plan.defaultTicked, [])
        XCTAssertEqual(plan.cardNotes, [.notAllowed(1), .shared(place: "Team")], "notes name the place as its chip does")
    }

    func testTwentyFiveItemsInAShareStayTicked() async {
        let (scope, memory) = await shareRig(files: 25)
        let sorted = await scope.handle("/Volumes/share/Team/Sorted")
        let plan = Kit.plan(await AgentPlanValidator().validate(Kit.proposal(moves: [([], "r1", sorted)]),
                                                                scope: scope, disk: memory, limits: .cloudModel))
        XCTAssertEqual(plan.steps.count, 25)
        XCTAssertNil(plan.groups.first?.guardedBy)
        XCTAssertEqual(plan.defaultTicked, [1])
        XCTAssertEqual(plan.cardNotes, [.notAllowed(1), .shared(place: "Team")], "notes name the place as its chip does")
    }

    func testOneFolderChangedInAShareIsGuarded() async {
        let (scope, memory) = await shareRig(files: 1, folder: true)
        let old = await scope.handle("/Volumes/share/Team/Old")
        let doc = await scope.handle("/Volumes/share/Team/report 1.pdf")
        let plan = Kit.plan(await AgentPlanValidator().validate(
            Kit.proposal(renames: [(old, "Older"), (doc, "report one.pdf")]), scope: scope, disk: memory, limits: .cloudModel))
        XCTAssertEqual(Kit.names(plan), ["rename Old Older", "rename report 1.pdf report one.pdf"])
        // Once a folder is changed there, every change in that place waits for its tick.
        XCTAssertEqual(plan.groups.map(\.guardedBy), [.reachesOthers])
        XCTAssertEqual(plan.groups.first?.steps, [0, 1])
        XCTAssertEqual(plan.defaultTicked, [])
    }

    /// iCloud Drive with a shared Team folder beside a Private one that isn't shared: one place, two kinds of folder.
    private func iCloudRig(files: Int, folder: Bool = false) async -> (AgentPlanTestScope, MemoryAgentDisk, String) {
        let memory = MemoryAgentDisk()
        let drive = "/home/helm/Library/Mobile Documents/com~apple~CloudDocs"
        memory.addFolder(drive + "/Team")
        for index in 1...files { memory.addFile(drive + "/Private/note \(index).txt") }
        if folder { memory.addFolder(drive + "/Private/Sub") }
        memory.setProbe(StorageProbe(isShared: true), under: drive + "/Team")
        let scope = AgentPlanTestScope(disk: memory)
        await scope.addRoot(drive, label: "iCloud Drive", isTab: true)
        return (scope, memory, drive)
    }

    func testTwentySixItemsMovedIntoASharedICloudFolderFromTheSamePlaceAreGuarded() async {
        let (scope, memory, drive) = await iCloudRig(files: 26)
        let team = await scope.handle(drive + "/Team"), privateFolder = await scope.handle(drive + "/Private")
        let plan = Kit.plan(await AgentPlanValidator().validate(Kit.proposal(moves: [([], privateFolder, team)]),
                                                                scope: scope, disk: memory, limits: .cloudModel))
        XCTAssertEqual(plan.steps.count, 26)
        XCTAssertEqual(plan.groups.map(\.guardedBy), [.reachesOthers])
        XCTAssertEqual(plan.groups.first?.place, "iCloud Drive")
        XCTAssertEqual(plan.defaultTicked, [])
        XCTAssertEqual(plan.cardNotes, [.shared(place: "iCloud Drive")])
    }

    func testOneFolderMovedIntoASharedICloudFolderFromTheSamePlaceIsGuarded() async {
        let (scope, memory, drive) = await iCloudRig(files: 1, folder: true)
        let team = await scope.handle(drive + "/Team"), sub = await scope.handle(drive + "/Private/Sub")
        let plan = Kit.plan(await AgentPlanValidator().validate(Kit.proposal(moves: [([sub], "", team)]),
                                                                scope: scope, disk: memory, limits: .cloudModel))
        XCTAssertEqual(Kit.names(plan), ["move Sub"])
        XCTAssertEqual(plan.groups.map(\.guardedBy), [.reachesOthers])
        XCTAssertEqual(plan.defaultTicked, [])
    }

    func testAFewFilesMovedIntoASharedICloudFolderStayTickedAndSaySo() async {
        let (scope, memory, drive) = await iCloudRig(files: 25)
        let team = await scope.handle(drive + "/Team"), privateFolder = await scope.handle(drive + "/Private")
        let plan = Kit.plan(await AgentPlanValidator().validate(Kit.proposal(moves: [([], privateFolder, team)]),
                                                                scope: scope, disk: memory, limits: .cloudModel))
        XCTAssertEqual(plan.steps.count, 25)
        XCTAssertNil(plan.groups.first?.guardedBy)
        XCTAssertEqual(plan.defaultTicked, [1])
        XCTAssertEqual(plan.cardNotes, [.shared(place: "iCloud Drive")])
    }

    func testThreeHundredMovesInACloudFolderOfUnknownSharingStayTicked() async {
        let memory = MemoryAgentDisk()
        let drivePath = "/home/helm/Library/CloudStorage/GoogleDrive-test@example.com/My Drive"
        memory.addFolder(drivePath + "/Inbox/Sorted")
        for index in 1...300 { memory.addFile(drivePath + "/Inbox/scan \(index).pdf") }
        let scope = AgentPlanTestScope(disk: memory)
        await scope.addRoot(drivePath, label: "My Drive", isTab: true)
        let inbox = await scope.handle(drivePath + "/Inbox"), sorted = await scope.handle(drivePath + "/Inbox/Sorted")
        let plan = Kit.plan(await AgentPlanValidator().validate(Kit.proposal(moves: [([], inbox, sorted)]),
                                                                scope: scope, disk: memory, limits: .cloudModel))
        XCTAssertEqual(plan.steps.count, 300)
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertNil(plan.groups[0].guardedBy)
        XCTAssertEqual(plan.defaultTicked, [1])
        XCTAssertEqual(plan.counts(ticked: plan.defaultTicked).moves, 300)
        XCTAssertTrue(plan.notices.contains(.syncsMaybeShared))
        XCTAssertEqual(plan.cardNotes, [.notAllowed(1), .syncsMaybeShared])
        XCTAssertEqual(plan.title, .move(300))
    }

    func testAPlanLargerThanItsStrictestPlaceAllowsIsRefused() async {
        let (scope, memory) = await shareRig(files: 201)
        let sorted = await scope.handle("/Volumes/share/Team/Sorted")
        let verdict = await AgentPlanValidator().validate(Kit.proposal(moves: [([], "r1", sorted)]),
                                                          scope: scope, disk: memory, limits: .cloudModel)
        guard case .refused(.too_many) = verdict else { return XCTFail("a server holds a plan to 200 changes: \(verdict)") }
    }
}
