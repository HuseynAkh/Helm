#if os(macOS)
import AppKit
import XCTest
import HelmCore
import HelmApp
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmUI

/// Hunt: the sidebar and Settings in a whole window over the in-memory home. Nothing here touches the real home,
/// real preferences or real permissions: every store is in memory and no window is ever shown.
@MainActor final class HuntSidebarSettingsWindowTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/helm", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var downloads: URL { home.appendingPathComponent("Downloads", isDirectory: true) }
    private var desktop: URL { home.appendingPathComponent("Desktop", isDirectory: true) }
    private var reports: URL { documents.appendingPathComponent("Reports", isDirectory: true) }
    private var alpha: URL { documents.appendingPathComponent("alpha.md") }
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
    }
    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers = []
        keep = []
        HeaderMotion.isDisabledForTesting = false
        super.tearDown()
    }

    /// A window that's never shown, over a home with Documents (holding alpha.md and Reports/q1.txt), Downloads and
    /// Desktop, already at `place`.
    private func window(at place: URL) async throws -> (BrowserWindowController, AppEnvironment) {
        let env = try await AppEnvironment.test(home: home)
        for folder in ["Documents", "Downloads", "Desktop", "Documents/Reports"] {
            try await env.fileSystem.createDirectory(at: home.appendingPathComponent(folder, isDirectory: true))
        }
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        try await memory.createFileExclusively(at: alpha, contents: Data("a".utf8))
        try await memory.createFileExclusively(at: reports.appendingPathComponent("q1.txt"), contents: Data("r".utf8))
        let operations = OperationCoordinator(fileSystem: env.fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: env.directories.home) { false }
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: env.fileSystem,
            operations: operations, home: env.directories.home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            sidebarLayout: env.sidebarLayout,
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.hunt-sidebar-settings.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith)
        let host = HuntQuietHost()
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "hunt-sidebar-settings",
                                                 seeds: [], activeIndex: 0)
        keep += [host, operations, volumes, env]
        controllers.append(controller)
        controller.navigate(to: .directory(place))
        let arrived = await until { self.isShowing(controller, place) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "\(place.lastPathComponent) never opened")
        return (controller, env)
    }

    /// Waits for something that happens a little later. Generous, so a busy Mac doesn't fail a test that would pass:
    /// it returns as soon as the condition holds.
    private func until(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
    private func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func isShowing(_ controller: BrowserWindowController, _ folder: URL) -> Bool {
        controller.activeTab?.location.mutationTarget?.standardizedFileURL.path == folder.standardizedFileURL.path
    }
    private func names(_ controller: BrowserWindowController) -> [String] {
        controller.activeTab.map { tab in tab.snapshot.sortedEntries.prefix(tab.snapshot.rootCount).map(\.name) } ?? []
    }
    private func paths(_ records: [String]) -> [String] { records.map { URL(fileURLWithPath: $0).lastPathComponent } }

    // MARK: Starred files

    /// A starred file's menu offers "Open in New Tab". Choosing it should open a tab, and leave this one where it is.
    func testOpenInNewTabOnAStarredFileOpensATabAndLeavesThisOneAlone() async throws {
        let (controller, env) = try await window(at: downloads)
        env.stars.star(alpha, at: Date())
        await settle()
        let id = Place.id(.starred, path: alpha.standardizedFileURL.path)
        let row = try XCTUnwrap(controller.sidebar.listIndexForTesting(of: id), "alpha.md isn't in the sidebar")
        let menu = try XCTUnwrap(controller.sidebar.menu(forRow: row))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open in New Tab" }, "no Open in New Tab")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        await settle(0.6)
        let tabs = controller.store.state.window.tabs
        XCTAssertEqual(tabs.count, 2, "Open in New Tab opened no tab")
        XCTAssertEqual(tabs.first.flatMap { controller.store.state.tabs[$0]?.location }, .directory(downloads),
                       "The tab you were in was taken to alpha.md's folder")
        // The new tab shows alpha.md in its folder, selected.
        XCTAssertTrue(isShowing(controller, documents))
        let selected = await until { controller.selectedEntries().map(\.name) == ["alpha.md"] }
        XCTAssertTrue(selected, "The new tab selected \(controller.selectedEntries().map(\.name))")
    }

    // MARK: Renaming and moving what the sidebar lists

    /// A bookmarked folder and a starred file renamed in Helm keep their bookmark and star, as Finder's sidebar follows
    /// a rename. Today the sidebar keeps the old paths: both rows go dead, and the renamed items lose them.
    func testRenamingABookmarkedFolderAndAStarredFileKeepsTheirRows() async throws {
        let (controller, env) = try await window(at: documents)
        XCTAssertTrue(env.bookmarks.add(reports, isDirectory: true, at: Date()))
        env.stars.star(alpha, at: Date())
        await settle()
        for (old, new) in [("Reports", "Reports 2026"), ("alpha.md", "beta.md")] {
            let entry = try XCTUnwrap(controller.activeTab?.snapshot.sortedEntries.first { $0.name == old }, "no \(old)")
            controller.commitRename(entry, to: new)
            let renamed = await until { controller.activeTab?.snapshot.sortedEntries.contains { $0.name == new } == true }
            XCTAssertTrue(renamed, "\(old) was never renamed")
        }
        await settle(0.6)
        XCTAssertEqual(paths(env.bookmarks.records.map(\.path)), ["Reports 2026"], "The bookmark still points at the old name")
        XCTAssertEqual(paths(env.stars.records.map(\.path)), ["beta.md"], "The star still points at the old name")
        XCTAssertEqual(controller.sidebarRowNamesForTesting(.bookmarks), ["Reports 2026"])
        XCTAssertEqual(controller.sidebarRowNamesForTesting(.starred), ["beta.md"])
    }

    /// Undo puts the folder back, and its bookmark goes back with it.
    func testUndoingARenameTakesTheBookmarkBack() async throws {
        let (controller, env) = try await window(at: documents)
        XCTAssertTrue(env.bookmarks.add(reports, isDirectory: true, at: Date()))
        let entry = try XCTUnwrap(controller.activeTab?.snapshot.sortedEntries.first { $0.name == "Reports" })
        controller.commitRename(entry, to: "Reports 2026")
        let renamed = await until { self.paths(env.bookmarks.records.map(\.path)) == ["Reports 2026"] }
        XCTAssertTrue(renamed, "The bookmark didn't follow the rename")
        await settle()
        await controller.refreshHistoryForTesting()
        controller.perform(.undo)
        let back = await until { self.paths(env.bookmarks.records.map(\.path)) == ["Reports"] }
        XCTAssertTrue(back, "After Undo the bookmark is on \(env.bookmarks.records.map(\.path))")
        XCTAssertEqual(controller.sidebarRowNamesForTesting(.bookmarks), ["Reports"])
    }

    /// A folder moved into another folder takes its bookmark along, and the star of a file inside it. A row you hid
    /// stays hidden after the move.
    func testMovingAFolderTakesItsBookmarkStarsAndHiddenRowAlong() async throws {
        let (controller, env) = try await window(at: documents)
        XCTAssertTrue(env.bookmarks.add(reports, isDirectory: true, at: Date()))
        env.stars.star(reports.appendingPathComponent("q1.txt"), at: Date())
        let layout = controller.dependencies.sidebarLayout
        layout.update { $0.setHidden(Place.id(.bookmark, path: self.reports.standardizedFileURL.path), true) }
        controller.run(.move(sources: [reports], destinationDirectory: desktop))
        let moved = await until { env.bookmarks.records.first?.path.hasPrefix(self.desktop.standardizedFileURL.path) == true }
        XCTAssertTrue(moved, "The bookmark stayed on \(env.bookmarks.records.map(\.path))")
        let movedReports = desktop.appendingPathComponent("Reports", isDirectory: true).standardizedFileURL.path
        XCTAssertEqual(env.bookmarks.records.map(\.path), [movedReports])
        XCTAssertEqual(env.stars.records.map(\.path), [movedReports + "/q1.txt"])
        XCTAssertTrue(layout.layout.isHidden(Place.id(.bookmark, path: movedReports)), "The hidden bookmark came back into view")
        XCTAssertFalse(layout.layout.isHidden(Place.id(.bookmark, path: reports.standardizedFileURL.path)))
        await settle()
        XCTAssertEqual(controller.sidebarRowNamesForTesting(.bookmarks), [])
        XCTAssertEqual(controller.sidebarRowNamesForTesting(.starred), ["q1.txt"])
    }

    // MARK: The sidebar's keys

    /// The sidebar's list, found by its accessibility label in the window's own view tree.
    private func placesList(in controller: BrowserWindowController) -> NSOutlineView? {
        func find(_ view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView, outline.accessibilityLabel() == "Places" { return outline }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return controller.window?.contentView.flatMap(find)
    }
    private func keyEvent(_ key: String, in outline: NSOutlineView) -> NSEvent? {
        let keys: [String: (String, UInt16)] = ["down": ("\u{F701}", 125), "up": ("\u{F700}", 126), "return": ("\r", 36)]
        guard let (characters, code) = keys[key] else { return nil }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: code >= 123 ? [.numericPad, .function] : [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: outline.window?.windowNumber ?? 0,
                                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }
    /// A key pressed while the sidebar's list has the keys.
    private func press(_ key: String, in outline: NSOutlineView) {
        guard let event = keyEvent(key, in: outline) else { return XCTFail("no such key") }
        outline.window?.makeFirstResponder(outline)
        outline.keyDown(with: event)
    }

    /// Arrow keys move the highlight, and the place it lands on opens, as in Finder's sidebar, so the highlight never
    /// names a place that isn't on show. Return opens the highlighted row.
    func testArrowsOpenThePlaceTheHighlightLandsOnAndReturnOpensIt() async throws {
        let (controller, _) = try await window(at: documents)
        let outline = try XCTUnwrap(placesList(in: controller))
        XCTAssertEqual(controller.sidebarHighlightForTesting, "Documents")
        press("down", in: outline)
        let down = await until { self.isShowing(controller, self.downloads) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(down, "Down left the window on \(String(describing: controller.activeTab?.location))")
        XCTAssertEqual(controller.sidebarHighlightForTesting, "Downloads")
        press("up", in: outline)
        let up = await until { self.isShowing(controller, self.documents) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(up, "Up left the window on \(String(describing: controller.activeTab?.location))")
        // A highlight that isn't on show yet, as after a click held down on a row: Return opens it.
        let row = try XCTUnwrap(controller.sidebar.listIndexForTesting(of: "desktop"))
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        press("return", in: outline)
        let opened = await until { self.isShowing(controller, self.desktop) }
        XCTAssertTrue(opened, "Return left the window on \(String(describing: controller.activeTab?.location))")
        XCTAssertEqual(controller.store.state.window.tabs.count, 1)
    }

    /// The menu bar's Rename is Return too. AppKit offers a key to the window's views as a key equivalent before the
    /// menu, so while the sidebar has the keys its Return opens the highlighted row, and doesn't rename the file
    /// selected beside it. While the files have the keys, the sidebar leaves Return to them.
    func testReturnInTheSidebarComesBeforeRename() async throws {
        let (controller, _) = try await window(at: documents)
        let outline = try XCTUnwrap(placesList(in: controller))
        let entry = try XCTUnwrap(controller.activeTab?.snapshot.sortedEntries.first { $0.name == "alpha.md" })
        controller.store.send(.tab(controller.activeTabID, .setSelection([entry.id], source: .user)))
        let event = try XCTUnwrap(keyEvent("return", in: outline))
        controller.focusFilesForTesting()
        XCTAssertFalse(outline.performKeyEquivalent(with: event), "The sidebar took Return from the files")
        let row = try XCTUnwrap(controller.sidebar.listIndexForTesting(of: "downloads"))
        outline.window?.makeFirstResponder(outline)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertTrue(outline.performKeyEquivalent(with: event), "Return went on to the menu bar's Rename")
        let opened = await until { self.isShowing(controller, self.downloads) }
        XCTAssertTrue(opened, "Return left the window on \(String(describing: controller.activeTab?.location))")
        XCTAssertFalse(controller.isRenamingForTesting)
    }

    /// A starred file the highlight lands on shows in its folder, selected. The highlight stays on the file's row
    /// rather than going up to its folder's, so the next arrow carries on past it.
    func testArrowsShowAStarredFileAndCarryOnPastIt() async throws {
        let (controller, env) = try await window(at: downloads)
        env.stars.star(alpha, at: Date())
        env.stars.star(reports.appendingPathComponent("q1.txt"), at: Date())
        await settle()
        let outline = try XCTUnwrap(placesList(in: controller))
        // Trash, the last row before the starred ones.
        let trash = try XCTUnwrap(controller.sidebar.listIndexForTesting(of: "trash"))
        outline.selectRowIndexes(IndexSet(integer: trash), byExtendingSelection: false)
        press("down", in: outline)
        let shown = await until {
            self.isShowing(controller, self.documents) && controller.activeTab?.isLoading == false
                && controller.selectedEntries().map(\.name) == ["alpha.md"]
        }
        XCTAssertTrue(shown, "Down onto alpha.md showed \(String(describing: controller.activeTab?.location)), selecting \(controller.selectedEntries().map(\.name))")
        XCTAssertEqual(controller.sidebarHighlightForTesting, "alpha.md")
        // Something redraws the window: the highlight stays where the keys left it.
        controller.store.send(.tab(controller.activeTabID, .refresh))
        await settle()
        XCTAssertEqual(controller.sidebarHighlightForTesting, "alpha.md")
        press("down", in: outline)
        let next = await until { self.isShowing(controller, self.reports) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(next, "The next Down showed \(String(describing: controller.activeTab?.location))")
        XCTAssertEqual(controller.sidebarHighlightForTesting, "q1.txt")
        // A click elsewhere ends it: the highlight follows what's on show again.
        controller.navigate(to: .directory(downloads))
        let back = await until { self.isShowing(controller, self.downloads) && controller.sidebarHighlightForTesting == "Downloads" }
        XCTAssertTrue(back, "The highlight stayed on \(controller.sidebarHighlightForTesting ?? "nothing")")
    }

    // MARK: Settings › View

    /// Settings › View says its choices are for new windows, except in folders you've changed. In a tab, a folder you've
    /// never changed keeps the view the tab already has, as in Finder.
    func testViewSettingsSayWhatTheyStart() async throws {
        XCTAssertEqual(SettingsPaneView.foldersNote, "New windows use these, except in folders you’ve changed.")
        let (controller, env) = try await window(at: documents)
        XCTAssertEqual(env.settings.snapshot.string(.defaultViewMode), "grid")
        controller.perform(.list)
        controller.navigate(to: .directory(downloads))
        let moved = await until { self.isShowing(controller, self.downloads) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(moved)
        XCTAssertEqual(controller.activeTab?.viewMode, .list, "A tab took Settings' view in a folder it never changed")
        // Documents keeps the view it was given.
        controller.navigate(to: .directory(documents))
        let back = await until { self.isShowing(controller, self.documents) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(back)
        XCTAssertEqual(controller.activeTab?.viewMode, .list)
        // A new window starts out as Settings says, in Downloads, which was never changed.
        let host = HuntQuietHost()
        let other = BrowserWindowController(dependencies: controller.dependencies, host: host, frameName: "hunt-sidebar-settings-2",
                                            seeds: [BrowserTabSeed(location: .directory(downloads))], activeIndex: 0)
        keep.append(host)
        controllers.append(other)
        let opened = await until { self.isShowing(other, self.downloads) && other.activeTab?.isLoading == false }
        XCTAssertTrue(opened)
        XCTAssertEqual(other.activeTab?.viewMode, .grid)
    }

    // MARK: Settings that reach open windows

    /// Settings › Advanced › "Update folders when they change" reaches a window that's already open: off, a
    /// file made elsewhere waits for a refresh; on again, the folder catches up by itself.
    func testTurningLiveUpdatesOffAndOnReachesAnOpenWindow() async throws {
        let (controller, env) = try await window(at: documents)
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        env.settings.set(.bool(false), for: .liveMonitoringEnabled)
        try await memory.createFileExclusively(at: documents.appendingPathComponent("made-elsewhere.txt"), contents: Data("x".utf8))
        // Longer than the in-memory disk's 3-second polling, which picks the file up while updates are on.
        await settle(4)
        XCTAssertFalse(names(controller).contains("made-elsewhere.txt"), "The open window kept updating with updates off")
        env.settings.set(.bool(true), for: .liveMonitoringEnabled)
        let caughtUp = await until { self.names(controller).contains("made-elsewhere.txt") }
        XCTAssertTrue(caughtUp, "Turning updates back on didn't catch the folder up: \(names(controller))")
    }

    /// Settings › Advanced › "Suggest folders … ms after you stop typing", under Typing a Path.
    func testFolderSuggestionsWaitForThePauseSettingsGives() async throws {
        let (controller, env) = try await window(at: documents)
        env.settings.set(.integer(3_000), for: .completionDebounceMilliseconds)
        controller.store.send(.tab(controller.activeTabID, .addressBar(.beginEditing)))
        controller.store.send(.tab(controller.activeTabID, .addressBar(.textChanged(home.path + "/Down"))))
        await settle(0.3)
        XCTAssertEqual(controller.activeTab?.addressBar.rows.map(\.name), [], "Suggestions came before the pause was over")
        let shown = await until { controller.activeTab?.addressBar.rows.map(\.name) == ["Downloads"] }
        XCTAssertTrue(shown, "No suggestion after the pause: \(controller.activeTab?.addressBar.rows.map(\.name) ?? [])")
    }

    /// Review: the pause is kept with only a lower bound, so a preference edited by hand can be huge. Typing then waits
    /// that long for suggestions; before, the wait overflowed and Helm crashed at the first key.
    func testAHugePauseInThePreferencesOnlyHoldsSuggestionsBack() async throws {
        let (controller, env) = try await window(at: documents)
        env.settings.set(.integer(Int.max), for: .completionDebounceMilliseconds)
        controller.store.send(.tab(controller.activeTabID, .addressBar(.beginEditing)))
        controller.store.send(.tab(controller.activeTabID, .addressBar(.textChanged(home.path + "/Down"))))
        controller.store.send(.tab(controller.activeTabID, .addressBar(.textChanged(home.path + "/Downl"))))
        await settle(0.3)
        XCTAssertEqual(controller.activeTab?.addressBar.rows.map(\.name), [])
        XCTAssertEqual(controller.activeTab?.addressBar.text, home.path + "/Downl")
    }
}

@MainActor private final class HuntQuietHost: BrowserWindowHost {
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
}
#endif
