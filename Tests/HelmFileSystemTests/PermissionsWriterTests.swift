#if os(macOS)
import Darwin
import Foundation
import XCTest
import HelmCore
import HelmTestKit
import HelmFileSystem

/// Properties changes an item's permissions only when the person owns it, it's still the item read and has the mode
/// read, and nothing stands in the way. Every refusal leaves the disk as it was. All on temporary files.
final class PermissionsWriterTests: XCTestCase {
    private var temp: TempDirectory!
    private var locked: [URL] = []
    override func setUpWithError() throws { temp = try TempDirectory() }
    override func tearDownWithError() throws {
        for url in locked { _ = chflags(url.path, 0) }
        try temp.remove()
    }

    private func file(_ name: String, mode: mode_t) throws -> URL {
        let url = temp.url.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, mode), 0)
        return url
    }
    private func mode(_ url: URL) -> UInt16 {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return UInt16(info.st_mode & 0o7777)
    }
    private func target(_ url: URL) throws -> PermissionTarget { try PermissionsWriter.target(at: url).get() }

    func testChangesAFileAndAnswersWhatTheDiskKeeps() throws {
        let url = try file("notes.txt", mode: 0o644)
        let before = try target(url)
        XCTAssertEqual(before.mode, 0o644)
        XCTAssertNil(before.refusal)
        XCTAssertEqual(PermissionsWriter.change(url, identity: before.identity, from: 0o644, to: 0o604), .success(0o604))
        XCTAssertEqual(mode(url), 0o604)
        // And back, as Undo does.
        XCTAssertEqual(PermissionsWriter.change(url, identity: before.identity, from: 0o604, to: 0o644), .success(0o644))
        XCTAssertEqual(mode(url), 0o644)
    }

    /// A folder's sticky bit stays, as does every bit a change isn't about.
    func testChangesAFolderKeepingItsStickyBit() throws {
        let url = temp.url.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(url.path, 0o1755), 0)
        let before = try target(url)
        XCTAssertEqual(PermissionsWriter.change(url, identity: before.identity, from: 0o1755, to: 0o1750), .success(0o1750))
        XCTAssertEqual(mode(url), 0o1750)
    }

    /// Changed since it was read, or replaced by another item of the same name: nothing is changed.
    func testRefusesAnItemThatChangedOrWasReplaced() throws {
        let url = try file("notes.txt", mode: 0o644)
        let before = try target(url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        XCTAssertEqual(PermissionsWriter.change(url, identity: before.identity, from: 0o644, to: 0o604), .failure(.changed))
        XCTAssertEqual(mode(url), 0o600)
        try FileManager.default.removeItem(at: url)
        let replacement = try file("notes.txt", mode: 0o644)
        XCTAssertNotEqual(try target(replacement).identity, before.identity)
        XCTAssertEqual(PermissionsWriter.change(replacement, identity: before.identity, from: 0o644, to: 0o604), .failure(.changed))
        XCTAssertEqual(mode(replacement), 0o644)
    }

    func testRefusesALockedItem() throws {
        let url = try file("Locked.txt", mode: 0o644)
        XCTAssertEqual(chflags(url.path, UInt32(UF_IMMUTABLE)), 0)
        locked.append(url)
        let before = try target(url)
        XCTAssertEqual(before.refusal, .locked)
        XCTAssertEqual(PermissionsWriter.change(url, identity: before.identity, from: 0o644, to: 0o600), .failure(.locked))
        XCTAssertEqual(mode(url), 0o644)
    }

    /// A link's own permissions aren't used, so it's refused, and what it points to is left alone.
    func testRefusesALinkAndLeavesItsOriginal() throws {
        let original = try file("notes.txt", mode: 0o644)
        let link = temp.url.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let before = try target(link)
        XCTAssertEqual(before.refusal, .link)
        XCTAssertEqual(PermissionsWriter.change(link, identity: before.identity, from: before.mode, to: 0o600), .failure(.link))
        XCTAssertEqual(mode(original), 0o644)
    }

    func testRefusesAnItemThatIsGone() throws {
        let url = temp.url.appendingPathComponent("gone.txt")
        XCTAssertEqual(PermissionsWriter.target(at: url), .failure(.missing))
        XCTAssertEqual(PermissionsWriter.change(url, identity: FileObjectIdentity(scope: "native:1", object: "1"), from: 0o644, to: 0o600),
                       .failure(.missing))
    }

    /// An item of root's is refused before anything is tried: only the owner may change it, and Helm asks for no
    /// password. Only its details are read.
    func testRefusesAnotherAccountsItem() throws {
        try XCTSkipIf(getuid() == 0, "root owns everything it could be tried on")
        let system = URL(fileURLWithPath: "/usr/bin/true")
        let before = try target(system)
        XCTAssertEqual(before.refusal, .notOwner)
        XCTAssertEqual(PermissionsWriter.change(system, identity: before.identity, from: before.mode, to: before.mode & ~UInt16(0o001)),
                       .failure(.notOwner))
        XCTAssertEqual(mode(system), before.mode)
    }
}
#endif
