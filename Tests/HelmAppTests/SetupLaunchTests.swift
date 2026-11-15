#if os(macOS)
import AppKit
import Foundation
import XCTest
import HelmCore
import HelmPersistence
@testable import HelmUI
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

#if os(macOS)
/// Setup comes before anything macOS guards: while it's owed, launch shows the welcome checklist and holds every window
/// back until it closes. It's owed until seen, and again whenever another build runs. Everything is a stand-in: in-memory
/// settings, permission, file viewer and mover, and a throwaway home.
@MainActor final class SetupBeforeWindowsTests: XCTestCase {
    private var root: URL!
    private var app: AppController?
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-first-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("r".utf8).write(to: documents.appendingPathComponent("report.txt"))
    }
    override func tearDownWithError() throws {
        app?.onboardingForTesting?.close()
        for window in app?.allWindows ?? [] { window.window?.close() }
        app = nil
        HeaderMotion.isDisabledForTesting = false
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// An app whose launch holds its windows back for setup, as a person's launch does.
    private func makeApp(build: String? = "cdhash H\"0a1b\"", continuing rows: [SetupRow]? = nil) -> AppController {
        var options = LaunchOptions()
        options.home = home
        options.support = root.appendingPathComponent("support", isDirectory: true)
        options.continueSetup = rows
        let app = AppController(options: options)
        app.staysInBackground = true
        app.access.gatesLaunchForTesting = true
        app.privacyForTesting?.buildIdentity = build
        self.app = app
        return app
    }

    private func until(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    func testAFirstLaunchShowsSetupBeforeAnyWindowAndReadsNothingUntilItCloses() async throws {
        let app = makeApp()
        // A folder asked for as Helm starts waits for setup too.
        app.receive(.open([documents]), from: nil)
        let launch = Task { @MainActor in await app.compose() }
        let shown = await until { app.onboardingForTesting?.modeForTesting == "setup" }
        XCTAssertTrue(shown, "the checklist came first")
        XCTAssertTrue(app.allWindows.isEmpty, "no window before setup")
        XCTAssertEqual(app.dependencies?.volumes.isStarted, false, "no drive or cloud folder read")
        XCTAssertTrue(app.access.windowsWaitForSetup)
        let screen = try XCTUnwrap(app.onboardingForTesting)
        XCTAssertEqual(screen.model.folderNote(.fullDiskAccess), SetupRow.fullDiskAccess.folderNote)
        XCTAssertNil(screen.model.folderNote(.fileViewer))
        // A new window asked for meanwhile waits for the checklist too.
        app.newWindow(nil)
        XCTAssertTrue(app.allWindows.isEmpty)

        XCTAssertTrue(screen.pressForTesting("Not Now"))
        await launch.value
        XCTAssertEqual(app.allWindows.count, 1, "the window opens as today once setup has closed")
        XCTAssertEqual(app.dependencies?.volumes.isStarted, true)
        let tab = try XCTUnwrap(app.frontmost()?.activeTab)
        XCTAssertEqual(tab.location.mutationTarget.map(PathSpelling.standardPath), PathSpelling.standardPath(documents))
        let settings = try XCTUnwrap(app.environment?.settings)
        XCTAssertTrue(settings.snapshot.bool(.onboardingCompleted))
        XCTAssertEqual(settings.snapshot.string(.setupBuild), "cdhash H\"0a1b\"", "the build that went through it is kept")
        XCTAssertFalse(app.access.setupOwed)
        XCTAssertFalse(app.access.windowsWaitForSetup)
        app.newWindow(nil)
        XCTAssertEqual(app.allWindows.count, 2)
    }

    func testAFixtureRunOpensItsWindowsAtOnce() async throws {
        var options = LaunchOptions()
        options.home = home
        options.support = root.appendingPathComponent("support", isDirectory: true)
        let app = AppController(options: options)
        app.staysInBackground = true
        self.app = app
        await app.compose()
        XCTAssertNil(app.onboardingForTesting, "a fixture run never shows setup by itself")
        XCTAssertEqual(app.allWindows.count, 1)
        XCTAssertFalse(app.access.launchWaitsForSetup)
        XCTAssertTrue(app.access.windowsMayOpen)
    }

    func testAMovedCopyCarriesOnBeforeItsWindows() async throws {
        let app = makeApp(continuing: [.fullDiskAccess, .moveToApplications])
        let launch = Task { @MainActor in await app.compose() }
        let shown = await until { app.onboardingForTesting?.modeForTesting == "setup" }
        XCTAssertTrue(shown)
        XCTAssertTrue(app.allWindows.isEmpty)
        let screen = try XCTUnwrap(app.onboardingForTesting)
        await screen.model.work?.value
        XCTAssertEqual(screen.model.state(of: .fullDiskAccess), .waiting)
        screen.close()
        await launch.value
        XCTAssertEqual(app.allWindows.count, 1)
        XCTAssertNotEqual(app.onboardingForTesting?.modeForTesting, "setup", "the checklist isn't shown twice")
    }

    func testALaunchOnlyForFinderShowsNothingUntilHelmIsAskedFor() async throws {
        let app = makeApp()
        app.receive(.open([documents.appendingPathComponent("Photos", isDirectory: true)]), from: "com.apple.archiveutility")
        await app.compose()
        XCTAssertTrue(app.startedForFinder)
        XCTAssertNil(app.onboardingForTesting, "nothing comes up over Finder")
        XCTAssertEqual(app.dependencies?.volumes.isStarted, false)
        // A click on the Dock icon is the launch that was put off: setup first, then the window.
        XCTAssertFalse(app.reopen(from: "com.apple.dock", hasVisibleWindows: false))
        let shown = await until { app.onboardingForTesting?.modeForTesting == "setup" }
        XCTAssertTrue(shown)
        XCTAssertTrue(app.allWindows.isEmpty)
        try XCTUnwrap(app.onboardingForTesting).close()
        let opened = await until { app.allWindows.count == 1 }
        XCTAssertTrue(opened)
    }

    /// Setup owed at launch opens the checklist on the Space the person is on, as the window in front, and ⌘W closes it,
    /// which lets the windows it held back open.
    func testSetupOwedAtLaunchOpensOnThePersonsSpaceInFrontAndCommandWClosesIt() async throws {
        let app = makeApp()
        let launch = Task { @MainActor in await app.compose() }
        let shown = await until { app.onboardingForTesting?.modeForTesting == "setup" }
        XCTAssertTrue(shown)
        let window = try XCTUnwrap(app.onboardingForTesting?.window)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace),
                      "the checklist stays on the Space where it was shown last, out of sight")
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(NSApp.orderedWindows.first(where: \.isVisible) === window, "the checklist isn't the window in front")
        let close = try WelcomeWindowFrontTests.commandW(app)
        XCTAssertTrue(app.validateMenuItem(close), "⌘W is off with the checklist in front")
        app.helmCommand(close)
        XCTAssertFalse(window.isVisible, "⌘W left the checklist open")
        await launch.value
        XCTAssertEqual(app.allWindows.count, 1)
    }
}

