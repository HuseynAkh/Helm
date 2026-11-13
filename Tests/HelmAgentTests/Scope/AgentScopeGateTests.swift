import XCTest
import HelmCore
@testable import HelmAgent

/// Which folders AI mode may work in, on a home shaped like the fixture's: the allow list of places, the place test
/// before any disk call and again on the real path, links, packages, dot names, the hidden flag, the eight-folder
/// limit, folders inside roots, replaced roots, a refused tab folder and aliases that are never reused.
final class AgentScopeGateTests: XCTestCase {
    private let fixture = "/private/tmp/x/.build/host-smoke/fixture"
    private var home: String { fixture + "/home" }
    private var support: String { fixture + "/support" }

    private func makeDisk() -> MemoryAgentDisk { MemoryAgentDisk(home: home) }
    private func gate(_ disk: MemoryAgentDisk) -> AgentScopeGate { AgentScopeGate(disk: disk, home: home, supportFolder: support) }
    private func typed(_ text: String) -> AgentRootInput { AgentRootInput(fromPerson: text, origin: .typed) }
    private func tab(_ text: String) -> AgentRootInput { AgentRootInput(fromPerson: text, origin: .tab) }

    private func admit(_ text: String, on disk: MemoryAgentDisk, existing: [AgentScopeRoot] = []) async -> Result<AgentScopeRoot, AgentScopeRefusal> {
        await gate(disk).admitRoot(typed(text), alias: "r1", existing: existing)
    }

    private func refusal(_ result: Result<AgentScopeRoot, AgentScopeRefusal>) -> AgentScopeRefusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    private func root(_ result: Result<AgentScopeRoot, AgentScopeRefusal>, file: StaticString = #filePath, line: UInt = #line) -> AgentScopeRoot? {
        switch result {
        case .success(let root): return root
        case .failure(let refusal):
            XCTFail("refused: \(refusal)", file: file, line: line)
            return nil
        }
    }

    /// Whether the disk was asked about `path` or anything inside it.
    private func touched(_ disk: MemoryAgentDisk, _ path: String) -> Bool {
        disk.asked.contains { AgentPathParts.isAt($0, orInside: path) }
    }

    // MARK: The allow list

    func testAFolderUnderTheHomeIsAdmitted() async {
        let disk = makeDisk()
        disk.addFolder(home + "/Projects")
        let found = root(await admit(home + "/Projects", on: disk))
        XCTAssertEqual(found?.path, home + "/Projects")
        XCTAssertEqual(found?.alias, "r1")
        XCTAssertEqual(found?.label, "Projects")
        XCTAssertEqual(found?.modelName, "Projects")
        XCTAssertEqual(found?.storage.kind, .thisMac)
        XCTAssertEqual(found?.isTabFolder, false)
        XCTAssertNotNil(found?.identity)
    }

    func testTheHomeFolderIsNamedHomeForTheModel() async {
        let disk = makeDisk()
        let found = root(await gate(disk).admitRoot(tab(home), alias: "r4", existing: []))
        XCTAssertEqual(found?.modelName, "Home")
        XCTAssertEqual(found?.label, "home")
        XCTAssertEqual(found?.isTabFolder, true)
        let tilde = root(await admit("~", on: disk))
        XCTAssertEqual(tilde?.path, home)
    }

    func testPlacesOutsideTheAllowListAreRefusedBeforeAnyDiskCall() async {
        let outside = ["/net/host/x", "/Applications", fixture + "/other", fixture + "/other/Documents",
                       fixture + "/homeother", fixture + "/homeother/Docs", "/System/Library", "/tmp/stuff", "/Volumes", "/Users"]
        for path in outside {
            let disk = makeDisk()
            disk.addFolder(path)
            agentEqual(refusal(await admit(path, on: disk)), .system, path)
            XCTAssertFalse(touched(disk, path), "the disk was asked about \(path)")
        }
        let disk = makeDisk()
        agentEqual(refusal(await admit("/", on: disk)), .system)
        XCTAssertFalse(disk.asked.contains("/"))
    }

