// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
final class T1ArchiveVolumeAdversarialTests: XCTestCase {
    private func member(_ path: String, size: UInt64 = 1, packed: UInt64 = 1, kind: ArchiveMember.Kind = .file) -> ArchiveMember {
        ArchiveMember(path: path, kind: kind, expandedBytes: size, compressedBytes: packed)
    }
    private func disk(_ name: String, uuid: String? = nil) -> VolumeDetails {
        VolumeDetails(volume: VolumeInfo(url: URL(fileURLWithPath: "/Volumes/" + name), name: name, uuid: uuid), isEjectable: true)
    }

    func testArchiveEmptyZeroBudgets()  {
        XCTAssertNoThrow(try ArchiveSafety.validate([], limits: ArchiveSafetyLimits(maximumMembers: 0, maximumExpandedBytes: 0)))
        XCTAssertThrowsError(try ArchiveSafety.validate([member("a")], limits: ArchiveSafetyLimits(maximumMembers: 0)))
    }
    func testArchiveExactSizeBoundary()  {
        XCTAssertNoThrow(try ArchiveSafety.validate([member("a", size: 10), member("b", size: 20)], limits: ArchiveSafetyLimits(maximumExpandedBytes: 30)))
        XCTAssertThrowsError(try ArchiveSafety.validate([member("a", size: 10), member("b", size: 20)], limits: ArchiveSafetyLimits(maximumExpandedBytes: 29)))
    }
    func testArchiveExactRatioBoundary()  {
        XCTAssertNoThrow(try ArchiveSafety.validate([member("a", size: 30, packed: 3)], limits: ArchiveSafetyLimits(maximumRatio: 10)))
        XCTAssertThrowsError(try ArchiveSafety.validate([member("a", size: 31, packed: 3)], limits: ArchiveSafetyLimits(maximumRatio: 10)))
    }
    func testArchiveUInt64Overflow()  {
        XCTAssertThrowsError(try ArchiveSafety.validate([member("a", size: UInt64.max, packed: UInt64.max), member("b")], limits: ArchiveSafetyLimits(maximumExpandedBytes: UInt64.max)))
    }
    func testArchiveUnicodeCanonicalCollision()  {
        XCTAssertThrowsError(try ArchiveSafety.validate([member("café/file"), member("cafe\u{301}/file")], caseSensitive: true))
        XCTAssertNoThrow(try ArchiveSafety.validate([member("日本語/🧭.txt")]))
    }
    func testArchiveTraversalAllPositions()  {
        for path in ["../a", "a/../b", "a/b/..", "a//../b", "a/./../b", "/a", "C:/a", "a\\b", "a\0b"] {
            XCTAssertThrowsError(try ArchiveSafety.validate([member(path)]), path)
        }
    }
    func testArchivePercentEscapesAreLiteral()  {
        XCTAssertNoThrow(try ArchiveSafety.validate([member("%2e%2e/%2f.txt"), member("..hidden/file")]))
    }
    func testArchiveRootDirectoryMarkers()  {
        XCTAssertNoThrow(try ArchiveSafety.validate([member(".", size: 0, packed: 0, kind: .directory), member("./", size: 0, packed: 0, kind: .directory), member("a")]))
        XCTAssertThrowsError(try ArchiveSafety.validate([member(".", kind: .directory)]))
    }
    func testArchiveNormalizedDuplicates()  {
        for path in ["./a/b", "a//b", "a/./b", "a/b/"] {
            XCTAssertThrowsError(try ArchiveSafety.validate([member("a/b"), member(path)]))
        }
    }
    func testArchiveAncestorConflictPermutation()  {
        let values = [member("a/b/c"), member("a")]
        XCTAssertThrowsError(try ArchiveSafety.validate(values))
        XCTAssertThrowsError(try ArchiveSafety.validate(Array(values.reversed())))
        XCTAssertNoThrow(try ArchiveSafety.validate([member("a/b/c"), member("a", size: 0, packed: 0, kind: .directory)]))
    }
    func testArchiveHundredThousandMembers()  {
        let values = (0..<100_000).map { member("file-\($0)") }
        XCTAssertNoThrow(try ArchiveSafety.validate(values))
        XCTAssertThrowsError(try ArchiveSafety.validate(values, limits: ArchiveSafetyLimits(maximumMembers: 99_999)))
    }
    func testArchiveSeededPermutationValidity()  {
        var values = (0..<400).map { member("dir/file-\($0)", size: UInt64($0), packed: UInt64(max(1, $0))) }
        var seed: UInt64 = 43
        for i in stride(from: values.count - 1, through: 1, by: -1) {
            seed = seed &* 6364136223846793005 &+ 1
            values.swapAt(i, Int(seed % UInt64(i + 1)))
        }
        XCTAssertNoThrow(try ArchiveSafety.validate(values)); XCTAssertNoThrow(try ArchiveSafety.validate(Array(values.reversed())))
    }
    func testArchiveCompressionDeduplicatesUnicode() throws {
        let file = URL(fileURLWithPath: "/files/日本語 🧭.txt")
        let plan = try ArchivePlanner.compress(items: [file, file], stagingDirectory: URL(fileURLWithPath: "/stage/token"))
        XCTAssertEqual(plan.expectedOutputName, "日本語 🧭.txt.zip")
        XCTAssertEqual(plan.command.arguments.filter { $0 == "./日本語 🧭.txt" }.count, 1)
    }
    func testArchiveCancellationPrecedesExitError()  {
        XCTAssertThrowsError(try ArchiveProcessResult(exitCode: 9, wasCancelled: true).validate()) {
            XCTAssertEqual($0 as? ArchivePlanningError, .cancelled)
        }
    }
    func testArchiveCancelledRunnerRetainsScript() async throws {
        let runner = ScriptedProcessRunner(results: [ArchiveProcessResult(exitCode: 7)])
        let plan = try ArchivePlanner.compress(items: [URL(fileURLWithPath: "/files/a")], stagingDirectory: URL(fileURLWithPath: "/stage/token"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await runner.run(plan.command); XCTFail("cancelled runner executed") }
            catch { XCTAssertEqual(error as? ArchivePlanningError, .cancelled) }
        }
        await task.value
        let commands = await runner.commands; XCTAssertTrue(commands.isEmpty)
        let result = try await runner.run(plan.command); XCTAssertEqual(result.exitCode, 7)
    }
    func testServerCanonicalRoundTrip() throws {
        for input in ["SMB://EXAMPLE.COM:445/", "webdavs://EXAMPLE.COM:443/share", "nfs://host:2049/日本語", "smb://[::1]/a%20b"] {
            let address = try ServerAddress(input)
            XCTAssertEqual(try ServerAddress(address.url.absoluteString), address)
        }
    }
    func testServerRejectsEncodedControls()  {
        for input in ["smb://host/a%00b", "smb://host/%0A", "https://host/%0D", "ftp://user%40name@host"] {
            XCTAssertThrowsError(try ServerAddress(input), input)
        }
    }
    func testServerPortBoundaries()  {
        XCTAssertNoThrow(try ServerAddress("smb://host:1/share"))
        XCTAssertNoThrow(try ServerAddress("smb://host:65535/share"))
        XCTAssertThrowsError(try ServerAddress("smb://host:0/share"))
        XCTAssertThrowsError(try ServerAddress("smb://host:65536/share"))
    }
    func testServerHistoryCapacityAndIdempotence() throws {
        let a = try ServerAddress("smb://a"), b = try ServerAddress("smb://b")
        var history = ServerHistory(capacity: 1)
        history.recordConnection(a); history.recordConnection(a); XCTAssertEqual(history.recents, [a])
        history.recordConnection(b); XCTAssertEqual(history.recents, [b])
        history.addFavorite(a); history.addFavorite(b); XCTAssertEqual(history.favorites, [a])
        history.removeFavorite(a); history.removeFavorite(a); XCTAssertTrue(history.favorites.isEmpty)
    }
    func testVolumeDuplicateMountIdempotence()  {
        let value = disk("USB", uuid: "u"); var registry = VolumeRegistry()
        XCTAssertEqual(registry.apply(.mounted(value)).inserted, [value])
        let again = registry.apply(.mounted(value))
        XCTAssertTrue(again.inserted.isEmpty); XCTAssertTrue(again.updated.isEmpty); XCTAssertEqual(registry.volumes, [value])
    }
    func testVolumeStaleUnmountAfterRename()  {
        let old = disk("old", uuid: "u"), new = disk("new", uuid: "u")
        var registry = VolumeRegistry(volumes: [old])
        XCTAssertEqual(registry.apply(.renamed(previousURL: old.volume.url, volume: new)).updated, [new])
        registry.apply(.unmounted(old.volume.url)); XCTAssertEqual(registry.volumes, [new])
        registry.apply(.unmounted(new.volume.url)); registry.apply(.renamed(previousURL: new.volume.url, volume: old))
        XCTAssertTrue(registry.volumes.isEmpty)
    }
    func testVolumeOrderingIndependentOfDelivery()  {
        let values = [disk("Zulu", uuid: "z"), disk("Alpha", uuid: "a"), disk("日本語", uuid: "j")]
        XCTAssertEqual(VolumeRegistry(volumes: values).volumes, VolumeRegistry(volumes: Array(values.reversed())).volumes)
    }
    func testVolumeBusyDoesNotAuthorizeRemoval()  {
        let value = disk("USB")
        XCTAssertEqual(VolumeRemovalPlanner.plan(volume: value, unmountOnly: true, busyReasons: ["copy", "preview"]), .busy(reasons: ["copy", "preview"]))
        var registry = VolumeRegistry(volumes: [value]); registry.apply(.ejectFailed(value.volume.url, reasons: ["busy"]))
        XCTAssertEqual(registry.volumes, [value])
    }
    func testDiskImageMalformedResponse()  {
        for data in [Data(), Data("not plist".utf8)] {
            XCTAssertEqual(DiskImagePlanner.result(ArchiveProcessResult(exitCode: 0), propertyList: data), .invalidResponse)
        }
    }
    func testPutBackMixedAuthorityOriginsFailClosedRegardlessOfOrder() throws {
        let item = URL(fileURLWithPath: "/trash/a")
        let local = PutBackOrigin(trashedURL: item, originalURL: URL(fileURLWithPath: "/original/a"))
        let remote = PutBackOrigin(trashedURL: item, originalURL: try XCTUnwrap(URL(string: "file://remote/original/a")))
        for records in [[local, remote], [remote, local]] {
            XCTAssertEqual(PutBackPlanner.plan(item: item, origins: records, parent: .exists), .invalidPath)
        }
    }
}
