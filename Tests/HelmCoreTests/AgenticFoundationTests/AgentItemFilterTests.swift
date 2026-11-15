import XCTest
@testable import HelmCore

/// Which places and names may be shown to a model. The same answers serve folder listings and AI search rows.
final class AgentItemFilterTests: XCTestCase {
    /// A home shaped like the one fixture runs use: it sits under a dot folder and under /private.
    private let home = "/private/tmp/x/.build/host-smoke/fixture/home"
    private func area(_ path: String, home: String? = nil) -> AgentItemFilter.Area {
        AgentItemFilter.area(ofPath: path, home: home ?? self.home)
    }

    // MARK: Areas

    func testTheHomeFolderAndWhatIsInsideIt() {
        XCTAssertEqual(area(home), .home)
        XCTAssertEqual(area(home + "/"), .home)
        XCTAssertEqual(area(home + "/Documents"), .home)
        XCTAssertEqual(area(home + "/Documents/Reports/2026/Q1.pdf"), .home)
        XCTAssertEqual(area(home + "/Library Books"), .home, "a name that only starts like Library")
        XCTAssertEqual(area(home + "/Documents/Library"), .home, "only the home's own Library is closed")
    }

    func testTheHomeLibraryATrashAndDotPartsBelowTheHomeAreRefused() {
        XCTAssertEqual(area(home + "/Library"), .refused)
        XCTAssertEqual(area(home + "/Library/Application Support/Helm"), .refused)
        XCTAssertEqual(area(home + "/Library/Keychains/login.keychain-db"), .refused)
        XCTAssertEqual(area(home + "/library/Keychains"), .refused, "whatever case the disk matched it in")
        XCTAssertEqual(area(home + "/.Trash"), .refused)
        XCTAssertEqual(area(home + "/.Trash/old.txt"), .refused)
        XCTAssertEqual(area(home + "/.config"), .refused)
        XCTAssertEqual(area(home + "/Documents/.git/config"), .refused)
        XCTAssertEqual(area(home + "/Documents/.hidden"), .refused)
        XCTAssertEqual(area(home + "/Documents/../../other"), .refused, "a path that climbs is never canonical")
    }

    func testADotPartAboveTheHomeDoesNotCount() {
        // The fixture home is under ".build"; that alone refuses nothing.
        XCTAssertEqual(area(home + "/Downloads/a.png"), .home)
        XCTAssertEqual(area("/private/tmp/x/.build/host-smoke/fixture/Shared/a.png"), .shared)
        // The same folders are refused when they aren't the home: nothing above the home is allowed by itself.
        XCTAssertEqual(area("/private/tmp/x/.build/host-smoke/fixture"), .refused)
        XCTAssertEqual(area("/private/tmp/x/.build"), .refused)
        XCTAssertEqual(area("/private/tmp"), .refused)
    }

    func testCloudFoldersInsideTheHomeLibrary() {
        let drive = home + "/Library/CloudStorage/GoogleDrive-me@example.com"
        XCTAssertEqual(area(drive), .cloud)
        XCTAssertEqual(area(drive + "/My Drive/Reports"), .cloud)
        // Google keeps shortcuts to shared folders in a dot folder of its own.
        XCTAssertEqual(area(drive + "/.shortcut-targets-by-id"), .cloud)
        XCTAssertEqual(area(drive + "/.shortcut-targets-by-id/1AbC/Shared Budget"), .cloud)
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        XCTAssertEqual(area(iCloud), .cloud)
        XCTAssertEqual(area(iCloud + "/Notes/todo.txt"), .cloud)
        // The folders that hold the providers' folders are the Library, not a place.
        XCTAssertEqual(area(home + "/Library/CloudStorage"), .refused)
        XCTAssertEqual(area(home + "/Library/Mobile Documents"), .refused)
        XCTAssertEqual(area(home + "/Library/CloudStorage/.DS_Store"), .refused)
        XCTAssertEqual(area(home + "/Library/CloudStorageOther/Folder"), .refused)
        // A cloud's own Trash is still a Trash.
        XCTAssertEqual(area(iCloud + "/.Trash"), .refused)
        XCTAssertEqual(area(iCloud + "/.Trash/old.txt"), .refused)
        XCTAssertEqual(area(drive + "/.Trash/old.txt"), .refused)
        // The exception is spelled exactly: another case isn't the provider's folder.
        XCTAssertEqual(area(home + "/library/cloudstorage/GoogleDrive-me@example.com"), .refused)
    }