    func testTheTwoCloudExceptionsUnderTheHomeLibrary() async {
        let disk = makeDisk()
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs/Notes"
        let drive = home + "/Library/CloudStorage/GoogleDrive-me@example.com"
        for path in [iCloud, drive + "/My Drive", home + "/Library/Preferences"] { disk.addFolder(path) }

        let notes = root(await admit(iCloud, on: disk))
        XCTAssertEqual(notes?.storage.kind, .iCloud)
        XCTAssertEqual(notes?.modelName, "Notes")

        let myDrive = root(await admit(drive + "/My Drive", on: disk))
        XCTAssertEqual(myDrive?.storage.kind, .cloud)
        XCTAssertEqual(myDrive?.storage.name, "Google Drive")
        XCTAssertEqual(myDrive?.modelName, "My Drive")

        // The provider's own folder is named by the provider, never by the account in its name.
        let provider = root(await admit(drive, on: disk))
        XCTAssertEqual(provider?.modelName, "Google Drive")
        XCTAssertEqual(provider?.label, "Google Drive")
        let container = root(await admit(home + "/Library/Mobile Documents/com~apple~CloudDocs", on: disk))
        XCTAssertEqual(container?.modelName, "iCloud Drive")

        for path in [home + "/Library/Preferences", home + "/Library", home + "/Library/CloudStorage", home + "/Library/Mobile Documents"] {
            agentEqual(refusal(await admit(path, on: disk)), .system, path)
        }
        XCTAssertFalse(touched(disk, home + "/Library/Preferences"))
    }

    func testAShortcutTargetsFolderInsideACloudStorageFolderIsAdmitted() async {
        let disk = makeDisk()
        let shortcut = home + "/Library/CloudStorage/GoogleDrive-me@example.com/.shortcut-targets-by-id/1AbC/Team"
        disk.addFolder(shortcut)
        let found = root(await admit(shortcut, on: disk))
        XCTAssertEqual(found?.path, shortcut)
        XCTAssertEqual(found?.storage.kind, .cloud)
    }

    func testVolumesAndTheSharedFolderAreAllowed() async {
        let disk = makeDisk()
        disk.addFolder("/Volumes/Disk/Photos")
        disk.addFolder("/Volumes/Disk/.Spotlight-V100")
        disk.addFolder(fixture + "/Shared/Team")
        disk.setProbe(StorageProbe(isLocal: true, isInternal: false), under: "/Volumes/Disk")
        let photos = root(await admit("/Volumes/Disk/Photos", on: disk))
        XCTAssertEqual(photos?.storage.kind, .external)
        let disk0 = root(await admit("/Volumes/Disk", on: disk))
        XCTAssertEqual(disk0?.modelName, "External disk")
        XCTAssertEqual(disk0?.label, "Disk")
        agentEqual(refusal(await admit("/Volumes/Disk/.Spotlight-V100", on: disk)), .hidden)
        agentNotNil(root(await admit(fixture + "/Shared/Team", on: disk)))
    }

    func testAServerIsNamedServerAndASilentOneIsNotResponding() async {
        let disk = makeDisk()
        disk.addFolder("/Volumes/standinhost/Projects")
        disk.addFolder("/Volumes/Quiet/Files")
        disk.setProbe(StorageProbe(isLocal: false), under: "/Volumes/standinhost")
        disk.setProbe(StorageProbe(timedOut: true), under: "/Volumes/Quiet")
        let share = root(await admit("/Volumes/standinhost", on: disk))
        XCTAssertEqual(share?.storage.kind, .network)
        XCTAssertEqual(share?.modelName, "Server")
        agentEqual(refusal(await admit("/Volumes/Quiet/Files", on: disk)), .notResponding)
    }

    // MARK: Links, packages, dot names and the hidden flag

    func testALinkPointingOutIsRefusedOnItsRealPath() async {
        let disk = makeDisk()
        disk.addFolder("/Applications/Tools")
        disk.addFolder(fixture + "/other/Documents")
        disk.addLink(home + "/Apps", to: "/Applications")
        disk.addLink(home + "/Theirs", to: fixture + "/other/Documents")
        agentEqual(refusal(await admit(home + "/Apps", on: disk)), .system)
        agentEqual(refusal(await admit(home + "/Apps/Tools", on: disk)), .system)
        agentEqual(refusal(await admit(home + "/Theirs", on: disk)), .system)
        // The real place was only ever looked at as a path, never listed or asked about as an item.
        XCTAssertFalse(disk.asked.contains("/Applications"))
    }

    func testALinkedFolderIsAdmittedByItsRealPath() async {
        let disk = makeDisk()
        disk.addFolder(home + "/Real")
        disk.addLink(home + "/Linked", to: home + "/Real")
        let found = root(await admit(home + "/Linked", on: disk))
        XCTAssertEqual(found?.path, home + "/Real")
        XCTAssertEqual(found?.label, "Real")
    }