/// Help › Set Up Helm… shows the welcome window as Settings is shown: the key window, in front of Helm's other windows,
/// on the Space the person is on now. The same window shows the AI mode screen, and before, the checklist shown in a
/// background run stayed on the Space where that screen had been. Once the person had moved to another Space, it opened
/// out of sight behind the browser windows, so ⌘W went past it. Everything is a stand-in on a throwaway home.
@MainActor final class WelcomeWindowFrontTests: XCTestCase {
    private var root: URL!
    private var app: AppController?

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("welcome-front-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/Documents", isDirectory: true),
                                                withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        app?.onboardingForTesting?.close()
        for window in app?.allWindows ?? [] { window.window?.close() }
        app = nil
        HeaderMotion.isDisabledForTesting = false
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// File › Close Tab, ⌘W, as the menu bar builds it. Its action has no target of its own, so with no browser window
    /// key it comes to the app, as AppKit sends it while Helm isn't in front.
    static func commandW(_ app: AppController) throws -> NSMenuItem {
        let file = MenuModel.menuBar.first { $0.title == "File" }
        let row = try XCTUnwrap(file?.sections.flatMap { $0 }.first { $0.command == .closeTab })
        let item = MainMenuBuilder.item(for: row, target: app)
        XCTAssertEqual(item.keyEquivalent, "w")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertNil(item.target)
        return item
    }

