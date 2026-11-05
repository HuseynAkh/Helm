// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem

final class ProviderMetadataTests: XCTestCase {
    func testVolumeDetailsPreservesFlagsAndUnknownEjectability() {
        let volume = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/test"), name: "Test",
                                isInternal: true, isRemovable: true, isBrowsable: false, isHidden: true)
        let details = VolumeDetails(volume: volume, isEjectable: true)
        XCTAssertEqual(details.volume, volume)
        XCTAssertEqual(details.isEjectable, true)
        XCTAssertNil(VolumeDetails(volume: volume, isEjectable: nil).isEjectable)
        XCTAssertEqual(VolumeDetails(volume: volume, isEjectable: false).isEjectable, false)
    }

    func testSnapshotStampSeparatesAcceptedIdentityFromRequest() {
        let request = Generation(rawValue: 7)
        let first = SnapshotStamp(id: Generation(rawValue: 10), loadGeneration: request)
        let rebuilt = SnapshotStamp(id: Generation(rawValue: 11), loadGeneration: request)
        XCTAssertNotEqual(first, rebuilt)
        XCTAssertEqual(first.loadGeneration, rebuilt.loadGeneration)
        XCTAssertEqual(first.id, Generation(rawValue: 10))
        XCTAssertEqual(first, SnapshotStamp(id: first.id, loadGeneration: request))
    }

    func testStampBridgeKeepsGenerationAndReducerOwnsAcceptance() {
        let home = URL(fileURLWithPath: "/home")
        let location = Location.directory(home)
        let context = ReducerContext(now: .distantPast, homeDirectory: home)
        let initial = TabState(location: location, homeDirectory: home)
        let loading = TabReducer.reduce(initial, .refresh, context: context).0
        let stamp = SnapshotStamp(id: Generation(rawValue: 900), loadGeneration: loading.loadGeneration)
        let entry = FileEntry(url: home.appendingPathComponent("file"))
        let progress = stamp.loadAction(location: location, sortedEntries: [entry], finished: false)
        let partial = TabReducer.reduce(loading, progress, context: context).0
        XCTAssertEqual(partial.snapshot.phase, .loading(loadedCount: 1))
        XCTAssertTrue(partial.isLoading)
        XCTAssertNotEqual(partial.snapshot.id, stamp.id)
        let completed = TabReducer.reduce(partial, stamp.loadAction(location: location, sortedEntries: [entry]), context: context).0
        XCTAssertFalse(completed.isLoading)
        XCTAssertEqual(completed.snapshot.sortedEntries, [entry])
        XCTAssertNotEqual(partial.snapshot.id, completed.snapshot.id)
        let stale = SnapshotStamp(id: stamp.id, loadGeneration: loading.loadGeneration.next())
        let ignored = TabReducer.reduce(loading, stale.loadAction(location: location, sortedEntries: [entry]), context: context).0
        XCTAssertEqual(ignored, loading)
    }

    #if os(Linux)
    func testLinuxVolumeFallbackAndProjection() async throws {
        let reader = VolumeReader()
        let details = try await reader.details()
        XCTAssertEqual(details.count, 1)
        let root = try XCTUnwrap(details.first)
        XCTAssertEqual(root.volume.url.path, "/")
        XCTAssertEqual(root.volume.name, "/")
        XCTAssertTrue(root.volume.isInternal)
        XCTAssertFalse(root.volume.isRemovable)
        XCTAssertTrue(root.volume.isBrowsable)
        XCTAssertFalse(root.volume.isHidden)
        XCTAssertNil(root.isEjectable)
        let filtered = try await reader.volumes()
        let all = try await reader.volumes(showAll: true)
        XCTAssertEqual(filtered, [root.volume])
        XCTAssertEqual(all, filtered)
    }

    func testLinuxCloudFallbackDoesNotRequireExistingFile() async throws {
        let reader = CloudAvailabilityReader()
        for path in ["/", "/missing-k9-cloud-placeholder/file"] {
            let value = try await reader.availability(at: URL(fileURLWithPath: path))
            XCTAssertEqual(value, .unknown)
        }
    }
    #endif
}
