import XCTest
@testable import HelmCore

/// What kind of place a folder is in, from its path and the raw facts a reader found. The basics: each rule once,
/// the order they apply in, and what the facts say about a place.
final class StorageClassifierBasicsTests: XCTestCase {
    private let home = "/private/tmp/x/.build/host-smoke/fixture/home"
    private var drive: String { home + "/Library/CloudStorage/GoogleDrive-me@example.com" }
    private func classify(_ path: String, _ probe: StorageProbe = StorageProbe(), mirrors: [String: String] = [:]) -> StorageFacts {
        StorageClassifier.classify(path: path, home: home, probe: probe, mirrors: mirrors)
    }

    // MARK: The rules, in order

    func testAnOrdinaryFolderIsThisMac() {
        XCTAssertEqual(classify(home + "/Documents"), .thisMac)
        XCTAssertEqual(classify(home), .thisMac)
        XCTAssertEqual(classify("/Applications"), .thisMac)
        let facts = classify(home + "/Documents", StorageProbe(isLocal: true, isInternal: true, isRemovable: false, isEjectable: false,
                                                               isReadOnly: false, isUbiquitous: false, hasTrash: true))
        XCTAssertEqual(facts, .thisMac)
        XCTAssertEqual(StorageFacts.thisMac, StorageFacts(kind: .thisMac, name: "This Mac", syncs: false, shared: .no, trash: .yes,
                                                          isReadOnly: false, isResponding: true, cloudRoot: nil, volumeRoot: nil))
    }

    func testAProbeThatTimedOutIsAServerThatIsNotResponding() {
        let facts = classify("/Volumes/team/Projects", StorageProbe(timedOut: true))
        XCTAssertEqual(facts.kind, .network)
        XCTAssertEqual(facts.name, "Server")
        XCTAssertFalse(facts.isResponding)
        XCTAssertEqual(facts.trash, .unknown)
        XCTAssertEqual(facts.volumeRoot, "/Volumes/team")
        // It comes first: no other fact is trusted once the place has stopped answering.
        let cloud = classify(drive + "/My Drive", StorageProbe(isLocal: true, isUbiquitous: true, timedOut: true))
        XCTAssertEqual(cloud.kind, .network)
        XCTAssertFalse(cloud.isResponding)
        XCTAssertNil(cloud.cloudRoot)
    }

    func testADiskThatIsNotLocalIsAServer() {
        let facts = classify("/Volumes/team/Projects", StorageProbe(isLocal: false, hasTrash: false, volumeRoot: "/Volumes/team"))
        XCTAssertEqual(facts, StorageFacts(kind: .network, name: "Server", syncs: false, shared: .yes, trash: .no,
                                           volumeRoot: "/Volumes/team"))
        XCTAssertTrue(facts.isResponding)
        // Before any path rule: a provider's folder kept on a server is still on a server.
        XCTAssertEqual(classify(drive, StorageProbe(isLocal: false)).kind, .network)
        // Whether it has a Trash is unknown until a reader says.
        XCTAssertEqual(classify("/Volumes/team", StorageProbe(isLocal: false)).trash, .unknown)
        XCTAssertEqual(classify("/Volumes/team", StorageProbe(isLocal: false, hasTrash: true)).trash, .yes)
    }

    func testMobileDocumentsIsICloudDrive() {
        let facts = classify(home + "/Library/Mobile Documents/com~apple~CloudDocs/Notes")
        XCTAssertEqual(facts, StorageFacts(kind: .iCloud, name: "iCloud Drive", syncs: true, shared: .no, trash: .yes,
                                           cloudRoot: home + "/Library/Mobile Documents"))
        XCTAssertEqual(classify(home + "/Library/Mobile Documents/iCloud~md~obsidian/Documents").placeKey, facts.placeKey,
                       "every folder of iCloud Drive is one place")
        XCTAssertEqual(classify(home + "/Library/Mobile DocumentsX/a").kind, .thisMac)
    }

