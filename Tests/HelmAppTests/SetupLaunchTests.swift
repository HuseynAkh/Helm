#if os(macOS)
import AppKit
import Foundation
import XCTest
import HelmCore
import HelmPersistence
import HelmUI
@testable import HelmApp

/// The copy that Set Up moved into Applications opens with --continue-setup, naming the rows to carry on with.
final class SetupLaunchTests: XCTestCase {
    func testAMovedCopyReadsBackTheRowsItWasGiven() {
        let rows: [SetupRow] = [.fileViewer, .fullDiskAccess, .moveToApplications]
        let options = LaunchOptions.parse(["Helm", SetupRow.continueFlag, SetupRow.flagValue(rows)])
        XCTAssertEqual(options?.continueSetup, rows)
        XCTAssertEqual(options?.isIsolated, false)
        XCTAssertEqual(LaunchOptions.parse(["Helm", "--continue-setup", "none"])?.continueSetup, [])
        XCTAssertEqual(LaunchOptions.parse(["Helm", "--continue-setup", "access,later"])?.continueSetup, [.fullDiskAccess])
        XCTAssertNil(LaunchOptions.parse(["Helm", "--continue-setup"]), "the flag needs its rows")
        // An ordinary launch carries nothing on.
        XCTAssertNil(LaunchOptions.parse(["Helm"])?.continueSetup)
        XCTAssertNil(LaunchOptions.parse(["Helm", "--home", "/tmp/fixture-home", "/tmp/fixture-home/Documents"])?.continueSetup)
    }
}

/// Review finding onb-3: Set Up saves the rows for the copy it moves into Applications, so that copy carries on even when
/// it's opened by hand, without the flag. Everything here is a stand-in: in-memory settings, permission, file viewer
/// and mover.
@MainActor final class SetupCarryOnTests: XCTestCase {
    func testACopyOpenedByHandCarriesOnWithTheSavedRows() async throws {
        _ = NSApplication.shared
        let settings = SettingsStore(storage: IsolatedSettings())
        let viewer = FileViewerModel(role: MemoryFileViewerRole())
        let access = AccessCoordinator(isolated: true, interactive: false)
        await access.start(settings: settings, fileViewer: { viewer }, windows: { [] })
        defer { access.onboarding?.close() }
        let mover = try XCTUnwrap(access.mover as? MemoryAppMover)
        // Set Up in a copy on a disk image: the move goes first, and the rest is saved for the copy in Applications.
        // The stand-in never quits, as when the quit is cancelled.
        mover.placement = .diskImage
        access.showWelcome()
        let window = try XCTUnwrap(access.onboarding)
        XCTAssertTrue(window.pressForTesting("Set Up"))
        await window.model.work?.value
        XCTAssertEqual(settings.snapshot.string(.setupCarriedRows), "viewer,access,move")
        XCTAssertEqual(window.model.state(of: .moveToApplications).name, "failed")
        XCTAssertFalse(viewer.isHelmDefault)
        window.close()
        // The same copy opened again from the disk image leaves them for the right one.
        access.showWelcomeIfNeeded()
        XCTAssertEqual(window.modeForTesting, "closed")
        XCTAssertEqual(settings.snapshot.string(.setupCarriedRows), "viewer,access,move")
        // The copy in Applications, opened by hand: no flag, and the welcome was seen long ago.
        XCTAssertTrue(settings.snapshot.bool(.onboardingCompleted))
        mover.placement = .applications
        access.showWelcomeIfNeeded()
        XCTAssertEqual(window.modeForTesting, "setup")
        await window.model.work?.value
        XCTAssertEqual(window.model.state(of: .moveToApplications), .done)
        XCTAssertEqual(window.model.state(of: .fileViewer), .done)
        XCTAssertEqual(window.model.state(of: .fullDiskAccess), .waiting)
        XCTAssertTrue(viewer.isHelmDefault)
        XCTAssertEqual(settings.snapshot.string(.setupCarriedRows), "", "carried on once")
        window.close()
        access.showWelcomeIfNeeded()
        XCTAssertEqual(window.modeForTesting, "closed")
    }
}
#endif