    func testAPackageAndTheInsideOfOneAreRefused() async {
        let disk = makeDisk()
        disk.addPackage(home + "/Thing.app")
        disk.addFolder(home + "/Thing.app/Contents")
        disk.addFile(home + "/notes.txt")
        agentEqual(refusal(await admit(home + "/Thing.app", on: disk)), .notAFolder)
        agentEqual(refusal(await admit(home + "/Thing.app/Contents", on: disk)), .insidePackage)
        agentEqual(refusal(await admit(home + "/notes.txt", on: disk)), .notAFolder)
        agentEqual(refusal(await admit(home + "/Missing", on: disk)), .notFound)
    }

    func testDotNamesAreRefusedBeforeAnyDiskCall() async {
        let disk = makeDisk()
        disk.addFolder(home + "/.ssh")
        disk.addFolder(home + "/Projects/.git/objects")
        agentEqual(refusal(await admit(home + "/.ssh", on: disk)), .hidden)
        agentEqual(refusal(await admit("~/.ssh", on: disk)), .hidden)
        agentEqual(refusal(await admit(home + "/Projects/.git/objects", on: disk)), .hidden)
        XCTAssertFalse(touched(disk, home + "/.ssh"))
        XCTAssertFalse(touched(disk, home + "/Projects/.git"))
        // A dot part above the home folder doesn't count: the fixture's own home sits under one.
        agentNotNil(root(await admit(home, on: disk)))
    }

    func testTheHiddenFlagRefuses() async {
        let disk = makeDisk()
        disk.addFolder(home + "/Secret")
        disk.setHidden(home + "/Secret")
        agentEqual(refusal(await admit(home + "/Secret", on: disk)), .hidden)
    }

    func testPrefixLookAlikesAreNotInside() async {
        let disk = makeDisk()
        disk.addFolder(fixture + "/home2/Docs")
        disk.addFolder("/VolumesX/Disk")
        disk.addFolder(home + "/LibraryBooks")
        agentEqual(refusal(await admit(fixture + "/home2/Docs", on: disk)), .system)
        agentEqual(refusal(await admit("/VolumesX/Disk", on: disk)), .system)
        // A folder whose name only starts like the Library's is an ordinary folder.
        agentNotNil(root(await admit(home + "/LibraryBooks", on: disk)))
    }

    func testHelmsSupportFolderIsRefused() async {
        let disk = makeDisk()
        disk.addFolder(home + "/HelmSupport/cache")
        let gate = AgentScopeGate(disk: disk, home: home, supportFolder: home + "/HelmSupport")
        let answer = await gate.admitRoot(typed(home + "/HelmSupport/cache"), alias: "r1", existing: [])
        XCTAssertEqual(refusal(answer), .system)
    }

    // MARK: The person's text

    func testTextThatIsNotAPlainAbsolutePathIsRefused() async {
        let disk = makeDisk()
        disk.addFolder(home + "/Projects")
        let bad = [home + "/Pro\u{0}jects", home + "/Projects\n", home + "/\u{7}", "Projects", "../Projects",
                   home + "/Projects/../Projects", home + "/./Projects", "~other/Projects", "file://otherhost" + home + "/Projects",
                   "file://" + home + "/Pro%0Ajects", "/" + String(repeating: "a", count: 4_096), home + "/Pro\u{2028}jects"]
        for text in bad {
            agentEqual(refusal(await admit(text, on: disk)), .badText, text.debugDescription)
        }
        XCTAssertFalse(touched(disk, home + "/Projects"))
        agentEqual(root(await admit("file://" + home.replacingOccurrences(of: ".build", with: "%2Ebuild") + "/Projects", on: disk))?.path,
                       home + "/Projects")
        agentEqual(root(await admit("~/Projects", on: disk))?.path, home + "/Projects")
        agentEqual(root(await admit(home + "/Projects/", on: disk))?.path, home + "/Projects")
    }

    // MARK: Protected folders

    func testFoldersMacOSAsksAboutAreLeavesOnlyUnderAHomeRoot() async {
        let disk = makeDisk()
        disk.addFolder(home + "/Projects")
        let gate = self.gate(disk)
        let homeRoot = root(await gate.admitRoot(tab(home), alias: "r1", existing: []))!
        let projects = root(await gate.admitRoot(typed(home + "/Projects"), alias: "r2", existing: []))!
        for name in ["Desktop", "Documents", "Downloads", "documents"] {
            XCTAssertTrue(gate.isProtectedLeaf(path: home + "/" + name, under: homeRoot), name)
        }
        XCTAssertTrue(gate.isProtectedLeaf(path: home + "/Music/Music", under: homeRoot))
        XCTAssertFalse(gate.isProtectedLeaf(path: home + "/Music", under: homeRoot))
        XCTAssertFalse(gate.isProtectedLeaf(path: home + "/Documents/Taxes", under: homeRoot))
        XCTAssertFalse(gate.isProtectedLeaf(path: home + "/Projects/Documents", under: projects))
    }

