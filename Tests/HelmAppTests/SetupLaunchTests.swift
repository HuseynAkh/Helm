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

/// Review finding onb-3: the move saves what the copy in Applications carries on with, so that copy carries on even
/// when it's opened by hand, without the flag. Everything here is a stand-in: in-memory settings, permission, file
/// viewer and mover.
@MainActor final class SetupCarryOnTests: XCTestCase {
    func testACopyOpenedByHandCarriesOnAfterTheWelcome() async throws {
        _ = NSApplication.shared
        let settings = SettingsStore(storage: IsolatedSettings())
        let viewer = FileViewerModel(role: MemoryFileViewerRole())
        let access = AccessCoordinator(isolated: true, interactive: false)
        await access.start(settings: settings, fileViewer: { viewer }, windows: { [] })
        defer { access.onboarding?.close() }
        let mover = try XCTUnwrap(access.mover as? MemoryAppMover)
        // Continue on the welcome of a copy on a disk image: the move goes first, and what's next is saved for the copy
        // in Applications. The stand-in never quits, as when the quit is cancelled.
        mover.placement = .diskImage
        access.showWelcome()
        let window = try XCTUnwrap(access.onboarding)
        XCTAssertEqual(window.stepForTesting, "welcome")
        XCTAssertTrue(window.pressForTesting("Continue"))
        await window.model.work?.value
        XCTAssertEqual(settings.snapshot.string(.setupCarriedRows), "move")
        XCTAssertEqual(window.model.state(of: .moveToApplications).name, "failed")
        XCTAssertEqual(mover.relaunches, [[.moveToApplications]])
        XCTAssertFalse(viewer.isHelmDefault)
        window.close()
        // The same copy opened again from the disk image leaves them for the right one.
        access.showWelcomeIfNeeded()
        XCTAssertEqual(window.modeForTesting, "closed")
        XCTAssertEqual(settings.snapshot.string(.setupCarriedRows), "move")
        // The copy in Applications, opened by hand: no flag, and the welcome was through long ago.
        XCTAssertTrue(settings.snapshot.bool(.onboardingCompleted))
        mover.placement = .applications
        access.showWelcomeIfNeeded()
        XCTAssertEqual(window.modeForTesting, "setup")
        XCTAssertEqual(window.stepForTesting, "access", "it carries on after the welcome, where the move was")
        XCTAssertEqual(window.model.state(of: .moveToApplications), .done)
        XCTAssertEqual(window.model.state(of: .fullDiskAccess), .pending)
        XCTAssertFalse(viewer.isHelmDefault, "the file viewer waits for its own step")
        XCTAssertEqual(settings.snapshot.string(.setupCarriedRows), "", "carried on once")
        window.close()
        access.showWelcomeIfNeeded()
        XCTAssertEqual(window.modeForTesting, "closed")
    }
}
#endif

