import XCTest
import HelmCore

/// The rules that tell what kind of place a folder is in, as one table. Each row's probe also carries every fact a
/// later rule would act on, so a row passes only when its own rule is the one that decides: the rules are tried in
/// the order DESIGN.md 8.2 gives them.
final class StorageClassifierTableTests: XCTestCase {
    private let home = "/private/tmp/x/.build/host-smoke/fixture/home"
    private var storage: String { home + "/Library/CloudStorage" }
    private var iCloud: String { home + "/Library/Mobile Documents" }

    private struct Row {
        let rule: String
        let path: String
        let probe: StorageProbe
        let mirrors: [String: String]
        let kind: StorageKind
        let name: String
        let root: String?
        let responding: Bool
    }

    /// Every fact a rule after `rule` acts on: the folder's own cloud flag, a sync app's attribute, and a disk that
    /// can be unplugged. `local` is false only where a row wants rule 2.
    private func everyLaterFact(local: Bool = true, timedOut: Bool = false) -> StorageProbe {
        StorageProbe(isLocal: local, isInternal: false, isRemovable: true, isEjectable: true, isUbiquitous: true,
                     hasSyncAttribute: true, volumeRoot: "/Volumes/Fast", timedOut: timedOut)
    }

    private var rows: [Row] {
        let target = home + "/Library/Mobile Documents/com~apple~CloudDocs/Mirror"
        return [
            Row(rule: "1 no answer in time", path: iCloud + "/com~apple~CloudDocs/a",
                probe: everyLaterFact(local: false, timedOut: true), mirrors: [target: "GoogleDrive-me@example.com"],
                kind: .network, name: "Server", root: nil, responding: false),
            Row(rule: "2 not local", path: iCloud + "/com~apple~CloudDocs/a",
                probe: everyLaterFact(local: false), mirrors: [target: "GoogleDrive-me@example.com"],
                kind: .network, name: "Server", root: nil, responding: true),
            Row(rule: "3 Mobile Documents", path: target + "/a",
                probe: everyLaterFact(), mirrors: [target: "GoogleDrive-me@example.com"],
                kind: .iCloud, name: "iCloud Drive", root: iCloud, responding: true),
            Row(rule: "4 a folder of CloudStorage", path: storage + "/Dropbox/Work",
                probe: everyLaterFact(), mirrors: [storage + "/Dropbox/Work": "GoogleDrive-me@example.com"],
                kind: .cloud, name: "Dropbox", root: storage + "/Dropbox", responding: true),
            Row(rule: "5 at or under a mirror target", path: home + "/Documents/My Drive/Budget",
                probe: everyLaterFact(), mirrors: [home + "/Documents/My Drive": "GoogleDrive-me@example.com"],
                kind: .cloud, name: "Google Drive", root: home + "/Documents/My Drive", responding: true),
            Row(rule: "6 the folder's own flag, in Documents", path: home + "/Documents/Reports",
                probe: everyLaterFact(), mirrors: [:],
                kind: .iCloud, name: "iCloud Drive", root: iCloud, responding: true),
            Row(rule: "6 the folder's own flag, elsewhere", path: home + "/Sync",
                probe: everyLaterFact(), mirrors: [:],
                kind: .cloud, name: "Cloud folder", root: home + "/Sync", responding: true),
            Row(rule: "7 a sync app's attribute", path: home + "/Dropbox",
                probe: StorageProbe(isLocal: true, isInternal: false, isRemovable: true, isEjectable: true, isUbiquitous: false,
                                    hasSyncAttribute: true, volumeRoot: "/Volumes/Fast"),
                mirrors: [:], kind: .cloud, name: "Cloud folder", root: home + "/Dropbox", responding: true),
            Row(rule: "8 not internal", path: "/Volumes/Fast/Photos",
                probe: StorageProbe(isLocal: true, isInternal: false, isUbiquitous: false, hasSyncAttribute: false),
                mirrors: [:], kind: .external, name: "External disk", root: nil, responding: true),
            Row(rule: "8 removable", path: "/Volumes/Card/DCIM",
                probe: StorageProbe(isLocal: true, isInternal: true, isRemovable: true), mirrors: [:],
                kind: .external, name: "External disk", root: nil, responding: true),
            Row(rule: "8 ejectable", path: "/Volumes/Image/Read Me",
                probe: StorageProbe(isLocal: true, isInternal: true, isRemovable: false, isEjectable: true), mirrors: [:],
                kind: .external, name: "External disk", root: nil, responding: true),
            Row(rule: "9 otherwise", path: home + "/Downloads",
                probe: StorageProbe(isLocal: true, isInternal: true, isRemovable: false, isEjectable: false, isUbiquitous: false,
                                    hasSyncAttribute: false),
                mirrors: [:], kind: .thisMac, name: "This Mac", root: nil, responding: true),
            Row(rule: "9 with nothing known", path: home + "/Downloads", probe: StorageProbe(), mirrors: [:],
                kind: .thisMac, name: "This Mac", root: nil, responding: true),
        ]
    }

