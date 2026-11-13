import XCTest
import HelmCore
@testable import HelmAgent

/// The disk that exists only in memory: what it answers, what it can be told to be, and that it notes every
/// question it is asked.
final class MemoryAgentDiskTests: XCTestCase {
    private let home = "/home/helm"

    private func names(_ listing: AgentDiskListing) -> [String] { listing.items.map(\.name) }

    // MARK: What is there

    func testANewDiskHoldsTheHomeFolderAndNothingElse() async {
        let disk = MemoryAgentDisk()
        let folder = await disk.item(at: home)
        XCTAssertEqual(folder?.kind, .directory)
        XCTAssertEqual(folder?.name, "helm")
        XCTAssertEqual(folder?.path, home)
        XCTAssertNotNil(folder?.identity)
        let listing = await disk.list(home, limit: 100, idleSeconds: 3)
        XCTAssertEqual(listing.state, .ok)
        XCTAssertEqual(names(listing), [])
        let above = await disk.item(at: "/home")
        XCTAssertEqual(above?.kind, .directory)
        let missing = await disk.item(at: "/home/helm/Documents")
        XCTAssertNil(missing)
        let other = await MemoryAgentDisk(home: "/private/tmp/x/.build/host-smoke/fixture/home").item(at: "/private/tmp/x/.build/host-smoke/fixture/home")
        XCTAssertEqual(other?.kind, .directory)
    }

    func testAFileIsAddedWithTheFoldersAboveIt() async {
        let disk = MemoryAgentDisk()
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        disk.addFile("/home/helm/Documents/Tax/2026/return.pdf", size: 410_000, modified: modified, typeIdentifier: "com.adobe.pdf")
        let file = await disk.item(at: "/home/helm/Documents/Tax/2026/return.pdf")
        XCTAssertEqual(file?.kind, .regular)
        XCTAssertEqual(file?.name, "return.pdf")
        XCTAssertEqual(file?.path, "/home/helm/Documents/Tax/2026/return.pdf")
        XCTAssertEqual(file?.size, 410_000)
        XCTAssertEqual(file?.modified, modified)
        XCTAssertEqual(file?.typeIdentifier, "com.adobe.pdf")
        XCTAssertEqual(file?.isHidden, false)
        XCTAssertEqual(file?.isDataless, false)
        XCTAssertNil(file?.place)
        for folder in ["/home/helm/Documents", "/home/helm/Documents/Tax", "/home/helm/Documents/Tax/2026"] {
            let item = await disk.item(at: folder)
            XCTAssertEqual(item?.kind, .directory, folder)
        }
        // Adding it again changes its details and leaves it the object it was.
        disk.addFile("/home/helm/Documents/Tax/2026/return.pdf", size: 5)
        let again = await disk.item(at: "/home/helm/Documents/Tax/2026/return.pdf")
        XCTAssertEqual(again?.size, 5)
        XCTAssertEqual(again?.identity, file?.identity)
    }

    func testEveryItemIsItsOwnObject() async throws {
        let disk = MemoryAgentDisk()
        disk.addFile("/home/helm/a.txt")
        disk.addFile("/home/helm/b.txt")
        disk.addFolder("/home/helm/Folder")
        disk.addFolder("/Volumes/Backup/Photos")
        var identities: [FileObjectIdentity] = []
        for path in ["/home/helm", "/home/helm/a.txt", "/home/helm/b.txt", "/home/helm/Folder", "/Volumes/Backup", "/Volumes/Backup/Photos"] {
            let item = await disk.item(at: path)
            identities.append(try XCTUnwrap(item?.identity))
        }
        XCTAssertEqual(Set(identities).count, identities.count)
        // A disk in the Volumes folder is another device than the startup disk.
        XCTAssertEqual(identities[0].scope, identities[1].scope)
        XCTAssertNotEqual(identities[0].scope, identities[4].scope)
        XCTAssertEqual(identities[4].scope, identities[5].scope)
    }

    // MARK: Listing