    func testAFolderOfCloudStorageIsItsProvidersCloudFolder() {
        let facts = classify(drive + "/My Drive/Budget")
        XCTAssertEqual(facts, StorageFacts(kind: .cloud, name: "Google Drive", syncs: true, shared: .unknown, trash: .yes, cloudRoot: drive))
        XCTAssertEqual(classify(drive).cloudRoot, drive)
        XCTAssertEqual(classify(home + "/Library/CloudStorage").kind, .thisMac, "the folder that holds the providers' folders")
        let names = ["Dropbox": "Dropbox", "OneDrive-Personal": "OneDrive", "OneDrive-SharedLibraries-Contoso": "OneDrive",
                     "Box-Box": "Box", "Nextcloud-me@cloud.example.org": "Nextcloud", "GoogleDrive-other@example.com": "Google Drive",
                     "ProtonDrive-me@example.com": "Cloud folder", "SynologyDrive-nas": "Cloud folder", "pCloud": "Cloud folder"]
        for (folder, name) in names {
            let found = classify(home + "/Library/CloudStorage/" + folder + "/a")
            XCTAssertEqual(found.kind, .cloud, folder)
            XCTAssertEqual(found.name, name, folder)
            XCTAssertEqual(found.cloudRoot, home + "/Library/CloudStorage/" + folder, folder)
            XCTAssertTrue(found.name == "Cloud folder" || StorageClassifier.knownProviders.contains(found.name), folder)
        }
    }

    func testTheAccountInAProvidersFolderNeverReachesTheName() {
        for folder in ["GoogleDrive-me@example.com", "OneDrive-rene@contoso.com", "Unknown-rene@contoso.com"] {
            let name = classify(home + "/Library/CloudStorage/" + folder + "/a").name
            XCTAssertFalse(name.contains("@"), name)
            XCTAssertFalse(name.contains("example") || name.contains("contoso") || name.contains("rene"), name)
        }
        // Two accounts with one provider have the same name and are still two places.
        let first = classify(home + "/Library/CloudStorage/GoogleDrive-me@example.com/a")
        let second = classify(home + "/Library/CloudStorage/GoogleDrive-other@example.com/a")
        XCTAssertEqual(first.name, second.name)
        XCTAssertNotEqual(first.placeKey, second.placeKey)
    }

    func testAMirrorTargetIsItsProvidersCloudFolder() {
        let mirrors = [home + "/My Drive": "GoogleDrive-me@example.com"]
        let facts = classify(home + "/My Drive/Budget", mirrors: mirrors)
        XCTAssertEqual(facts, StorageFacts(kind: .cloud, name: "Google Drive", syncs: true, shared: .unknown, trash: .yes,
                                           cloudRoot: home + "/My Drive"))
        XCTAssertEqual(classify(home + "/My Drive", mirrors: mirrors).kind, .cloud, "the target itself")
        XCTAssertEqual(classify(home + "/My Drive 2/Budget", mirrors: mirrors), .thisMac, "a name that only starts like it")
        XCTAssertEqual(classify(home + "/Documents", mirrors: mirrors), .thisMac)
    }

    func testAFolderKeptInACloudByItsOwnFlag() {
        let ubiquitous = StorageProbe(isUbiquitous: true)
        // The home's Desktop and Documents are iCloud's, and one place with the rest of iCloud Drive.
        for folder in ["/Desktop", "/Documents", "/Documents/Reports/2026"] {
            let facts = classify(home + folder, ubiquitous)
            XCTAssertEqual(facts.kind, .iCloud, folder)
            XCTAssertEqual(facts.name, "iCloud Drive", folder)
            XCTAssertEqual(facts.placeKey, classify(home + "/Library/Mobile Documents/com~apple~CloudDocs").placeKey, folder)
        }
        // Anywhere else it is some provider's folder, and a place of its own.
        let elsewhere = classify(home + "/Sync/Work", ubiquitous)
        XCTAssertEqual(elsewhere, StorageFacts(kind: .cloud, name: "Cloud folder", syncs: true, shared: .unknown, trash: .yes,
                                               cloudRoot: home + "/Sync/Work"))
        XCTAssertEqual(classify(home + "/DocumentsOld", ubiquitous).kind, .cloud)
        // Without the flag, Documents is an ordinary folder.
        XCTAssertEqual(classify(home + "/Documents", StorageProbe(isUbiquitous: false)), .thisMac)
    }

    func testASyncAppsAttributeMakesACloudFolder() {
        let facts = classify(home + "/Dropbox/Work", StorageProbe(hasSyncAttribute: true))
        XCTAssertEqual(facts.kind, .cloud)
        XCTAssertEqual(facts.name, "Cloud folder")
        XCTAssertTrue(facts.syncs)
        XCTAssertEqual(facts.shared, .unknown)
        XCTAssertNotEqual(facts.placeKey, StorageFacts.thisMac.placeKey, "leaving it is leaving a cloud")
        XCTAssertEqual(classify(home + "/Dropbox/Work", StorageProbe(hasSyncAttribute: false)), .thisMac)
        XCTAssertFalse(StorageClassifier.syncAttributePrefixes.isEmpty)
        for prefix in StorageClassifier.syncAttributePrefixes {
            XCTAssertTrue(prefix.hasPrefix("com."), prefix)
            XCTAssertFalse(prefix.hasPrefix("com.apple."), "macOS's own attributes are on every folder: \(prefix)")
        }
    }