    // MARK: Eight folders

    func testANinthFolderIsRefused() async {
        let disk = makeDisk()
        let gate = self.gate(disk)
        var existing = [root(await gate.admitRoot(tab(home), alias: "r1", existing: []))!]
        for index in 1...7 {
            disk.addFolder(home + "/Folder\(index)/Inner")
            existing.append(root(await gate.admitRoot(typed(home + "/Folder\(index)"), alias: "r\(index + 1)", existing: existing))!)
        }
        disk.addFolder(home + "/Ninth")
        agentEqual(refusal(await gate.admitRoot(typed(home + "/Ninth"), alias: "r9", existing: existing)), .full)
        // One inside an added folder isn't a ninth.
        agentNotNil(root(await gate.admitRoot(typed(home + "/Folder3/Inner"), alias: "r9", existing: existing)))
        // The tab's folder always has its place.
        agentNotNil(root(await gate.admitRoot(tab(home + "/Ninth"), alias: "r9", existing: existing)))

        disk.addFolder(home + "/TabFolder")
        let scope = AgentScope(disk: disk, home: home, supportFolder: support)
        _ = await scope.setTabFolder(tab(home + "/TabFolder"))
        for index in 1...7 {
            guard case .added = await scope.folder(for: typed(home + "/Folder\(index)/Inner")) else { return XCTFail("folder \(index)") }
        }
        agentEqual(await scope.folder(for: typed(home + "/Ninth")), .refused(.full))
        let roots = await scope.roots()
        XCTAssertEqual(roots.count, 8)
    }

    // MARK: Roots in a scope

    func testAFolderAlreadyInsideARootAnswersInsideWithAHandle() async {
        let disk = makeDisk()
        disk.addFolder(home + "/Projects/2026")
        let scope = AgentScope(disk: disk, home: home, supportFolder: support)
        guard case .root(let homeRoot) = await scope.setTabFolder(tab(home)) else { return XCTFail("no tab root") }
        guard case .inside(let handle, let name) = await scope.folder(for: typed("~/Projects/2026")) else { return XCTFail("not inside") }
        XCTAssertEqual(name, "2026")
        XCTAssertTrue(handle.hasPrefix("d"))
        let record = await scope.record(for: handle)
        XCTAssertEqual(record?.rootAlias, homeRoot.alias)
        XCTAssertEqual(record?.path, home + "/Projects/2026")
        let roots = await scope.roots()
        XCTAssertEqual(roots.map(\.alias), [homeRoot.alias])
        // The folder that is the root answers with the root.
        agentEqual(await scope.folder(for: typed(home)), .root(homeRoot))
        XCTAssertEqual(AgentFolderRef.inside(handle: handle, name: name).modelID, handle)
    }

    func testAFolderBehindAProtectedFolderBecomesARootOfItsOwn() async {
        let disk = makeDisk()
        disk.addFolder(home + "/Documents/Taxes")
        let scope = AgentScope(disk: disk, home: home, supportFolder: support)
        _ = await scope.setTabFolder(tab(home))
        guard case .added(let taxes) = await scope.folder(for: typed(home + "/Documents/Taxes")) else { return XCTFail("not added") }
        XCTAssertEqual(taxes.path, home + "/Documents/Taxes")
        guard case .added = await scope.folder(for: typed(home + "/Documents")) else { return XCTFail("Documents not added") }
    }

    func testAFolderThatHoldsAddedRootsReplacesThem() async {
        let disk = makeDisk()
        disk.addFolder(home + "/Work/A")
        disk.addFolder(home + "/Work/B")
        let scope = AgentScope(disk: disk, home: home, supportFolder: support)
        guard case .added(let a) = await scope.folder(for: typed(home + "/Work/A")),
              case .added = await scope.folder(for: typed(home + "/Work/B")) else { return XCTFail("not added") }
        let listed = await scope.children(of: (await scope.record(for: a.alias))!, limit: 10)
        XCTAssertEqual(listed.state, .ok)
        guard case .added(let work) = await scope.folder(for: typed(home + "/Work")) else { return XCTFail("Work not added") }
        let roots = await scope.roots()
        XCTAssertEqual(roots.map(\.alias), [work.alias])
        let retired = await scope.isRetired(a.alias)
        XCTAssertTrue(retired)
    }