    func testAListingIsSortedByNameAndCutAtTheLimit() async {
        let disk = MemoryAgentDisk()
        for name in ["b.txt", "A.txt", "file10.txt", "file2.txt", "Zeta", "alpha", ".hidden", "~$lock.docx"] {
            disk.addFile("/home/helm/Downloads/" + name)
        }
        disk.addFolder("/home/helm/Downloads/Folder")
        disk.addFile("/home/helm/Downloads/Folder/inside.txt")
        let all = await disk.list("/home/helm/Downloads", limit: 100, idleSeconds: 3)
        // Everything in the folder itself, dot names included: what may be shown to a model is not the disk's to decide.
        XCTAssertEqual(names(all), [".hidden", "A.txt", "alpha", "b.txt", "file2.txt", "file10.txt", "Folder", "Zeta", "~$lock.docx"])
        XCTAssertEqual(all.more, 0)
        XCTAssertEqual(all.unreadable, 0)
        XCTAssertEqual(all.state, .ok)
        XCTAssertEqual(all.items.first { $0.name == "Folder" }?.kind, .directory)
        XCTAssertEqual(all.items.first { $0.name == "A.txt" }?.path, "/home/helm/Downloads/A.txt")

        let page = await disk.list("/home/helm/Downloads", limit: 3, idleSeconds: 3)
        XCTAssertEqual(names(page), [".hidden", "A.txt", "alpha"])
        XCTAssertEqual(page.more, 6)
        let none = await disk.list("/home/helm/Downloads", limit: 0, idleSeconds: 3)
        XCTAssertEqual(names(none), [])
        XCTAssertEqual(none.more, 9)
    }

    func testAListingSaysWhyItHasNothing() async {
        let disk = MemoryAgentDisk()
        disk.addFile("/home/helm/Documents/a.txt")
        disk.addFolder("/home/helm/Private")
        disk.addFile("/home/helm/Private/secret.txt")
        disk.addFolder("/home/helm/Cloud/Old")
        disk.markDenied("/home/helm/Private")
        disk.markNotLoaded("/home/helm/Cloud/Old")

        let gone = await disk.list("/home/helm/Nowhere", limit: 10, idleSeconds: 3)
        XCTAssertEqual(gone.state, .gone)
        let file = await disk.list("/home/helm/Documents/a.txt", limit: 10, idleSeconds: 3)
        XCTAssertEqual(file.state, .gone)
        let denied = await disk.list("/home/helm/Private", limit: 10, idleSeconds: 3)
        XCTAssertEqual(denied.state, .denied)
        XCTAssertEqual(names(denied), [])
        let notLoaded = await disk.list("/home/helm/Cloud/Old", limit: 10, idleSeconds: 3)
        XCTAssertEqual(notLoaded.state, .notLoaded)
        let folder = await disk.item(at: "/home/helm/Cloud/Old")
        XCTAssertEqual(folder?.isDataless, true)
        // The folder that holds them lists them by name all the same.
        let parent = await disk.list(home, limit: 10, idleSeconds: 3)
        XCTAssertEqual(names(parent), ["Cloud", "Documents", "Private"])
    }

    // MARK: Marks

    func testMarksShowOnTheItem() async {
        let disk = MemoryAgentDisk()
        disk.addFile("/home/helm/Drive/Budget.xlsx", size: 88_000)
        disk.addFile("/home/helm/Drive/plain.txt")
        disk.markCloudOnly("/home/helm/Drive/Budget.xlsx")
        disk.setHidden("/home/helm/Drive/plain.txt")
        let cloud = await disk.item(at: "/home/helm/Drive/Budget.xlsx")
        XCTAssertEqual(cloud?.isDataless, true)
        XCTAssertEqual(cloud?.size, 88_000, "a file that isn't downloaded still has its size")
        XCTAssertEqual(cloud?.isHidden, false)
        let hidden = await disk.item(at: "/home/helm/Drive/plain.txt")
        XCTAssertEqual(hidden?.isHidden, true)
        XCTAssertEqual(hidden?.isDataless, false)
        let listing = await disk.list("/home/helm/Drive", limit: 10, idleSeconds: 3)
        XCTAssertEqual(listing.items.map(\.isDataless), [true, false])
        XCTAssertEqual(listing.items.map(\.isHidden), [false, true])
        // A mark on something that isn't there marks nothing.
        disk.markCloudOnly("/home/helm/Drive/missing.txt")
        let missing = await disk.item(at: "/home/helm/Drive/missing.txt")
        XCTAssertNil(missing)
    }

    func testAPackageIsOneItem() async {
        let disk = MemoryAgentDisk()
        disk.addPackage("/home/helm/Apps/Tool.app")
        disk.addFile("/home/helm/Apps/Tool.app/Contents/Info.plist")
        let package = await disk.item(at: "/home/helm/Apps/Tool.app")
        XCTAssertEqual(package?.kind, .package)
        let listing = await disk.list("/home/helm/Apps", limit: 10, idleSeconds: 3)
        XCTAssertEqual(listing.items.map(\.kind), [.package])
        // Adding a file inside it didn't turn it into a plain folder.
        let inside = await disk.item(at: "/home/helm/Apps/Tool.app/Contents")
        XCTAssertEqual(inside?.kind, .directory)
    }