    func testADiskThatCanBeUnpluggedIsExternal() {
        for probe in [StorageProbe(isInternal: false), StorageProbe(isInternal: true, isRemovable: true),
                      StorageProbe(isInternal: true, isEjectable: true)] {
            let facts = classify("/Volumes/Backup/Photos", probe)
            XCTAssertEqual(facts.kind, .external)
            XCTAssertEqual(facts.name, "External disk")
            XCTAssertFalse(facts.syncs)
            XCTAssertEqual(facts.shared, .no)
            XCTAssertEqual(facts.volumeRoot, "/Volumes/Backup")
            XCTAssertEqual(facts.trash, .unknown)
        }
        XCTAssertEqual(classify("/Volumes/Backup", StorageProbe(isInternal: false, hasTrash: true, volumeRoot: "/Volumes/Backup")).trash, .yes)
        // An internal second disk is this Mac, and a place apart from the startup disk once its mount point is known.
        let second = classify("/Volumes/Data/Work", StorageProbe(isInternal: true, isRemovable: false, isEjectable: false, volumeRoot: "/Volumes/Data"))
        XCTAssertEqual(second.kind, .thisMac)
        XCTAssertEqual(second.placeKey, "/Volumes/Data")
    }

    func testEarlierRulesWin() {
        // A provider's folder decides before the folder's own flag, an attribute or the disk.
        let probe = StorageProbe(isInternal: false, isUbiquitous: true, hasSyncAttribute: true)
        XCTAssertEqual(classify(drive + "/a", probe).name, "Google Drive")
        XCTAssertEqual(classify(home + "/Library/Mobile Documents/x/a", probe).kind, .iCloud)
        // The flag decides before an attribute, and both before the disk: a provider's folder on an external disk.
        XCTAssertEqual(classify("/Volumes/Fast/Dropbox", StorageProbe(isInternal: false, hasSyncAttribute: true)).kind, .cloud)
        XCTAssertEqual(classify("/Volumes/Fast/Sync", StorageProbe(isInternal: false, isUbiquitous: true)).kind, .cloud)
        XCTAssertEqual(classify("/Volumes/Fast/Other", StorageProbe(isInternal: false)).kind, .external)
    }

    // MARK: The facts

    func testFactsThatComeFromTheProbe() {
        XCTAssertTrue(classify(home + "/Documents", StorageProbe(isReadOnly: true)).isReadOnly)
        XCTAssertFalse(classify(home + "/Documents", StorageProbe(isReadOnly: false)).isReadOnly)
        XCTAssertTrue(classify(drive, StorageProbe(isReadOnly: true)).isReadOnly)
        XCTAssertEqual(classify(home + "/Documents", StorageProbe(hasTrash: false)).trash, .no)
        XCTAssertEqual(classify(drive, StorageProbe(hasTrash: false)).trash, .no)
        // iCloud says whether a folder is shared; other providers don't, so no answer stays unknown.
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs/Shared Notes"
        XCTAssertEqual(classify(iCloud, StorageProbe(isShared: true)).shared, .yes)
        XCTAssertEqual(classify(iCloud, StorageProbe(isShared: false)).shared, .no)
        XCTAssertEqual(classify(iCloud).shared, .no)
        XCTAssertEqual(classify(drive, StorageProbe(isShared: false)).shared, .unknown)
        XCTAssertEqual(classify(drive).shared, .unknown)
    }