    func testHelpSetUpHelmOpensTheWelcomeOnThePersonsSpaceInFrontAndCommandWClosesIt() async throws {
        var options = LaunchOptions()
        options.home = root.appendingPathComponent("home", isDirectory: true)
        options.support = root.appendingPathComponent("support", isDirectory: true)
        let app = AppController(options: options)
        app.staysInBackground = true
        self.app = app
        await app.compose()
        let browser = try XCTUnwrap(app.frontmost()?.window)
        XCTAssertTrue(browser.isVisible)
        // The AI mode screen in the same window first, closed again, as in the scripted run before the checklist.
        app.showAIModeScreen(from: app.frontmost())
        let screen = try XCTUnwrap(app.onboardingForTesting)
        XCTAssertEqual(screen.modeForTesting, "ai")
        screen.window?.performClose(nil)
        XCTAssertEqual(screen.modeForTesting, "closed")

        app.showSetup(nil)
        XCTAssertEqual(screen.modeForTesting, "setup")
        let window = try XCTUnwrap(screen.window)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace),
                      "the welcome opens on the Space where the AI mode screen was, not the person's")
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(NSApp.orderedWindows.first(where: \.isVisible) === window, "the welcome opened behind the browser window")
        let close = try Self.commandW(app)
        XCTAssertTrue(app.validateMenuItem(close), "⌘W is off with the welcome in front")
        app.helmCommand(close)
        XCTAssertEqual(screen.modeForTesting, "closed", "⌘W left the welcome open")
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(browser.isVisible, "⌘W closed the browser window instead")
    }
}

/// Whether setup is owed, as the access coordinator works it out from what Settings kept and which build runs.
@MainActor final class SetupOwedTests: XCTestCase {
    private func until(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    private func coordinator(_ settings: SettingsStore) async -> AccessCoordinator {
        _ = NSApplication.shared
        let viewer = FileViewerModel(role: MemoryFileViewerRole())
        let access = AccessCoordinator(isolated: true, interactive: false)
        access.gatesLaunchForTesting = true
        await access.start(settings: settings, fileViewer: { viewer }, windows: { [] })
        return access
    }

    func testSetupIsOwedUntilSeenAndAgainWhenAnotherBuildRuns() async throws {
        let settings = SettingsStore(storage: IsolatedSettings())
        let access = await coordinator(settings)
        defer { access.onboarding?.close() }
        let privacy = try XCTUnwrap(access.privacy as? MemoryPrivacyAccess)
        privacy.buildIdentity = "cdhash H\"aaaa\""
        XCTAssertTrue(access.setupOwed, "never seen")

        let first = Task { @MainActor in await access.setUpBeforeWindows() }
        let shown = await until { access.onboarding?.modeForTesting == "setup" }
        XCTAssertTrue(shown)
        XCTAssertTrue(access.windowsWaitForSetup)
        XCTAssertFalse(access.windowsMayOpen)
        // A second way to a window waits for the same checklist.
        var second = false
        let other = Task { @MainActor in await access.setUpBeforeWindows(); second = true }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(second)
        XCTAssertTrue(try XCTUnwrap(access.onboarding).pressForTesting("Not Now"))
        await first.value
        await other.value
        XCTAssertTrue(second)
        XCTAssertTrue(access.windowsMayOpen)
        XCTAssertEqual(settings.snapshot.string(.setupBuild), "cdhash H\"aaaa\"")
        XCTAssertFalse(access.setupOwed)

        // Another ad hoc build has another code hash, so macOS has forgotten its access: setup is owed again.
        privacy.buildIdentity = "cdhash H\"bbbb\""
        XCTAssertTrue(access.setupOwed)
        // A properly signed build keeps its requirement across updates, and one that can't say counts as the same.
        privacy.buildIdentity = "cdhash H\"aaaa\""
        XCTAssertFalse(access.setupOwed)
        privacy.buildIdentity = nil
        XCTAssertFalse(access.setupOwed)
    }

    func testTheBuildThatWentThroughSetupGoesStraightToItsWindows() async throws {
        let settings = SettingsStore(storage: IsolatedSettings())
        settings.set(.bool(true), for: .onboardingCompleted)
        settings.set(.string("identifier \"com.helm.filemanager\" and anchor apple generic"), for: .setupBuild)
        let access = await coordinator(settings)
        defer { access.onboarding?.close() }
        let privacy = try XCTUnwrap(access.privacy as? MemoryPrivacyAccess)
        privacy.buildIdentity = "identifier \"com.helm.filemanager\" and anchor apple generic"
        await access.setUpBeforeWindows()
        XCTAssertNil(access.onboarding, "nothing was shown")
        XCTAssertTrue(access.windowsMayOpen)

        // Seen long ago by a build before this one, as after an update from 0.1: the checklist comes back.
        let again = await coordinator(settings)
        defer { again.onboarding?.close() }
        (again.privacy as? MemoryPrivacyAccess)?.buildIdentity = "cdhash H\"cccc\""
        let gate = Task { @MainActor in await again.setUpBeforeWindows() }
        let shown = await until { again.onboarding?.modeForTesting == "setup" }
        XCTAssertTrue(shown)
        again.onboarding?.close()
        await gate.value
        XCTAssertEqual(settings.snapshot.string(.setupBuild), "cdhash H\"cccc\"")
    }
}
#endif
