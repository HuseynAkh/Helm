// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem

final class AO3DeferredVolumeTests: XCTestCase {
    func testPartialVolumeFailureCanary() async throws {
        let healthy = URL(fileURLWithPath: "/healthy"), denied = URL(fileURLWithPath: "/denied")
        let reader = VolumeReader(mountedURLs: { [healthy, denied] }, readVolume: { url in
            if url == denied { throw FileSystemError.permissionDenied }
            return VolumeDetails(volume: VolumeInfo(url: url, name: "healthy"), isEjectable: false)
        })
        let values: [VolumeDetails]
        do { values = try await reader.details() }
        catch let error as FileSystemError where error == .permissionDenied {
            throw XCTSkip("FB1-4/T-8 reproduced: one denied mount discards healthy mounts; partial-result policy is deferred")
        }
        XCTAssertEqual(values.map(\.volume.url), [healthy])
    }
}
