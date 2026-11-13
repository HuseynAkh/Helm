import Foundation
import XCTest
import HelmCore
import HelmFileSystem

/// The stand-in reader of what kind of place a folder is in: the classifier's path rules on an injected home, plus
/// what a path can't say, set by prefix. It never reads the disk, so none of these folders exists.
final class MemoryStorageFactsReaderTests: XCTestCase {
    private let home = "/private/tmp/x/.build/host-smoke/fixture/home"
    private func folder(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }
    private func reader() -> MemoryStorageFactsReader { MemoryStorageFactsReader(home: folder(home)) }

    func testPathRulesApplyToTheInjectedHomeWithNothingSet() async {
        let reader = reader()
        let documents = await reader.facts(for: folder(home + "/Documents"))
        XCTAssertEqual(documents, .thisMac)
        let drive = await reader.facts(for: folder(home + "/Library/CloudStorage/GoogleDrive-me@example.com/My Drive/Reports"))
        XCTAssertEqual(drive, StorageFacts(kind: .cloud, name: "Google Drive", syncs: true, shared: .unknown, trash: .yes,
                                           cloudRoot: home + "/Library/CloudStorage/GoogleDrive-me@example.com"))
        let iCloud = await reader.facts(for: folder(home + "/Library/Mobile Documents/com~apple~CloudDocs"))
        XCTAssertEqual(iCloud.kind, .iCloud)
        XCTAssertEqual(iCloud.name, "iCloud Drive")
        // The rules are for the home it was given: the same folders under another home are ordinary ones.
        let elsewhere = await reader.facts(for: folder("/home/helm/Library/CloudStorage/Dropbox/Work"))
        XCTAssertEqual(elsewhere, .thisMac)
        let other = MemoryStorageFactsReader(home: folder("/home/helm"))
        let dropbox = await other.facts(for: folder("/home/helm/Library/CloudStorage/Dropbox/Work"))
        XCTAssertEqual(dropbox.name, "Dropbox")
        XCTAssertEqual(dropbox.cloudRoot, "/home/helm/Library/CloudStorage/Dropbox")
    }

    func testAProbeAppliesAtAndInsideItsPrefix() async {
        let reader = reader()
        reader.set(StorageProbe(isLocal: false, hasTrash: false, volumeRoot: "/Volumes/team"), under: "/Volumes/team")
        for path in ["/Volumes/team", "/Volumes/team/Projects", "/Volumes/team/Projects/2026/Q4"] {
            let facts = await reader.facts(for: folder(path))
            XCTAssertEqual(facts, StorageFacts(kind: .network, name: "Server", shared: .yes, trash: .no, volumeRoot: "/Volumes/team"), path)
        }
        // A name that only starts the same isn't inside, and neither is the folder above.
        for path in ["/Volumes/team2", "/Volumes/teams/Projects", "/Volumes"] {
            let facts = await reader.facts(for: folder(path))
            XCTAssertNotEqual(facts.kind, .network, path)
        }
        // A trailing slash on the prefix changes nothing.
        reader.set(StorageProbe(isInternal: false, isEjectable: true), under: "/Volumes/Backup/")
        let disk = await reader.facts(for: folder("/Volumes/Backup/Photos"))
        XCTAssertEqual(disk.kind, .external)
        XCTAssertEqual(disk.volumeRoot, "/Volumes/Backup")
    }

    func testTheLongestPrefixWins() async {
        let reader = reader()
        // Set in either order: the deeper prefix answers for what is inside it.
        reader.set(StorageProbe(isReadOnly: true), under: home + "/Documents/Archive")
        reader.set(StorageProbe(isUbiquitous: true), under: home + "/Documents")
        reader.set(StorageProbe(hasTrash: false), under: home)
        let documents = await reader.facts(for: folder(home + "/Documents/Letters"))
        XCTAssertEqual(documents.kind, .iCloud, "Documents kept in iCloud, under an ordinary home")
        XCTAssertFalse(documents.isReadOnly)
        let archive = await reader.facts(for: folder(home + "/Documents/Archive/2019"))
        XCTAssertEqual(archive.kind, .thisMac, "The deeper probe replaces the outer one whole")
        XCTAssertTrue(archive.isReadOnly)
        let downloads = await reader.facts(for: folder(home + "/Downloads"))
        XCTAssertEqual(downloads.kind, .thisMac)
        XCTAssertEqual(downloads.trash, .no)
        // Setting a prefix again replaces its probe.
        reader.set(StorageProbe(timedOut: true), under: home + "/Documents")
        let silent = await reader.facts(for: folder(home + "/Documents/Letters"))
        XCTAssertFalse(silent.isResponding)
        reader.set(StorageProbe(), under: home + "/Documents")
        let plain = await reader.facts(for: folder(home + "/Documents/Letters"))
        XCTAssertEqual(plain, .thisMac)
    }

