#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import HelmCore
import HelmApp
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmUI

/// Bug hunt, views: a whole window over the in-memory home. Each test states what a person expects; a failure here
/// is the bug it names.
@MainActor final class HuntViewsWindowTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/hunt", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var many: URL { documents.appendingPathComponent("Many", isDirectory: true) }
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        ListMotion.enabled = false
    }
    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers = []
        keep = []
        HeaderMotion.isDisabledForTesting = false
        ListMotion.enabled = true
        super.tearDown()
    }

    /// A window that's never shown, in Documents, which holds aq-file.txt, q-file.txt, top.txt and Many (five files).
    private func documentsWindow(clock: any HelmClock = SystemHelmClock()) async throws -> BrowserWindowController {
        let env = try await AppEnvironment.test(home: home, clock: clock)
        for folder in ["Documents", "Documents/Many"] {
            try await env.fileSystem.createDirectory(at: home.appendingPathComponent(folder, isDirectory: true))
        }
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        for name in ["aq-file.txt", "q-file.txt", "top.txt"] {
            try await memory.createFileExclusively(at: documents.appendingPathComponent(name), contents: Data("x".utf8))
        }
        for number in 1...5 {
            try await memory.createFileExclusively(at: many.appendingPathComponent("file-0\(number).txt"), contents: Data("abc".utf8))
        }
        let operations = OperationCoordinator(fileSystem: env.fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: env.directories.home) { false }
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: env.fileSystem,
            operations: operations, home: env.directories.home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.hunt-views.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith)
        let host = HuntViewsQuietHost()
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "hunt-views",
                                                 seeds: [], activeIndex: 0)
        keep += [host, operations, volumes]
        controllers.append(controller)
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
    private func rootNames(_ controller: BrowserWindowController) -> [String] {
        guard let tab = controller.activeTab else { return [] }
        return tab.snapshot.sortedEntries.prefix(tab.snapshot.rootCount).map(\.name)
    }
    /// Opens Many in the list and waits for its files.
    private func openMany(_ controller: BrowserWindowController) async throws {
        controller.perform(.list)
        let entry = try XCTUnwrap(controller.activeTab?.snapshot.sortedEntries.first { $0.name == "Many" })
        controller.store.send(.tab(controller.activeTabID, .expand(entry.id)))
        let opened = await until { controller.activeTab?.snapshot.children[entry.id]?.sortedIDs.count == 5 }
        XCTAssertTrue(opened, "Many never opened")
    }
    private func select(_ names: [String], in controller: BrowserWindowController) {
        guard let tab = controller.activeTab else { return }
        let ids = tab.snapshot.sortedEntries.filter { names.contains($0.name) }.map(\.id)
        controller.store.send(.tab(tab.id, .setSelection(Set(ids), source: .user)))
    }
    /// The status bar's words, read from the view on show.
    private func statusText(_ controller: BrowserWindowController) -> String? {
        func find(_ view: NSView) -> NSHostingView<StatusBarView>? {
            for child in view.subviews {
                if let host = child as? NSHostingView<StatusBarView> { return host }
                if let found = find(child) { return found }
            }
            return nil
        }
        guard let content = controller.window?.contentView, let host = find(content) else { return nil }
        return Mirror(reflecting: host.rootView).children.first { $0.label == "text" }?.value as? String
    }

    // MARK: The sort button during a search

    /// A search lists its results Best Match first, so the sort button, View › Sort By and the popover should say so.
    /// They kept saying the folder's own sort ("A to Z"), and pressing Name, which they said was on, turned it Z to A.
    func testTheSortButtonSaysBestMatchWhileTheResultsAreInBestMatchOrder() async throws {
        let controller = try await documentsWindow()
        controller.contentSetSortForTesting(ItemSort(field: .name, ascending: true))
        XCTAssertEqual(controller.headerSortTitleForTesting, "A to Z")
        controller.search("q")
        let found = await until { self.rootNames(controller).count == 2 }
        XCTAssertTrue(found, "no results")
        XCTAssertEqual(rootNames(controller), ["q-file.txt", "aq-file.txt"], "the results are in Best Match order, not A to Z")
        XCTAssertEqual(controller.headerSortTitleForTesting, "Best Match", "the sort button names a sort the results aren't in")
        XCTAssertEqual(controller.activeTab?.shownSort.field, .relevance, "the popover ticks Name")
        XCTAssertEqual(tickedSortItems(controller), ["Best Match"], "View › Sort By ticks Name")
        // Name after Best Match starts at A to Z, as any new field does; it doesn't reverse a sort never applied.
        controller.pressSort(.name)
        await settle()
        XCTAssertEqual(rootNames(controller), ["aq-file.txt", "q-file.txt"])
        XCTAssertEqual(controller.headerSortTitleForTesting, "A to Z")
        // Best Match again, then the search ends: the folder has its own sort back, never Best Match.
        controller.pressSort(.relevance)
        await settle()
        XCTAssertEqual(rootNames(controller), ["q-file.txt", "aq-file.txt"])
        XCTAssertEqual(controller.headerSortTitleForTesting, "Best Match")
        controller.store.send(.tab(controller.activeTabID, .searchEnded))
        await settle()
        XCTAssertEqual(controller.activeTab?.sort, ItemSort(field: .name, ascending: true))
        XCTAssertEqual(controller.headerSortTitleForTesting, "A to Z")
        XCTAssertEqual(tickedSortItems(controller), ["Name", "A to Z", "Keep Folders on Top"])
    }
    /// The ticked rows of View › Sort By, as the menu bar fills it.
    private func tickedSortItems(_ controller: BrowserWindowController) -> [String] {
        let menu = NSMenu()
        controller.fillSortItems(in: menu)
        return menu.items.filter { $0.state == .on }.map(\.title)
    }

    // MARK: Switching to the grid

    /// The grid shows only the folder's own items. A file selected inside an open folder in the list can't be seen
    /// there, so it shouldn't stay selected: today the grid draws nothing selected while Move to Trash, Quick Look
    /// and Return all act on that file.
    func testTheGridDoesntKeepASelectionItCantShow() async throws {
        let controller = try await documentsWindow()
        try await openMany(controller)
        select(["file-01.txt"], in: controller)
        XCTAssertEqual(controller.selectedEntries().map(\.name), ["file-01.txt"])
        controller.perform(.grid)
        await settle()
        XCTAssertEqual(controller.activeTab?.viewMode, .grid)
        XCTAssertEqual(controller.selectedEntries().map(\.name), [], "a file the grid doesn't show is still selected")
        XCTAssertFalse(controller.title(of: .trash).1, "Move to Trash is on for a file nobody can see")
    }

    // MARK: The status bar

    /// Five files selected inside an open folder read as five, not as the three items at the top.
    func testTheStatusBarCountsWhatsSelectedInsideAnOpenFolder() async throws {
        let controller = try await documentsWindow()
        try await openMany(controller)
        select((1...5).map { "file-0\($0).txt" }, in: controller)
        XCTAssertEqual(controller.activeTab?.selection.count, 5)
        await settle()
        let text = statusText(controller) ?? "<no status bar>"
        XCTAssertTrue(text.contains("5 selected"), "the status bar says “\(text)”")
        // The rows inside the open folder are on show, so they count: four at the top and Many's five.
        XCTAssertTrue(text.hasPrefix("9 items  •  5 selected  •  15 bytes"), "the status bar says “\(text)”")
        controller.perform(.grid)
        await settle()
        XCTAssertTrue(statusText(controller)?.hasPrefix("4 items  •  ") == true, statusText(controller) ?? "")
    }

    /// The free space is read again after a refresh, and once a reading is a few seconds old, so a download or a copy
    /// shows. It used to keep the first reading for as long as the window was open.
    func testTheFreeSpaceIsReadAgain() async throws {
        let clock = HuntViewsClock()
        let controller = try await documentsWindow(clock: clock)
        let memory = try XCTUnwrap(controller.dependencies.fileSystem as? InMemoryFileSystem)
        let first = await until { self.statusText(controller)?.hasSuffix(" free") == true }
        XCTAssertTrue(first, statusText(controller) ?? "")
        await memory.setAvailableCapacity(2_000_000_000)
        controller.perform(.refresh)
        let refreshed = await until { self.statusText(controller)?.hasSuffix("2 GB free") == true }
        XCTAssertTrue(refreshed, statusText(controller) ?? "")
        // A fresh reading stands for a few seconds, then the next look at the folder reads the disk again.
        await memory.setAvailableCapacity(1_000_000_000)
        select(["top.txt"], in: controller)
        await settle()
        XCTAssertTrue(statusText(controller)?.hasSuffix("2 GB free") == true, statusText(controller) ?? "")
        clock.advance(by: BrowserWindowController.freeSpaceLifetime + 1)
        select(["q-file.txt"], in: controller)
        let aged = await until { self.statusText(controller)?.hasSuffix("1 GB free") == true }
        XCTAssertTrue(aged, statusText(controller) ?? "")
    }

    // MARK: Inside an open folder

    /// Inside a folder open in the list, a renamed file stays selected, and Move to Trash hands the selection to the
    /// next file, as both do at the top level.
    func testRenameAndTrashInsideAnOpenFolderKeepASelection() async throws {
        let controller = try await documentsWindow()
        try await openMany(controller)
        select(["file-02.txt"], in: controller)
        let entry = try XCTUnwrap(controller.selectedEntries().first)
        controller.commitRename(entry, to: "file-02b.txt")
        let renamed = await until { controller.selectedEntries().map(\.name) == ["file-02b.txt"] }
        XCTAssertTrue(renamed, "selected \(controller.selectedEntries().map(\.name))")
        select(["file-03.txt"], in: controller)
        controller.perform(.trash)
        let next = await until {
            controller.selectedEntries().map(\.name) == ["file-04.txt"]
                && controller.activeTab?.snapshot.entry(ItemID(url: self.many.appendingPathComponent("file-03.txt"))) == nil
        }
        XCTAssertTrue(next, "selected \(controller.selectedEntries().map(\.name))")
    }
}

/// A clock a test moves on by hand.
private final class HuntViewsClock: HelmClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(by seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
}

/// A host for a window on its own: nothing to open, close or show.
@MainActor private final class HuntViewsQuietHost: BrowserWindowHost {
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
}
#endif