    func testVolumes() {
        XCTAssertEqual(area("/Volumes/Backup"), .volume)
        XCTAssertEqual(area("/Volumes/Backup/Photos/2024"), .volume)
        XCTAssertEqual(area("/Volumes/My Disk/a b/c.txt"), .volume)
        XCTAssertEqual(area("/Volumes"), .refused, "the folder of disks isn't a disk")
        XCTAssertEqual(area("/Volumes/Backup/.Trashes"), .refused)
        XCTAssertEqual(area("/Volumes/Backup/.Spotlight-V100/Store"), .refused)
        XCTAssertEqual(area("/Volumes/Backup/Photos/.thumbnails/a.jpg"), .refused)
        XCTAssertEqual(area("/Volumes/.timemachine/disk"), .refused, "a hidden mount isn't a disk the person added")
        XCTAssertEqual(area("/VolumesOther/Backup"), .refused)
        XCTAssertEqual(area("/private/Volumes/Backup"), .refused)
    }

    func testTheSharedFolderBesideTheHomes() {
        XCTAssertEqual(area("/Users/Shared", home: "/Users/me"), .shared)
        XCTAssertEqual(area("/Users/Shared/Scans/a.pdf", home: "/Users/me"), .shared)
        XCTAssertEqual(area("/Users/Shared/.hidden/a.pdf", home: "/Users/me"), .refused)
        XCTAssertEqual(area("/Users/SharedOther", home: "/Users/me"), .refused)
        XCTAssertEqual(area("/private/tmp/x/.build/host-smoke/fixture/Shared"), .shared)
        // Shared sits beside the homes. A folder of that name anywhere else is just a folder.
        XCTAssertEqual(area("/Shared", home: "/Users/me"), .refused)
        XCTAssertEqual(area("/Shared", home: "/me"), .refused, "a home at the top of the disk has no folder of homes")
        XCTAssertEqual(area(home + "/Shared"), .home)
    }

    func testEverythingElseIsRefused() {
        for path in ["/", "/net", "/net/server/share", "/Applications", "/Applications/Safari.app", "/System/Library",
                     "/Library", "/usr/local", "/opt", "/tmp", "/private/var/folders", "/Network", "/cores", "/dev", ""] {
            XCTAssertEqual(area(path), .refused, path)
            XCTAssertEqual(area(path, home: "/Users/me"), .refused, path)
        }
        // Another account's home, beside this one.
        XCTAssertEqual(area("/private/tmp/x/.build/host-smoke/fixture/other"), .refused)
        XCTAssertEqual(area("/private/tmp/x/.build/host-smoke/fixture/other/Documents"), .refused)
        XCTAssertEqual(area("/Users/other", home: "/Users/me"), .refused)
        XCTAssertEqual(area("/Users/other/Documents/a.txt", home: "/Users/me"), .refused)
        XCTAssertEqual(area("/Users", home: "/Users/me"), .refused)
        // A home whose name only starts like this one.
        XCTAssertEqual(area("/Users/me2/Documents", home: "/Users/me"), .refused)
        XCTAssertEqual(area(home + "2/Documents"), .refused)
        // Names are compared as the disk spells them: on a disk that tells case apart, this is someone else's.
        XCTAssertEqual(area("/Users/ME/Documents", home: "/Users/me"), .refused)
    }