    func testEveryRuleInOrder() {
        for row in rows {
            let facts = StorageClassifier.classify(path: row.path, home: home, probe: row.probe, mirrors: row.mirrors)
            XCTAssertEqual(facts.kind, row.kind, row.rule)
            XCTAssertEqual(facts.name, row.name, row.rule)
            XCTAssertEqual(facts.cloudRoot, row.root, row.rule)
            XCTAssertEqual(facts.isResponding, row.responding, row.rule)
            XCTAssertEqual(facts.syncs, [.iCloud, .cloud].contains(row.kind), row.rule)
        }
        // Each rule of the nine is in the table.
        XCTAssertEqual(Set(rows.map { $0.rule.prefix(1) }), Set((1...9).map { Substring(String($0)) }))
    }

    func testAProbeThatTimedOut() {
        let facts = StorageClassifier.classify(path: "/Volumes/team/Projects", home: home,
                                               probe: StorageProbe(isLocal: true, isInternal: true, hasTrash: true, timedOut: true))
        XCTAssertEqual(facts, StorageFacts(kind: .network, name: "Server", shared: .yes, trash: .unknown, isResponding: false,
                                           volumeRoot: "/Volumes/team"))
        // Nothing the probe said before it gave up is trusted: not the Trash, not that the disk was local.
        XCTAssertTrue(facts.isSeenElsewhere)
        XCTAssertTrue(facts.sharingIsKnown)
        // In the home folder there is no mount point to name the place by.
        let inHome = StorageClassifier.classify(path: home + "/Documents", home: home, probe: StorageProbe(timedOut: true))
        XCTAssertEqual(inHome.kind, .network)
        XCTAssertFalse(inHome.isResponding)
        XCTAssertNil(inHome.volumeRoot)
    }

    func testAProviderFolderOnAnExternalDisk() {
        let external = StorageProbe(isLocal: true, isInternal: false, isRemovable: true, isEjectable: true, volumeRoot: "/Volumes/Fast")
        // Mirrored there, flagged by the folder itself, or marked by its sync app: a cloud folder each time, which
        // also knows the disk it is on.
        let mirrored = StorageClassifier.classify(path: "/Volumes/Fast/My Drive/Budget", home: home, probe: external,
                                                  mirrors: ["/Volumes/Fast/My Drive": "GoogleDrive-me@example.com"])
        XCTAssertEqual(mirrored, StorageFacts(kind: .cloud, name: "Google Drive", syncs: true, shared: .unknown, trash: .unknown,
                                              cloudRoot: "/Volumes/Fast/My Drive", volumeRoot: "/Volumes/Fast"))
        var flagged = external
        flagged.isUbiquitous = true
        XCTAssertEqual(StorageClassifier.classify(path: "/Volumes/Fast/Sync", home: home, probe: flagged).kind, .cloud)
        var marked = external
        marked.hasSyncAttribute = true
        let dropbox = StorageClassifier.classify(path: "/Volumes/Fast/Dropbox", home: home, probe: marked)
        XCTAssertEqual(dropbox.kind, .cloud)
        XCTAssertEqual(dropbox.volumeRoot, "/Volumes/Fast")
        XCTAssertEqual(dropbox.trash, .unknown, "a Trash on that disk isn't known until a reader says")
        // The disk's other folders are an external disk, and a place apart from the cloud folder on it.
        let other = StorageClassifier.classify(path: "/Volumes/Fast/Photos", home: home, probe: external)
        XCTAssertEqual(other.kind, .external)
        XCTAssertNotEqual(other.placeKey, mirrored.placeKey)
        XCTAssertNotEqual(other.placeKey, dropbox.placeKey)
    }