    func testAMirrorTargetIsThatProvidersCloudFolder() async {
        let reader = reader()
        let none = await reader.mirrors()
        XCTAssertEqual(none, [:])
        reader.setMirror(target: home + "/My Drive", cloudFolder: "GoogleDrive-me@example.com")
        let mirrors = await reader.mirrors()
        XCTAssertEqual(mirrors, [home + "/My Drive": "GoogleDrive-me@example.com"])
        let inside = await reader.facts(for: folder(home + "/My Drive/Reports"))
        XCTAssertEqual(inside.kind, .cloud)
        XCTAssertEqual(inside.name, "Google Drive")
        XCTAssertEqual(inside.cloudRoot, home + "/My Drive")
        let beside = await reader.facts(for: folder(home + "/My Drive 2"))
        XCTAssertEqual(beside, .thisMac)
    }

    func testAskedListsEveryFolderInOrder() async {
        let reader = reader()
        XCTAssertEqual(reader.asked, [])
        _ = await reader.facts(for: folder(home + "/Documents"))
        _ = await reader.facts(for: folder(home + "/Downloads"))
        _ = await reader.facts(for: folder(home + "/Documents"))
        XCTAssertEqual(reader.asked, [home + "/Documents", home + "/Downloads", home + "/Documents"])
        // Asking for the mirrors is not asking about a folder.
        _ = await reader.mirrors()
        XCTAssertEqual(reader.asked.count, 3)
    }

    func testClearForgetsEverythingButTheHome() async {
        let reader = reader()
        reader.set(StorageProbe(isLocal: false), under: home + "/Documents")
        reader.setMirror(target: home + "/My Drive", cloudFolder: "GoogleDrive-me@example.com")
        _ = await reader.facts(for: folder(home + "/Documents"))
        reader.clear()
        XCTAssertEqual(reader.asked, [])
        let mirrors = await reader.mirrors()
        XCTAssertEqual(mirrors, [:])
        let documents = await reader.facts(for: folder(home + "/Documents"))
        XCTAssertEqual(documents, .thisMac)
        let mirrored = await reader.facts(for: folder(home + "/My Drive"))
        XCTAssertEqual(mirrored, .thisMac)
        let drive = await reader.facts(for: folder(home + "/Library/CloudStorage/Dropbox"))
        XCTAssertEqual(drive.kind, .cloud, "The home's path rules still apply")
    }

    func testItIsUsedThroughTheProtocolAndFromAnyThread() async {
        let reader = reader()
        reader.set(StorageProbe(isLocal: false), under: "/Volumes/team")
        let storage: any StorageFactsReading = reader
        let kinds = await withTaskGroup(of: StorageKind.self) { group -> [StorageKind] in
            for index in 0..<200 {
                group.addTask {
                    if index % 3 == 0 { reader.set(StorageProbe(isLocal: false), under: "/Volumes/team") }
                    return await storage.facts(for: URL(fileURLWithPath: "/Volumes/team/\(index)", isDirectory: true)).kind
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(kinds, Array(repeating: .network, count: 200))
        XCTAssertEqual(reader.asked.count, 200)
    }

    /// A reader that only knows facts. What it mirrors is the protocol's own answer.
    private struct FactsOnly: StorageFactsReading {
        func facts(for folder: URL) async -> StorageFacts { .thisMac }
    }

    func testAReaderThatKnowsNoMirrorsAnswersNone() async {
        let reader: any StorageFactsReading = FactsOnly()
        let mirrors = await reader.mirrors()
        XCTAssertEqual(mirrors, [:])
    }
}
