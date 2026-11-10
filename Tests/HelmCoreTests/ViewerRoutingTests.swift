import Foundation
import XCTest
@testable import HelmCore

/// Who shows a request sent to the file viewer: Helm, or Finder when the request started in Finder.
final class ViewerRoutingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let downloads = URL(fileURLWithPath: "/Users/me/Downloads", isDirectory: true)
    private var archive: URL { downloads.appendingPathComponent("Photos.zip") }
    private var expanded: URL { downloads.appendingPathComponent("Photos", isDirectory: true) }
    private let archiveUtility = "com.apple.archiveutility"

    private func route(_ request: ViewerRequest, from sender: String?, _ ledger: HandoffLedger = HandoffLedger(),
                       at time: Date? = nil) -> ViewerRoute {
        ViewerRouter.route(request, sender: sender, ledger: ledger, now: time ?? now)
    }
    private func ledger(_ handoffs: HelperHandoff...) -> HandoffLedger {
        var ledger = HandoffLedger()
        for handoff in handoffs { ledger.record(handoff) }
        return ledger
    }
    private func handoff(_ helper: String = "com.apple.archiveutility", _ item: URL? = nil, secondsAgo: TimeInterval = 30,
                         namesBefore: Set<String>? = nil) -> HelperHandoff {
        HelperHandoff(helper: helper, item: item ?? archive, date: now.addingTimeInterval(-secondsAgo), namesBefore: namesBefore)
    }

    // MARK: Finder itself

    func testFinderOpeningSomethingInHelmStaysInHelm() {
        // Open With › Helm in Finder, or a drop on Helm's icon in a Finder window: you chose Helm.
        XCTAssertEqual(route(.open([downloads]), from: "com.apple.finder"), .helm(reveal: false, handoff: nil))
    }
    func testADoubleClickOnHelmInFinderStaysInHelm() {
        // A running Helm gets a double-click on Helm.app in a Finder window as a reopen from Finder. Sent back to
        // Finder, it brought Finder forward instead, so Helm couldn't be opened from a Finder window.
        XCTAssertEqual(route(.reopen, from: "com.apple.finder"), .helm(reveal: false, handoff: nil))
        XCTAssertEqual(route(.reopen, from: "COM.APPLE.FINDER"), .helm(reveal: false, handoff: nil), "bundle identifiers ignore case")
        // Even with a hand-off waiting: Finder isn't the helper Helm handed the archive to.
        XCTAssertEqual(route(.reopen, from: "com.apple.finder", ledger(handoff())), .helm(reveal: false, handoff: nil))
        XCTAssertEqual(route(.reveal([archive]), from: "com.apple.finder"), .helm(reveal: true, handoff: nil))
    }

    // MARK: A helper Finder started

    func testArchiveUtilityStartedInFinderGoesBackToFinder() {
        // A double-click on an archive in Finder: Helm handed nothing to Archive Utility.
        XCTAssertEqual(route(.open([expanded]), from: archiveUtility), .finder([downloads]))
        XCTAssertEqual(route(.reveal([expanded]), from: archiveUtility), .finder([downloads]))
        // Its reopen as it quits names nothing: Finder only comes forward. This one opened a Home window before.
        XCTAssertEqual(route(.reopen, from: archiveUtility), .finder([]))
    }
    func testDiskImageMounterIsFindersHelperToo() {
        let volume = URL(fileURLWithPath: "/Volumes/Installer", isDirectory: true)
        XCTAssertEqual(route(.open([volume]), from: "com.apple.DiskImageMounter"), .finder([URL(fileURLWithPath: "/Volumes", isDirectory: true)]))
    }
    func testAHandoffToAnotherHelperOrFolderDoesNotCount() {
        let other = URL(fileURLWithPath: "/Users/me/Desktop/Other", isDirectory: true)
        XCTAssertEqual(route(.open([other]), from: archiveUtility, ledger(handoff())), .finder([other.deletingLastPathComponent()]),
                       "what Archive Utility expanded somewhere else came from somewhere else")
        XCTAssertEqual(route(.open([expanded]), from: archiveUtility, ledger(handoff("com.apple.DiskImageMounter"))), .finder([downloads]))
    }

    // MARK: A helper Helm started

    func testArchiveUtilityStartedFromHelmComesBackToHelm() {
        let given = handoff(namesBefore: ["Photos.zip"])
        XCTAssertEqual(route(.open([expanded]), from: archiveUtility, ledger(given)), .helm(reveal: true, handoff: given))
        XCTAssertEqual(route(.open([archive]), from: archiveUtility, ledger(given)), .helm(reveal: true, handoff: given))
        XCTAssertEqual(route(.reopen, from: archiveUtility, ledger(given)), .helm(reveal: true, handoff: given))
        XCTAssertEqual(given.added(in: ["Photos.zip", "Photos", "Album 10", "Album 9"]), ["Album 9", "Album 10", "Photos"])
        XCTAssertEqual(handoff().added(in: ["Photos"]), [], "nothing is picked out when the folder wasn't listed before")
    }
    func testAHandoffLastsTenMinutes() {
        let given = handoff(secondsAgo: HandoffLedger.lifetime - 1)
        XCTAssertEqual(route(.reopen, from: archiveUtility, ledger(given)), .helm(reveal: true, handoff: given))
        var stale = ledger(given)
        XCTAssertEqual(route(.reopen, from: archiveUtility, stale, at: now.addingTimeInterval(2)), .finder([]))
        stale.prune(now: now.addingTimeInterval(2))
        XCTAssertTrue(stale.handoffs.isEmpty)
    }
    func testForgettingAHelperEndsItsHandoffs() {
        var record = ledger(handoff(), handoff("com.apple.DiskImageMounter", URL(fileURLWithPath: "/Users/me/Disk.dmg")))
        record.forget(helper: "com.apple.ArchiveUtility")
        XCTAssertEqual(route(.reopen, from: archiveUtility, record), .finder([]))
        XCTAssertEqual(record.handoffs.map(\.helper), ["com.apple.diskimagemounter"])
    }
    func testAHelperQuittingEndsWhatItWasHandedBefore() {
        // Its last request never came. Left alone, the hand-off would take Finder's next expansion for Helm's.
        var record = ledger(handoff(secondsAgo: 30), handoff("com.apple.DiskImageMounter", URL(fileURLWithPath: "/Users/me/Disk.dmg")))
        record.forget(helper: "com.apple.ArchiveUtility", handedBefore: now.addingTimeInterval(-10))
        XCTAssertEqual(record.handoffs.map(\.helper), ["com.apple.diskimagemounter"])
        XCTAssertEqual(route(.reopen, from: archiveUtility, record), .finder([]))
        // What Helm handed a new copy of it after the quit stays.
        var later = ledger(handoff(secondsAgo: 5))
        later.forget(helper: archiveUtility, handedBefore: now.addingTimeInterval(-10))
        XCTAssertEqual(later.handoffs.count, 1)
    }
    func testTheLatestMatchingHandoffWinsAndARepeatReplacesTheOld() {
        let older = handoff(secondsAgo: 120), newer = handoff(archiveUtility, URL(fileURLWithPath: "/Users/me/Desktop/Other.zip"), secondsAgo: 10)
        let record = ledger(older, newer)
        XCTAssertEqual(route(.reopen, from: archiveUtility, record), .helm(reveal: true, handoff: newer))
        XCTAssertEqual(route(.open([expanded]), from: archiveUtility, record), .helm(reveal: true, handoff: older))
        let again = handoff(secondsAgo: 5)
        XCTAssertEqual(ledger(older, again).handoffs, [again], "the same archive handed over again replaces the first")
    }
    func testOnlyFindersHelpersAreNoted() {
        XCTAssertTrue(FinderFamily.isHelper("com.apple.ArchiveUtility"))
        XCTAssertTrue(FinderFamily.isHelper("com.apple.DiskImageMounter"))
        XCTAssertFalse(FinderFamily.isHelper("com.apple.finder"))
        XCTAssertFalse(FinderFamily.isHelper("com.apple.Safari"))
        XCTAssertFalse(FinderFamily.isHelper(nil))
        XCTAssertTrue(FinderFamily.isMember("com.apple.finder"))
    }

    // MARK: Anyone else

    func testAnotherAppStaysWithHelm() {
        let file = downloads.appendingPathComponent("Report.pdf")
        XCTAssertEqual(route(.open([file]), from: "com.apple.Safari"), .helm(reveal: false, handoff: nil))
        XCTAssertEqual(route(.reveal([file]), from: "com.apple.mail"), .helm(reveal: true, handoff: nil))
        XCTAssertEqual(route(.reopen, from: "com.apple.dock"), .helm(reveal: false, handoff: nil))
        // A hand-off to a helper says nothing about another app.
        XCTAssertEqual(route(.open([expanded]), from: "com.apple.Safari", ledger(handoff())), .helm(reveal: false, handoff: nil))
    }
    func testAnUnknownSenderStaysWithHelm() {
        XCTAssertEqual(route(.open([archive]), from: nil), .helm(reveal: false, handoff: nil))
        XCTAssertEqual(route(.reveal([archive]), from: nil), .helm(reveal: true, handoff: nil))
        XCTAssertEqual(route(.reopen, from: nil), .helm(reveal: false, handoff: nil))
    }

    // MARK: Launches

    func testALaunchWhileArchiveUtilityRunsIsArchiveUtilitys() {
        XCTAssertTrue(FinderFamily.isArchiveUtilityLaunch(running: ["com.apple.finder", "com.apple.archiveutility"]))
        XCTAssertTrue(FinderFamily.isArchiveUtilityLaunch(running: ["com.apple.ArchiveUtility"]), "bundle IDs compare without case")
        XCTAssertFalse(FinderFamily.isArchiveUtilityLaunch(running: ["com.apple.finder", "com.apple.Safari"]))
        XCTAssertFalse(FinderFamily.isArchiveUtilityLaunch(running: []))
    }

    // MARK: Paths

    func testFoldersAreListedOnceInOrder() {
        let a = URL(fileURLWithPath: "/Users/me/A/one.txt"), b = URL(fileURLWithPath: "/Users/me/B/two.txt")
        let c = URL(fileURLWithPath: "/Users/me/A/three.txt")
        XCTAssertEqual(ViewerRouter.folders(of: [a, b, c]).map(\.path), ["/Users/me/A", "/Users/me/B"])
        XCTAssertEqual(ViewerRequest.reopen.items, [])
    }
    func testOnePathSpelledTwoWaysStillMatches() {
        // AppKit hands Helm /private/tmp paths; a window may know the same folder as /tmp.
        let given = HelperHandoff(helper: archiveUtility, item: URL(fileURLWithPath: "/tmp/Case/Photos.zip"), date: now)
        let revealed = URL(fileURLWithPath: "/private/tmp/Case/Photos", isDirectory: true)
        XCTAssertEqual(route(.open([revealed]), from: archiveUtility, ledger(given)), .helm(reveal: true, handoff: given))
        #if canImport(Darwin)
        let decomposed = HelperHandoff(helper: archiveUtility, item: URL(fileURLWithPath: "/Users/me/Re\u{301}sume\u{301}s/a.zip"), date: now)
        let composed = URL(fileURLWithPath: "/Users/me/R\u{E9}sum\u{E9}s/a", isDirectory: true)
        XCTAssertEqual(route(.open([composed]), from: archiveUtility, ledger(decomposed)), .helm(reveal: true, handoff: decomposed))
        #endif
    }
}
