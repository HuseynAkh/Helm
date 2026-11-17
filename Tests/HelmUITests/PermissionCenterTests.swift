#if os(macOS)
import AppKit
import Foundation
import XCTest
import HelmAgent
import HelmCore
import HelmPersistence
import HelmTestKit
@testable import HelmUI

/// Full Disk Access is found out without asking macOS anything, and every way to it goes through a seam
/// that tests and fixture runs fill with a stand-in. Nothing here opens System Settings or relaunches.
@MainActor final class PermissionCenterTests: XCTestCase {
    func testOnlyARefusalByMacOSMeansOff() {
        XCTAssertEqual(FullDiskAccessProbe.decide([.refused, .opened]), .denied)
        XCTAssertEqual(FullDiskAccessProbe.decide([.opened, .missing]), .granted)
        XCTAssertEqual(FullDiskAccessProbe.decide([.missing, .inconclusive]), .unknown)
        XCTAssertEqual(FullDiskAccessProbe.decide([]), .unknown)
    }

    func testProbeOpensAndClosesWithoutReading() throws {
        let temp = try TempDirectory()
        let locked = temp.url.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755); try? temp.remove() }
        XCTAssertEqual(FullDiskAccessProbe.probe(temp.url.path), .opened)
        XCTAssertEqual(FullDiskAccessProbe.probe(temp.url.appendingPathComponent("missing").path), .missing)
        // EACCES is ordinary permissions, never read as Full Disk Access being off.
        XCTAssertEqual(FullDiskAccessProbe.probe(locked.path), .inconclusive)
    }

    func testSettingsLinksTryTheNewAddressFirst() {
        XCTAssertEqual(SystemPrivacyAccess.settingsURLs(for: .fullDiskAccess).map(\.absoluteString), [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"])
        XCTAssertEqual(SystemPrivacyAccess.settingsURLs(for: .media).last?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Media")
        // The probe only looks where macOS never asks, and never at the privacy database.
        XCTAssertEqual(SystemPrivacyAccess.probedFolders, [".Trash", "Library/Safari", "Library/Mail"])
    }

    /// What tells one build from another is the code signature's designated requirement, read from the signature the
    /// process already carries: the same every time it's read, one line of text Settings keeps as it is.
    func testTheBuildIsToldApartByItsDesignatedRequirement() throws {
        let running = SystemPrivacyAccess()
        let identity = try XCTUnwrap(running.buildIdentity, "the test runner is signed")
        XCTAssertEqual(running.buildIdentity, identity)
        XCTAssertEqual(SystemPrivacyAccess().buildIdentity, identity, "every read of the same build agrees")
        XCTAssertEqual(SettingsSchema.validated(.string(identity), for: .setupBuild), .string(identity))
        // The stand-in says nothing until a test sets it, and the shared permission passes on what it says.
        let stand = MemoryPrivacyAccess()
        XCTAssertNil(stand.buildIdentity)
        stand.buildIdentity = "cdhash H\"0a1b\""
        XCTAssertEqual(PermissionCenter(provider: stand).buildIdentity, "cdhash H\"0a1b\"")
    }

    func testChangesAreSentOncePerChange() async {
        let stand = MemoryPrivacyAccess(status: .denied)
        let center = PermissionCenter(provider: stand)
        var heard: [PrivacyAccessStatus] = []
        _ = center.changes.subscribe { heard.append($0) }
        XCTAssertEqual(center.fullDiskAccess, .unknown)
        await center.refresh()
        await center.refresh()
        stand.status = .granted
        await center.refresh()
        XCTAssertEqual(heard, [.denied, .granted])
        XCTAssertEqual(center.fullDiskAccess, .granted)
    }

    func testGuideAndSettingsGoThroughTheProvider() {
        let stand = MemoryPrivacyAccess()
        let center = PermissionCenter(provider: stand)
        center.showGuide(.media)
        XCTAssertEqual(stand.openedPanes, [.media])
        var guided: [PrivacyPane] = []
        center.presentGuide = { guided.append($0) }
        center.showGuide(.fullDiskAccess)
        XCTAssertEqual(guided, [.fullDiskAccess])
        XCTAssertEqual(stand.openedPanes, [.media])
        center.openTrashInFinder()
        XCTAssertEqual(stand.trashOpenedInFinder, 1)
    }

    func testWatchingNests() {
        let center = PermissionCenter(provider: MemoryPrivacyAccess())
        center.watch(true); center.watch(true)
        XCTAssertTrue(center.isWatching)
        center.watch(false)
        XCTAssertTrue(center.isWatching)
        center.watch(false)
        XCTAssertFalse(center.isWatching)
        center.watch(false)
        XCTAssertFalse(center.isWatching)
    }
}

/// A folder macOS keeps private shows as a plain folder, not as a write-only drop box.
@MainActor final class PrivacyFolderIconTests: XCTestCase {
    func testPrivateFoldersKeepThePlainFolder() {
        let cache = IconCache()
        let tv = FileEntry(url: URL(fileURLWithPath: "/tmp/helm-fixture/TV"), kind: .directory, isReadable: false,
                           contentTypeIdentifier: "public.folder", isPrivacyProtected: true)
        XCTAssertTrue(IconCache.showsPlainFolder(tv))
        XCTAssertNil(cache.load(for: tv, points: 96, scale: 2, previews: true) { _ in XCTFail("Nothing should load") })
        XCTAssertFalse(IconCache.wantsPreview(tv, points: 96))
        XCTAssertTrue(cache.icon(for: tv) === cache.placeholder(for: tv))
    }

    func testOrdinaryUnreadableFoldersStillAskTheSystem() {
        let cache = IconCache()
        // Write-only and locked folders keep the system's drop-box and no-entry badges, as in Finder.
        let dropBox = FileEntry(url: URL(fileURLWithPath: "/tmp/helm-fixture/Drop Box"), kind: .directory, isReadable: false)
        XCTAssertFalse(IconCache.showsPlainFolder(dropBox))
        let ticket = cache.load(for: dropBox, points: 64, scale: 2, previews: false) { _ in }
        XCTAssertNotNil(ticket)
        cache.cancel(ticket)
        // Quick Look can't read what Helm can't.
        let unreadable = FileEntry(url: URL(fileURLWithPath: "/tmp/helm-fixture/secret.pdf"), kind: .regular, isReadable: false,
                                   contentTypeIdentifier: "com.adobe.pdf")
        XCTAssertFalse(IconCache.wantsPreview(unreadable, points: 96))
        let readable = FileEntry(url: URL(fileURLWithPath: "/tmp/helm-fixture/open.pdf"), kind: .regular, contentTypeIdentifier: "com.adobe.pdf")
        XCTAssertTrue(IconCache.wantsPreview(readable, points: 96))
    }
}

/// The status page over the content area.
@MainActor final class ContentStatePageTests: XCTestCase {
    func testEmptyStatesLetClicksThroughAndProblemsDoNot() {
        let page = ContentStatePage()
        page.show(ContentStatePresentation.empty(.folder), perform: { _ in }, retryWaiting: {})
        XCTAssertFalse(page.view.isHidden)
        XCTAssertTrue(page.view.passesThrough)
        XCTAssertNil(page.view.hitTest(NSPoint(x: 1, y: 1)))
        let problem = ContentStatePresentation.failure(.notFound, attempted: .directory(URL(fileURLWithPath: "/x/Gone")),
                                                       home: URL(fileURLWithPath: "/x"), fullDiskAccess: .denied)
        page.show(problem, perform: { _ in }, retryWaiting: {})
        XCTAssertFalse(page.view.passesThrough)
        page.show(nil, perform: { _ in }, retryWaiting: {})
        XCTAssertTrue(page.view.isHidden)
        XCTAssertNil(page.state)
    }

    func testAWaitingCardTriesAgainByItself() async throws {
        let page = ContentStatePage()
        page.retryInterval = 0.05
        var retries = 0
        let waiting = ContentStatePresentation.failure(.timedOut, attempted: .directory(URL(fileURLWithPath: "/Users/me/Documents")),
                                                       home: URL(fileURLWithPath: "/Users/me"), fullDiskAccess: .denied)
        XCTAssertEqual(waiting?.style, .waiting)
        page.show(waiting, perform: { _ in }, retryWaiting: { retries += 1 })
        page.show(waiting, perform: { _ in }, retryWaiting: { retries += 1 })
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(retries, 1)
        // Once the question is answered and the card goes, no more tries.
        page.show(waiting, perform: { _ in }, retryWaiting: { retries += 1 })
        page.show(nil, perform: { _ in }, retryWaiting: { retries += 1 })
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(retries, 1)
    }

    func testQuietRetriesBackOffAndStop() async throws {
        let page = ContentStatePage()
        page.retryInterval = 0.01
        page.longestRetryInterval = 0.04
        page.retryLimit = 3
        let waiting = ContentStatePresentation.failure(.timedOut, attempted: .directory(URL(fileURLWithPath: "/Users/me/Documents")),
                                                       home: URL(fileURLWithPath: "/Users/me"), fullDiskAccess: .denied)
        var times: [Date] = []
        // As the window does: each try that fails again shows the same card again.
        func retry() { times.append(Date()); page.show(waiting, perform: { _ in }, retryWaiting: retry) }
        page.show(waiting, perform: { _ in }, retryWaiting: retry)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(times.count, 3, "a stuck folder isn't tried forever")
        if times.count == 3 {
            XCTAssertGreaterThan(times[2].timeIntervalSince(times[1]), times[1].timeIntervalSince(times[0]) * 0.9)
        }
        // Try Again starts the count over.
        page.restartRetries()
        page.show(waiting, perform: { _ in }, retryWaiting: retry)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(times.count, 3)
    }

    func testANewProblemIsAnnouncedOnce() {
        let page = ContentStatePage()
        let gone = ContentStatePresentation.failure(.notFound, attempted: .directory(URL(fileURLWithPath: "/x/Gone")),
                                                    home: URL(fileURLWithPath: "/x"), fullDiskAccess: .denied)
        page.show(ContentStatePresentation.empty(.folder), perform: { _ in }, retryWaiting: {})
        XCTAssertNil(page.lastAnnouncement, "an empty folder is no news")
        page.show(gone, perform: { _ in }, retryWaiting: {})
        XCTAssertEqual(page.lastAnnouncement, "“Gone” no longer exists. It may have been moved, renamed or deleted.")
    }
}

#endif