#if os(macOS)
/// Setup comes before anything macOS guards: while it's owed, launch shows the onboarding and holds every window back
/// until it's through, AI mode included as one of its steps. It's owed until through, again whenever another build runs,
/// and while an onboarding that was quit part way is kept: macOS's Quit & Reopen, stood in for here, ends one launch with
/// the onboarding open, and the next carries on at the next step. Everything is a stand-in: in-memory settings,
/// permission, file viewer, mover and AI provider, and a throwaway home.
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
    /// A launch macOS ended, as Quit & Reopen does: kept until the test ends, so its windows can be closed then.
    private var earlier: [AppController] = []

    override func tearDownWithError() throws {
        for app in earlier + [app].compactMap({ $0 }) {
            app.onboardingForTesting?.close()
            for window in app.allWindows { window.window?.close() }
        }
        app = nil
        earlier = []
        HeaderMotion.isDisabledForTesting = false
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// An app whose launch holds its windows back for setup, as a person's launch does. `settings` are the preferences
    /// a launch before this one left, as the real ones carry over from launch to launch.
    private func makeApp(build: String? = "cdhash H\"0a1b\"", continuing rows: [SetupRow]? = nil,
                         settings: IsolatedSettings? = nil) -> AppController {
        var options = LaunchOptions()
        options.home = home
        options.support = root.appendingPathComponent("support", isDirectory: true)
        options.continueSetup = rows
        let app = AppController(options: options)
        app.staysInBackground = true
        app.access.gatesLaunchForTesting = true
        app.fixtureSettingsForTesting = settings
        app.privacyForTesting?.buildIdentity = build
        self.app = app
        return app
    }

    /// Continue on each step until `step`, leaving the file viewer as it is.
    private func continueTo(_ step: String, in screen: OnboardingWindowController) async {
        for _ in 0..<6 where screen.stepForTesting != step {
            screen.model.setChecked(.fileViewer, false)
            XCTAssertTrue(screen.pressForTesting(screen.model.primaryTitle))
            await screen.model.work?.value
        }
        XCTAssertEqual(screen.stepForTesting, step)
    }

    /// What macOS does to the launch with the onboarding open when the person clicks Quit & Reopen: Helm quits as it
    /// would, and the process ends with the window open. Nothing else in Helm quits or reopens.
    private func quitAsMacOSDoes(_ app: AppController) {
        app.access.quitting()
        app.onboardingForTesting?.endWithProcess()
        earlier.append(app)
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
        XCTAssertTrue(shown, "the onboarding came first")
        XCTAssertTrue(app.allWindows.isEmpty, "no window before setup")
        XCTAssertEqual(app.dependencies?.volumes.isStarted, false, "no drive or cloud folder read")
        XCTAssertTrue(app.access.windowsWaitForSetup)
        let screen = try XCTUnwrap(app.onboardingForTesting)
        XCTAssertEqual(screen.stepForTesting, "welcome")
        XCTAssertEqual(screen.model.steps, [.welcome, .access, .viewer, .ai, .done], "AI mode is one of its steps")
        // A new window asked for meanwhile waits for the onboarding too.
        app.newWindow(nil)
        XCTAssertTrue(app.allWindows.isEmpty)
        XCTAssertTrue(screen.pressForTesting("Continue"))
        XCTAssertEqual(screen.model.folderNote(.fullDiskAccess), SetupRow.fullDiskAccess.folderNote)
        XCTAssertNil(screen.model.folderNote(.fileViewer))

        screen.close()
        await launch.value
        XCTAssertEqual(app.allWindows.count, 1, "the window opens as today once setup has closed")
        XCTAssertEqual(app.dependencies?.volumes.isStarted, true)
        let tab = try XCTUnwrap(app.frontmost()?.activeTab)
        XCTAssertEqual(tab.location.mutationTarget.map(PathSpelling.standardPath), PathSpelling.standardPath(documents))
        let settings = try XCTUnwrap(app.environment?.settings)
        XCTAssertTrue(settings.snapshot.bool(.onboardingCompleted))
        XCTAssertEqual(settings.snapshot.string(.setupBuild), "cdhash H\"0a1b\"", "the build that went through it is kept")
        XCTAssertEqual(settings.snapshot.string(.setupProgress), "", "nothing left to carry on with")
        XCTAssertFalse(app.access.setupOwed)
        XCTAssertFalse(app.access.windowsWaitForSetup)
        app.newWindow(nil)
        XCTAssertEqual(app.allWindows.count, 2)
    }

    /// The first launch goes through every step in the one window, and the file window opens only when it's through.
    /// After it nothing else comes up by itself: AI mode was one of its steps.
    func testTheMainWindowOpensOnlyWhenTheOnboardingIsThroughAndNothingPopsUpAfter() async throws {
        let app = makeApp()
        app.access.opensAIIntroForTesting = true
        let launch = Task { @MainActor in await app.compose() }
        let shown = await until { app.onboardingForTesting?.modeForTesting == "setup" }
        XCTAssertTrue(shown)
        let screen = try XCTUnwrap(app.onboardingForTesting)
        screen.model.finishDelay = 0
        let ai = try XCTUnwrap(app.aiSetupModelForTesting)
        var seen: [String] = []
        while screen.stepForTesting != "done" {
            seen.append(screen.stepForTesting)
            XCTAssertTrue(app.allWindows.isEmpty, "a file window opened during \(screen.stepForTesting)")
            XCTAssertEqual(screen.modeForTesting, "setup", "one window from step to step")
            if screen.stepForTesting == "ai" {
                XCTAssertTrue(screen.model.aiSetup === ai, "the AI step shows the app's AI mode")
                ai.setOn(true)
                ai.enterKey("test-key-for-the-first-launch")
                await ai.settle()
            }
            XCTAssertTrue(screen.pressForTesting("Continue"))
            await screen.model.work?.value
            _ = await until(2) { !screen.model.isFinishing }
        }
        XCTAssertEqual(seen, ["welcome", "access", "viewer", "ai"])
        XCTAssertTrue(app.allWindows.isEmpty, "not even on the done step")
        XCTAssertTrue(screen.pressForTesting("Get Started"))
        await launch.value
        XCTAssertEqual(app.allWindows.count, 1)
        XCTAssertEqual(screen.modeForTesting, "closed")
        let settings = try XCTUnwrap(app.environment?.settings)
        XCTAssertTrue(settings.snapshot.bool(.aiModeEnabled), "Continue on the AI step left it on")
        XCTAssertTrue(settings.snapshot.bool(.aiIntroSeen))
        XCTAssertTrue(settings.snapshot.bool(.onboardingCompleted))
        // No AI pop-up over the file window, at this launch or the next.
        app.showAIIntroIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(screen.modeForTesting, "closed", "nothing came up after the onboarding")
        XCTAssertEqual(app.privacyForTesting?.openedPanes, [], "System Settings opens only from its step's button")
    }

    /// macOS's Quit & Reopen once Full Disk Access is switched on: the launch with the onboarding open ends, nothing in
    /// Helm quits or reopens by itself, nothing counts as through, and the launch macOS starts carries on at the next
    /// step in the same window, before any file window. The window opens only when that onboarding is through.
    func testQuitAndReopenCarriesOnAtTheNextStepInTheNextLaunch() async throws {
        let preferences = IsolatedSettings()
        let first = makeApp(settings: preferences)
        let launch = Task { @MainActor in await first.compose() }
        let shown = await until { first.onboardingForTesting?.modeForTesting == "setup" }
        XCTAssertTrue(shown)
        let screen = try XCTUnwrap(first.onboardingForTesting)
        await continueTo("access", in: screen)
        XCTAssertTrue(screen.pressForTesting("Open System Settings"))
        XCTAssertEqual(first.privacyForTesting?.openedPanes, [.fullDiskAccess])
        XCTAssertEqual(screen.model.state(of: .fullDiskAccess), .waiting)
        let mover = try XCTUnwrap(first.moverForTesting)
        quitAsMacOSDoes(first)
        XCTAssertEqual(mover.moves, 0)
        XCTAssertTrue(mover.relaunches.isEmpty, "Helm doesn't relaunch itself for a permission")
        XCTAssertTrue(first.allWindows.isEmpty)
        let kept = try XCTUnwrap(first.environment?.settings)
        XCTAssertFalse(kept.snapshot.bool(.onboardingCompleted), "quitting isn't going through it")
        XCTAssertEqual(kept.snapshot.string(.setupProgress), "access:welcome,access,viewer,ai,done:asked")
        launch.cancel()

        // The launch macOS starts, with Full Disk Access on now.
        let second = makeApp(settings: preferences)
        second.privacyForTesting?.status = .granted
        let relaunch = Task { @MainActor in await second.compose() }
        let carried = await until { second.onboardingForTesting?.modeForTesting == "setup" }
        XCTAssertTrue(carried, "the onboarding came back first")
        let again = try XCTUnwrap(second.onboardingForTesting)
        XCTAssertEqual(again.stepForTesting, "viewer", "the next step, since Full Disk Access is on")
        XCTAssertEqual(again.model.steps, [.welcome, .access, .viewer, .ai, .done], "the same steps")
        XCTAssertEqual(again.window?.contentView?.frame.size, NSSize(width: OnboardingView.width, height: OnboardingView.stepHeight))
        XCTAssertTrue(second.allWindows.isEmpty, "no file window before the onboarding is through")
        XCTAssertEqual(second.privacyForTesting?.openedPanes, [], "System Settings isn't opened again")
        XCTAssertTrue(second.moverForTesting?.relaunches.isEmpty ?? false)
        XCTAssertTrue(again.pressForTesting("Back"))
        XCTAssertEqual(again.model.state(of: .fullDiskAccess), .done)
        await continueTo("done", in: again)
        XCTAssertTrue(second.allWindows.isEmpty)
        XCTAssertTrue(again.pressForTesting("Get Started"))
        await relaunch.value
        XCTAssertEqual(second.allWindows.count, 1)
        let settings = try XCTUnwrap(second.environment?.settings)
        XCTAssertTrue(settings.snapshot.bool(.onboardingCompleted))
        XCTAssertEqual(settings.snapshot.string(.setupProgress), "")
    }

    /// A quit for any other reason, part way through, carries on at the same step in the next launch: here the file
    /// viewer step, with Full Disk Access still off.
    func testAQuitForAnyOtherReasonCarriesOnWhereItStopped() async throws {
        let preferences = IsolatedSettings()
        let first = makeApp(settings: preferences)
        let launch = Task { @MainActor in await first.compose() }
        _ = await until { first.onboardingForTesting?.modeForTesting == "setup" }
        let screen = try XCTUnwrap(first.onboardingForTesting)
        await continueTo("viewer", in: screen)
        quitAsMacOSDoes(first)
        launch.cancel()
        let second = makeApp(settings: preferences)
        let relaunch = Task { @MainActor in await second.compose() }
        let carried = await until { second.onboardingForTesting?.modeForTesting == "setup" }
        XCTAssertTrue(carried)
        let again = try XCTUnwrap(second.onboardingForTesting)
        XCTAssertEqual(again.stepForTesting, "viewer")
        XCTAssertTrue(second.allWindows.isEmpty)
        // Closed part way, it's through: the window opens and the next launch shows nothing.
        again.close()
        await relaunch.value
        XCTAssertEqual(second.allWindows.count, 1)
        XCTAssertFalse(second.access.setupOwed)
    }

    /// Full Disk Access that shows up while Helm still runs moves the onboarding on, and nothing in Helm quits or reopens.
    func testAccessArrivingWhileHelmRunsMovesOnWithoutAQuit() async throws {
        let app = makeApp()
        let launch = Task { @MainActor in await app.compose() }
        _ = await until { app.onboardingForTesting?.modeForTesting == "setup" }
        let screen = try XCTUnwrap(app.onboardingForTesting)
        screen.model.finishDelay = 0
        await continueTo("access", in: screen)
        XCTAssertTrue(screen.pressForTesting("Open System Settings"))
        app.privacyForTesting?.status = .granted
        await app.permissionsForTesting.refresh()
        let movedOn = await until(5) { screen.stepForTesting == "viewer" }
        XCTAssertTrue(movedOn)
        XCTAssertEqual(app.moverForTesting?.moves, 0)
        XCTAssertTrue(app.moverForTesting?.relaunches.isEmpty ?? false, "no relaunch of Helm's own")
        XCTAssertTrue(app.allWindows.isEmpty)
        XCTAssertEqual(screen.modeForTesting, "setup")
        screen.close()
        await launch.value
        XCTAssertEqual(app.allWindows.count, 1)
    }

    /// A new window asked for while the onboarding holds the windows back opens none: the onboarding comes to the front
    /// as it is. A click on the Dock icon meanwhile waits for the launch, and adds no second window after it.
    func testANewWindowAskedForWhileTheOnboardingIsOpenBringsItForward() async throws {
        let app = makeApp()
        let launch = Task { @MainActor in await app.compose() }
        _ = await until { app.onboardingForTesting?.modeForTesting == "setup" }
        let screen = try XCTUnwrap(app.onboardingForTesting)
        XCTAssertTrue(screen.pressForTesting("Continue"))
        let window = try XCTUnwrap(screen.window)
        window.orderBack(nil)
        app.newWindow(nil)
        XCTAssertTrue(app.allWindows.isEmpty)
        XCTAssertEqual(screen.stepForTesting, "access", "it keeps its step")
        XCTAssertTrue(NSApp.orderedWindows.first(where: \.isVisible) === window, "the onboarding is the window in front")
        XCTAssertFalse(app.reopen(from: "com.apple.dock", hasVisibleWindows: false))
        XCTAssertTrue(app.allWindows.isEmpty)
        screen.close()
        await launch.value
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(app.allWindows.count, 1, "one window, once the onboarding was through")
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
        XCTAssertEqual(screen.stepForTesting, "access", "after the welcome, where the move was")
        XCTAssertEqual(screen.model.state(of: .moveToApplications), .done)
        screen.close()
        await launch.value
        XCTAssertEqual(app.allWindows.count, 1)
        XCTAssertNotEqual(app.onboardingForTesting?.modeForTesting, "setup", "the onboarding isn't shown twice")
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

    /// Setup owed at launch opens the onboarding on the Space the person is on, as the window in front, and ⌘W closes it,
    /// which lets the windows it held back open.
    func testSetupOwedAtLaunchOpensOnThePersonsSpaceInFrontAndCommandWClosesIt() async throws {
        let app = makeApp()
        let launch = Task { @MainActor in await app.compose() }
        let shown = await until { app.onboardingForTesting?.modeForTesting == "setup" }
        XCTAssertTrue(shown)
        let window = try XCTUnwrap(app.onboardingForTesting?.window)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace),
                      "the onboarding stays on the Space where it was shown last, out of sight")
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(NSApp.orderedWindows.first(where: \.isVisible) === window, "the onboarding isn't the window in front")
        let close = try WelcomeWindowFrontTests.commandW(app)
        XCTAssertTrue(app.validateMenuItem(close), "⌘W is off with the onboarding in front")
        app.helmCommand(close)
        XCTAssertFalse(window.isVisible, "⌘W left the onboarding open")
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
        // The AI mode screen in the same window first, closed again, as in the scripted run before the onboarding.
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
        // A second way to a window waits for the same onboarding.
        var second = false
        let other = Task { @MainActor in await access.setUpBeforeWindows(); second = true }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(second)
        try XCTUnwrap(access.onboarding).close()
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
        // An onboarding quit part way is owed to the same build, until it's through.
        privacy.buildIdentity = "cdhash H\"aaaa\""
        settings.set(.string("viewer:welcome,access,viewer,done:"), for: .setupProgress)
        XCTAssertTrue(access.setupOwed)
        XCTAssertEqual(access.savedProgress?.step, .viewer)
        settings.set(.string("nonsense"), for: .setupProgress)
        XCTAssertFalse(access.setupOwed, "what can't be read isn't an onboarding under way")
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

        // Seen long ago by a build before this one, as after an update from 0.1: the onboarding comes back.
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
