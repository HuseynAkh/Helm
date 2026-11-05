// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem

final class AO3DeferredVolumeTests: XCTestCase {
    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URL] = []
        func add(_ url: URL) { lock.lock(); values.append(url); lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return values }
    }
    func testPartialVolumeFailureKeepsHealthyMountsAndReportsTheOther() async throws {
        let first = URL(fileURLWithPath: "/first"), denied = URL(fileURLWithPath: "/denied"), last = URL(fileURLWithPath: "/last")
        let reported = Reported()
        let reader = VolumeReader(mountedURLs: { [first, denied, last] }, readVolume: { url in
            if url == denied { throw FileSystemError.permissionDenied }
            return VolumeDetails(volume: VolumeInfo(url: url, name: url.lastPathComponent), isEjectable: false)
        }, diagnostic: { url, error in
            XCTAssertEqual(error, .permissionDenied)
            reported.add(url)
        })
        let values = try await reader.details()
        XCTAssertEqual(values.map(\.volume.url), [first, last], "Healthy mounts survive, in mount-table order")
        XCTAssertEqual(reported.urls, [denied])
    }
    func testEveryVolumeFailingThrowsRatherThanReportingNoDevices() async {
        let reader = VolumeReader(mountedURLs: { [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")] },
                                  readVolume: { _ in throw FileSystemError.permissionDenied })
        do {
            _ = try await reader.details()
            XCTFail("A total outage must not read as an empty device list")
        } catch { XCTAssertEqual(error as? FileSystemError, .permissionDenied) }
    }
    func testNoMountedVolumesIsAnEmptySuccess() async throws {
        let reader = VolumeReader(mountedURLs: { [] }, readVolume: { _ in throw FileSystemError.permissionDenied })
        let values = try await reader.details()
        XCTAssertTrue(values.isEmpty)
    }
    func testMountTableFailurePropagates() async {
        let reader = VolumeReader(mountedURLs: { throw FileSystemError.permissionDenied },
                                  readVolume: { _ in throw FileSystemError.unsupported })
        do {
            _ = try await reader.details()
            XCTFail("Expected the mount-table failure")
        } catch { XCTAssertEqual(error as? FileSystemError, .permissionDenied) }
    }
}