    func testWhatTheFactsSayAboutAPlace() {
        let thisMac = StorageFacts.thisMac
        let iCloud = classify(home + "/Library/Mobile Documents/com~apple~CloudDocs")
        let sharedICloud = classify(home + "/Library/Mobile Documents/com~apple~CloudDocs/Team", StorageProbe(isShared: true))
        let cloud = classify(drive)
        let server = classify("/Volumes/team", StorageProbe(isLocal: false))
        let disk = classify("/Volumes/Backup", StorageProbe(isInternal: false))

        XCTAssertEqual([thisMac, iCloud, cloud, server, disk].map(\.symbolName), ["folder", "icloud", "cloud", "network", "externaldrive"])
        XCTAssertEqual([thisMac, iCloud, cloud, server, disk].map(\.modelWord), ["this_mac", "icloud", "cloud", "server", "external"])
        XCTAssertEqual([thisMac, iCloud, cloud, server, disk].map(\.kind), StorageKind.allCases)
        XCTAssertEqual([thisMac, iCloud, cloud, server, disk].map(\.syncs), [false, true, true, false, false])

        // Seen elsewhere: it syncs, it is shared, or it is a server.
        XCTAssertEqual([thisMac, iCloud, sharedICloud, cloud, server, disk].map(\.isSeenElsewhere), [false, true, true, true, true, false])
        // Sharing is known only for a server and for a folder that says it is shared.
        XCTAssertEqual([thisMac, iCloud, sharedICloud, cloud, server, disk].map(\.sharingIsKnown), [false, false, true, false, true, false])

        XCTAssertEqual(thisMac.placeKey, "this-mac")
        XCTAssertEqual(iCloud.placeKey, home + "/Library/Mobile Documents")
        XCTAssertEqual(cloud.placeKey, drive)
        XCTAssertEqual(server.placeKey, "/Volumes/team")
        XCTAssertEqual(disk.placeKey, "/Volumes/Backup")
        // The provider's folder comes before the mount point: cloud folders on one disk are still different places.
        XCTAssertEqual(StorageFacts(kind: .cloud, name: "Dropbox", cloudRoot: "/Volumes/Fast/Dropbox", volumeRoot: "/Volumes/Fast").placeKey,
                       "/Volumes/Fast/Dropbox")
    }

    func testTheWordsForKindsAndAnswers() {
        XCTAssertEqual(StorageKind.allCases.map(\.rawValue), ["thisMac", "iCloud", "cloud", "network", "external"])
        XCTAssertEqual([Tri.yes, .no, .unknown].map(\.rawValue), ["yes", "no", "unknown"])
        XCTAssertEqual(StorageClassifier.knownProviders, ["iCloud Drive", "Google Drive", "Dropbox", "OneDrive", "Box", "Nextcloud"])
        XCTAssertEqual(StorageProbe(), StorageProbe(isLocal: nil, isInternal: nil, isRemovable: nil, isEjectable: nil, isReadOnly: nil,
                                                    isUbiquitous: nil, isShared: nil, hasTrash: nil, hasSyncAttribute: nil,
                                                    volumeRoot: nil, timedOut: false))
        XCTAssertEqual(try JSONDecoder().decode([StorageKind].self, from: JSONEncoder().encode(StorageKind.allCases)), StorageKind.allCases)
    }

    // MARK: Told from the path alone

    func testCloudRootFromThePath() {
        let mirrors = [home + "/My Drive": "GoogleDrive-me@example.com", home + "/My Drive/Team": "GoogleDrive-team@example.com"]
        func root(_ path: String) -> String? { StorageClassifier.cloudRoot(of: path, home: home, mirrors: mirrors) }
        XCTAssertEqual(root(home + "/Library/Mobile Documents/com~apple~CloudDocs/a"), home + "/Library/Mobile Documents")
        XCTAssertEqual(root(drive + "/My Drive/a"), drive)
        XCTAssertEqual(root(drive), drive)
        XCTAssertEqual(root(home + "/My Drive/a"), home + "/My Drive")
        XCTAssertEqual(root(home + "/My Drive/Team/a"), home + "/My Drive/Team", "the deepest target")
        XCTAssertNil(root(home + "/Documents"))
        XCTAssertNil(root(home + "/Library/CloudStorage"))
        XCTAssertNil(root("/Volumes/Backup"))
        XCTAssertNil(StorageClassifier.cloudRoot(of: home + "/My Drive/a", home: home), "no mirrors, no target")
    }

    func testOnlyAFewChildrenCanBeInADifferentPlaceFromTheirParent() {
        let mirrors = [home + "/My Drive": "GoogleDrive-me@example.com"]
        func differs(_ path: String) -> Bool { StorageClassifier.mayDiffer(child: path, home: home, mirrors: mirrors) }
        XCTAssertTrue(differs(home + "/Desktop"))
        XCTAssertTrue(differs(home + "/Documents"))
        XCTAssertTrue(differs(home + "/My Drive"))
        XCTAssertFalse(differs(home + "/Downloads"))
        XCTAssertFalse(differs(home + "/Documents/Reports"), "inside Documents, a folder is where Documents is")
        XCTAssertFalse(differs(home + "/Work/Documents"))
        XCTAssertFalse(differs(home + "/My Drive/Budget"))
        XCTAssertFalse(differs(home))
        XCTAssertFalse(differs("/Users/other/Documents"))
        XCTAssertFalse(StorageClassifier.mayDiffer(child: home + "/My Drive", home: home, mirrors: [:]))
    }
}
