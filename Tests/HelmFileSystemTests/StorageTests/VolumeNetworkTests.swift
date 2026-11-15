import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem

/// A share on a server is told from a disk by the volume's "is local" key, so the sidebar draws it as a server
/// and offers to eject it.
final class VolumeNetworkTests: XCTestCase {
    private func details(isLocal: Bool?, isInternal: Bool? = nil, isRemovable: Bool? = nil, name: String = "team") -> VolumeDetails {
        VolumeReader.details(url: URL(fileURLWithPath: "/Volumes/" + name), name: name, uuid: nil, isInternal: isInternal,
                             isRemovable: isRemovable, isBrowsable: true, isHidden: false, isEjectable: true, isLocal: isLocal)
    }

    func testAVolumeThatIsNotLocalIsANetworkShare() {
        XCTAssertTrue(details(isLocal: false).volume.isNetwork)
        XCTAssertFalse(details(isLocal: true).volume.isNetwork)
        XCTAssertFalse(details(isLocal: nil).volume.isNetwork, "a volume that doesn't say stays a disk, as before")
        // Everything else is read as before.
        let share = details(isLocal: false)
        XCTAssertEqual(share.volume.name, "team")
        XCTAssertEqual(share.volume.url.path, "/Volumes/team")
        XCTAssertEqual(share.isEjectable, true)
        XCTAssertFalse(share.volume.isInternal)
        XCTAssertEqual(VolumeReader.details(url: URL(fileURLWithPath: "/Volumes/x"), name: nil, uuid: nil, isInternal: nil,
                                            isRemovable: nil, isBrowsable: nil, isHidden: nil, isEjectable: nil, isLocal: nil).volume,
                       VolumeInfo(url: URL(fileURLWithPath: "/Volumes/x"), name: "x"))
    }

    func testAShareHasTheNetworkSymbolWhateverElseItSays() {
        let server = details(isLocal: false).volume
        let removableServer = details(isLocal: false, isRemovable: true).volume
        let disk = details(isLocal: true, isRemovable: true, name: "Backup").volume
        let inside = details(isLocal: true, isInternal: true).volume
        XCTAssertEqual(PlacesModel.symbol(for: server), "network")
        XCTAssertEqual(PlacesModel.symbol(for: removableServer), "network")
        XCTAssertEqual(PlacesModel.symbol(for: disk), "externaldrive")
        XCTAssertEqual(PlacesModel.symbol(for: inside), "internaldrive")
        XCTAssertEqual(PlacesModel.symbol(for: VolumeInfo(url: URL(fileURLWithPath: "/x"), name: "Google Drive", isCloud: true)), "cloud")
        // The sidebar's Locations draw it so.
        let places = PlacesModel(home: URL(fileURLWithPath: "/home/helm"), volumes: [server, disk])
        XCTAssertEqual(places.devices.map(\.iconName).sorted(), ["externaldrive", "network"])
    }

    func testTheReaderPassesTheShareThrough() async throws {
        let reader = VolumeReader(mountedURLs: { [URL(fileURLWithPath: "/Volumes/team"), URL(fileURLWithPath: "/Volumes/Backup")] },
                                  readVolume: { url in
            VolumeReader.details(url: url, name: url.lastPathComponent, uuid: url.lastPathComponent, isInternal: false,
                                 isRemovable: false, isBrowsable: true, isHidden: false, isEjectable: true,
                                 isLocal: url.lastPathComponent != "team")
        })
        let volumes = try await reader.volumes()
        XCTAssertEqual(volumes.map(\.name), ["Backup", "team"])
        XCTAssertEqual(volumes.map(\.isNetwork), [false, true])
    }
}