    func testRemovingAndReplacing() async {
        let disk = MemoryAgentDisk()
        disk.addFile("/home/helm/Old/a.txt")
        disk.addFile("/home/helm/Old/Deeper/b.txt")
        disk.addFile("/home/helm/Older/c.txt")
        let before = await disk.item(at: "/home/helm/Old")

        disk.replaceIdentity(at: "/home/helm/Old")
        let replaced = await disk.item(at: "/home/helm/Old")
        XCTAssertEqual(replaced?.path, before?.path)
        XCTAssertEqual(replaced?.kind, .directory)
        XCTAssertNotEqual(replaced?.identity, before?.identity)
        let child = await disk.item(at: "/home/helm/Old/a.txt")
        XCTAssertNotNil(child, "what was inside is still there")

        disk.remove("/home/helm/Old")
        for path in ["/home/helm/Old", "/home/helm/Old/a.txt", "/home/helm/Old/Deeper", "/home/helm/Old/Deeper/b.txt"] {
            let item = await disk.item(at: path)
            XCTAssertNil(item, path)
        }
        // A folder whose name only starts the same way is untouched.
        let sibling = await disk.item(at: "/home/helm/Older/c.txt")
        XCTAssertNotNil(sibling)
        let listing = await disk.list(home, limit: 10, idleSeconds: 3)
        XCTAssertEqual(names(listing), ["Older"])
    }

    // MARK: Links

    func testALinkIsNeverFollowedWhenItIsLookedAt() async {
        let disk = MemoryAgentDisk()
        disk.addFolder("/home/helm/Real/Folder")
        disk.addFile("/home/helm/Real/file.txt", size: 7)
        disk.addFile("/outside/secret.txt")
        disk.addLink("/home/helm/Links/toFolder", to: "/home/helm/Real/Folder")
        disk.addLink("/home/helm/Links/toFile", to: "../Real/file.txt")
        disk.addLink("/home/helm/Links/out", to: "/outside")
        disk.addLink("/home/helm/Links/broken", to: "/home/helm/Nowhere")

        let toFolder = await disk.item(at: "/home/helm/Links/toFolder")
        XCTAssertEqual(toFolder?.kind, .symlinkToDirectory)
        XCTAssertEqual(toFolder?.path, "/home/helm/Links/toFolder")
        let toFile = await disk.item(at: "/home/helm/Links/toFile")
        XCTAssertEqual(toFile?.kind, .symlinkToFile)
        XCTAssertEqual(toFile?.size, 0, "the link's own details, not its target's")
        let out = await disk.item(at: "/home/helm/Links/out")
        XCTAssertEqual(out?.kind, .symlinkToDirectory)
        let broken = await disk.item(at: "/home/helm/Links/broken")
        XCTAssertEqual(broken?.kind, .danglingSymlink)
        let listing = await disk.list("/home/helm/Links", limit: 10, idleSeconds: 3)
        XCTAssertEqual(listing.items.map(\.kind), [.danglingSymlink, .symlinkToDirectory, .symlinkToFile, .symlinkToDirectory])
    }

