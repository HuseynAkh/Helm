#if os(macOS)
import AppKit
import Foundation
import XCTest
import HelmCore
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

/// A model with stand-ins for everything it could change: the permission, the file viewer and Dock, and the mover.
@MainActor private final class SetupRig {
    let privacy: MemoryPrivacyAccess
    let role: any FileViewerRegistering
    let mover: MemoryAppMover
    let center: PermissionCenter
    let model: OnboardingModel
    var closed = 0
    var seen = 0
    /// What Set Up saved for the copy in Applications, in order; nil is a clear.
    var carried: [[SetupRow]?] = []
    var voiceOver = false
    var said: [String] = []

    init(access: PrivacyAccessStatus = .denied, placement: AppPlacement = .applications,
         appURL: URL? = URL(fileURLWithPath: "/Applications/Helm.app"), withViewer: Bool = true,
         role: (any FileViewerRegistering)? = nil) {
        privacy = MemoryPrivacyAccess(status: access, appURL: appURL)
        mover = MemoryAppMover(placement: placement)
        center = PermissionCenter(provider: privacy)
        self.role = role ?? MemoryFileViewerRole()
        model = OnboardingModel(permissions: center, fileViewer: withViewer ? FileViewerModel(role: self.role) : nil, mover: mover)
        model.finishDelay = 0
        model.close = { [unowned self] in self.closed += 1; self.model.closed() }
        model.seen = { [unowned self] in self.seen += 1 }
        model.carry = { [unowned self] rows in self.carried.append(rows) }
        model.announce = { [unowned self] text in self.said.append(text) }
        model.isVoiceOverRunning = { [unowned self] in self.voiceOver }
    }
    /// Reads the permission, then opens the checklist afresh, as the window does.
    func open() async {
        await center.refresh()
        model.begin(.setup)
    }
    /// What the window does when the permission changes.
    func access(_ status: PrivacyAccessStatus) async {
        privacy.status = status
        await center.refresh()
        model.permissionsChanged()
    }
}

/// macOS taking its time over the folder handler, as `setDefaultApplication` can. Answers when told to.
@MainActor private final class SlowRole: FileViewerRegistering {
    var isHelmDefault = false
    var opensAtLogin = false
    var isFirstInDock = false
    var canRegister: Bool { true }
    private var pending: (@MainActor (String?) -> Void)?
    func makeHelmDefault(_ done: @escaping @MainActor (String?) -> Void) { isHelmDefault = true; pending = done }
    func restoreFinder(_ done: @escaping @MainActor (String?) -> Void) { isHelmDefault = false; done(nil) }
    func setOpensAtLogin(_ on: Bool) -> String? { opensAtLogin = on; return nil }
    func setFirstInDock(_ on: Bool) -> String? { isFirstInDock = on; return nil }
    func answer() { pending?(nil); pending = nil }
}

/// The welcome checklist, without a window: which rows show, what Set Up does through the stand-ins, that Not Now
/// changes nothing, and that a needed move goes first.
@MainActor final class OnboardingModelTests: XCTestCase {
    func testRowsShowOnlyWhatAppliesToThisCopy() async {
        let rig = SetupRig()
        await rig.open()
        XCTAssertEqual(rig.model.rows, [.fileViewer, .fullDiskAccess])
        XCTAssertEqual(rig.model.checked, Set(SetupRow.allCases), "every box starts ticked")
        // Running from a disk image adds the move, ticked like the rest.
        rig.mover.placement = .diskImage
        XCTAssertEqual(rig.model.rows, [.fileViewer, .fullDiskAccess, .moveToApplications])
        XCTAssertTrue(rig.model.hasCheckbox(.moveToApplications))
        XCTAssertTrue(rig.model.isChecked(.moveToApplications))
        // The guide is the Full Disk Access row on its own, with no checkbox.
        rig.model.begin(.guide)
        XCTAssertEqual(rig.model.rows, [.fullDiskAccess])
        XCTAssertFalse(rig.model.hasCheckbox(.fullDiskAccess))
        // Outside an app bundle there's nothing to switch on, and without the switches no file viewer row.
        let bare = SetupRig(appURL: nil, withViewer: false)
        await bare.open()
        XCTAssertEqual(bare.model.rows, [])
        XCTAssertTrue(bare.model.nothingToDo)
    }

