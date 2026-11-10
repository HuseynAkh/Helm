import Foundation
import XCTest
@testable import HelmCore

/// What the content area says when a place is empty or couldn't open, and which buttons it offers.
final class ContentStatePresentationTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    private func folder(_ path: String) -> Location { .directory(home.appendingPathComponent(path, isDirectory: true)) }
    private func url(_ path: String) -> URL { home.appendingPathComponent(path, isDirectory: true) }
    private func titles(_ state: ContentState?) -> [String] { state?.buttons.map(\.title) ?? [] }
    private func primary(_ state: ContentState?) -> ContentStateButton? { state?.buttons.first(where: \.isPrimary) }
    private func offersSettings(_ state: ContentState?) -> Bool {
        state?.buttons.contains { if case .grantAccess = $0.action { return true } else { return false } } ?? false
    }
    private func refusal(_ location: Location, access: PrivacyAccessStatus = .denied,
                         evidence: ContentStatePresentation.RefusalEvidence = .none) -> ContentState? {
        ContentStatePresentation.failure(.permissionDenied, attempted: location, home: home, fullDiskAccess: access, evidence: evidence)
    }
    /// A tab still on `location`, whose listing there is `entries`, after `attempted` failed with `error`.
    private func failedTab(at location: Location, entries: [FileEntry] = [], attempted: Location,
                           error: LoadError = .permissionDenied) -> TabState {
        var tab = TabState(location: location, homeDirectory: home)
        tab.snapshot = PresentationSnapshot(location: location, phase: .failed(error, attempted: attempted), sortedEntries: entries)
        return tab
    }
    private func pending(_ target: Location) -> PendingNavigation {
        PendingNavigation(target: target, intent: .push, restoredSelection: [], generation: Generation(), steps: 1)
    }

    // MARK: Refusals

    func testTrashWithoutFullDiskAccess() {
        let state = refusal(.trash)
        XCTAssertEqual(state?.style, .problem)
        XCTAssertEqual(state?.symbol, "trash.slash")
        XCTAssertEqual(state?.title, "Helm can’t show the Trash")
        XCTAssertEqual(state?.message, "Only apps with Full Disk Access can look inside the Trash.")
        XCTAssertEqual(titles(state), ["Grant Access…", "Open in Finder", "Try Again"])
        XCTAssertEqual(primary(state)?.action, .grantAccess(.fullDiskAccess))
        XCTAssertEqual(state?.buttons[1].action, .openTrashInFinder)
        XCTAssertEqual(state?.buttons[2].action, .tryAgain(.trash))
        // Not knowing reads the same as off: the guide is the way forward either way.
        XCTAssertEqual(refusal(.trash, access: .unknown), state)
    }

    func testTrashWithFullDiskAccessOnPointsAtItsOwnPermissions() {
        // Full Disk Access reads as on only once Helm opened a guarded folder in this very run, so reopening
        // Helm can't help, and the card doesn't say it would.
        let state = refusal(.trash, access: .granted)
        XCTAssertEqual(state?.title, "Helm can’t show the Trash")
        XCTAssertEqual(state?.message, "Helm has Full Disk Access, so the Trash’s own permissions are keeping it out. Finder can still show it.")
        XCTAssertFalse(state?.message?.contains("reopen") ?? true)
        XCTAssertEqual(titles(state), ["Try Again", "Open in Finder"])
        XCTAssertEqual(primary(state)?.action, .tryAgain(.trash))
    }

    func testOtherAppsDataNeedsFullDiskAccess() {
        let state = refusal(folder("Library/Containers/com.example.notes"))
        XCTAssertEqual(state?.symbol, "lock.shield")
        XCTAssertEqual(state?.title, "Helm can’t open “com.example.notes”")
        XCTAssertEqual(state?.message, "macOS keeps this folder private. Give Helm Full Disk Access to see inside.")
        XCTAssertEqual(titles(state), ["Grant Access…", "Try Again"])
        XCTAssertEqual(primary(state)?.action, .grantAccess(.fullDiskAccess))
        XCTAssertEqual(refusal(folder("Library/Mail"))?.buttons.first?.action, .grantAccess(.fullDiskAccess))
    }

    func testFoldersMacOSAsksAboutPointAtFilesAndFolders() {
        for path in ["Documents", "Desktop/Plans", "Downloads", "Library/CloudStorage/GoogleDrive-me@example.com"] {
            let state = refusal(folder(path))
            XCTAssertEqual(primary(state)?.action, .grantAccess(.filesAndFolders), path)
            XCTAssertTrue(state?.message?.contains("Files & Folders") == true, path)
            XCTAssertEqual(titles(state), ["Grant Access…", "Try Again"], path)
        }
    }

    func testMediaLibrariesOfferTheirRowAndFullDiskAccess() {
        let state = refusal(folder("Movies/TV"))
        XCTAssertEqual(state?.title, "Helm can’t open “TV”")
        XCTAssertTrue(state?.message?.contains("Media & Apple Music") == true)
        XCTAssertEqual(titles(state), ["Grant Access…", "Full Disk Access…", "Try Again"])
        XCTAssertEqual(state?.buttons[0].action, .grantAccess(.media))
        XCTAssertEqual(state?.buttons[1].action, .grantAccess(.fullDiskAccess))
        XCTAssertEqual(refusal(folder("Pictures/Photos Library.photoslibrary"))?.buttons.first?.action, .grantAccess(.photos))
    }

    func testWithFullDiskAccessOnRowsOfTheirOwnStillOfferAWayIn() {
        // Review case 4: the TV library refused with Full Disk Access on keeps its own row's button.
        let media = refusal(folder("Movies/TV"), access: .granted)
        XCTAssertEqual(titles(media), ["Grant Access…", "Try Again"])
        XCTAssertEqual(primary(media)?.action, .grantAccess(.media))
        XCTAssertEqual(media?.message, "Helm has Full Disk Access, but macOS also guards your TV and music libraries. Allow Helm in Media & Apple Music.")
        XCTAssertEqual(primary(refusal(folder("Pictures/Photos Library.photoslibrary"), access: .granted))?.action, .grantAccess(.photos))
        let cloud = refusal(folder("Library/CloudStorage/Dropbox/Work"), access: .granted)
        XCTAssertEqual(primary(cloud)?.action, .grantAccess(.filesAndFolders))
        XCTAssertTrue(cloud?.message?.contains("each cloud provider") == true)
        // Areas Full Disk Access opens on its own: with it on, the folder's owner is what's left. No Settings
        // button, and no word about reopening Helm, which wouldn't change anything.
        for path in ["Documents/Plans", "Library/Containers/com.example.notes", "Library/Mail/V10"] {
            let state = refusal(folder(path), access: .granted)
            XCTAssertEqual(state?.symbol, "lock", path)
            XCTAssertEqual(titles(state), ["Try Again"], path)
            XCTAssertFalse(offersSettings(state), path)
            XCTAssertTrue(state?.message?.hasPrefix("Helm has Full Disk Access, so the folder’s owner") == true, path)
            XCTAssertFalse(state?.message?.contains("reopen") ?? true, path)
        }
    }

    func testOrdinaryPermissionsMakeNoSettingsClaim() {
        let state = refusal(folder("Projects/Private"))
        XCTAssertEqual(state?.symbol, "lock")
        XCTAssertEqual(state?.title, "You don’t have permission to see inside “Private”")
        XCTAssertEqual(state?.message, "Its owner or its permissions don’t allow it.")
        XCTAssertEqual(titles(state), ["Try Again"])
        XCTAssertFalse(offersSettings(state))
        XCTAssertEqual(refusal(.directory(URL(fileURLWithPath: "/Volumes/Backup/Private")))?.title,
                       "You don’t have permission to see inside “Private”")
    }

    func testEvidenceOnlyNarrowsARefusalDown() {
        // The folder's own entry says EACCES: ordinary permissions, even inside a guarded folder.
        XCTAssertEqual(refusal(folder("Documents/Locked"), evidence: .ownership)?.symbol, "lock")
        // Another folder in the same area just listed, so macOS isn't what's refusing.
        XCTAssertEqual(refusal(folder("Documents/Locked"), evidence: .areaIsReadable)?.symbol, "lock")
        // EPERM on a folder outside the table only suggests privacy: careful words, Full Disk Access as a maybe.
        let likely = refusal(folder("Library/Calendars"), evidence: .privacy)
        XCTAssertEqual(likely?.title, "Helm can’t open “Calendars”")
        XCTAssertEqual(likely?.message, "macOS won’t let Helm in. If this folder holds another app’s data, Full Disk Access may help.")
        XCTAssertEqual(titles(likely), ["Full Disk Access…", "Try Again"])
        XCTAssertEqual(primary(likely)?.action, .grantAccess(.fullDiskAccess))
        let likelyWithAccess = refusal(folder("Library/Calendars"), access: .granted, evidence: .privacy)
        XCTAssertEqual(likelyWithAccess?.message, "macOS won’t let Helm in, even with Full Disk Access.")
        XCTAssertEqual(titles(likelyWithAccess), ["Try Again"])
        // EPERM in a folder the table knows keeps the confident words.
        XCTAssertEqual(refusal(folder("Library/Mail"), evidence: .privacy)?.message,
                       "macOS keeps this folder private. Give Helm Full Disk Access to see inside.")
        // The Trash has no entry of its own; its path always speaks for it.
        XCTAssertEqual(refusal(.trash, evidence: .ownership)?.title, "Helm can’t show the Trash")
    }

    func testEvidenceFromTheTabsOwnListing() {
        let parent = url("Movies")
        let tv = parent.appendingPathComponent("TV", isDirectory: true)
        func snapshot(_ entries: [FileEntry], at location: Location) -> PresentationSnapshot {
            PresentationSnapshot(location: location, sortedEntries: entries)
        }
        let privacy = FileEntry(url: tv, kind: .directory, isReadable: false, isPrivacyProtected: true)
        let ownership = FileEntry(url: tv, kind: .directory, isReadable: false)
        XCTAssertEqual(ContentStatePresentation.evidence(about: .directory(tv), in: snapshot([privacy], at: .directory(parent)), home: home), .privacy)
        XCTAssertEqual(ContentStatePresentation.evidence(about: .directory(tv), in: snapshot([ownership], at: .directory(parent)), home: home), .ownership)
        // A readable entry says nothing about why the read failed now.
        let readable = FileEntry(url: tv, kind: .directory)
        XCTAssertEqual(ContentStatePresentation.evidence(about: .directory(tv), in: snapshot([readable], at: .directory(parent)), home: home), .none)
        // Listing Documents shows the Documents area lets Helm in.
        let documents = url("Documents")
        let listed = snapshot([FileEntry(url: documents.appendingPathComponent("a.txt"))], at: .directory(documents))
        XCTAssertEqual(ContentStatePresentation.evidence(about: .directory(documents.appendingPathComponent("Locked")), in: listed, home: home), .areaIsReadable)
        XCTAssertEqual(ContentStatePresentation.evidence(about: .directory(tv), in: listed, home: home), .none)
        // The same folder failing again is no evidence about itself.
        XCTAssertEqual(ContentStatePresentation.evidence(about: .directory(documents), in: listed, home: home), .none)
        XCTAssertEqual(ContentStatePresentation.evidence(about: .trash, in: listed, home: home), .none)
    }

    func testAreasGuardedChildByChildAreNotVouchedForByTheirListing() {
        // Review cases 1 and 2: macOS asks about each app's container and each cloud provider on its own, so
        // listing the area says nothing about one folder inside it, which keeps its Full Disk Access card.
        let containers = url("Library/Containers")
        let notes = containers.appendingPathComponent("com.apple.Notes", isDirectory: true)
        let tab = failedTab(at: .directory(containers), entries: [FileEntry(url: notes, kind: .directory),
                                                                  FileEntry(url: containers.appendingPathComponent("com.example.x"), kind: .directory)],
                            attempted: .directory(notes))
        XCTAssertEqual(ContentStatePresentation.evidence(about: .directory(notes), in: tab.snapshot, home: home), .none)
        let state = ContentStatePresentation.state(for: tab, home: home, fullDiskAccess: .denied)
        XCTAssertEqual(state?.title, "Helm can’t open “com.apple.Notes”")
        XCTAssertEqual(titles(state), ["Grant Access…", "Try Again"])
        XCTAssertTrue(ContentStatePresentation.isBlockedByPrivacy(tab, home: home, fullDiskAccess: .denied))

        let cloud = url("Library/CloudStorage")
        let drive = cloud.appendingPathComponent("GoogleDrive-me@example.com", isDirectory: true)
        let cloudTab = failedTab(at: .directory(cloud), entries: [FileEntry(url: drive, kind: .directory)], attempted: .directory(drive))
        let cloudState = ContentStatePresentation.state(for: cloudTab, home: home, fullDiskAccess: .denied)
        XCTAssertEqual(cloudState?.title, "Helm can’t open “Google Drive”")
        XCTAssertEqual(primary(cloudState)?.action, .grantAccess(.filesAndFolders))
        XCTAssertTrue(ContentStatePresentation.isBlockedByPrivacy(cloudTab, home: home, fullDiskAccess: .denied))
    }

    func testCloudDrivesAreNamedAsThePathBarNamesThem() {
        let gone = ContentStatePresentation.failure(.notFound, attempted: folder("Library/CloudStorage/OneDrive-Personal"), home: home, fullDiskAccess: .denied)
        XCTAssertEqual(gone?.title, "“OneDrive” no longer exists")
        let icloud = ContentStatePresentation.failure(.notFound, attempted: folder("Library/Mobile Documents/com~apple~CloudDocs"), home: home, fullDiskAccess: .denied)
        XCTAssertEqual(icloud?.title, "“iCloud Drive” no longer exists")
        // Folders inside a cloud drive keep their own names.
        let inside = ContentStatePresentation.failure(.notFound, attempted: folder("Library/CloudStorage/OneDrive-Personal/Work"), home: home, fullDiskAccess: .denied)
        XCTAssertEqual(inside?.title, "“Work” no longer exists")
    }

    // MARK: Timeouts and other failures

    func testTimeoutsWaitingOnMacOSAndSlowDisks() {
        let waiting = ContentStatePresentation.failure(.timedOut, attempted: folder("Documents"), home: home, fullDiskAccess: .denied)
        XCTAssertEqual(waiting?.style, .waiting)
        XCTAssertEqual(waiting?.symbol, "hand.raised")
        XCTAssertEqual(waiting?.title, "Waiting for permission")
        XCTAssertEqual(waiting?.message, "macOS may be asking whether Helm can open “Documents”. Answer its question and Helm will carry on.")
        XCTAssertEqual(titles(waiting), ["Try Again"])
        let disk = ContentStatePresentation.failure(.timedOut, attempted: .directory(URL(fileURLWithPath: "/Volumes/X/Work")), home: home, fullDiskAccess: .denied)
        XCTAssertEqual(disk?.style, .problem)
        XCTAssertEqual(disk?.title, "The disk holding “Work” isn’t responding")
        // The Trash never asks, so a slow Trash is a slow disk.
        XCTAssertEqual(ContentStatePresentation.failure(.timedOut, attempted: .trash, home: home, fullDiskAccess: .denied)?.style, .problem)
    }

    func testTimeoutsNoQuestionExplainsAreNotCalledWaiting() {
        // Review case 6: a cloud provider that stalls has no macOS question on screen.
        let cloud = ContentStatePresentation.failure(.timedOut, attempted: folder("Library/CloudStorage/GoogleDrive-me@example.com"),
                                                     home: home, fullDiskAccess: .denied)
        XCTAssertEqual(cloud?.style, .problem)
        XCTAssertEqual(cloud?.symbol, "clock.badge.exclamationmark")
        XCTAssertEqual(cloud?.title, "“Google Drive” isn’t responding")
        XCTAssertEqual(titles(cloud), ["Try Again"])
        // With Full Disk Access on, macOS doesn't ask about Documents at all.
        let documents = ContentStatePresentation.failure(.timedOut, attempted: folder("Documents"), home: home, fullDiskAccess: .granted)
        XCTAssertEqual(documents?.style, .problem)
        XCTAssertEqual(documents?.title, "“Documents” isn’t responding")
        // Neither waits for access, so neither is tried again by itself or reopened after a quit.
        XCTAssertFalse(ContentStatePresentation.isBlockedByPrivacy(failedTab(at: folder("Library/CloudStorage"), attempted: folder("Library/CloudStorage/GoogleDrive-me@example.com"),
                                                                             error: .timedOut), home: home, fullDiskAccess: .denied))
        XCTAssertFalse(ContentStatePresentation.isBlockedByPrivacy(failedTab(at: folder("Movies"), attempted: folder("Documents"), error: .timedOut),
                                                                   home: home, fullDiskAccess: .granted))
        XCTAssertTrue(ContentStatePresentation.isBlockedByPrivacy(failedTab(at: folder("Movies"), attempted: folder("Documents"), error: .timedOut),
                                                                  home: home, fullDiskAccess: .denied))
    }

    func testMissingDisconnectedAndOtherFailures() {
        let gone = ContentStatePresentation.failure(.notFound, attempted: folder("Gone"), home: home, fullDiskAccess: .denied)
        XCTAssertEqual(gone?.title, "“Gone” no longer exists")
        XCTAssertEqual(gone?.buttons, [ContentStateButton(title: "Go to Home", action: .goHome, isPrimary: true)])
        let unplugged = ContentStatePresentation.failure(.volumeUnmounted, attempted: folder("Work"), home: home, fullDiskAccess: .denied)
        XCTAssertEqual(unplugged?.title, "The disk holding “Work” was disconnected")
        XCTAssertEqual(titles(unplugged), ["Try Again", "Go to Home"])
        let other = ContentStatePresentation.failure(.other("Not a directory"), attempted: folder("x"), home: home, fullDiskAccess: .denied)
        XCTAssertEqual(other?.title, "Helm couldn’t open “x”")
        XCTAssertEqual(other?.message, "Not a directory")
        XCTAssertNotNil(ContentStatePresentation.failure(.notIndexed, attempted: .recent, home: home, fullDiskAccess: .denied))
        XCTAssertNil(ContentStatePresentation.failure(.cancelled, attempted: folder("x"), home: home, fullDiskAccess: .denied))
    }

    func testErrorNamesAreReadBackIntoWords() {
        // Monitor and refresh problems arrive as the error's own name, sometimes wrapped in another.
        XCTAssertEqual(ContentStatePresentation.plain(.other("notFound")), .notFound)
        XCTAssertEqual(ContentStatePresentation.plain(.other("permissionDenied")), .permissionDenied)
        XCTAssertEqual(ContentStatePresentation.plain(.other("other(\"timedOut\")")), .timedOut)
        XCTAssertEqual(ContentStatePresentation.plain(.other("other(\"The disk is full.\")")), .other("The disk is full."))
        XCTAssertEqual(ContentStatePresentation.plain(.notFound), .notFound)
        let wrapped = ContentStatePresentation.failure(.other("other(\"notFound\")"), attempted: folder("Gone"), home: home, fullDiskAccess: .denied)
        XCTAssertEqual(wrapped?.title, "“Gone” no longer exists")
        // Names and system dumps aren't for reading; sentences are.
        XCTAssertEqual(ContentStatePresentation.readable("unavailable"), "Something went wrong while reading it. Try again in a moment.")
        XCTAssertEqual(ContentStatePresentation.readable("collision(noMutation: false)"), "Something went wrong while reading it. Try again in a moment.")
        XCTAssertEqual(ContentStatePresentation.readable("Error Domain=NSCocoaErrorDomain Code=256 \"x\""),
                       "Something went wrong while reading it. Try again in a moment.")
        XCTAssertEqual(ContentStatePresentation.readable("No space"), "No space")
        XCTAssertNil(ContentStatePresentation.readable("  "))
    }

    // MARK: Which failure is on show

    func testTabStates() {
        var tab = TabState(location: folder("Documents"), homeDirectory: home)
        tab.snapshot = PresentationSnapshot(location: folder("Documents"), phase: .ready)
        XCTAssertEqual(ContentStatePresentation.state(for: tab, home: home, fullDiskAccess: .denied)?.title, "Folder is empty")
        XCTAssertEqual(ContentStatePresentation.state(for: tab, home: home, fullDiskAccess: .denied)?.style, .empty)
        tab.isLoading = true
        XCTAssertNil(ContentStatePresentation.state(for: tab, home: home, fullDiskAccess: .denied))
        tab.isLoading = false
        tab.snapshot = PresentationSnapshot(location: folder("Documents"), phase: .loading(loadedCount: 0))
        XCTAssertNil(ContentStatePresentation.state(for: tab, home: home, fullDiskAccess: .denied))
        tab.snapshot = PresentationSnapshot(location: folder("Documents"), phase: .ready,
                                            sortedEntries: [FileEntry(url: home.appendingPathComponent("Documents/a.txt"))])
        XCTAssertNil(ContentStatePresentation.state(for: tab, home: home, fullDiskAccess: .denied))
        tab.snapshot = PresentationSnapshot(location: folder("Documents"), phase: .failed(.permissionDenied, attempted: .trash))
        XCTAssertEqual(ContentStatePresentation.state(for: tab, home: home, fullDiskAccess: .denied)?.title, "Helm can’t show the Trash")
        XCTAssertTrue(ContentStatePresentation.hidesListing(tab))
        XCTAssertEqual(ContentStatePresentation.placeOnShow(tab), .trash)

        var trash = TabState(location: .trash, homeDirectory: home)
        trash.snapshot = PresentationSnapshot(location: .trash, phase: .ready)
        XCTAssertEqual(ContentStatePresentation.state(for: trash, home: home, fullDiskAccess: .granted)?.title, "Trash is empty")
        var recent = TabState(location: .recent, homeDirectory: home)
        recent.snapshot = PresentationSnapshot(location: .recent, phase: .ready)
        XCTAssertEqual(ContentStatePresentation.state(for: recent, home: home, fullDiskAccess: .granted)?.title, "No recent items")
        XCTAssertEqual(ContentStatePresentation.empty(.noResults).title, "No results")
    }

    func testGoingSomewhereElseTakesTheCardDownButKeepsTheOldListingHidden() {
        // Review finding: the Trash card stayed up, and "Permission denied" in the status bar, while Desktop loaded.
        var tab = failedTab(at: folder("Documents"), entries: [FileEntry(url: url("Documents/a.txt"))], attempted: .trash)
        tab.isLoading = true
        tab.pendingNavigation = pending(folder("Desktop"))
        XCTAssertNil(ContentStatePresentation.state(for: tab, home: home, fullDiskAccess: .denied))
        XCTAssertNil(ContentStatePresentation.failureOnShow(tab))
        XCTAssertTrue(ContentStatePresentation.hidesListing(tab))
        XCTAssertNil(ContentStatePresentation.statusActivity(for: tab, home: home, fullDiskAccess: .denied))
        XCTAssertEqual(ContentStatePresentation.placeOnShow(tab), folder("Documents"))
        // Trying the same place again keeps its card up rather than flashing the listing underneath.
        tab.pendingNavigation = pending(.trash)
        XCTAssertEqual(ContentStatePresentation.state(for: tab, home: home, fullDiskAccess: .denied)?.title, "Helm can’t show the Trash")
        XCTAssertEqual(ContentStatePresentation.statusActivity(for: tab, home: home, fullDiskAccess: .denied), .denied)
    }

    func testBackFromACardShowsTheCoveredFolderAtOnce() {
        let tab = failedTab(at: folder("Documents"), entries: [FileEntry(url: url("Documents/a.txt"))], attempted: folder("Documents/Private"))
        XCTAssertEqual(ContentStatePresentation.coveredPlace(tab), folder("Documents"))
        XCTAssertEqual(ContentStatePresentation.enclosingFolder(of: folder("Documents/Private")), folder("Documents"))
        // A reload of the folder underneath, such as Show Hidden Files, leaves the card up.
        var reloading = tab
        reloading.isLoading = true
        XCTAssertNotNil(ContentStatePresentation.failureOnShow(reloading))
        XCTAssertTrue(ContentStatePresentation.hidesListing(reloading))
        XCTAssertEqual(ContentStatePresentation.placeOnShow(reloading), folder("Documents/Private"))
        // Back takes the card down first: no card, the listing is the right one, the sidebar follows.
        let back = TabReducer.reduce(tab, .returnToListing, context: ReducerContext(now: .distantPast, homeDirectory: home)).0
        XCTAssertNil(ContentStatePresentation.failureOnShow(back))
        XCTAssertFalse(ContentStatePresentation.hidesListing(back))
        XCTAssertNil(ContentStatePresentation.coveredPlace(back))
        XCTAssertEqual(ContentStatePresentation.placeOnShow(back), folder("Documents"))
        // A place that's the tab's own, refused on reload, has nothing underneath to go back to.
        let own = failedTab(at: .trash, attempted: .trash)
        XCTAssertNil(ContentStatePresentation.coveredPlace(own))
        XCTAssertNil(ContentStatePresentation.enclosingFolder(of: .trash))
        XCTAssertNil(ContentStatePresentation.enclosingFolder(of: .directory(URL(fileURLWithPath: "/"))))
    }

    func testMonitorProblemsKeepAGoodListing() {
        // Review case 5: a watch problem on a listed share left the listing behind raw text.
        let share = URL(fileURLWithPath: "/Volumes/NAS/Team", isDirectory: true)
        let listed = [FileEntry(url: share.appendingPathComponent("a.txt"))]
        let hiccup = failedTab(at: .directory(share), entries: listed, attempted: .directory(share),
                               error: .other(String(describing: MonitorFailure.unavailable)))
        XCTAssertNil(ContentStatePresentation.state(for: hiccup, home: home, fullDiskAccess: .denied))
        XCTAssertFalse(ContentStatePresentation.hidesListing(hiccup))
        XCTAssertEqual(ContentStatePresentation.statusActivity(for: hiccup, home: home, fullDiskAccess: .denied), .working("Couldn’t refresh"))
        XCTAssertEqual(StatusText.format(StatusPresentation(itemCount: 1, activity: .working("Couldn’t refresh"))), "Couldn’t refresh  •  1 item")
        // An empty folder whose watch stopped is still just empty.
        let empty = failedTab(at: .directory(share), attempted: .directory(share), error: .other("unavailable"))
        XCTAssertEqual(ContentStatePresentation.state(for: empty, home: home, fullDiskAccess: .denied)?.title, "Folder is empty")
        // A slow refresh keeps the listing too, and says so.
        let slow = failedTab(at: .directory(share), entries: listed, attempted: .directory(share), error: .timedOut)
        XCTAssertFalse(ContentStatePresentation.hidesListing(slow))
        XCTAssertEqual(ContentStatePresentation.statusActivity(for: slow, home: home, fullDiskAccess: .denied), .working("Not responding"))
        // A folder that's gone isn't a hiccup, however the news arrived.
        let gone = failedTab(at: .directory(share), entries: listed, attempted: .directory(share), error: .other("other(\"notFound\")"))
        XCTAssertEqual(ContentStatePresentation.state(for: gone, home: home, fullDiskAccess: .denied)?.title, "“Team” no longer exists")
        XCTAssertTrue(ContentStatePresentation.hidesListing(gone))
    }

    // MARK: Waiting for access, the status bar and the session

    func testOnlyPrivacyBlocksWaitForAccess() {
        var tab = TabState(location: folder("Documents"), homeDirectory: home)
        func failing(_ error: LoadError, _ attempted: Location, listing: [FileEntry] = [], access: PrivacyAccessStatus = .denied) -> Bool {
            tab.snapshot = PresentationSnapshot(location: folder("Documents"), phase: .failed(error, attempted: attempted), sortedEntries: listing)
            return ContentStatePresentation.isBlockedByPrivacy(tab, home: home, fullDiskAccess: access)
        }
        XCTAssertTrue(failing(.permissionDenied, .trash))
        XCTAssertTrue(failing(.permissionDenied, folder("Movies/TV")))
        XCTAssertTrue(failing(.timedOut, folder("Downloads")))
        XCTAssertFalse(failing(.timedOut, .directory(URL(fileURLWithPath: "/Volumes/X/Work"))))
        XCTAssertFalse(failing(.timedOut, .trash))
        XCTAssertFalse(failing(.notFound, folder("Desktop/Gone")))
        XCTAssertFalse(failing(.permissionDenied, folder("Projects/Private")))
        // Documents just listed, so a refusal inside it is ordinary permissions, which reopening won't change.
        XCTAssertFalse(failing(.permissionDenied, folder("Documents/Locked"), listing: [FileEntry(url: home.appendingPathComponent("Documents/a.txt"))]))
        XCTAssertFalse(ContentStatePresentation.isBlockedByPrivacy(TabState(location: .trash, homeDirectory: home), home: home, fullDiskAccess: .denied))
        // With Full Disk Access on, its own areas refuse for other reasons; rows of their own may still be off.
        XCTAssertFalse(failing(.permissionDenied, .trash, access: .granted))
        XCTAssertFalse(failing(.permissionDenied, folder("Library/Mail"), access: .granted))
        XCTAssertTrue(failing(.permissionDenied, folder("Movies/TV"), access: .granted))
    }

    func testAnErrorCodeAloneDoesNotMakeAFolderPrivate() {
        // Review case 3: EPERM outside the folders macOS is known to guard (an endpoint security tool, say) gets
        // careful words, and nothing waits for access, retries by itself or reopens there.
        let projects = URL(fileURLWithPath: "/Users/Shared/Projects", isDirectory: true)
        let blocked = projects.appendingPathComponent("Blocked", isDirectory: true)
        let tab = failedTab(at: .directory(projects), entries: [FileEntry(url: blocked, kind: .directory, isReadable: false, isPrivacyProtected: true)],
                            attempted: .directory(blocked))
        let state = ContentStatePresentation.state(for: tab, home: home, fullDiskAccess: .denied)
        XCTAssertEqual(state?.message, "macOS won’t let Helm in. If this folder holds another app’s data, Full Disk Access may help.")
        XCTAssertFalse(ContentStatePresentation.isBlockedByPrivacy(tab, home: home, fullDiskAccess: .denied))
        XCTAssertEqual(ContentStatePresentation.sessionLocation(for: tab, home: home, fullDiskAccess: .denied), .directory(projects))
    }

    func testStatusBarSaysWhyInsteadOfCountingTheFolderUnderneath() {
        var tab = TabState(location: folder("Documents"), homeDirectory: home)
        XCTAssertNil(ContentStatePresentation.statusActivity(for: tab, home: home, fullDiskAccess: .denied))
        func note(_ error: LoadError, _ attempted: Location, access: PrivacyAccessStatus = .denied) -> StatusActivity? {
            tab.snapshot = PresentationSnapshot(location: folder("Documents"), phase: .failed(error, attempted: attempted))
            return ContentStatePresentation.statusActivity(for: tab, home: home, fullDiskAccess: access)
        }
        XCTAssertEqual(note(.notFound, folder("Gone")), .unavailable("Not found"))
        XCTAssertEqual(note(.timedOut, folder("Downloads")), .unavailable("Waiting for permission"))
        XCTAssertEqual(note(.timedOut, folder("Downloads"), access: .granted), .unavailable("Not responding"))
        XCTAssertEqual(note(.timedOut, .directory(URL(fileURLWithPath: "/Volumes/X"))), .unavailable("Not responding"))
        XCTAssertEqual(note(.volumeUnmounted, folder("Work")), .unavailable("Disk disconnected"))
        XCTAssertEqual(note(.other("x"), folder("Work")), .unavailable("Couldn’t open"))
        XCTAssertEqual(note(.permissionDenied, .trash), .denied)
        XCTAssertNil(note(.cancelled, folder("Work")))
        XCTAssertEqual(StatusText.format(StatusPresentation(itemCount: 10, freeBytes: 100, activity: .unavailable("Not found"))), "Not found")
    }

    func testSessionReopensWhereHelmWasRefused() {
        var tab = TabState(location: folder("Documents"), homeDirectory: home)
        XCTAssertEqual(ContentStatePresentation.sessionLocation(for: tab, home: home, fullDiskAccess: .denied), folder("Documents"))
        tab.snapshot = PresentationSnapshot(location: folder("Documents"), phase: .failed(.permissionDenied, attempted: .trash))
        XCTAssertEqual(ContentStatePresentation.sessionLocation(for: tab, home: home, fullDiskAccess: .denied), .trash)
        // Ordinary permissions won't change by reopening, and a missing folder is gone.
        tab.snapshot = PresentationSnapshot(location: folder("Documents"), phase: .failed(.permissionDenied, attempted: folder("Projects/Private")))
        XCTAssertEqual(ContentStatePresentation.sessionLocation(for: tab, home: home, fullDiskAccess: .denied), folder("Documents"))
        tab.snapshot = PresentationSnapshot(location: folder("Documents"), phase: .failed(.notFound, attempted: folder("Desktop/Gone")))
        XCTAssertEqual(ContentStatePresentation.sessionLocation(for: tab, home: home, fullDiskAccess: .denied), folder("Documents"))
    }
}