    func testAPathUnderAMirrorTargetHoweverItWasReached() {
        let target = home + "/Mirrored Drive"
        let mirrors = [target: "GoogleDrive-me@example.com"]
        let expected = StorageClassifier.classify(path: target, home: home, probe: StorageProbe(), mirrors: mirrors)
        XCTAssertEqual(expected.kind, .cloud)
        XCTAssertEqual(expected.name, "Google Drive")
        XCTAssertEqual(expected.cloudRoot, target)
        // At any depth, whatever the folder's own flags say, and with its name's accents in either form.
        let decomposed = home + "/Mirrored Drive/Cafe\u{301}/Notes", composed = home + "/Mirrored Drive/Caf\u{E9}/Notes"
        let probes = [StorageProbe(), StorageProbe(isLocal: true, isInternal: true), StorageProbe(isUbiquitous: false, hasSyncAttribute: false),
                      StorageProbe(isUbiquitous: true, hasSyncAttribute: true)]
        for path in [target + "/Budget", target + "/Budget/2026/Q1", decomposed, composed] {
            for probe in probes {
                let facts = StorageClassifier.classify(path: path, home: home, probe: probe, mirrors: mirrors)
                XCTAssertEqual(facts.kind, .cloud, path)
                XCTAssertEqual(facts.name, "Google Drive", path)
                XCTAssertEqual(facts.placeKey, expected.placeKey, path)
            }
        }
        // A mirror target spelled with the other form of an accent is found too.
        let accented = [home + "/Re\u{301}sume\u{301}s": "Dropbox"]
        XCTAssertEqual(StorageClassifier.classify(path: home + "/R\u{E9}sum\u{E9}s/a", home: home, probe: StorageProbe(), mirrors: accented).name,
                       "Dropbox")
        // A sibling whose name only starts the same isn't inside it.
        XCTAssertEqual(StorageClassifier.classify(path: home + "/Mirrored Drive Old", home: home, probe: StorageProbe(), mirrors: mirrors),
                       .thisMac)
    }

    func testASyncAttribute() {
        let marked = StorageClassifier.classify(path: home + "/Work/Shared", home: home, probe: StorageProbe(hasSyncAttribute: true))
        XCTAssertEqual(marked.kind, .cloud)
        XCTAssertEqual(marked.name, "Cloud folder")
        XCTAssertTrue(marked.syncs)
        XCTAssertEqual(marked.shared, .unknown)
        XCTAssertEqual(marked.cloudRoot, home + "/Work/Shared")
        XCTAssertTrue(marked.isSeenElsewhere)
        XCTAssertFalse(marked.sharingIsKnown)
        XCTAssertEqual(StorageClassifier.classify(path: home + "/Work/Shared", home: home, probe: StorageProbe(hasSyncAttribute: nil)), .thisMac)
    }

    func testTwoAccountsOfOneProviderShowNoAccountInAnyName() {
        let folders = ["GoogleDrive-me@example.com", "GoogleDrive-work@example.org", "OneDrive-Personal", "OneDrive-SharedLibraries-Contoso",
                       "Dropbox", "Dropbox-Team Example"]
        let facts = folders.map { StorageClassifier.classify(path: storage + "/" + $0 + "/Notes", home: home, probe: StorageProbe()) }
        XCTAssertEqual(facts.map(\.name), ["Google Drive", "Google Drive", "OneDrive", "OneDrive", "Dropbox", "Dropbox"])
        for (folder, found) in zip(folders, facts) {
            XCTAssertEqual(found.kind, .cloud, folder)
            for word in ["me", "work", "example", "Personal", "Contoso", "Team", "@", "SharedLibraries"] {
                XCTAssertFalse(found.name.contains(word), "\(found.name) holds \(word)")
            }
        }
        // Two accounts are two places, however alike their names.
        XCTAssertNotEqual(facts[0].placeKey, facts[1].placeKey)
        XCTAssertNotEqual(facts[2].placeKey, facts[3].placeKey)
        XCTAssertNotEqual(facts[4].placeKey, facts[5].placeKey)
    }

    func testPlaceKeysAreEqualInOneProviderAndDifferAcrossProviders() {
        func key(_ path: String, _ probe: StorageProbe = StorageProbe()) -> String {
            StorageClassifier.classify(path: path, home: home, probe: probe).placeKey
        }
        let google = storage + "/GoogleDrive-me@example.com"
        XCTAssertEqual(key(google + "/My Drive/Budget"), key(google + "/Shared drives/Team/Plans"))
        XCTAssertEqual(key(google), key(google + "/My Drive"))
        XCTAssertEqual(key(iCloud + "/com~apple~CloudDocs/Notes"), key(iCloud + "/iCloud~md~obsidian/Vault"))
        XCTAssertEqual(key(iCloud + "/com~apple~CloudDocs/Notes"), key(home + "/Documents/Reports", StorageProbe(isUbiquitous: true)),
                       "Desktop and Documents in iCloud are part of iCloud Drive")
        let providers = [google + "/My Drive", storage + "/Dropbox/Work", storage + "/OneDrive-Personal/Work", storage + "/Box-Box/Work",
                         iCloud + "/com~apple~CloudDocs/Work", home + "/Work"]
        XCTAssertEqual(Set(providers.map { key($0) }).count, providers.count, "each provider, and this Mac, is a place of its own")
    }
}