    func testRowsThatAreDoneShowOnlyTheirCheckMark() async {
        let rig = SetupRig(access: .granted)
        rig.role.makeHelmDefault { _ in }
        _ = rig.role.setFirstInDock(true)
        await rig.open()
        XCTAssertEqual(rig.model.state(of: .fileViewer), .done)
        XCTAssertEqual(rig.model.state(of: .fullDiskAccess), .done)
        XCTAssertFalse(rig.model.hasCheckbox(.fileViewer))
        XCTAssertFalse(rig.model.hasCheckbox(.fullDiskAccess))
        XCTAssertTrue(rig.model.nothingToDo)
        XCTAssertEqual(rig.model.primaryTitle, "Done")
        XCTAssertNil(rig.model.secondaryTitle)
        XCTAssertEqual(rig.model.statusLine, "Full Disk Access is on")
        // Helm as the file viewer but not in the Dock still leaves that row to do.
        _ = rig.role.setFirstInDock(false)
        rig.model.refresh()
        XCTAssertEqual(rig.model.state(of: .fileViewer), .pending)
        XCTAssertTrue(rig.model.hasCheckbox(.fileViewer))
        XCTAssertFalse(rig.model.nothingToDo)
    }

    func testSetUpDoesEveryCheckedRowThroughTheStandIns() async throws {
        let rig = SetupRig()
        await rig.open()
        XCTAssertEqual(rig.model.primaryTitle, "Set Up")
        XCTAssertEqual(rig.model.secondaryTitle, "Not Now")
        XCTAssertTrue(rig.model.press("Set Up"))
        await rig.model.work?.value
        XCTAssertEqual(rig.seen, 1)
        XCTAssertTrue(rig.role.isHelmDefault)
        XCTAssertTrue(rig.role.isFirstInDock)
        XCTAssertFalse(rig.role.opensAtLogin, "only what the rows say")
        XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess])
        XCTAssertEqual(rig.model.state(of: .fileViewer), .done)
        XCTAssertEqual(rig.model.state(of: .fullDiskAccess), .waiting)
        XCTAssertEqual(rig.model.statusLine, "Waiting for Full Disk Access")
        XCTAssertTrue(rig.model.showsAccessHelp)
        XCTAssertTrue(rig.model.isWaitingForAccess)
        XCTAssertEqual(rig.model.primaryTitle, "Done")
        XCTAssertNil(rig.model.secondaryTitle)
        XCTAssertFalse(rig.model.canChoose)
        XCTAssertEqual(rig.mover.moves, 0)
        // The window stays until Full Disk Access is on, then shows the check mark and closes by itself.
        XCTAssertEqual(rig.closed, 0)
        XCTAssertFalse(rig.model.isFinishing)
        await rig.access(.granted)
        XCTAssertEqual(rig.model.state(of: .fullDiskAccess), .done)
        XCTAssertFalse(rig.model.showsAccessHelp)
        XCTAssertTrue(rig.model.isFinishing)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.closed, 1)
        // Done closes it any time before that.
        let early = SetupRig()
        await early.open()
        XCTAssertTrue(early.model.press("Set Up"))
        await early.model.work?.value
        XCTAssertTrue(early.model.press("Done"))
        XCTAssertEqual(early.closed, 1)
    }

    func testUncheckedRowsAreLeftAlone() async {
        let rig = SetupRig()
        await rig.open()
        rig.model.setChecked(.fileViewer, false)
        XCTAssertTrue(rig.model.press("Set Up"))
        await rig.model.work?.value
        XCTAssertFalse(rig.role.isHelmDefault)
        XCTAssertFalse(rig.role.isFirstInDock)
        XCTAssertEqual(rig.model.state(of: .fileViewer), .pending)
        XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess])
        // Once Set Up is pressed the choices stay as they were.
        rig.model.setChecked(.fileViewer, true)
        XCTAssertFalse(rig.model.isChecked(.fileViewer))
        // With nothing ticked, Set Up only closes the window.
        let idle = SetupRig()
        await idle.open()
        idle.model.setChecked(.fileViewer, false)
        idle.model.setChecked(.fullDiskAccess, false)
        XCTAssertTrue(idle.model.press("Set Up"))
        XCTAssertEqual(idle.closed, 1)
        XCTAssertEqual(idle.seen, 1)
        XCTAssertFalse(idle.role.isHelmDefault)
        XCTAssertTrue(idle.privacy.openedPanes.isEmpty)
    }

    func testNotNowChangesNothing() async {
        let rig = SetupRig(placement: .diskImage)
        await rig.open()
        XCTAssertTrue(rig.model.press("Not Now"))
        XCTAssertEqual(rig.closed, 1)
        XCTAssertEqual(rig.seen, 1)
        XCTAssertNil(rig.model.work)
        XCTAssertFalse(rig.role.isHelmDefault)
        XCTAssertFalse(rig.role.isFirstInDock)
        XCTAssertFalse(rig.role.opensAtLogin)
        XCTAssertTrue(rig.privacy.openedPanes.isEmpty)
        XCTAssertEqual(rig.mover.moves, 0)
        XCTAssertTrue(rig.mover.relaunches.isEmpty)
        XCTAssertFalse(rig.model.press("Done"), "nothing was started")
    }

    func testTheMoveGoesFirstAndTheMovedCopyCarriesOn() async {
        let rig = SetupRig(placement: .diskImage)
        rig.mover.quitsOnRelaunch = true
        await rig.open()
        XCTAssertTrue(rig.model.press("Set Up"))
        await rig.model.work?.value
        XCTAssertEqual(rig.mover.moves, 1)
        XCTAssertEqual(rig.mover.relaunches, [[.fileViewer, .fullDiskAccess, .moveToApplications]])
        // The rows are saved before anything quits, so the copy carries on even if it's opened by hand.
        XCTAssertEqual(rig.carried, [nil, [.fileViewer, .fullDiskAccess, .moveToApplications]])
        // Nothing else changes here: the copy in Applications does it after it reopens, so it points at that copy.
        XCTAssertFalse(rig.role.isHelmDefault)
        XCTAssertFalse(rig.role.isFirstInDock)
        XCTAssertTrue(rig.privacy.openedPanes.isEmpty)
        // On its way out.
        XCTAssertEqual(rig.model.state(of: .moveToApplications), .working)
        // The copy in Applications, opened with --continue-setup.
        let flag = SetupRow.flagValue(rig.mover.relaunches[0])
        XCTAssertEqual(flag, "viewer,access,move")
        let copy = SetupRig()
        await copy.center.refresh()
        copy.model.continueSetup(SetupRow.rows(fromFlag: flag))
        await copy.model.work?.value
        XCTAssertEqual(copy.model.rows, [.fileViewer, .fullDiskAccess, .moveToApplications])
        XCTAssertEqual(copy.model.state(of: .moveToApplications), .done)
        XCTAssertTrue(copy.role.isHelmDefault)
        XCTAssertTrue(copy.role.isFirstInDock)
        XCTAssertEqual(copy.privacy.openedPanes, [.fullDiskAccess])
        XCTAssertEqual(copy.model.primaryTitle, "Done")
        XCTAssertEqual(copy.mover.moves, 0)
        // A row left unticked before the move stays unticked and untouched.
        let partial = SetupRig()
        await partial.center.refresh()
        partial.model.continueSetup([.fullDiskAccess, .moveToApplications])
        await partial.model.work?.value
        XCTAssertFalse(partial.model.isChecked(.fileViewer))
        XCTAssertFalse(partial.role.isHelmDefault)
        XCTAssertEqual(partial.privacy.openedPanes, [.fullDiskAccess])
        // A copy that still isn't in Applications starts again from the checklist, with the same boxes ticked.
        let stuck = SetupRig(placement: .translocated)
        await stuck.center.refresh()
        stuck.model.continueSetup([.fileViewer, .moveToApplications])
        XCTAssertNil(stuck.model.work)
        XCTAssertEqual(stuck.model.primaryTitle, "Set Up")
        XCTAssertEqual(stuck.model.state(of: .moveToApplications), .pending)
        XCTAssertFalse(stuck.model.isChecked(.fullDiskAccess))
    }

    func testAFailedOrRefusedMoveChangesNothingElse() async {
        let rig = SetupRig(placement: .elsewhere)
        rig.mover.result = .failed("Helm couldn’t be copied to /Applications: the disk is full.")
        await rig.open()
        XCTAssertTrue(rig.model.press("Set Up"))
        await rig.model.work?.value
        XCTAssertEqual(rig.model.state(of: .moveToApplications), .failed("Helm couldn’t be copied to /Applications: the disk is full."))
        XCTAssertFalse(rig.role.isHelmDefault)
        XCTAssertTrue(rig.privacy.openedPanes.isEmpty)
        XCTAssertTrue(rig.mover.relaunches.isEmpty)
        XCTAssertEqual(rig.said.last, "Move to Applications didn’t work. Helm couldn’t be copied to /Applications: the disk is full.")
        // The person can untick the move and set up the rest from where Helm is, which stays put in Downloads.
        XCTAssertTrue(rig.model.canChoose)
        XCTAssertEqual(rig.model.primaryTitle, "Set Up")
        rig.model.setChecked(.moveToApplications, false)
        XCTAssertTrue(rig.model.press("Set Up"))
        await rig.model.work?.value
        XCTAssertEqual(rig.mover.moves, 1)
        XCTAssertTrue(rig.role.isHelmDefault)
        XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess])
        // Saying no to replacing the Helm already in Applications leaves everything as it was.
        let declined = SetupRig(placement: .elsewhere)
        declined.mover.result = .cancelled
        await declined.open()
        XCTAssertTrue(declined.model.press("Set Up"))
        await declined.model.work?.value
        XCTAssertEqual(declined.model.state(of: .moveToApplications), .pending)
        XCTAssertFalse(declined.role.isHelmDefault)
        XCTAssertTrue(declined.mover.relaunches.isEmpty)
        XCTAssertTrue(declined.model.canChoose)
    }

    /// Review finding onb-1: from a disk image or macOS's temporary copy, the Dock would point at a copy that goes away,
    /// so Use Helm instead of Finder goes only together with the move. The copy in Applications does it.
    func testUseHelmInsteadOfFinderNeedsTheMoveFromACopyThatGoesAway() async {
        for placement in [AppPlacement.translocated, .diskImage] {
            let rig = SetupRig(placement: placement)
            await rig.open()
            XCTAssertTrue(rig.model.isAvailable(.fileViewer))
            rig.model.setChecked(.moveToApplications, false)
            XCTAssertFalse(rig.model.isAvailable(.fileViewer), "\(placement)")
            XCTAssertNotNil(rig.model.unavailableReason(.fileViewer))
            XCTAssertTrue(rig.model.hasCheckbox(.fileViewer), "shown, but it can't be ticked")
            XCTAssertFalse(rig.model.isChecked(.fileViewer))
            rig.model.setChecked(.fileViewer, true)
            XCTAssertFalse(rig.model.isChecked(.fileViewer))
            XCTAssertTrue(rig.model.press("Set Up"))
            await rig.model.work?.value
            XCTAssertFalse(rig.role.isHelmDefault)
            XCTAssertFalse(rig.role.isFirstInDock)
            XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess], "Full Disk Access doesn't depend on where Helm is")
            XCTAssertEqual(rig.mover.moves, 0)
        }
        // Ticking the move again brings back the person's own choice.
        let rig = SetupRig(placement: .diskImage)
        await rig.open()
        rig.model.setChecked(.moveToApplications, false)
        rig.model.setChecked(.moveToApplications, true)
        XCTAssertTrue(rig.model.isChecked(.fileViewer))
        XCTAssertTrue(rig.model.unavailableReason(.fileViewer) == nil)
        // From Downloads, Helm stays where it is, so it can go in the Dock from there.
        let downloads = SetupRig(placement: .elsewhere)
        await downloads.open()
        downloads.model.setChecked(.moveToApplications, false)
        XCTAssertTrue(downloads.model.isChecked(.fileViewer))
    }

    /// Review finding onb-3: a quit that doesn't happen (the person cancelled it, or the copy didn't open) no longer
    /// leaves the move spinning. The copy in Applications still finds the rows, and trying again only reopens it.
    func testAMoveWhoseQuitIsCancelledCanBeTriedAgain() async {
        let rig = SetupRig(placement: .diskImage)
        await rig.open()
        XCTAssertTrue(rig.model.press("Set Up"))
        await rig.model.work?.value
        XCTAssertEqual(rig.mover.relaunches.count, 1)
        guard case .failed(let message) = rig.model.state(of: .moveToApplications) else {
            return XCTFail("the move can't still be working: \(rig.model.state(of: .moveToApplications))")
        }
        XCTAssertEqual(message, "Couldn’t reopen from /Applications, so quit Helm and open it there.")
        XCTAssertTrue(rig.model.canChoose)
        XCTAssertEqual(rig.model.primaryTitle, "Set Up")
        XCTAssertEqual(rig.model.secondaryTitle, "Not Now")
        XCTAssertEqual(rig.carried.last, [.fileViewer, .fullDiskAccess, .moveToApplications])
        // Trying again doesn't copy Helm a second time.
        XCTAssertTrue(rig.model.press("Set Up"))
        await rig.model.work?.value
        XCTAssertEqual(rig.mover.moves, 1)
        XCTAssertEqual(rig.mover.relaunches.count, 2)
        XCTAssertFalse(rig.role.isHelmDefault)
        XCTAssertTrue(rig.privacy.openedPanes.isEmpty)
    }

    /// Review finding onb-6: closing the window stops a Set Up that's still waiting on macOS. The row in progress
    /// finishes, but System Settings doesn't open behind the person's back, and a window opened afterwards starts clean.
    func testClosingStopsASetUpThatIsStillRunning() async {
        let slow = SlowRole()
        let rig = SetupRig(role: slow)
        await rig.open()
        XCTAssertTrue(rig.model.press("Set Up"))
        for _ in 0..<50 where rig.model.state(of: .fileViewer) != .working { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(rig.model.state(of: .fileViewer), .working)
        // Return twice: Set Up, then Done, which closes the window.
        XCTAssertTrue(rig.model.press("Done"))
        XCTAssertEqual(rig.closed, 1)
        // Help › Set Up Helm… opens it again before macOS has answered.
        rig.model.begin(.setup)
        slow.answer()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(rig.privacy.openedPanes.isEmpty, "System Settings never opens after the window has gone")
        XCTAssertTrue(slow.isHelmDefault)
        XCTAssertTrue(slow.isFirstInDock, "the row that had started is finished, not left half done")
        XCTAssertFalse(rig.model.started)
        XCTAssertEqual(rig.model.primaryTitle, "Set Up")
        XCTAssertEqual(rig.model.state(of: .fullDiskAccess), .pending)
        XCTAssertFalse(rig.model.showsAccessHelp)
    }

    /// Review finding onb-4: Full Disk Access asked for while the checklist is open gets its own button for System
    /// Settings, which leaves the other rows alone.
    func testAskingForAccessWhileTheChecklistIsOpen() async {
        let rig = SetupRig()
        await rig.open()
        XCTAssertFalse(rig.model.showsAccessHelp)
        XCTAssertFalse(rig.model.press("Open System Settings"), "no such button on a fresh checklist")
        rig.model.requestAccessHelp()
        XCTAssertTrue(rig.model.showsAccessHelp)
        XCTAssertTrue(rig.model.rowOpensSettings)
        XCTAssertTrue(rig.model.press("Open System Settings"))
        XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess])
        XCTAssertEqual(rig.model.state(of: .fullDiskAccess), .waiting)
        XCTAssertFalse(rig.role.isHelmDefault)
        XCTAssertFalse(rig.role.isFirstInDock)
        XCTAssertFalse(rig.model.started)
        XCTAssertEqual(rig.model.primaryTitle, "Set Up")
        // Set Up does the rest, without opening System Settings a second time, and waits for the switch.
        XCTAssertTrue(rig.model.press("Set Up"))
        await rig.model.work?.value
        XCTAssertTrue(rig.role.isHelmDefault)
        XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess])
        XCTAssertEqual(rig.closed, 0)
        await rig.access(.granted)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rig.closed, 1)
        // Closed before a run begins, Set Up does nothing at all.
        let quick = SetupRig()
        await quick.open()
        XCTAssertTrue(quick.model.press("Set Up"))
        quick.model.closed()
        await quick.model.work?.value
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(quick.role.isHelmDefault)
        XCTAssertTrue(quick.privacy.openedPanes.isEmpty)
    }

    /// Review finding onb-5: the guide turning into the checklist keeps the wait for Full Disk Access.
    func testTheChecklistKeepsTheGuidesWait() async {
        let rig = SetupRig()
        await rig.center.refresh()
        rig.model.begin(.guide)
        XCTAssertTrue(rig.model.press("Open System Settings"))
        XCTAssertEqual(rig.model.state(of: .fullDiskAccess), .waiting)
        rig.model.switchToSetup()
        XCTAssertEqual(rig.model.mode, .setup)
        XCTAssertEqual(rig.model.state(of: .fullDiskAccess), .waiting)
        XCTAssertTrue(rig.model.showsAccessHelp)
        XCTAssertTrue(rig.model.isWaitingForAccess)
        XCTAssertTrue(rig.model.rowOpensSettings)
        XCTAssertTrue(rig.model.canChoose, "the other rows are still the person's to choose")
        XCTAssertEqual(rig.model.primaryTitle, "Set Up")
        XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess])
    }

    /// Review finding onb-5: asked for again just as it was about to close by itself, the window stays.
    func testAskedForAgainItStaysOpen() async throws {
        let rig = SetupRig()
        rig.model.finishDelay = 0.2
        await rig.open()
        rig.model.setChecked(.fileViewer, false)
        XCTAssertTrue(rig.model.press("Set Up"))
        await rig.model.work?.value
        await rig.access(.granted)
        XCTAssertTrue(rig.model.isFinishing)
        rig.model.askedForAgain()
        XCTAssertFalse(rig.model.isFinishing)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(rig.closed, 0)
        // Something changing later doesn't close it either.
        rig.model.refresh()
        XCTAssertFalse(rig.model.isFinishing)
    }

    /// Review finding onb-9: VoiceOver hears each row that's done or didn't work, and the window doesn't close by itself
    /// while VoiceOver is on. Anyone who can't drag is told about the + button.
    func testChangesAreAnnouncedAndVoiceOverKeepsTheWindow() async throws {
        let rig = SetupRig()
        await rig.open()
        XCTAssertTrue(rig.said.isEmpty, "what's done already isn't news")
        XCTAssertTrue(rig.model.press("Set Up"))
        await rig.model.work?.value
        XCTAssertTrue(rig.said.contains("Helm now opens instead of Finder."), "\(rig.said)")
        await rig.access(.granted)
        XCTAssertEqual(rig.said.last, "Full Disk Access is on. Everything you chose is set up.")
        XCTAssertEqual(rig.model.lastAnnouncement, rig.said.last)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rig.closed, 1)
        // With VoiceOver on it says so, and the person closes it.
        let reading = SetupRig()
        reading.voiceOver = true
        await reading.open()
        XCTAssertTrue(reading.model.press("Set Up"))
        await reading.model.work?.value
        await reading.access(.granted)
        XCTAssertEqual(reading.said.last, "Full Disk Access is on. Everything you chose is set up.")
        XCTAssertFalse(reading.model.isFinishing)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reading.closed, 0)
        XCTAssertTrue(reading.model.press("Done"))
        XCTAssertEqual(reading.closed, 1)
        // The way to add Helm without dragging is on Helm's icon, for VoiceOver: the steps beside it leave it out.
        let icon = AppIconDragView(appURL: URL(fileURLWithPath: "/Applications/Helm.app", isDirectory: true), image: NSImage())
        XCTAssertEqual(icon.accessibilityLabel(), "Helm icon: drag it into the Full Disk Access list, or click + there and choose Helm.")
    }

    func testTheGuideStandsAlone() async throws {
        let rig = SetupRig()
        await rig.open()
        rig.model.begin(.guide)
        XCTAssertEqual(rig.model.primaryTitle, "Open System Settings")
        XCTAssertEqual(rig.model.secondaryTitle, "Not Now")
        XCTAssertTrue(rig.model.showsAccessHelp)
        XCTAssertTrue(rig.model.isWaitingForAccess)
        XCTAssertEqual(rig.model.statusLine, "Full Disk Access is off")
        XCTAssertFalse(rig.model.press("Set Up"))
        XCTAssertTrue(rig.model.press("Open System Settings"))
        XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess])
        XCTAssertEqual(rig.model.statusLine, "Waiting for Full Disk Access")
        XCTAssertEqual(rig.model.primaryTitle, "Done")
        // Its row can open System Settings again.
        XCTAssertTrue(rig.model.press("Open System Settings"))
        XCTAssertEqual(rig.privacy.openedPanes, [.fullDiskAccess, .fullDiskAccess])
        XCTAssertFalse(rig.role.isHelmDefault, "the guide never touches the file viewer")
        XCTAssertEqual(rig.seen, 0)
        await rig.access(.granted)
        XCTAssertEqual(rig.model.statusLine, "Full Disk Access is on")
        XCTAssertFalse(rig.model.showsAccessHelp)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.closed, 1)
    }

    func testOutsideAnAppBundleThereIsNothingToSwitchOn() async {
        let rig = SetupRig(appURL: nil)
        await rig.open()
        XCTAssertEqual(rig.model.rows, [.fileViewer])
        rig.model.begin(.guide)
        XCTAssertTrue(rig.model.isOutsideApp)
        XCTAssertFalse(rig.model.isWaitingForAccess)
        XCTAssertEqual(rig.model.primaryTitle, "Done")
        XCTAssertFalse(rig.model.press("Open System Settings"))
        rig.model.openFullDiskAccess()
        XCTAssertTrue(rig.privacy.openedPanes.isEmpty)
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

/// The welcome window counts as seen once each time it opens: Set Up, Not Now, closing it or quitting with it open. The
/// guide never counts, and the window floats over System Settings only while that helps.
@MainActor final class OnboardingWindowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func controller(_ privacy: MemoryPrivacyAccess? = nil, role: MemoryFileViewerRole? = nil) -> OnboardingWindowController {
        let controller = OnboardingWindowController(permissions: PermissionCenter(provider: privacy ?? MemoryPrivacyAccess()),
                                                    fileViewer: FileViewerModel(role: role ?? MemoryFileViewerRole()), mover: MemoryAppMover())
        controller.model.isVoiceOverRunning = { false }
        return controller
    }

    func testTheChecklistCountsAsSeenOnceEachTimeItOpens() {
        let controller = controller()
        defer { controller.close() }
        var seen = 0
        controller.onSeen = { seen += 1 }
        controller.show(.setup, activate: false)
        XCTAssertEqual(controller.modeForTesting, "setup")
        XCTAssertEqual(seen, 0, "opening isn't seeing")
        controller.quitting()
        XCTAssertEqual(seen, 1)
        controller.close()
        XCTAssertEqual(seen, 1, "once each time it opens")
        XCTAssertEqual(controller.modeForTesting, "closed")
        // Not Now closes it, and counts.
        controller.show(.setup, activate: false)
        XCTAssertTrue(controller.pressForTesting("Not Now"))
        XCTAssertEqual(seen, 2)
        XCTAssertEqual(controller.modeForTesting, "closed")
        // So does closing it.
        controller.show(.setup, activate: false)
        controller.close()
        XCTAssertEqual(seen, 3)
        // The guide on its own isn't the welcome.
        controller.show(.guide, activate: false)
        XCTAssertEqual(controller.modeForTesting, "guide")
        controller.quitting()
        controller.close()
        XCTAssertEqual(seen, 3)
    }

    func testAskingForTheGuideKeepsAnOpenChecklist() {
        let controller = controller()
        defer { controller.close() }
        controller.show(.setup, activate: false)
        controller.show(.guide, activate: false)
        XCTAssertEqual(controller.modeForTesting, "setup")
        controller.close()
        controller.show(.guide, activate: false)
        controller.show(.setup, activate: false)
        XCTAssertEqual(controller.modeForTesting, "setup")
    }

    /// Review finding onb-4: a card's Grant Access… while the checklist is open shows the Full Disk Access row's own way
    /// into System Settings, which changes nothing else.
    func testTheChecklistAskedForTheGuideOpensSystemSettingsByItself() {
        let privacy = MemoryPrivacyAccess()
        let role = MemoryFileViewerRole()
        let controller = controller(privacy, role: role)
        defer { controller.close() }
        controller.show(.setup, activate: false)
        XCTAssertFalse(controller.pressForTesting("Open System Settings"))
        controller.show(.guide, activate: false)
        XCTAssertEqual(controller.modeForTesting, "setup")
        XCTAssertTrue(controller.pressForTesting("Open System Settings"))
        XCTAssertEqual(privacy.openedPanes, [.fullDiskAccess])
        XCTAssertFalse(role.isHelmDefault)
        XCTAssertFalse(role.isFirstInDock)
        XCTAssertEqual(controller.model.primaryTitle, "Set Up")
        XCTAssertTrue(controller.model.permissions.isWatching, "it watches for the switch")
    }

    /// Review finding onb-5: Help › Set Up Helm… while the guide waits keeps the wait, and asked for again just before it
    /// closes by itself, the window stays.
    func testAskingAgainKeepsWhatTheWindowIsDoing() async throws {
        let privacy = MemoryPrivacyAccess()
        let controller = controller(privacy)
        defer { controller.close() }
        controller.model.finishDelay = 0.2
        controller.show(.guide, activate: false)
        XCTAssertTrue(controller.pressForTesting("Open System Settings"))
        controller.show(.setup, activate: false)
        XCTAssertEqual(controller.modeForTesting, "setup")
        XCTAssertEqual(controller.model.state(of: .fullDiskAccess), .waiting)
        XCTAssertTrue(controller.model.permissions.isWatching)
        XCTAssertEqual(privacy.openedPanes, [.fullDiskAccess])
        // Set Up for the rest, then access arrives, then Help › Set Up Helm… once more before it closes.
        XCTAssertTrue(controller.pressForTesting("Set Up"))
        await controller.model.work?.value
        privacy.status = .granted
        await controller.model.permissions.refresh()
        XCTAssertTrue(controller.model.isFinishing)
        controller.show(.setup, activate: false)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(controller.modeForTesting, "setup")
    }

    /// Review finding onb-7: hidden along with Helm (Command-H), the checklist is still open, so quitting then counts
    /// it as seen.
    func testQuittingWhileHelmIsHiddenCountsAsSeen() async throws {
        let app = NSApplication.shared
        let controller = controller()
        defer { controller.close(); app.unhide(nil) }
        var seen = 0
        controller.onSeen = { seen += 1 }
        controller.show(.setup, activate: false)
        app.hide(nil)
        for _ in 0..<20 where controller.window?.isVisible == true { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(controller.isShown)
        XCTAssertEqual(controller.modeForTesting, "setup")
        controller.quitting()
        XCTAssertEqual(seen, 1)
        // Asked for again while hidden, it keeps what it was doing rather than starting over.
        controller.model.setChecked(.fileViewer, false)
        controller.show(.setup, activate: false)
        XCTAssertFalse(controller.model.isChecked(.fileViewer))
        app.unhide(nil)
        controller.close()
        XCTAssertFalse(controller.isShown)
    }

    /// Review finding onb-10: the file viewer row is read again when the window is asked for and when Helm comes back
    /// to the front, so a change made elsewhere shows.
    func testTheFileViewerRowIsReadAgain() async throws {
        let role = MemoryFileViewerRole()
        role.makeHelmDefault { _ in }
        _ = role.setFirstInDock(true)
        let controller = controller(MemoryPrivacyAccess(status: .granted), role: role)
        defer { controller.close() }
        controller.show(.setup, activate: false)
        XCTAssertEqual(controller.model.state(of: .fileViewer), .done)
        // As `Helm --dock-first off` or dragging the tile would: the switch changes, the window isn't told.
        _ = role.setFirstInDock(false)
        controller.show(.setup, activate: false)
        XCTAssertEqual(controller.model.state(of: .fileViewer), .pending)
        XCTAssertTrue(controller.model.hasCheckbox(.fileViewer))
        _ = role.setFirstInDock(true)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(controller.model.state(of: .fileViewer), .done)
    }

    func testItWatchesForAccessOnlyWhileItWaits() async {
        let privacy = MemoryPrivacyAccess()
        let controller = controller(privacy)
        defer { controller.close() }
        let center = controller.model.permissions
        controller.show(.setup, activate: false)
        XCTAssertFalse(center.isWatching, "nothing to wait for before Set Up")
        XCTAssertTrue(controller.pressForTesting("Set Up"))
        await controller.model.work?.value
        XCTAssertTrue(center.isWatching)
        XCTAssertEqual(privacy.openedPanes, [.fullDiskAccess])
        controller.close()
        XCTAssertFalse(center.isWatching)
    }

    func testTheWindowFloatsOnlyOverSystemSettingsWhileItWaits() {
        let settings = OnboardingWindowController.systemSettings
        XCTAssertEqual(settings, "com.apple.systempreferences")
        XCTAssertEqual(OnboardingWindowController.level(waitingForAccess: true, interactive: true, hasAccess: false, frontmost: settings), .floating)
        // Anywhere else it's an ordinary window, which other apps cover as usual.
        XCTAssertEqual(OnboardingWindowController.level(waitingForAccess: true, interactive: true, hasAccess: false, frontmost: "com.apple.Safari"), .normal)
        XCTAssertEqual(OnboardingWindowController.level(waitingForAccess: true, interactive: true, hasAccess: false, frontmost: nil), .normal)
        XCTAssertEqual(OnboardingWindowController.level(waitingForAccess: true, interactive: true, hasAccess: true, frontmost: settings), .normal)
        XCTAssertEqual(OnboardingWindowController.level(waitingForAccess: false, interactive: true, hasAccess: false, frontmost: settings), .normal)
        XCTAssertEqual(OnboardingWindowController.level(waitingForAccess: true, interactive: false, hasAccess: false, frontmost: settings), .normal)
    }
}
#endif
