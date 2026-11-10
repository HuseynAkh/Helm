#if os(macOS)
import AppKit
import XCTest
import HelmCore
import HelmApp
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmUI

/// Navigation in a whole window over the in-memory home: how wide the window lets itself get, what the path, the tabs
/// and the title say while a card is up, where Go › Utilities goes, what new tabs and windows leave in Recent, and how
/// a hidden item asked for by name is shown.
@MainActor final class HuntNavigationWindowTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/helm", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var reports: URL { documents.appendingPathComponent("Reports", isDirectory: true) }
    private let longName = "A folder with a really long name that goes on and on for quite a while longer than usual"
    private var longFolder: URL { documents.appendingPathComponent(longName, isDirectory: true) }
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []
    private var recents: (any AppRecentStoring)?
    private var settings: SettingsStore?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
    }
    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers = []
        keep = []
        recents = nil
        settings = nil
        HeaderMotion.isDisabledForTesting = false
        super.tearDown()
    }

    /// What a window needs, over a home with Documents, Downloads, Reports, a folder with a long name and a hidden file.
    private func dependencies() async throws -> WindowDependencies {
        let env = try await AppEnvironment.test(home: home)
        for folder in ["Documents", "Downloads", "Documents/Reports", "Documents/\(longName)"] {
            try await env.fileSystem.createDirectory(at: home.appendingPathComponent(folder, isDirectory: true))
        }
        try await env.fileSystem.createFileExclusively(at: documents.appendingPathComponent(".secret"), contents: Data("s".utf8))
        let operations = OperationCoordinator(fileSystem: env.fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: env.directories.home) { false }
        keep += [operations, volumes]
        recents = env.recents
        settings = env.settings
        return WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: env.fileSystem,
            operations: operations, home: env.directories.home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.hunt-navigation.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith)
    }
    /// A window that's never shown, opening its tabs as `seeds` say.
    private func window(_ dependencies: WindowDependencies, seeds: [BrowserTabSeed]) -> BrowserWindowController {
        let host = HuntNavigationHost()
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "hunt-navigation",
                                                 seeds: seeds, activeIndex: 0)
        keep.append(host)
        controllers.append(controller)
        return controller
    }
    /// A window that's never shown, in Documents.
    private func documentsWindow() async throws -> BrowserWindowController {
        let controller = window(try await dependencies(), seeds: [])
        controller.navigate(to: .directory(documents))
        let arrived = await until { controller.activeTab?.location == .directory(self.documents) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "Documents never opened")
        return controller
    }

    private func until(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
    private func settle(_ seconds: Double = 0.2) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    /// Asks the window for a width, as a drag or tiling does, and lets it lay out.
    private func resize(_ controller: BrowserWindowController, to width: CGFloat) async {
        guard let window = controller.window else { return XCTFail("no window") }
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: false)
        await layOut(controller)
    }
    private func layOut(_ controller: BrowserWindowController) async {
        controller.window?.displayIfNeeded()
        await settle(0.1)
        controller.window?.contentView?.superview?.layoutSubtreeIfNeeded()
        await settle(0.1)
    }

    // MARK: The window's width

    func testOpeningTabsNeverWidensTheWindowByItself() async throws {
        let controller = try await documentsWindow()
        await resize(controller, to: 1040)
        XCTAssertEqual(controller.window?.frame.width ?? 0, 1040, accuracy: 0.5)
        for _ in 0..<11 { controller.perform(.newTab) }
        _ = await until { controller.store.state.window.tabs.count == 12 }
        await layOut(controller)
        XCTAssertEqual(controller.window?.frame.width ?? 0, 1040, accuracy: 0.5,
                       "Twelve tabs made the window wider by themselves; the tabs' names should shorten instead")
        await resize(controller, to: 800)
        XCTAssertEqual(controller.window?.frame.width ?? 0, 800, accuracy: 0.5, "With twelve tabs the window can't be made narrower")
        // The tabs are at their narrowest, so the strip scrolls, and the tab on show is the one in view.
        XCTAssertTrue(controller.activeTabInViewForTesting, "The active tab is scrolled out of sight")
        controller.perform(.nextTab)
        await layOut(controller)
        XCTAssertTrue(controller.activeTabInViewForTesting, "The first tab, now active, is out of sight")
    }

    func testAFolderWithALongNameNeverWidensTheWindowByItself() async throws {
        let controller = try await documentsWindow()
        await resize(controller, to: 900)
        controller.navigate(to: .directory(longFolder))
        _ = await until { controller.activeTab?.location == .directory(self.longFolder) && controller.activeTab?.isLoading == false }
        await layOut(controller)
        XCTAssertEqual(controller.window?.frame.width ?? 0, 900, accuracy: 0.5,
                       "Opening a folder with a long name made the window wider; the path should shorten the name instead")
        // The search names the folder too, in its scope, which shortens the same way and leaves the room to the words.
        controller.beginSearch()
        await layOut(controller)
        XCTAssertEqual(controller.window?.frame.width ?? 0, 900, accuracy: 0.5, "The search's scope made the window wider")
        XCTAssertLessThanOrEqual(controller.searchScopeWidthForTesting, HeaderSearchField.maximumScopeWidth + 0.5)
        XCTAssertGreaterThan(controller.searchTextRoomForTesting, HeaderSearchField.minimumTextWidth + 20,
                             "The long name in the scope left the words you type no more than their minimum")
    }

    func testAtItsNarrowestTheSearchKeepsRoomForTheWordsYouType() async throws {
        let controller = try await documentsWindow()
        // Narrower than the window goes: it stops at its narrowest.
        await resize(controller, to: 400)
        let narrowest = controller.window?.frame.width ?? 0
        controller.beginSearch()
        await layOut(controller)
        XCTAssertEqual(controller.window?.frame.width ?? 0, narrowest, accuracy: 0.5, "Opening the search made the window wider")
        XCTAssertGreaterThanOrEqual(controller.searchTextRoomForTesting, HeaderSearchField.minimumTextWidth - 0.5,
                                    "The search leaves \(controller.searchTextRoomForTesting) points for the words you type")
        // The scope gave way first, down to its chevron, and names the folder again once there's room.
        XCTAssertLessThan(controller.searchScopeWidthForTesting, 30)
        await resize(controller, to: 1040)
        XCTAssertGreaterThan(controller.searchScopeWidthForTesting, 60)
    }

    func testATabWithALongNameNeverWidensTheWindowByItself() async throws {
        let controller = try await documentsWindow()
        await resize(controller, to: 900)
        controller.newTab(at: .directory(longFolder))
        _ = await until { controller.activeTab?.location == .directory(self.longFolder) && controller.activeTab?.isLoading == false }
        controller.perform(.previousTab)
        await layOut(controller)
        XCTAssertEqual(controller.window?.frame.width ?? 0, 900, accuracy: 0.5,
                       "A second tab with a long name made the window wider; the tab's name should shorten instead")
    }

    // MARK: The path while a card is up

    func testThePathNamesThePlaceTheCardIsAbout() async throws {
        let controller = try await documentsWindow()
        controller.perform(.newTab)
        _ = await until { controller.store.state.window.tabs.count == 2 && controller.activeTab?.isLoading == false }
        let gone = documents.appendingPathComponent("Gone", isDirectory: true)
        controller.navigate(to: .directory(gone))
        let failed = await until { controller.contentStateForTesting?.title == "“Gone” no longer exists" }
        XCTAssertTrue(failed, "No card for the missing folder")
        // The path, the tab and the window's title are all about Gone, as the card and the sidebar are.
        XCTAssertEqual(controller.pathSegmentsForTesting(), ["Home", "Documents", "Gone"],
                       "The path reads \(controller.pathSegmentsForTesting()) while the card says Gone can't be found")
        XCTAssertEqual(controller.tabTitlesForTesting, ["Documents", "Gone"])
        XCTAssertEqual(controller.window?.title, "Gone")
        // Back from the card, everything names Documents again.
        controller.perform(.back)
        _ = await until { controller.contentStateForTesting == nil && controller.activeTab?.isLoading == false }
        XCTAssertEqual(controller.pathSegmentsForTesting(), ["Home", "Documents"])
        XCTAssertEqual(controller.tabTitlesForTesting, ["Documents", "Documents"])
        XCTAssertEqual(controller.window?.title, "Documents")
    }

    /// A drop on a tab goes where the tab says. While a card is up the tab is named for the place that couldn't open,
    /// and the folder under the card is hidden, so the tab takes nothing, as the window's commands put nothing there.
    /// Once the card has gone, the tab takes drops into its folder again.
    func testATabWhoseCardIsUpTakesNoDrop() async throws {
        let controller = try await documentsWindow()
        let file = home.appendingPathComponent("Downloads/plan.txt")
        try await controller.dependencies.fileSystem.createFileExclusively(at: file, contents: Data("p".utf8))
        controller.perform(.newTab)
        _ = await until { controller.store.state.window.tabs.count == 2 && controller.activeTab?.isLoading == false }
        controller.navigate(to: .directory(documents.appendingPathComponent("Gone", isDirectory: true)))
        let failed = await until { controller.contentStateForTesting?.title == "“Gone” no longer exists" }
        XCTAssertTrue(failed, "No card for the missing folder")
        XCTAssertEqual(controller.tabTitlesForTesting, ["Documents", "Gone"])
        let pasteboard = NSPasteboard(name: .init("helm.hunt-navigation.drop.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let drag = ScriptedSidebarDrag(pasteboard: pasteboard, location: .zero, window: controller.window)
        let tab = controller.activeTabID
        XCTAssertEqual(controller.tabStripDropOperation(drag, onto: tab), [],
                       "The tab named Gone offered to take plan.txt into Documents, hidden under its card")
        XCTAssertFalse(controller.tabStripPerformDrop(drag, onto: tab))
        await settle(0.3)
        let names = try await controller.dependencies.fileSystem.childNames(of: documents)
        XCTAssertFalse(names.contains("plan.txt"), "plan.txt went into Documents, under the card")
        // Back from the card, the tab is Documents again and takes the file there.
        controller.perform(.back)
        _ = await until { controller.contentStateForTesting == nil && controller.activeTab?.isLoading == false }
        XCTAssertEqual(controller.tabTitlesForTesting, ["Documents", "Documents"])
        XCTAssertEqual(controller.tabStripDropOperation(drag, onto: tab), .move)
    }

    // MARK: Go menu

    func testGoUtilitiesOpensAFolderHoldingMacOSsUtilities() async throws {
        let controller = try await documentsWindow()
        controller.perform(.utilities)
        guard case .directory(let target)? = controller.activeTab?.pendingNavigation?.target else {
            return XCTFail("Go › Utilities went nowhere")
        }
        XCTAssertEqual(target.path, "/System/Applications/Utilities")
        // Only reads the folder's names, where this Mac has them; nothing is opened or changed.
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
        XCTAssertTrue(names.contains("Terminal.app") && names.contains("Activity Monitor.app"),
                      "Go › Utilities opens \(target.path), which holds \(names.isEmpty ? "nothing" : names.joined(separator: ", "))")
    }

    // MARK: Recent

    func testAFolderOpenedInANewTabGoesIntoRecent() async throws {
        let controller = try await documentsWindow()
        recents?.clear()
        controller.newTab(at: .directory(reports))
        let arrived = await until { controller.activeTab?.location == .directory(self.reports) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived)
        XCTAssertTrue(inRecent(reports), "Recent has \(recentPaths) after opening Reports in a new tab")
    }

    func testANewWindowAtAFolderGoesIntoRecentButARestoredOneDoesNot() async throws {
        let shared = try await dependencies()
        recents?.clear()
        let restored = window(shared, seeds: [BrowserTabSeed(location: .directory(documents))])
        let opened = window(shared, seeds: [BrowserTabSeed(location: .directory(reports), intent: .open)])
        let arrived = await until { [restored, opened].allSatisfy { $0.activeTab?.isLoading == false } }
        XCTAssertTrue(arrived)
        XCTAssertTrue(inRecent(reports), "Recent has \(recentPaths) after a new window opened at Reports")
        XCTAssertFalse(inRecent(documents), "A restored window counted as a visit: \(recentPaths)")
    }

    private var recentPaths: [String] { recents?.records.map(\.path) ?? [] }
    private func inRecent(_ folder: URL) -> Bool {
        recentPaths.contains { PathSpelling.standardPath(URL(fileURLWithPath: $0)) == PathSpelling.standardPath(folder) }
    }

    // MARK: Hidden items asked for by name

    func testAHiddenItemAskedForByNameIsShownAndSelected() async throws {
        let controller = try await documentsWindow()
        let secret = documents.appendingPathComponent(".secret")
        XCTAssertFalse(controller.activeTab?.snapshot.sortedEntries.contains { $0.name == ".secret" } ?? true)
        // As a typed path, or Go › Enclosing Folder from a search, reveals it: from another folder.
        controller.navigate(to: .directory(home))
        _ = await until { controller.activeTab?.location == .directory(self.home) && controller.activeTab?.isLoading == false }
        controller.revealInCurrentTab(secret)
        let shown = await until { controller.selectedEntries().map(\.name) == [".secret"] }
        XCTAssertTrue(shown, "Selected \(controller.selectedEntries().map(\.name)) in \(String(describing: controller.activeTab?.location))")
        // Only this tab lists hidden items, and the setting stays as it was.
        XCTAssertEqual(controller.activeTab?.showHidden, true)
        XCTAssertEqual(settings?.snapshot.showHiddenFiles, false)
        // Another app's Show in Finder, in a tab that hides them, does the same.
        controller.perform(.newTab)
        controller.perform(.hidden)
        _ = await until { controller.activeTab?.showHidden == false && controller.activeTab?.isLoading == false }
        controller.show(folder: documents, selecting: [secret])
        let again = await until { controller.selectedEntries().map(\.name) == [".secret"] }
        XCTAssertTrue(again, "Selected \(controller.selectedEntries().map(\.name))")
    }

    /// A tab listing hidden items to show one asked for by name keeps them through settings that have nothing to do
    /// with hidden files, such as ⌘+, rather than lose the item it was asked to show. Show Hidden Files itself, changed
    /// in Settings, still reaches the tab.
    func testARevealedHiddenItemStaysThroughOtherSettings() async throws {
        let controller = try await documentsWindow()
        controller.revealInCurrentTab(documents.appendingPathComponent(".secret"))
        let shown = await until { controller.selectedEntries().map(\.name) == [".secret"] && controller.activeTab?.isLoading == false }
        XCTAssertTrue(shown, "Selected \(controller.selectedEntries().map(\.name))")
        controller.stepText(by: 1) // ⌘+
        await settle(0.3)
        _ = await until { controller.activeTab?.isLoading == false }
        XCTAssertEqual(controller.activeTab?.showHidden, true, "⌘+ hid the hidden items again")
        XCTAssertEqual(controller.selectedEntries().map(\.name), [".secret"])
        settings?.set(.bool(true), for: .showHiddenFiles)
        settings?.set(.bool(false), for: .showHiddenFiles)
        let hidden = await until { controller.activeTab?.showHidden == false && controller.activeTab?.isLoading == false }
        XCTAssertTrue(hidden, "Show Hidden Files turned off in Settings didn't reach the tab")
        XCTAssertFalse(controller.activeTab?.snapshot.sortedEntries.contains { $0.name == ".secret" } ?? true)
    }
}

@MainActor private final class HuntNavigationHost: BrowserWindowHost {
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
}
#endif
