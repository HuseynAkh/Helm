import Foundation
import XCTest
@testable import HelmCore

/// Permissions hunt: cards and status words that explained a refusal wrongly or said nothing at all.
final class HuntPermissionsPresentationTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    private func failure(_ error: LoadError = .permissionDenied, at location: Location, access: PrivacyAccessStatus = .denied,
                         evidence: ContentStatePresentation.RefusalEvidence = .none) -> ContentState? {
        ContentStatePresentation.failure(error, attempted: location, home: home, fullDiskAccess: access, evidence: evidence)
    }
    private func offersAccess(_ state: ContentState?) -> Bool {
        state?.buttons.contains { if case .grantAccess = $0.action { return true } else { return false } } ?? false
    }
    private func describe(_ state: ContentState?) -> String {
        "\(state?.title ?? "no card") / \(state?.message ?? "") / \(state?.buttons.map(\.title) ?? [])"
    }
    private func disk(_ path: String) -> Location { .directory(URL(fileURLWithPath: path, isDirectory: true)) }

    /// macOS asks before Helm reads a removable or network disk (Privacy & Security › Files & Folders › Removable
    /// Volumes, Network Volumes). Turned down, the disk's own folder refuses Helm. That isn't its owner, and the card
    /// offers the switch that lets Helm in.
    func testARefusedDiskOffersAWayToGrantAccess() {
        for path in ["/Volumes/Photos Stick", "/Volumes/Team Share", "/volumes/Photos Stick/"] {
            let state = failure(at: disk(path))
            XCTAssertTrue(offersAccess(state), describe(state))
            XCTAssertEqual(state?.title, "Helm can’t open “\(URL(fileURLWithPath: path).lastPathComponent)”", describe(state))
            XCTAssertEqual(state?.message, "macOS hasn’t let Helm in yet. Allow it in Files & Folders, or give Helm Full Disk Access.")
            XCTAssertEqual(state?.buttons.first?.action, .grantAccess(.filesAndFolders))
        }
        // The disk's own entry says its owner refuses: ordinary permissions, as before.
        XCTAssertEqual(failure(at: disk("/Volumes/Photos Stick"), evidence: .ownership)?.title, "You don’t have permission to see inside “Photos Stick”")
        // With Full Disk Access on, macOS lets Helm onto any disk, so what's left is the owner.
        let granted = failure(at: disk("/Volumes/Photos Stick"), access: .granted)
        XCTAssertFalse(offersAccess(granted), describe(granted))
        // A folder further in on a disk that let Helm in, and a disk that's slow, read as they always have.
        XCTAssertEqual(failure(at: disk("/Volumes/Backup/Private"))?.title, "You don’t have permission to see inside “Private”")
        XCTAssertEqual(failure(.timedOut, at: disk("/Volumes/Photos Stick"))?.title, "The disk holding “Photos Stick” isn’t responding")
        // Access may arrive in System Settings, so a refused disk is tried again when Helm comes back to the front.
        var tab = TabState(location: .directory(home), homeDirectory: home)
        tab.snapshot = PresentationSnapshot(location: .directory(home), phase: .failed(.permissionDenied, attempted: disk("/Volumes/Photos Stick")))
        XCTAssertTrue(ContentStatePresentation.isBlockedByPrivacy(tab, home: home, fullDiskAccess: .denied))
        XCTAssertFalse(ContentStatePresentation.isBlockedByPrivacy(tab, home: home, fullDiskAccess: .granted))
    }

    /// While macOS's question is on screen, the waiting card names the folder macOS asks about. Opening Documents ›
    /// Reports, macOS asks about the Documents folder; another app's data is asked about one app at a time.
    func testTheWaitingCardNamesTheFolderMacOSAsksAbout() {
        let reports = Location.directory(home.appendingPathComponent("Documents/Reports", isDirectory: true))
        let state = failure(.timedOut, at: reports)
        XCTAssertEqual(state?.style, .waiting, describe(state))
        XCTAssertEqual(state?.message, "macOS may be asking whether Helm can open “Documents”. Answer its question and Helm will carry on.")
        let episode = Location.directory(home.appendingPathComponent("Movies/TV/Media.localized", isDirectory: true))
        XCTAssertTrue(failure(.timedOut, at: episode)?.message?.contains("“TV”") == true, describe(failure(.timedOut, at: episode)))
        let container = Location.directory(home.appendingPathComponent("Library/Containers/com.example.notes/Data/Documents", isDirectory: true))
        XCTAssertTrue(failure(.timedOut, at: container)?.message?.contains("“com.example.notes”") == true,
                      describe(failure(.timedOut, at: container)))
        // The guarded folder itself names itself.
        XCTAssertTrue(failure(.timedOut, at: .directory(home.appendingPathComponent("Downloads")))?.message?.contains("“Downloads”") == true)
    }

    /// A folder opened by its triangle that couldn't be read closes again, and the status bar says why, in the words
    /// its own card would use, beside the count. It used to snap shut without a word.
    func testAFolderThatCouldNotOpenInPlaceSaysWhyInTheStatusBar() {
        let movies = home.appendingPathComponent("Movies", isDirectory: true)
        let tv = movies.appendingPathComponent("TV", isDirectory: true)
        var tab = TabState(location: .directory(movies), homeDirectory: home)
        tab.snapshot = PresentationSnapshot(location: .directory(movies), phase: .ready,
                                            sortedEntries: [FileEntry(url: tv, kind: .directory, isReadable: false, isPrivacyProtected: true)])
        XCTAssertNil(ContentStatePresentation.statusActivity(for: tab, home: home, fullDiskAccess: .denied))
        tab.folderProblem = FolderProblem(url: tv, error: .permissionDenied)
        XCTAssertEqual(ContentStatePresentation.statusActivity(for: tab, home: home, fullDiskAccess: .denied), .working("Helm can’t open “TV”"))
        XCTAssertEqual(StatusText.format(StatusPresentation(itemCount: 1, activity: .working("Helm can’t open “TV”"))), "Helm can’t open “TV”  •  1 item")
        // Its own entry says the owner refuses: the words say so too.
        tab.snapshot = PresentationSnapshot(location: .directory(movies), phase: .ready,
                                            sortedEntries: [FileEntry(url: tv, kind: .directory, isReadable: false)])
        XCTAssertEqual(ContentStatePresentation.statusActivity(for: tab, home: home, fullDiskAccess: .denied),
                       .working("You don’t have permission to see inside “TV”"))
        // A card about a place that couldn't open says why first.
        tab.snapshot = PresentationSnapshot(location: .directory(movies), phase: .failed(.notFound, attempted: .directory(home.appendingPathComponent("Gone"))))
        XCTAssertEqual(ContentStatePresentation.statusActivity(for: tab, home: home, fullDiskAccess: .denied), .unavailable("Not found"))
    }
}
