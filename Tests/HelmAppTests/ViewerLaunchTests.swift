#if os(macOS)
import AppKit
import XCTest
import HelmCore
import HelmPersistence
@testable import HelmApp
@testable import HelmUI

/// Requests that come while Helm is starting: each shows its item, never a Home window in its place. The app runs
/// on a throwaway home with its windows invisible, and Finder is the fixture run's stand-in.
@MainActor final class ViewerLaunchTests: XCTestCase {
    private var root: URL!
    private var app: AppController?
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var report: URL { documents.appendingPathComponent("report.txt") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        root = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try Data("r".utf8).write(to: report)
    }
    override func tearDownWithError() throws {
        for window in app?.allWindows ?? [] { window.window?.close() }
        app = nil
        HeaderMotion.isDisabledForTesting = false
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeApp(continuing rows: [SetupRow]? = nil) -> AppController {
        var options = LaunchOptions()
        options.home = home
        options.support = root.appendingPathComponent("support", isDirectory: true)
        options.continueSetup = rows
        let app = AppController(options: options)
        app.staysInBackground = true
        self.app = app
        return app
    }
    private func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
    private func shows(_ app: AppController, _ folder: URL, selecting item: URL) -> Bool {
        guard let tab = app.frontmost()?.activeTab, !tab.isLoading,
              let here = tab.location.mutationTarget, BrowserWindowController.isSame(here, folder) else { return false }
        return tab.snapshot.sortedEntries.contains { tab.selection.contains($0.id) && BrowserWindowController.isSame($0.url, item) }
    }
    private func showsHome(_ app: AppController) -> Bool {
        app.allWindows.contains { window in
            window.activeTab?.location.mutationTarget.map { BrowserWindowController.isSame($0, home) } ?? false
        }
    }

    func testARequestThatStartsHelmShowsItsItemNotHome() async {
        let app = makeApp()
        // The launch's own open-documents event comes before there's a window to take it.
        app.receive(.open([report]), from: nil)
        await app.compose()
        let shown = await until { shows(app, documents, selecting: report) }
        XCTAssertTrue(shown, "the report was never shown selected in Documents")
        XCTAssertEqual(app.allWindows.count, 1)
        XCTAssertFalse(showsHome(app))
    }

    /// Review: Services › Show in Helm can start Helm, and its request then comes before there's a window to take it.
    /// It waits for the launch, as Open in Helm does. Before, it was lost and the launch showed Home.
    func testShowInHelmThatStartsHelmShowsItsItemNotHome() async {
        let app = makeApp()
        let pasteboard = NSPasteboard(name: .init("helm.viewer-launch.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([report as NSURL])
        var error: NSString?
        app.showInHelm(pasteboard, userData: nil, error: &error)
        XCTAssertNil(error)
        // Whatever the service does by itself is done before the launch gets going.
        try? await Task.sleep(nanoseconds: 200_000_000)
        await app.compose()
        let shown = await until { shows(app, documents, selecting: report) }
        XCTAssertTrue(shown, "the report was never shown selected in Documents")
        XCTAssertEqual(app.allWindows.count, 1)
        XCTAssertFalse(showsHome(app))
    }

    func testARequestWhileTheWindowsArePlacedIsNotLost() async {
        let app = makeApp()
        // Sent just after the launch took the waiting requests, while it places the first window: before, it was lost
        // and the launch showed Home.
        app.launchQueueTakenForTesting = { [unowned app, report = self.report] in
            app.launchQueueTakenForTesting = nil
            XCTAssertTrue(app.isPlacingWindows)
            app.receive(.reveal([report]), from: "com.apple.mail")
        }
        await app.compose()
        let shown = await until { shows(app, documents, selecting: report) }
        XCTAssertTrue(shown, "the report was never shown selected in Documents")
        XCTAssertEqual(app.allWindows.count, 1)
        XCTAssertFalse(showsHome(app))
    }

    func testAHelperFinderStartedOpensNoWindowThenTheDockLaunchesAsUsual() async {
        let app = makeApp()
        // Archive Utility, after a double-click in Finder, launching Helm with what it expanded.
        let expanded = documents.appendingPathComponent("Photos", isDirectory: true)
        app.receive(.open([expanded]), from: "com.apple.archiveutility")
        await app.compose()
        XCTAssertTrue(app.allWindows.isEmpty, "Helm opened a window for a request that was Finder's")
        XCTAssertTrue(app.startedForFinder)
        XCTAssertEqual(app.finderShownForTesting.map { $0.map(PathSpelling.standardPath) }, [[PathSpelling.standardPath(documents)]])
        // Its reopen as it quits brings Finder forward and still opens nothing here.
        XCTAssertFalse(app.reopen(from: "com.apple.archiveutility", hasVisibleWindows: false))
        XCTAssertEqual(app.finderShownForTesting.last, [])
        XCTAssertTrue(app.allWindows.isEmpty)
        // A click on Helm's Dock icon is the launch that was put off.
        XCTAssertFalse(app.reopen(from: "com.apple.dock", hasVisibleWindows: false))
        let opened = await until { app.allWindows.count == 1 }
        XCTAssertTrue(opened, "the Dock click opened no window")
        XCTAssertFalse(app.startedForFinder)
    }

    /// Review: while Archive Utility runs, a launch that names nothing is taken for the one it makes as it quits, and
    /// opens no window. A click on the Dock icon afterwards is someone asking for Helm: it's the launch that was put
    /// off, and it opens a window whatever else is running. Before, it was taken for Archive Utility's too.
    func testTheDockOpensAWindowEvenWhileArchiveUtilityRuns() async {
        let app = makeApp()
        app.isArchiveUtilityRunning = { true }
        await app.compose()
        XCTAssertTrue(app.allWindows.isEmpty, "Archive Utility's launch opened a window")
        XCTAssertTrue(app.startedForFinder)
        XCTAssertFalse(app.reopen(from: "com.apple.dock", hasVisibleWindows: false))
        let opened = await until { app.allWindows.count == 1 }
        XCTAssertTrue(opened, "the Dock click opened no window while Archive Utility ran")
        XCTAssertFalse(app.startedForFinder)
    }

    /// Review: the copy Set Up moved into Applications names nothing either, but Helm's own mover opened it, with
    /// --continue-setup. It opens its window and carries on with the setup even while Archive Utility runs.
    func testTheCopySetUpMovedOpensEvenWhileArchiveUtilityRuns() async throws {
        let app = makeApp(continuing: [.fileViewer, .moveToApplications])
        app.isArchiveUtilityRunning = { true }
        await app.compose()
        let welcome = try XCTUnwrap(app.onboardingForTesting, "the moved copy didn't carry on with the setup")
        defer { welcome.close() }
        XCTAssertEqual(app.allWindows.count, 1, "the moved copy opened no window while Archive Utility ran")
        XCTAssertFalse(app.startedForFinder)
        XCTAssertEqual(welcome.modeForTesting, "setup")
        // A test stays in the background, the welcome window included.
        XCTAssertEqual(welcome.window?.alphaValue, 0)
    }

    func testAHandoffEndsSoonAfterTheHelperQuits() async {
        let app = makeApp()
        app.lastRequestGrace = 0.1
        let helper = "com.apple.archiveutility"
        app.handoffs.record([documents.appendingPathComponent("Photos.zip")], helper: helper)
        // Archive Utility quits, and its last request doesn't reach Helm, or comes with a sender Helm can't name.
        app.senders.forget(4242, identifier: helper)
        // Just after the quit, its last request still comes back to Helm.
        XCTAssertEqual(app.handoffs.route(.reopen, sender: helper), .helm(reveal: true, handoff: app.handoffs.ledger.handoffs.first))
        let ended = await until { app.handoffs.ledger.handoffs.isEmpty }
        XCTAssertTrue(ended, "the hand-off outlived Archive Utility, so Finder's next expansion would come to Helm")
        XCTAssertEqual(app.handoffs.route(.reopen, sender: helper), .finder([]))
        // An archive handed to a new copy right after that quit stays Helm's.
        app.senders.forget(4243, identifier: helper)
        try? await Task.sleep(nanoseconds: 20_000_000)
        app.handoffs.record([documents.appendingPathComponent("Other.zip")], helper: helper)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(app.handoffs.ledger.handoffs.map(\.item.lastPathComponent), ["Other.zip"])
        // Another app quitting ends nothing.
        app.senders.forget(4244, identifier: "com.apple.Safari")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(app.handoffs.ledger.handoffs.count, 1)
    }

    func testADoubleClickOnHelmInFinderShowsHelmNotFinder() async {
        let app = makeApp()
        app.receive(.open([documents.appendingPathComponent("Photos", isDirectory: true)]), from: "com.apple.archiveutility")
        await app.compose()
        XCTAssertTrue(app.startedForFinder)
        let handedBack = app.finderShownForTesting.count
        // A double-click on Helm.app in a Finder window reaches a running Helm as a reopen from Finder. It's the
        // launch that was put off, as a Dock click is, and nothing goes back to Finder.
        XCTAssertFalse(app.reopen(from: "com.apple.finder", hasVisibleWindows: false))
        let opened = await until { app.allWindows.count == 1 }
        XCTAssertTrue(opened, "the double-click in Finder opened no Helm window")
        XCTAssertEqual(app.finderShownForTesting.count, handedBack, "the double-click on Helm was handed to Finder")
        // With Helm's window up, another one brings Helm forward: still nothing for Finder, and no second window.
        XCTAssertTrue(app.reopen(from: "com.apple.finder", hasVisibleWindows: true))
        XCTAssertEqual(app.finderShownForTesting.count, handedBack)
        XCTAssertEqual(app.allWindows.count, 1)
    }

    // MARK: Documents Helm couldn't read

    /// A sidebar.json from a newer Helm, which this one can't read, so the launch has something to report.
    private func leaveAnUnreadableDocument() throws {
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":2,"items":{}}"#.utf8).write(to: StoreLocation(directory: support).sidebar)
    }
    /// Each time the alert would come up: the documents it names, and how many windows Helm had then.
    private func watchReports(_ app: AppController) -> LoadFailureReports {
        let reports = LoadFailureReports()
        app.loadFailuresShownForTesting = { [weak app] documents in reports.shown.append((documents, app?.allWindows.count ?? 0)) }
        return reports
    }

    /// At a normal launch, the alert comes as before: once the first window is up, before the launch goes on.
    func testANormalLaunchReportsWhatItCouldntReadAtOnce() async throws {
        try leaveAnUnreadableDocument()
        let app = makeApp()
        let reports = watchReports(app)
        await app.compose()
        XCTAssertEqual(reports.shown.map(\.documents), [["sidebar"]])
        XCTAssertEqual(reports.shown.first?.windows, 1)
        app.openWindow(at: .directory(documents), selecting: [])
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(reports.shown.count, 1, "the alert came again for another window")
    }

    /// Review: a launch only for Finder, as Archive Utility makes, has no window, so the alert waited for none and came
    /// up over Finder. It's held back now, and the first window Helm opens later says it, once: from the Dock here.
    func testALaunchOnlyForFinderHoldsItsReportForTheFirstWindow() async throws {
        try leaveAnUnreadableDocument()
        let app = makeApp()
        let reports = watchReports(app)
        app.receive(.open([documents.appendingPathComponent("Photos", isDirectory: true)]), from: "com.apple.archiveutility")
        await app.compose()
        XCTAssertTrue(app.startedForFinder)
        // Archive Utility's reopen as it quits goes to Finder too.
        XCTAssertFalse(app.reopen(from: "com.apple.archiveutility", hasVisibleWindows: false))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(app.allWindows.isEmpty)
        XCTAssertTrue(reports.shown.isEmpty, "the alert came up with no window of Helm's, over Finder")
        XCTAssertFalse(app.reopen(from: "com.apple.dock", hasVisibleWindows: false))
        let reported = await until { !reports.shown.isEmpty }
        XCTAssertTrue(reported, "the first window never said what couldn't be read")
        XCTAssertEqual(reports.shown.map(\.documents), [["sidebar"]])
        XCTAssertEqual(reports.shown.first?.windows, 1)
        app.openWindow(at: .directory(documents), selecting: [])
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(reports.shown.count, 1)
    }

    /// The same when the first window is Show in Helm's, after Archive Utility's launch that named nothing.
    func testALaunchOnlyForFinderReportsWhenShowInHelmOpensAWindow() async throws {
        try leaveAnUnreadableDocument()
        let app = makeApp()
        let reports = watchReports(app)
        app.isArchiveUtilityRunning = { true }
        await app.compose()
        XCTAssertTrue(app.startedForFinder)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(reports.shown.isEmpty, "the alert came up with no window of Helm's, over Finder")
        let pasteboard = NSPasteboard(name: .init("helm.viewer-launch.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([report as NSURL])
        var error: NSString?
        app.showInHelm(pasteboard, userData: nil, error: &error)
        XCTAssertNil(error)
        let reported = await until { !reports.shown.isEmpty }
        XCTAssertTrue(reported, "Show in Helm's window never said what couldn't be read")
        XCTAssertEqual(reports.shown.map(\.documents), [["sidebar"]])
        XCTAssertEqual(reports.shown.first?.windows, 1)
        let shown = await until { shows(app, documents, selecting: report) }
        XCTAssertTrue(shown, "the report was never shown selected in Documents")
    }
}

/// What the alert about unreadable documents would have said, each time it came up.
private final class LoadFailureReports {
    var shown: [(documents: [String], windows: Int)] = []
}
#endif
