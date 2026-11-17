import XCTest
import HelmCore
@testable import HelmAgent

/// Whole Mac under the same folder rules, on a home shaped like the fixture's: the home folder, iCloud Drive, each
/// cloud folder and each disk are roots of their own; the home's Library and other apps' data stay out; Desktop,
/// Documents and Downloads are leaves; links are never followed; a disk is named by its kind; and This Folder takes
/// the places away and retires every handle.
final class AgentWholeMacScopeTests: XCTestCase {
    private let fixture = "/private/tmp/x/.build/host-smoke/fixture"
    private var home: String { fixture + "/home" }
    private var iCloud: String { home + "/Library/Mobile Documents/com~apple~CloudDocs" }
    private var drive: String { home + "/Library/CloudStorage/GoogleDrive-me@example.com" }
    /// What the app says is mounted: one real disk, and paths the folder rules must turn away.
    private let volumes = ["/Volumes/Backup", "/Volumes/Macintosh HD", "/Volumes/.timemachine", "/", "/net/host/share", "/System/Volumes/Data"]

    private func makeDisk() -> MemoryAgentDisk {
        let disk = MemoryAgentDisk(home: home)
        disk.addFile(home + "/Documents/Screenshot 1.png")
        disk.addFolder(home + "/Desktop")
        disk.addFolder(home + "/Downloads")
        disk.addFolder(home + "/Pictures/Screenshots")
        disk.addFolder(home + "/Music/Music")
        disk.addFile(home + "/Library/Preferences/com.example.plist")
        disk.addFolder(home + "/Library/Containers/com.example.notes/Data")
        disk.addFolder(home + "/.ssh")
        disk.addFolder(iCloud + "/Notes")
        disk.addFile(drive + "/My Drive/plan.txt")
        disk.addFolder("/Volumes/Backup/Old")
        disk.setProbe(StorageProbe(isLocal: true, isInternal: false), under: "/Volumes/Backup")
        disk.addLink("/Volumes/Macintosh HD", to: "/")
        disk.addFolder("/Volumes/.timemachine/Backups")
        disk.addFolder("/System/Volumes/Data/private")
        disk.addLink(home + "/Escape", to: "/private/etc")
        disk.addFolder("/private/etc/ssh")
        return disk
    }

    private func scope(_ disk: MemoryAgentDisk, volumes: [String]? = nil) -> AgentScope {
        let mounted = volumes ?? self.volumes
        return AgentScope(disk: disk, home: home, supportFolder: fixture + "/support", mountedVolumes: { mounted })
    }

    private func tab(_ path: String) -> AgentRootInput { AgentRootInput(fromPerson: path, origin: .tab) }

    private func runner(_ scope: AgentScope, _ disk: MemoryAgentDisk) -> AgentToolRunner {
        AgentToolRunner(scope: scope, disk: disk, validator: AgentPlanValidator(), limits: .cloudModel)
    }