    func testTheCanonicalPathFollowsEveryLink() async {
        let disk = MemoryAgentDisk()
        disk.addFile("/home/helm/Real/Folder/a.txt")
        disk.addFolder("/outside/Folder")
        disk.addLink("/home/helm/Links/toFolder", to: "/home/helm/Real/Folder")
        disk.addLink("/home/helm/Links/relative", to: "../Real")
        disk.addLink("/home/helm/Links/out", to: "/outside")
        disk.addLink("/home/helm/Links/chain", to: "relative")
        disk.addLink("/home/helm/Links/broken", to: "/home/helm/Nowhere")
        disk.addLink("/home/helm/Links/loopA", to: "loopB")
        disk.addLink("/home/helm/Links/loopB", to: "loopA")

        func canonical(_ path: String) async -> String? { await disk.canonicalPath(path) }
        var answer = await canonical("/home/helm/Real/Folder/a.txt")
        XCTAssertEqual(answer, "/home/helm/Real/Folder/a.txt")
        answer = await canonical("/home/helm/Links/toFolder")
        XCTAssertEqual(answer, "/home/helm/Real/Folder")
        answer = await canonical("/home/helm/Links/toFolder/a.txt")
        XCTAssertEqual(answer, "/home/helm/Real/Folder/a.txt")
        answer = await canonical("/home/helm/Links/relative/Folder")
        XCTAssertEqual(answer, "/home/helm/Real/Folder")
        answer = await canonical("/home/helm/Links/chain/Folder/a.txt")
        XCTAssertEqual(answer, "/home/helm/Real/Folder/a.txt")
        // A link that leaves the home folder shows where it really goes.
        answer = await canonical("/home/helm/Links/out/Folder")
        XCTAssertEqual(answer, "/outside/Folder")
        answer = await canonical("/home/helm/./Real/../Real/Folder")
        XCTAssertEqual(answer, "/home/helm/Real/Folder")
        answer = await canonical("/")
        XCTAssertEqual(answer, "/")
        // Nil when any part is missing, a link goes nowhere, or links go round in a circle.
        for path in ["/home/helm/Nowhere", "/home/helm/Real/Folder/missing.txt", "/home/helm/Links/broken", "/home/helm/Links/broken/x",
                     "/home/helm/Links/loopA", "/home/helm/Real/Folder/a.txt/below"] {
            answer = await canonical(path)
            XCTAssertNil(answer, path)
        }
        // Looking through a link in a folder above reaches what is really there.
        let through = await disk.item(at: "/home/helm/Links/toFolder/a.txt")
        XCTAssertEqual(through?.kind, .regular)
        let listed = await disk.list("/home/helm/Links/toFolder", limit: 10, idleSeconds: 3)
        XCTAssertEqual(names(listed), ["a.txt"])
    }

    // MARK: Places

    func testAFoldersPlaceComesFromItsPathAndItsFacts() async {
        let disk = MemoryAgentDisk()
        disk.addFolder("/home/helm/Documents")
        disk.addFolder("/home/helm/Library/CloudStorage/GoogleDrive-me@example.com/My Drive")
        disk.addFolder("/home/helm/Library/Mobile Documents/com~apple~CloudDocs/Notes")
        disk.addFolder("/Volumes/Share/Team")
        disk.addFolder("/Volumes/Stick/Photos")

        var facts = await disk.storage(of: "/home/helm/Documents")
        XCTAssertEqual(facts, .thisMac)
        facts = await disk.storage(of: "/home/helm/Library/CloudStorage/GoogleDrive-me@example.com/My Drive")
        XCTAssertEqual(facts.kind, .cloud)
        XCTAssertEqual(facts.name, "Google Drive")
        XCTAssertTrue(facts.syncs)
        XCTAssertFalse(facts.name.contains("example"), "the account is never part of the name")
        facts = await disk.storage(of: "/home/helm/Library/Mobile Documents/com~apple~CloudDocs/Notes")
        XCTAssertEqual(facts.kind, .iCloud)

        // What a path can't say is set as raw facts under a prefix. The longest prefix wins.
        disk.setProbe(StorageProbe(isLocal: false, hasTrash: false, volumeRoot: "/Volumes/Share"), under: "/Volumes/Share")
        disk.setProbe(StorageProbe(isInternal: false, isRemovable: true, volumeRoot: "/Volumes/Stick"), under: "/Volumes/Stick")
        disk.setProbe(StorageProbe(isLocal: false, isReadOnly: true, volumeRoot: "/Volumes/Share"), under: "/Volumes/Share/Team/Archive")
        facts = await disk.storage(of: "/Volumes/Share/Team")
        XCTAssertEqual(facts.kind, .network)
        XCTAssertEqual(facts.name, "Server")
        XCTAssertEqual(facts.trash, .no)
        XCTAssertFalse(facts.isReadOnly)
        XCTAssertTrue(facts.isResponding)
        facts = await disk.storage(of: "/Volumes/Share/Team/Archive/2020")
        XCTAssertTrue(facts.isReadOnly)
        facts = await disk.storage(of: "/Volumes/Stick/Photos")
        XCTAssertEqual(facts.kind, .external)
        // A folder whose name only starts like the prefix isn't under it.
        facts = await disk.storage(of: "/Volumes/Share2")
        XCTAssertNotEqual(facts.kind, .network)

        // A place that gave no answer isn't responding.
        disk.setProbe(StorageProbe(timedOut: true), under: "/Volumes/Share")
        facts = await disk.storage(of: "/Volumes/Share/Team")
        XCTAssertEqual(facts.kind, .network)
        XCTAssertFalse(facts.isResponding)
    }

