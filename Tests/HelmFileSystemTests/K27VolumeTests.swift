// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem

final class K27VolumeTests: XCTestCase {
    private func disk(_ name: String = "Disk", uuid: String? = "id", internalDisk: Bool = false, ejectable: Bool? = true) -> VolumeDetails {
        VolumeDetails(volume: VolumeInfo(url: URL(fileURLWithPath: "/Volumes/" + name), name: name,
            uuid: uuid, isInternal: internalDisk), isEjectable: ejectable)
    }
    func testRegistryDedupesAndDiffs() {
        let first = disk()
        var registry = VolumeRegistry(volumes: [first, first])
        XCTAssertEqual(registry.volumes, [first])
        XCTAssertEqual(registry.apply(.mounted(first)).inserted, [])
        let renamed = disk("Renamed")
        let change = registry.apply(.renamed(previousURL: first.volume.url, volume: renamed))
        XCTAssertEqual(change.updated, [renamed]); XCTAssertTrue(change.inserted.isEmpty)
        registry.apply(.unmounted(first.volume.url))
        XCTAssertEqual(registry.volumes, [renamed])
        XCTAssertEqual(registry.apply(.unmounted(renamed.volume.url)).removed, [renamed])
        registry.apply(.renamed(previousURL: renamed.volume.url, volume: first))
        XCTAssertTrue(registry.volumes.isEmpty)
    }
    func testFilteringOrderingAndEjectFailure() {
        let root = disk("System", uuid: "root", internalDisk: true)
        let vm = disk("VM Images", uuid: "vm-images")
        let hidden = disk("Preboot", uuid: "hidden")
        var registry = VolumeRegistry(volumes: [hidden, vm, root])
        XCTAssertEqual(registry.volumes, [root, vm])
        XCTAssertEqual(registry.apply(.ejectFailed(vm.volume.url, reasons: ["copy active"])).ejectFailure, ["copy active"])
        XCTAssertEqual(registry.volumes, [root, vm])
        XCTAssertEqual(VolumeRegistry(volumes: [hidden, hidden, vm], showAll: true).volumes.count, 2)
        let replacement = disk("VM Images", uuid: "replacement")
        registry.apply(.mounted(replacement))
        XCTAssertEqual(registry.volumes, [root, replacement])
    }
    func testScriptedEventsReplay() async {
        let script: [VolumeEvent] = [.mounted(disk()), .unmounted(disk().volume.url)]
        let source = ScriptedVolumeEventSource(script: script)
        for _ in 0..<2 {
            var received: [VolumeEvent] = []
            for await event in source.events() { received.append(event) }
            XCTAssertEqual(received, script)
        }
    }
    func testRemovalOutcomes() {
        XCTAssertEqual(VolumeRemovalPlanner.plan(volume: nil), .alreadyGone)
        XCTAssertEqual(VolumeRemovalPlanner.plan(volume: disk(internalDisk: true)), .internalVolumeRefusal)
        XCTAssertEqual(VolumeRemovalPlanner.plan(volume: disk(), busyReasons: ["open file"]), .busy(reasons: ["open file"]))
        XCTAssertEqual(VolumeRemovalPlanner.plan(volume: disk()), .ejectable(disk().volume.url))
        XCTAssertEqual(VolumeRemovalPlanner.plan(volume: disk(ejectable: nil)), .unsupported)
        XCTAssertEqual(VolumeRemovalPlanner.plan(volume: disk(ejectable: false)), .unsupported)
        XCTAssertEqual(VolumeRemovalPlanner.plan(volume: disk(ejectable: nil), unmountOnly: true), .unmountable(disk().volume.url))
        let root = VolumeDetails(volume: VolumeInfo(url: URL(fileURLWithPath: "/"), name: "root"), isEjectable: true)
        XCTAssertEqual(VolumeRemovalPlanner.plan(volume: root, unmountOnly: true), .internalVolumeRefusal)
    }
    func testServerNormalizationAndSchemes() throws {
        XCTAssertEqual(try ServerAddress(" SMB://EXAMPLE.COM:445/ "), try ServerAddress("smb://example.com"))
        XCTAssertEqual(try ServerAddress("webdavs://Example.com:443/path"), try ServerAddress("https://example.com/path"))
        XCTAssertEqual(try ServerAddress("webdav://Example.com:80/"), try ServerAddress("http://example.com"))
        for scheme in ["afp", "nfs", "ftp", "https", "vnc"] {
            XCTAssertEqual(try ServerAddress(scheme + "://host/share").url.scheme, scheme)
        }
        XCTAssertEqual(try ServerAddress("smb://[::1]/share").url.path, "/share")
        XCTAssertEqual(try ServerAddress("smb://host/My%20Share").url.path, "/My Share")
    }
    func testServerRejectsCredentialsAndMalformedInput() {
        for input in ["", "host", "file:///tmp/a", "smb:///share", "smb://host:0", "smb://host:65536",
                      "smb://host/#fragment", "https://host/?secret=1", "smb://ho st/share", "smb://host/a\nb", "smb://host/a%00b", "smb://host\\path"] {
            XCTAssertThrowsError(try ServerAddress(input), input)
        }
        for input in ["smb://user:secret@host", "ftp://user@host"] {
            XCTAssertThrowsError(try ServerAddress(input)) { XCTAssertEqual($0 as? ServerAddressError, .credentialsNotAllowed) }
        }
    }
    func testHistoryDedupeCapacityAndOrdering() throws {
        let a = try ServerAddress("smb://a"), b = try ServerAddress("smb://b"), c = try ServerAddress("smb://c")
        var history = ServerHistory(favorites: [a, a], recents: [a, a, b, c], capacity: 2)
        XCTAssertEqual(history.favorites, [a]); XCTAssertEqual(history.recents, [a, b])
        history.addFavorite(b); history.addFavorite(b); history.removeFavorite(a)
        XCTAssertEqual(history.favorites, [b])
        history.recordConnection(b); XCTAssertEqual(history.recents, [b, a])
        history.recordConnection(c); XCTAssertEqual(history.recents, [c, b])
        var zero = ServerHistory(capacity: -1); zero.recordConnection(a); zero.addFavorite(a)
        XCTAssertTrue(zero.recents.isEmpty); XCTAssertTrue(zero.favorites.isEmpty)
        let capped = ServerHistory(favorites: [a, b, c], capacity: 2)
        XCTAssertEqual(capped.favorites, [a, b])
    }
    func testPutBackOriginsAndParentStates() {
        let item = URL(fileURLWithPath: "/trash/a.txt"), destination = URL(fileURLWithPath: "/original/a.txt")
        let origin = PutBackOrigin(trashedURL: item, originalURL: destination)
        XCTAssertEqual(PutBackPlanner.plan(item: item, origins: [], parent: .exists), .unknownOrigin)
        XCTAssertEqual(PutBackPlanner.plan(item: item, origins: [origin], parent: .exists), .restore(source: item, destination: destination))
        let renamed = URL(fileURLWithPath: "/original/a 2.txt")
        XCTAssertEqual(PutBackPlanner.plan(item: item, origins: [origin], parent: .exists, occupiedNames: ["A.txt"]), .restore(source: item, destination: renamed))
        XCTAssertEqual(PutBackPlanner.plan(item: item, origins: [origin], parent: .missing), .missingParent(source: item, originalDestination: destination, suggestedDestination: destination))
        for state in [PutBackParentState.denied, .volumeUnavailable] {
            XCTAssertEqual(PutBackPlanner.plan(item: item, origins: [origin], parent: state), .unavailable(state))
        }
        let other = PutBackOrigin(trashedURL: item, originalURL: URL(fileURLWithPath: "/other/a.txt"))
        XCTAssertEqual(PutBackPlanner.plan(item: item, origins: [origin, other], parent: .exists), .ambiguousOrigin)
        XCTAssertEqual(PutBackPlanner.plan(item: item, origins: [PutBackOrigin(trashedURL: item, originalURL: item)], parent: .exists), .invalidPath)
        XCTAssertEqual(PutBackPlanner.plan(item: URL(fileURLWithPath: "/"), origins: [], parent: .exists), .invalidPath)
    }
    func testPutBackRejectsRemoteAndDescendantOrigins() throws {
        let item = URL(fileURLWithPath: "/trash/item", isDirectory: true)
        for original in [URL(fileURLWithPath: "/trash/item/child"), try XCTUnwrap(URL(string: "file://remote/path")), URL(fileURLWithPath: "/")] {
            XCTAssertEqual(PutBackPlanner.plan(item: item, origins: [PutBackOrigin(trashedURL: item, originalURL: original)], parent: .exists), .invalidPath)
        }
        let origin = PutBackOrigin(trashedURL: URL(fileURLWithPath: "/trash/item"), originalURL: URL(fileURLWithPath: "/original/item"))
        XCTAssertEqual(PutBackPlanner.plan(item: item, origins: [origin], parent: .exists), .restore(source: item.standardizedFileURL, destination: origin.originalURL))
    }
    func testUnmountDirectoryURLAndUUIDLessRename() {
        let old = disk("Old", uuid: nil), new = disk("New", uuid: nil)
        var registry = VolumeRegistry(volumes: [old])
        let change = registry.apply(.renamed(previousURL: URL(fileURLWithPath: "/Volumes/Old", isDirectory: true), volume: new))
        XCTAssertEqual(change.removed, [old]); XCTAssertEqual(change.inserted, [new])
        registry.apply(.unmounted(URL(fileURLWithPath: "/Volumes/New", isDirectory: true)))
        XCTAssertTrue(registry.volumes.isEmpty)
    }
    func testTrashLocations() {
        XCTAssertEqual(TrashLocation.home(URL(fileURLWithPath: "/users/test")).root.path, "/users/test/.Trash")
        let location = TrashLocation.volume(URL(fileURLWithPath: "/Volumes/USB"), userID: 501, availability: .denied)
        XCTAssertEqual(location.root.path, "/Volumes/USB/.Trashes/501"); XCTAssertEqual(location.availability, .denied)
        XCTAssertEqual(TrashLocation.cloud(URL(fileURLWithPath: "/cloud")).root.path, "/cloud/.Trash")
    }
}