    private func list(_ id: String, with runner: AgentToolRunner) async -> AgentToolOutcome {
        let call = AgentToolCall(id: "c1", name: "list_folder", arguments: Data(#"{"folder": "\#(id)", "depth": 1, "after": ""}"#.utf8))
        return await runner.run(call, selectedPaths: [])
    }

    private func code(_ outcome: AgentToolOutcome) -> AgentToolCode? {
        if case .error(let code) = outcome { return code }
        return nil
    }

    /// The names a listing gave, in its order.
    private func names(_ outcome: AgentToolOutcome) -> [String] {
        guard case .result(let json, _) = outcome, let found = AgentJSON(jsonText: json) else { return [] }
        return AgentLoopKit.array(found, "items").compactMap { AgentLoopKit.string($0, "name") }
    }

    // MARK: The places

    func testWholeMacAddsTheHomeICloudDriveEachCloudFolderAndEachDisk() async {
        let disk = makeDisk()
        let scope = self.scope(disk)
        guard case .root(let shown) = await scope.setTabFolder(tab(home + "/Documents")) else { return XCTFail("the tab's folder") }
        await scope.setMode(.wholeMac)
        let roots = await scope.roots()
        XCTAssertEqual(roots.map(\.path), [home + "/Documents", home, iCloud, drive, "/Volumes/Backup"])
        XCTAssertEqual(roots.map(\.modelName), ["Documents", "Home", "iCloud Drive", "Google Drive", "External disk"])
        XCTAssertEqual(roots.map(\.isWholeMac), [false, true, true, true, true])
        XCTAssertEqual(roots.first?.alias, shown.alias, "the tab's folder keeps its alias")
        XCTAssertEqual(Set(roots.map(\.alias)).count, roots.count)
        XCTAssertEqual(roots.map(\.storage.kind), [.thisMac, .thisMac, .iCloud, .cloud, .external])
        // The startup disk, a dot name, /net and the system's own volumes are turned away, /net before any disk call.
        XCTAssertFalse(disk.asked.contains { AgentPathParts.isAt($0, orInside: "/net") }, "the disk was asked about /net")
        XCTAssertFalse(disk.asked.contains { AgentPathParts.isAt($0, orInside: "/System") })
        XCTAssertFalse(disk.asked.contains { AgentPathParts.isAt($0, orInside: "/Volumes/.timemachine") })
        let mode = await scope.mode
        XCTAssertEqual(mode, .wholeMac)
    }

    func testADiskIsNamedForTheModelByItsKindNeverByItsName() async {
        let disk = makeDisk()
        disk.addFolder("/Volumes/Marlowe's Disk/Work")
        disk.addFolder("/Volumes/standinhost/Team")
        disk.setProbe(StorageProbe(isLocal: false), under: "/Volumes/standinhost")
        let scope = self.scope(disk, volumes: ["/Volumes/Marlowe's Disk", "/Volumes/standinhost"])
        await scope.setMode(.wholeMac)
        let disks = await scope.roots().filter { $0.path.hasPrefix("/Volumes/") }
        XCTAssertEqual(disks.map(\.modelName), ["Disk", "Server"])
        XCTAssertEqual(disks.map(\.label), ["Marlowe's Disk", "standinhost"], "the person still sees the disk's name")
    }

    func testThePlacesDontCountTowardTheSevenAddedFolders() async {
        let disk = makeDisk()
        let scope = self.scope(disk)
        _ = await scope.setTabFolder(tab(home + "/Pictures"))
        for index in 1...7 {
            disk.addFolder(home + "/Added \(index)")
            guard case .added = await scope.folder(for: AgentRootInput(fromPerson: home + "/Added \(index)", origin: .typed)) else {
                return XCTFail("folder \(index) wasn't added")
            }
        }
        await scope.setMode(.wholeMac)
        let roots = await scope.roots()
        XCTAssertEqual(roots.count, 1 + 4 + 7)
        XCTAssertEqual(roots.filter(\.isWholeMac).count, 4)
        // A folder inside the home is already in reach, so it gets a handle under Home and no root.
        disk.addFolder(home + "/Projects")
        guard case .inside = await scope.folder(for: AgentRootInput(fromPerson: home + "/Projects", origin: .typed)) else {
            return XCTFail("a folder in the home folder is inside a root")
        }
    }

    // MARK: The home folder's listing

    func testTheHomeListingLeavesOutLibraryAndKeepsGuardedFoldersAsLeaves() async {
        let disk = makeDisk()
        let scope = self.scope(disk)
        _ = await scope.setTabFolder(tab(home + "/Pictures"))
        await scope.setMode(.wholeMac)
        guard let homeRoot = await scope.roots().first(where: { $0.modelName == "Home" }),
              let record = await scope.record(for: homeRoot.alias) else { return XCTFail("no home root") }
        let runner = self.runner(scope, disk)
        agentEqual(names(await list(homeRoot.alias, with: runner)),
                   ["Desktop", "Documents", "Downloads", "Escape", "Music", "Pictures"],
                   "no Library, no dot folder")
        let children = await scope.children(of: record, limit: 100).records
        let leaves = children.filter(\.isProtectedLeaf).map(\.name)
        XCTAssertEqual(leaves, ["Desktop", "Documents", "Downloads"])
        // A guarded folder is named, never entered; nor is the music library inside Music.
        for name in leaves {
            guard let leaf = children.first(where: { $0.name == name }) else { continue }
            agentEqual(code(await list(leaf.handle, with: runner)), .not_allowed, name)
        }
        guard let music = children.first(where: { $0.name == "Music" }) else { return XCTFail("no Music") }
        let inMusic = await scope.children(of: music, limit: 10).records
        XCTAssertEqual(inMusic.map(\.isProtectedLeaf), [true])
        XCTAssertFalse(disk.asked.contains { AgentPathParts.isAt($0, orInside: self.home + "/Documents") && $0 != self.home + "/Documents" })
        // The Library is never a child, by listing or by name, and neither is another app's data.
        agentEqual(await scope.admit(childNamed: "Library", in: record).failureCode, .not_allowed)
        XCTAssertFalse(disk.asked.contains { AgentPathParts.isAt($0, orInside: self.home + "/Library/Containers") })
        XCTAssertFalse(disk.asked.contains { AgentPathParts.isAt($0, orInside: self.home + "/Library/Preferences") })
        // Pictures is open, and so is the folder for screenshots in it.
        guard let pictures = children.first(where: { $0.name == "Pictures" }) else { return XCTFail("no Pictures") }
        agentEqual(names(await list(pictures.handle, with: runner)), ["Screenshots"])
    }

    func testALinkOutOfTheHomeIsALinkAndNeverEntered() async {
        let disk = makeDisk()
        let scope = self.scope(disk)
        _ = await scope.setTabFolder(tab(home + "/Pictures"))
        await scope.setMode(.wholeMac)
        guard let homeRoot = await scope.roots().first(where: { $0.modelName == "Home" }),
              let record = await scope.record(for: homeRoot.alias) else { return XCTFail("no home root") }
        let children = await scope.children(of: record, limit: 100).records
        guard let escape = children.first(where: { $0.name == "Escape" }) else { return XCTFail("the link isn't listed") }
        XCTAssertEqual(escape.kind, .symlinkToDirectory)
        agentEqual(code(await list(escape.handle, with: runner(scope, disk))), .link)
        XCTAssertFalse(disk.asked.contains { AgentPathParts.isAt($0, orInside: "/private/etc") }, "the link was followed")
        // Named as a folder of its own, its real path is outside the allowed places.
        guard case .refused(.system) = await scope.folder(for: AgentRootInput(fromPerson: home + "/Escape", origin: .typed)) else {
            return XCTFail("a link out of the home folder was let in")
        }
        // So is /net, before the disk is asked anything.
        guard case .refused(.system) = await scope.folder(for: AgentRootInput(fromPerson: "/net/host/share", origin: .typed)) else {
            return XCTFail("/net was let in")
        }
        XCTAssertFalse(disk.asked.contains { AgentPathParts.isAt($0, orInside: "/net") })
    }

    // MARK: Back to This Folder

    func testThisFolderTakesThePlacesAwayAndRetiresEveryHandle() async {
        let disk = makeDisk()
        let scope = self.scope(disk)
        guard case .root(let shown) = await scope.setTabFolder(tab(home + "/Pictures")) else { return XCTFail("the tab's folder") }
        await scope.setMode(.wholeMac)
        guard let homeRoot = await scope.roots().first(where: { $0.modelName == "Home" }),
              let record = await scope.record(for: homeRoot.alias) else { return XCTFail("no home root") }
        let child = await scope.children(of: record, limit: 100).records.first { $0.name == "Pictures" }
        guard let child else { return XCTFail("no Pictures") }

        await scope.setMode(.thisFolder)
        let roots = await scope.roots()
        XCTAssertEqual(roots.map(\.alias), [shown.alias], "only the tab's folder, under its own alias")
        agentNil(await scope.record(for: child.handle))
        agentTrue(await scope.isRetired(child.handle))
        agentNil(await scope.record(for: homeRoot.alias))
        agentTrue(await scope.isRetired(homeRoot.alias))

        // On again, the places come back under new aliases, never the old ones.
        await scope.setMode(.wholeMac)
        let again = await scope.roots().filter(\.isWholeMac).map(\.alias)
        XCTAssertFalse(again.contains(homeRoot.alias))
        XCTAssertEqual(again.count, 4)
    }

    func testClearComesBackToThisFolder() async {
        let disk = makeDisk()
        let scope = self.scope(disk)
        _ = await scope.setTabFolder(tab(home + "/Pictures"))
        await scope.setMode(.wholeMac)
        await scope.clear()
        let roots = await scope.roots()
        XCTAssertEqual(roots.count, 1)
        XCTAssertFalse(roots.contains(where: \.isWholeMac))
        let mode = await scope.mode
        XCTAssertEqual(mode, .thisFolder)
    }
}

private extension Result where Failure == AgentToolCode {
    var failureCode: AgentToolCode? {
        if case .failure(let code) = self { return code }
        return nil
    }
}
