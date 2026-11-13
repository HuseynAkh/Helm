import Foundation
import XCTest
import HelmCore
import HelmTestKit
@testable import HelmFileSystem
#if canImport(Darwin)
import Darwin
#endif

/// The facts reader that asks macOS, on a temporary home folder. A test Mac has no cloud provider and no server, so
/// what only those could answer is stood in for, and every read is watched to show it ran with downloads off.
final class SystemStorageFactsReaderTests: XCTestCase {
    private var temp: TempDirectory!
    /// The home folder as the disk spells it, so the paths the reader answers with can be compared.
    private var home: String!
    private let watched = StorageWatchedReads()

    override func setUpWithError() throws {
        temp = try TempDirectory()
        home = CanonicalPath.realPath(temp.url.path)! + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try temp.remove() }

    private func folder(_ relative: String) throws -> String {
        let path = home + "/" + relative
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
    private func link(_ relative: String, to target: String) throws {
        let path = home + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }

    /// The system's reads, each noting whether its thread had downloads off; the Trash is stood in for, so nothing
    /// asks about a real one, and so is iCloud's shared answer.
    private func reader(shared: @escaping @Sendable (String) -> Bool? = { _ in nil },
                        volume: (@Sendable (URL) throws -> StorageProbe)? = nil, homeURL: URL? = nil) -> SystemStorageFactsReader {
        let system = SystemStorageFactsReader.Reads.system, seen = watched
        let reads = SystemStorageFactsReader.Reads(
            canonical: { seen.note("canonical"); return system.canonical($0) },
            volume: { seen.note("volume"); return try (volume ?? system.volume)($0) },
            hasTrash: { _ in seen.note("trash"); return true },
            attributeNames: { seen.note("attributes"); return system.attributeNames($0) },
            isShared: { seen.note("shared"); return shared($0.path) },
            names: { seen.note("names"); return system.names($0) },
            linkTarget: { seen.note("link"); return system.linkTarget($0) })
        return SystemStorageFactsReader(home: homeURL ?? URL(fileURLWithPath: home), reads: reads)
    }

    func testALinkTwoLevelsInsideACloudStorageFolderMakesItsTargetAMirror() async throws {
        let provider = "Library/CloudStorage/GoogleDrive-me@example.com"
        let mirrored = try folder("Mirrored"), deep = try folder("Deep"), third = try folder("Third")
        _ = try folder("Mirrored/Budget")
        try link(provider + "/My Drive", to: mirrored)
        try link(provider + "/Shortcuts/Team", to: "../../../../Deep")
        try link(provider + "/Shortcuts/More/Too Deep", to: third)
        try link(provider + "/Home", to: home)
        try link(provider + "/Inside", to: home + "/" + provider + "/Shortcuts")
        // A home reached through a link still finds them.
        let reader = reader(homeURL: temp.url.appendingPathComponent("home"))
        let mirrors = await reader.mirrors()
        XCTAssertEqual(mirrors, [mirrored: "GoogleDrive-me@example.com", deep: "GoogleDrive-me@example.com"],
                       "one and two levels in only; never the home or the providers' own folders")

        let budget = await reader.facts(for: URL(fileURLWithPath: mirrored + "/Budget"))
        XCTAssertEqual(budget.kind, .cloud)
        XCTAssertEqual(budget.name, "Google Drive")
        XCTAssertEqual(budget.cloudRoot, mirrored)
        // However it was reached: through the provider's shortcut, or by a path that isn't the disk's own spelling.
        let throughShortcut = await reader.facts(for: URL(fileURLWithPath: home + "/" + provider + "/My Drive/Budget"))
        XCTAssertEqual(throughShortcut, budget)
        let respelled = await reader.facts(for: temp.url.appendingPathComponent("home/Mirrored/Budget"))
        XCTAssertEqual(respelled, budget)
        let deeper = await reader.facts(for: URL(fileURLWithPath: deep))
        XCTAssertEqual(deeper.placeKey, deep)
        let notAMirror = await reader.facts(for: URL(fileURLWithPath: third))
        XCTAssertEqual(notAMirror.kind, .thisMac)

        // Read again when the list of providers' folders changes, and not before.
        let boxed = try folder("Boxed")
        try link("Library/CloudStorage/Dropbox/Shortcut", to: boxed)
        let again = await reader.mirrors()
        XCTAssertEqual(again[boxed], "Dropbox")
        XCTAssertEqual(again.count, 3)
        _ = watched.take()
        _ = await reader.mirrors()
        XCTAssertFalse(watched.take().contains { $0.read == "link" }, "an unchanged list isn't read again")
    }

    func testASharedAnswerOnAParentFolderMakesTheChildShared() async throws {
        let drive = "Library/Mobile Documents/com~apple~CloudDocs"
        let team = try folder(drive + "/Team"), notes = try folder(drive + "/Team/Notes/2026"), solo = try folder(drive + "/Solo")
        let mobile = home + "/Library/Mobile Documents"
        let reader = reader(shared: { path in path == team ? true : (path == self.home + "/Library" ? true : false) })
        let child = await reader.facts(for: URL(fileURLWithPath: notes))
        XCTAssertEqual(child.kind, .iCloud)
        XCTAssertEqual(child.shared, .yes, "a folder inside a shared folder is seen by the same people")
        XCTAssertTrue(child.sharingIsKnown)
        let parent = await reader.facts(for: URL(fileURLWithPath: team))
        XCTAssertEqual(parent.shared, .yes)
        let other = await reader.facts(for: URL(fileURLWithPath: solo))
        XCTAssertEqual(other.shared, .no, "a shared answer above the place's root doesn't count")
        XCTAssertEqual(other.cloudRoot, mobile)
        // Asked folder by folder from the child up to iCloud Drive's root, and no further.
        let asked = watched.take().filter { $0.read == "shared" }
        XCTAssertFalse(asked.isEmpty)
    }

    func testEveryReadIsObservedInsideDownloadsOff() async throws {
        let provider = "Library/CloudStorage/OneDrive-Personal"
        let target = try folder("Synced")
        try link(provider + "/Synced", to: target)
        let notes = try folder("Library/Mobile Documents/com~apple~CloudDocs/Notes")
        let reader = reader(shared: { _ in false })
        _ = await reader.facts(for: URL(fileURLWithPath: notes))
        _ = await reader.facts(for: URL(fileURLWithPath: target + "/"))
        _ = await reader.mirrors()
        let seen = watched.take()
        XCTAssertEqual(Set(seen.map(\.read)), ["canonical", "volume", "trash", "attributes", "shared", "names", "link"])
        XCTAssertTrue(seen.allSatisfy(\.isOff), "\(seen.filter { !$0.isOff })")
        // The reader's own answer for an ordinary folder of this Mac.
        let plain = await reader.facts(for: URL(fileURLWithPath: try folder("Plain")))
        XCTAssertEqual(plain.kind, .thisMac)
        XCTAssertTrue(plain.isResponding)
    }

    func testASyncAppsAttributeIsReadByName() async throws {
        let marked = try folder("Team Sync"), plain = try folder("Plain")
        #if canImport(Darwin)
        XCTAssertEqual(setxattr(marked, "com.dropbox.attrs", "x", 1, 0, XATTR_NOFOLLOW), 0)
        XCTAssertEqual(setxattr(plain, "org.example.note", "x", 1, 0, XATTR_NOFOLLOW), 0)
        #endif
        let reader = reader()
        let found = await reader.facts(for: URL(fileURLWithPath: marked))
        XCTAssertEqual(found.kind, .cloud)
        XCTAssertEqual(found.name, "Cloud folder")
        let ordinary = await reader.facts(for: URL(fileURLWithPath: plain))
        XCTAssertEqual(ordinary.kind, .thisMac)
    }

    func testAFolderThatDoesNotAnswerInTwoSecondsIsNotResponding() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let stuck = try folder("Stuck")
        let reader = reader(volume: { url in
            if url.path.hasSuffix("/Stuck") { _ = gate.wait(timeout: .now() + 6) }
            return StorageProbe(isLocal: true, isInternal: true)
        })
        let start = Date()
        let facts = await reader.facts(for: URL(fileURLWithPath: stuck))
        let waited = Date().timeIntervalSince(start)
        XCTAssertEqual(facts.kind, .network)
        XCTAssertFalse(facts.isResponding)
        XCTAssertGreaterThanOrEqual(waited, 1.9)
        XCTAssertLessThan(waited, 5)
    }
}

/// Which reads ran, and whether the thread each ran on had downloads off.
private final class StorageWatchedReads: @unchecked Sendable {
    struct Read: Sendable { let read: String, isOff: Bool }
    private let lock = NSLock()
    private var reads: [Read] = []
    func note(_ read: String) {
        let off = DatalessGuard.threadPolicyIsOffForTesting
        lock.lock(); reads.append(Read(read: read, isOff: off)); lock.unlock()
    }
    func take() -> [Read] { lock.lock(); defer { reads.removeAll(); lock.unlock() }; return reads }
}
