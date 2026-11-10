#if os(macOS)
import AppKit
import XCTest
@testable import HelmApp
@testable import HelmUI

/// Which window commands and requests go to. Review: AppKit's handler for an open-documents event brought a scripted
/// run to the front, and from then on the window that was main took every command, so a step that closed the window
/// it had just opened closed the one before it. The app runs on a throwaway home with its windows invisible.
@MainActor final class FrontWindowTests: XCTestCase {
    private var root: URL!
    private var app: AppController?

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        root = FileManager.default.temporaryDirectory.appendingPathComponent("front-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/Documents", isDirectory: true),
                                                withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for window in app?.allWindows ?? [] { window.window?.close() }
        app = nil
        HeaderMotion.isDisabledForTesting = false
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func composedApp() async -> AppController {
        var options = LaunchOptions()
        options.home = root.appendingPathComponent("home", isDirectory: true)
        options.support = root.appendingPathComponent("support", isDirectory: true)
        let app = AppController(options: options)
        app.staysInBackground = true
        self.app = app
        await app.compose()
        return app
    }

    func testAScriptedRunGoesToTheWindowOpenedLastWhicheverAppKitHasAsKey() async throws {
        let app = await composedApp()
        app.newWindow(nil)
        let windows = app.allWindows
        XCTAssertEqual(windows.count, 2)
        let first = try XCTUnwrap(windows.first), newest = try XCTUnwrap(windows.last)
        XCTAssertTrue(app.frontmost() === newest)
        // Brought to the front by AppKit, with the first window key and main: still the window opened last.
        XCTAssertTrue(AppController.front(of: windows, key: first.window, main: first.window, inBackground: true) === newest)
        // Closing it leaves the one before in front.
        newest.window?.close()
        XCTAssertTrue(app.frontmost() === first)
        XCTAssertEqual(app.allWindows.count, 1)
    }

    func testHelmInUseGoesToTheKeyWindowFirst() async throws {
        let app = await composedApp()
        app.newWindow(nil)
        let windows = app.allWindows
        let first = try XCTUnwrap(windows.first), newest = try XCTUnwrap(windows.last)
        XCTAssertTrue(AppController.front(of: windows, key: first.window, main: newest.window, inBackground: false) === first)
        // With Settings or a panel key, the main window.
        let panel = NSPanel()
        XCTAssertTrue(AppController.front(of: windows, key: panel, main: first.window, inBackground: false) === first)
        // With none key, the window opened last.
        XCTAssertTrue(AppController.front(of: windows, key: panel, main: nil, inBackground: false) === newest)
    }

    func testAScriptedRunLeavesOutAppKitsPartOfAReopen() async {
        let app = await composedApp()
        // AppKit's part brings Helm to the front, which a scripted run never does. Helm's own part still happens.
        XCTAssertTrue(app.reopen(from: nil, hasVisibleWindows: true))
        XCTAssertFalse(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertEqual(app.allWindows.count, 1)
    }
}
#endif