    #if canImport(Darwin)
    /// A Mac's disk treats an accent written as one character and as a letter and a mark as one name.
    func testAccentsWrittenEitherWayAreOneName() {
        XCTAssertEqual(area("/Users/rene\u{301}/Documents", home: "/Users/ren\u{E9}"), .home)
        XCTAssertEqual(area("/Users/ren\u{E9}/Library", home: "/Users/rene\u{301}"), .refused)
    }
    #endif

    // MARK: Names

    func testListableNames() {
        for name in ["Report.pdf", "a", "Photos 2026", "~Budget.xlsx", "name.with.dots", "$RECYCLE", "#notes#"] {
            XCTAssertTrue(AgentItemFilter.isListable(name: name, isHidden: false), name)
        }
        for name in [".DS_Store", "._Report.pdf", ".git", ".env", ".~lock.Budget.ods#", "~$Budget.xlsx", "~$", ".", "..", ""] {
            XCTAssertFalse(AgentItemFilter.isListable(name: name, isHidden: false), name)
        }
    }

    func testTheHiddenFlagHidesAnyName() {
        XCTAssertTrue(AgentItemFilter.isListable(name: "Report.pdf", isHidden: false))
        XCTAssertFalse(AgentItemFilter.isListable(name: "Report.pdf", isHidden: true))
        XCTAssertFalse(AgentItemFilter.isListable(name: "Library", isHidden: true))
        XCTAssertFalse(AgentItemFilter.allowsSearchRow(path: home + "/Documents/Report.pdf", name: "Report.pdf", isHidden: true, home: home))
    }

    func testInsideAPackage() {
        XCTAssertTrue(AgentItemFilter.isInsidePackage(path: "/Applications/Safari.app/Contents/Info.plist"))
        XCTAssertTrue(AgentItemFilter.isInsidePackage(path: home + "/Pictures/Photos Library.photoslibrary/originals/1/a.heic"))
        XCTAssertTrue(AgentItemFilter.isInsidePackage(path: home + "/Documents/Notes.rtfd/TXT.rtf"))
        XCTAssertTrue(AgentItemFilter.isInsidePackage(path: home + "/Code/App.xcodeproj/project.pbxproj"))
        XCTAssertTrue(AgentItemFilter.isInsidePackage(path: home + "/Apps/Tool.APP/Contents"), "whatever case the extension is in")
        // A package is one item, so it isn't inside itself.
        XCTAssertFalse(AgentItemFilter.isInsidePackage(path: "/Applications/Safari.app"))
        XCTAssertFalse(AgentItemFilter.isInsidePackage(path: home + "/Documents/Notes.rtfd"))
        // Ordinary folders with dots in their names, and a dot folder that merely looks like an extension.
        XCTAssertFalse(AgentItemFilter.isInsidePackage(path: home + "/Documents/v1.2/notes.txt"))
        XCTAssertFalse(AgentItemFilter.isInsidePackage(path: home + "/Documents/2026.03/notes.txt"))
        XCTAssertFalse(AgentItemFilter.isInsidePackage(path: home + "/Documents/application/notes.txt"))
        XCTAssertFalse(AgentItemFilter.isInsidePackage(path: home + "/.app/notes.txt"))
        XCTAssertFalse(AgentItemFilter.isInsidePackage(path: home + "/Code/en.lproj/Main.strings"))
        // A provider's folder carries an account, whose address can end like a package. It is still a folder.
        XCTAssertFalse(AgentItemFilter.isInsidePackage(path: home + "/Library/CloudStorage/GoogleDrive-me@studio.app/My Drive/a.txt"))
        XCTAssertTrue(AgentItemFilter.isInsidePackage(path: home + "/Library/CloudStorage/GoogleDrive-me@studio.app/Tool.app/Contents"))
        XCTAssertTrue(AgentItemFilter.allowsSearchRow(path: home + "/Library/CloudStorage/GoogleDrive-me@studio.app/My Drive/a.txt",
                                                      name: "a.txt", isHidden: false, home: home))
        XCTAssertEqual(AgentItemFilter.packageExtensions, Set(AgentItemFilter.packageExtensions.map { $0.lowercased() }))
    }