    func testARootReplacedByAnotherFolderGoesStale() async {
        let disk = makeDisk()
        disk.addFile(home + "/Projects/plan.txt")
        let scope = AgentScope(disk: disk, home: home, supportFolder: support)
        guard case .added(let projects) = await scope.folder(for: typed(home + "/Projects")) else { return XCTFail("not added") }
        let rootRecord = await scope.record(for: projects.alias)!
        let file = await scope.children(of: rootRecord, limit: 10).records.first!
        let stillThere = await scope.recheck(file)
        XCTAssertNil(stillThere)

        disk.replaceIdentity(at: home + "/Projects")
        let recheckedRoot = await scope.recheckRoot(alias: projects.alias)
        XCTAssertNil(recheckedRoot)
        agentEqual(await scope.recheck(file), .stale_id)
        let dropped = await scope.dropChangedRoots()
        XCTAssertEqual(dropped.map(\.alias), [projects.alias])
        let roots = await scope.roots()
        XCTAssertTrue(roots.isEmpty)
        let gone = await scope.record(for: file.handle)
        XCTAssertNil(gone)
        let retired = await scope.isRetired(file.handle)
        XCTAssertTrue(retired)
    }

    func testARefusedTabFolderLeavesNoTabRootAndRetiresTheOldOnesHandles() async {
        let disk = makeDisk()
        disk.addFile(home + "/Projects/plan.txt")
        disk.addFolder("/Applications/Tools")
        let scope = AgentScope(disk: disk, home: home, supportFolder: support)
        guard case .root(let projects) = await scope.setTabFolder(tab(home + "/Projects")) else { return XCTFail("no tab root") }
        let file = await scope.children(of: (await scope.record(for: projects.alias))!, limit: 10).records.first!

        agentEqual(await scope.setTabFolder(tab("/Applications")), .refused(.system))
        let roots = await scope.roots()
        XCTAssertTrue(roots.isEmpty)
        for handle in [projects.alias, file.handle] {
            let record = await scope.record(for: handle)
            XCTAssertNil(record, handle)
            let retired = await scope.isRetired(handle)
            XCTAssertTrue(retired, handle)
        }
        agentEqual(await scope.setTabFolder(tab(home + "/.config")), .refused(.hidden))
        agentEqual(await scope.setTabFolder(nil), AgentTabFolder.none)
    }

    func testTheTabFolderFollowsTheTabUnderANewAlias() async {
        let disk = makeDisk()
        disk.addFolder(home + "/A")
        disk.addFolder(home + "/B")
        let scope = AgentScope(disk: disk, home: home, supportFolder: support)
        guard case .root(let a) = await scope.setTabFolder(tab(home + "/A")),
              case .root(let again) = await scope.setTabFolder(tab(home + "/A")),
              case .root(let b) = await scope.setTabFolder(tab(home + "/B")) else { return XCTFail("no tab root") }
        XCTAssertEqual(a.alias, again.alias)
        XCTAssertNotEqual(a.alias, b.alias)
        let retired = await scope.isRetired(a.alias)
        XCTAssertTrue(retired)
        guard case .root(let backToA) = await scope.setTabFolder(tab(home + "/A")) else { return XCTFail("no tab root") }
        XCTAssertNotEqual(backToA.alias, a.alias)
    }

    func testAnAliasIsNeverIssuedTwiceAlsoAfterClear() async {
        let disk = makeDisk()
        disk.addFolder(home + "/Projects")
        disk.addFolder(home + "/Other")
        let scope = AgentScope(disk: disk, home: home, supportFolder: support)
        var aliases: [String] = []
        func note(_ folder: AgentTabFolder) { if case .root(let root) = folder { aliases.append(root.alias) } }
        func note(_ ref: AgentFolderRef) { if case .added(let root) = ref { aliases.append(root.alias) } }
        note(await scope.setTabFolder(tab(home + "/Other")))
        note(await scope.folder(for: typed(home + "/Projects")))
        await scope.clear()
        aliases += await scope.roots().map(\.alias)
        note(await scope.folder(for: typed(home + "/Projects")))
        await scope.startOver()
        let afterStartOver = await scope.roots().map(\.alias)
        XCTAssertEqual(afterStartOver, Array(aliases.suffix(2)), "starting over keeps the roots' aliases")
        await scope.clear()
        aliases += await scope.roots().map(\.alias)
        note(await scope.setTabFolder(tab(home)))
        XCTAssertEqual(aliases.count, 6)
        XCTAssertEqual(Set(aliases).count, aliases.count, "\(aliases)")
    }
}