    func testAChildFolderInAnotherPlaceCarriesItsPlace() async {
        let disk = MemoryAgentDisk()
        disk.addFolder("/home/helm/Documents")
        disk.addFolder("/home/helm/Desktop")
        disk.addFolder("/home/helm/Downloads")
        disk.addFile("/home/helm/note.txt")
        // iCloud keeps Documents; everything else in the home folder is on this Mac.
        disk.setProbe(StorageProbe(isUbiquitous: true), under: "/home/helm/Documents")
        let listing = await disk.list(home, limit: 10, idleSeconds: 3)
        XCTAssertEqual(names(listing), ["Desktop", "Documents", "Downloads", "note.txt"])
        XCTAssertEqual(listing.items.map { $0.place?.kind }, [nil, .iCloud, nil, nil])
        XCTAssertEqual(listing.items[1].place?.name, "iCloud Drive")
        // Listed from inside, the folder is in its own place, so nothing is marked.
        disk.addFolder("/home/helm/Documents/Reports")
        let inside = await disk.list("/home/helm/Documents", limit: 10, idleSeconds: 3)
        XCTAssertEqual(inside.items.map { $0.place?.kind }, [nil])
    }

    // MARK: Slow places and what was asked

    func testASlowPlaceEndsAListingAfterTheIdleTime() async {
        let disk = MemoryAgentDisk()
        disk.addFile("/Volumes/Share/Team/a.txt")
        disk.addFile("/home/helm/Documents/a.txt")
        disk.setDelay(5, under: "/Volumes/Share")
        let started = Date()
        let slow = await disk.list("/Volumes/Share/Team", limit: 10, idleSeconds: 0.05)
        XCTAssertEqual(slow.state, .slow)
        XCTAssertEqual(names(slow), [])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the wait is the idle time, not the place's own")
        // Another place answers at once.
        let quick = await disk.list("/home/helm/Documents", limit: 10, idleSeconds: 0.05)
        XCTAssertEqual(quick.state, .ok)
        // A place that is slow but inside the limit answers.
        disk.setDelay(0.02, under: "/Volumes/Share")
        let patient = await disk.list("/Volumes/Share/Team", limit: 10, idleSeconds: 1)
        XCTAssertEqual(patient.state, .ok)
        XCTAssertEqual(names(patient), ["a.txt"])
    }

    func testAPlaceThatStoppedAnsweringGivesNoAnswer() async {
        let disk = MemoryAgentDisk()
        disk.addFile("/Volumes/Share/Team/a.txt")
        disk.setDelay(AgentLimits.diskSeconds + 5, under: "/Volumes/Share")
        let started = Date()
        async let item = disk.item(at: "/Volumes/Share/Team/a.txt")
        async let canonical = disk.canonicalPath("/Volumes/Share/Team")
        async let facts = disk.storage(of: "/Volumes/Share/Team")
        let answers = await (item, canonical, facts)
        XCTAssertNil(answers.0)
        XCTAssertNil(answers.1)
        XCTAssertFalse(answers.2.isResponding)
        XCTAssertEqual(answers.2.kind, .network)
        // Each question waited out its two seconds and no longer.
        XCTAssertLessThan(Date().timeIntervalSince(started), AgentLimits.diskSeconds + 3)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), AgentLimits.diskSeconds - 0.2)
    }

    func testEveryQuestionIsNoted() async {
        let disk = MemoryAgentDisk()
        disk.addFile("/home/helm/Documents/a.txt")
        disk.addFile("/home/helm/Private/secret.txt")
        XCTAssertEqual(disk.asked, [], "building the disk asks it nothing")

        _ = await disk.canonicalPath("/home/helm/Documents")
        _ = await disk.item(at: "/home/helm/Documents/a.txt")
        _ = await disk.list("/home/helm/Documents", limit: 10, idleSeconds: 3)
        _ = await disk.storage(of: "/home/helm/Documents")
        _ = await disk.item(at: "/home/helm/Nowhere")
        XCTAssertEqual(disk.asked, ["/home/helm/Documents", "/home/helm/Documents/a.txt", "/home/helm/Documents",
                                    "/home/helm/Documents", "/home/helm/Nowhere"])
        // So a test can show a folder was never looked at.
        XCTAssertFalse(disk.asked.contains { $0.hasPrefix("/home/helm/Private") })
    }
}