    func testSecretKinds() {
        for name in ["server.pem", "Identity.p12", "cert.PFX", "AuthKey_ABC123.p8", "putty.ppk", "Passwords.kdbx", "login.keychain",
                     "login.keychain-db", "My.wallet", "wallet.dat", "release.jks", "debug.keystore", "private.asc", "secret.gpg",
                     "office.ovpn", "id_rsa", "id_rsa.pub", "id_ed25519", "id_ecdsa.old", "credentials", "Dev.mobileprovision",
                     "backup.pem.bak", "1Password.opvault"] {
            XCTAssertTrue(AgentItemFilter.isSecretKind(name: name), name)
        }
        for name in ["Talk.key", "Budget.xlsx", "keys.txt", "wallet", "Wallet photos.zip", "pem", "password ideas.md",
                     "Keychain Access.app", "credentials-howto.pdf", "id.pdf"] {
            XCTAssertFalse(AgentItemFilter.isSecretKind(name: name), name)
        }
    }

    func testSearchRows() {
        func allows(_ path: String, hidden: Bool = false) -> Bool {
            AgentItemFilter.allowsSearchRow(path: path, name: URL(fileURLWithPath: path).lastPathComponent, isHidden: hidden, home: home)
        }
        XCTAssertTrue(allows(home + "/Documents/Invoice March.pdf"))
        XCTAssertTrue(allows(home + "/Library/CloudStorage/GoogleDrive-me@example.com/My Drive/Budget.xlsx"))
        XCTAssertTrue(allows("/Volumes/Backup/Photos/a.jpg"))
        XCTAssertTrue(allows("/private/tmp/x/.build/host-smoke/fixture/Shared/Scan.pdf"))
        XCTAssertTrue(allows("/Applications/Safari.app") == false, "outside every allowed area")
        // Each rule refuses on its own.
        XCTAssertFalse(allows("/net/server/share/a.txt"))
        XCTAssertFalse(allows(home + "/Library/Preferences/com.apple.finder.plist"))
        XCTAssertFalse(allows(home + "/Documents/.secret.txt"))
        XCTAssertFalse(allows(home + "/Documents/~$Budget.xlsx"))
        XCTAssertFalse(allows(home + "/Documents/Budget.xlsx", hidden: true))
        XCTAssertFalse(allows(home + "/Documents/Notes.rtfd/TXT.rtf"))
        XCTAssertFalse(allows(home + "/Documents/server.pem"))
        XCTAssertFalse(allows(home + "/Documents/Passwords.kdbx"))
        XCTAssertFalse(allows("/private/tmp/x/.build/host-smoke/fixture/other/Documents/a.txt"))
        // A package itself is one item and may be a row.
        XCTAssertTrue(allows(home + "/Documents/Notes.rtfd"))
    }

    // MARK: Sizes and places in words

    func testSizesAreRoundedToTwoFigures() {
        let table: [(Int64, Int64)] = [
            (0, 0), (1, 1), (9, 9), (42, 42), (99, 99), (100, 100), (104, 100), (105, 110), (149, 150), (999, 1_000),
            (1_234, 1_200), (1_250, 1_300), (88_000, 88_000), (88_499, 88_000), (88_500, 89_000), (1_234_567, 1_200_000),
            (999_999, 1_000_000), (5_368_709_120, 5_400_000_000), (-5, 0), (Int64.max, 9_200_000_000_000_000_000)
        ]
        for (bytes, rounded) in table {
            XCTAssertEqual(AgentItemFilter.roundedBytes(bytes), rounded, "\(bytes)")
        }
        // Two figures at most, whatever the size.
        for bytes: Int64 in [123, 4_567, 89_012, 345_678_901, 2_345_678_901_234] {
            let digits = String(AgentItemFilter.roundedBytes(bytes)).drop { $0 == "0" }
            XCTAssertLessThanOrEqual(String(digits.reversed().drop { $0 == "0" }).count, 2, "\(bytes)")
        }
    }

    func testPlaceWords() {
        func words(_ path: String, _ storage: StorageFacts = .thisMac, home: String? = nil) -> [String] {
            AgentItemFilter.placeWords(path: path, home: home ?? self.home, storage: storage)
        }
        XCTAssertEqual(words(home), ["Home"])
        XCTAssertEqual(words(home + "/Documents/Reports"), ["Home", "Documents", "Reports"])
        // Inside the home folder the first word is Home, whatever cloud keeps the folder in step.
        let iCloud = StorageFacts(kind: .iCloud, name: "iCloud Drive", syncs: true, cloudRoot: home + "/Library/Mobile Documents")
        XCTAssertEqual(words(home + "/Documents/Reports", iCloud), ["Home", "Documents", "Reports"])
        XCTAssertEqual(words(home + "/Library/Mobile Documents/com~apple~CloudDocs/Notes", iCloud), ["iCloud Drive", "Notes"])

        // A provider's folder is named by the provider, never by the folder on disk, which holds the account.
        let drive = home + "/Library/CloudStorage/GoogleDrive-me@example.com"
        let google = StorageFacts(kind: .cloud, name: "Google Drive", syncs: true, shared: .unknown, cloudRoot: drive)
        XCTAssertEqual(words(drive, google), ["Google Drive"])
        XCTAssertEqual(words(drive + "/My Drive/Budget", google), ["Google Drive", "My Drive", "Budget"])
        // The same words when the caller's facts don't say it is a cloud, so the account can't slip through.
        XCTAssertEqual(words(drive + "/My Drive/Budget"), ["Google Drive", "My Drive", "Budget"])
        XCTAssertEqual(words(home + "/Library/CloudStorage/ProtonDrive-me@example.com/Work"), ["Cloud folder", "Work"])
        XCTAssertEqual(words(home + "/Library/Mobile Documents/com~apple~CloudDocs/Notes"), ["iCloud Drive", "Notes"])
        for found in [words(drive + "/My Drive/Budget", google), words(drive + "/My Drive/Budget")] {
            XCTAssertFalse(found.joined().contains("example.com"))
            XCTAssertFalse(found.joined().contains("@"))
        }

        XCTAssertEqual(words("/Users/Shared/Scans", home: "/Users/me"), ["Shared", "Scans"])
        XCTAssertEqual(words("/Users/Shared", home: "/Users/me"), ["Shared"])

        // A disk's own name is left out too.
        let disk = StorageFacts(kind: .external, name: "External disk", volumeRoot: "/Volumes/Rene’s Backup")
        XCTAssertEqual(words("/Volumes/Rene’s Backup/Photos/2024", disk), ["External disk", "Photos", "2024"])
        XCTAssertEqual(words("/Volumes/Rene’s Backup", disk), ["External disk"])
        let server = StorageFacts(kind: .network, name: "Server", shared: .yes, volumeRoot: "/Volumes/team")
        XCTAssertEqual(words("/Volumes/team/Projects", server), ["Server", "Projects"])
        let onDisk = StorageFacts(kind: .cloud, name: "Dropbox", syncs: true, shared: .unknown, cloudRoot: "/Volumes/Fast/Dropbox",
                                  volumeRoot: "/Volumes/Fast")
        XCTAssertEqual(words("/Volumes/Fast/Dropbox/Work", onDisk), ["Dropbox", "Work"])

        // A refused place has no words.
        XCTAssertEqual(words("/Applications/Safari.app"), [])
        XCTAssertEqual(words(home + "/Library/Preferences"), [])
        XCTAssertEqual(words("/Users/other/Documents", home: "/Users/me"), [])
    }
}
