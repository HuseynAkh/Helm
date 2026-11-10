#if os(macOS)
import AppKit
import XCTest
import HelmCore
import HelmApp
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmUI

/// File operations in real windows over the in-memory home: windows share one pasteboard, so a cut made in one window
/// and pasted in another must move, as it does inside one window. Operations asked for one after another each get
/// their turn, a card stays up through the refresh an operation causes, and Undo takes away only the latest change.
@MainActor final class HuntOperationsWindowTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/hunt", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var downloads: URL { home.appendingPathComponent("Downloads", isDirectory: true) }
    private var desktop: URL { home.appendingPathComponent("Desktop", isDirectory: true) }
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []
    private var messages: [String] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }
    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers = []
        keep = []
        super.tearDown()
    }

    /// Two windows that are never shown, sharing everything a real app's windows share.
    private func twoWindows(files: [String] = ["Documents/notes.txt"]) async throws -> (BrowserWindowController, BrowserWindowController, InMemoryFileSystem) {
        let env = try await AppEnvironment.test(home: home)
        for folder in ["Documents", "Downloads", "Desktop"] {
            try await env.fileSystem.createDirectory(at: home.appendingPathComponent(folder, isDirectory: true))
        }
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        for path in files {
            let url = home.appendingPathComponent(path)
            if path.hasSuffix("/") { try await memory.createDirectory(at: url) }
            else { try await memory.createFileExclusively(at: url, contents: Data("hello".utf8)) }
        }
        let operations = OperationCoordinator(fileSystem: env.fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: env.directories.home) { false }
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: env.fileSystem,
            operations: operations, home: env.directories.home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.hunt-operations.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith)
        dependencies.settings.set(.bool(false), for: .askOnConflict)
        let host = HuntOperationsQuietHost()
        let first = BrowserWindowController(dependencies: dependencies, host: host, frameName: "hunt-1", seeds: [], activeIndex: 0)
        let second = BrowserWindowController(dependencies: dependencies, host: host, frameName: "hunt-2", seeds: [], activeIndex: 0)
        keep += [host, operations, volumes]
        controllers += [first, second]
        for controller in [first, second] {
            controller.messageObserver = { [weak self] in self?.messages.append($0) }
            controller.confirmsForTesting = true
        }
        first.navigate(to: .directory(documents))
        second.navigate(to: .directory(downloads))
        let arrived = await until {
            first.activeTab?.location == .directory(self.documents) && first.activeTab?.isLoading == false
                && second.activeTab?.location == .directory(self.downloads) && second.activeTab?.isLoading == false
        }
        XCTAssertTrue(arrived, "the folders never opened")
        return (first, second, memory)
    }

    private func until(_ timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
    private func names(_ controller: BrowserWindowController) -> [String] {
        controller.activeTab.map { tab in tab.snapshot.visibleIDs(expanding: tab.expandedIDs).compactMap { tab.snapshot.entry($0)?.name } } ?? []
    }
    private func selected(_ controller: BrowserWindowController) -> [String] {
        controller.selectedEntries().map(\.name).sorted()
    }
    private func select(_ chosen: String..., in controller: BrowserWindowController) {
        guard let tab = controller.activeTab else { return XCTFail("no tab") }
        let entries = tab.snapshot.sortedEntries.filter { chosen.contains($0.name) }
        XCTAssertEqual(entries.count, chosen.count, "not all of \(chosen) are listed")
        controller.store.send(.tab(tab.id, .setSelection(Set(entries.map(\.id)), source: .user)))
    }
    /// Waits for the window's operations to finish and its listing to settle.
    private func settle(_ controller: BrowserWindowController) async {
        _ = await until { !controller.isRunningOperations && controller.activeTab?.isLoading == false }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    private func openInList(_ folder: String, in controller: BrowserWindowController) async {
        controller.perform(.list)
        guard let tab = controller.activeTab, let entry = tab.snapshot.sortedEntries.first(where: { $0.name == folder }) else {
            return XCTFail("no \(folder)")
        }
        controller.store.send(.tab(tab.id, .expand(entry.id)))
        let opened = await until { controller.activeTab?.snapshot.children[entry.id] != nil }
        XCTAssertTrue(opened, "\(folder) never opened")
    }

    func testCutInOneWindowAndPasteInAnotherMoves() async throws {
        let (first, second, memory) = try await twoWindows()
        select("notes.txt", in: first)
        first.perform(.cut)
        XCTAssertEqual(first.activeTab?.cutIDs.count, 1)
        second.perform(.paste)
        let pasted = await until { second.activeTab?.snapshot.sortedEntries.contains { $0.name == "notes.txt" } == true }
        XCTAssertTrue(pasted, "the paste never arrived")
        let stillThere = await memory.exists(documents.appendingPathComponent("notes.txt"))
        XCTAssertFalse(stillThere, "a cut and paste moves the file, whichever window it's pasted in")
        _ = await until(1) { first.activeTab?.cutIDs.isEmpty == true }
        XCTAssertEqual(first.activeTab?.cutIDs.count, 0, "nothing is left drawn as cut once the cut is pasted")
    }

    /// Between two tabs the move always worked, but the first tab kept the item marked: Undo brought it back dimmed.
    func testCutBetweenTabsLeavesNothingDrawnAsCutAfterUndo() async throws {
        let (first, _, memory) = try await twoWindows()
        let cutTab = first.activeTabID
        select("notes.txt", in: first)
        first.perform(.cut)
        first.newTab(at: .directory(downloads))
        _ = await until { first.activeTab?.location == .directory(self.downloads) && first.activeTab?.isLoading == false }
        first.perform(.paste)
        _ = await until { await memory.exists(self.downloads.appendingPathComponent("notes.txt")) }
        await settle(first)
        XCTAssertEqual(first.store.state.tabs[cutTab]?.cutIDs, [])
        first.perform(.undo)
        _ = await until { await memory.exists(self.documents.appendingPathComponent("notes.txt")) }
        await settle(first)
        XCTAssertEqual(first.store.state.tabs[cutTab]?.cutIDs, [], "Undo brings the file back, not the cut")
    }

    /// The card for a place that couldn't open stands in for the folder it covers. An operation's refresh, in this tab
    /// or another, mustn't take it down.
    func testACardStaysUpThroughAnOperationsRefresh() async throws {
        let (first, _, memory) = try await twoWindows(files: ["Documents/notes.txt", "Documents/alpha.md", "Private/"])
        let locked = home.appendingPathComponent("Private", isDirectory: true)
        await memory.setFailure(.permissionDenied, at: locked)
        select("alpha.md", in: first)
        first.perform(.duplicate)
        _ = await until { await memory.exists(self.documents.appendingPathComponent("alpha 2.md")) }
        await settle(first)
        let cardTab = first.activeTabID
        first.navigate(to: .directory(locked))
        let carded = await until { first.activeTab.map { ContentStatePresentation.coveredPlace($0) != nil } ?? false }
        XCTAssertTrue(carded, "no card for Private")

        await first.refreshHistoryForTesting()
        first.perform(.undo)
        _ = await until { !(await memory.exists(self.documents.appendingPathComponent("alpha 2.md"))) }
        await settle(first)
        XCTAssertNotNil(first.activeTab.flatMap(ContentStatePresentation.coveredPlace), "Undo's refresh left the card up")
        XCTAssertTrue(first.isListingHiddenForTesting)

        first.newTab(at: .directory(documents))
        _ = await until { first.activeTab?.location == .directory(self.documents) && first.activeTab?.isLoading == false }
        select("notes.txt", in: first)
        first.perform(.duplicate)
        _ = await until { await memory.exists(self.documents.appendingPathComponent("notes 2.txt")) }
        await settle(first)
        first.store.send(.window(.activate(cardTab)))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(first.activeTab.flatMap(ContentStatePresentation.coveredPlace), "another tab's operation took the card down")
        XCTAssertTrue(first.isListingHiddenForTesting)
    }

    /// The window's history takes one change at a time. A second request used to be refused with a beep, which also
    /// lost half of a Put Back from two folders; now it waits its turn. Undo meanwhile says why it can't run yet.
    func testARequestMadeWhileAnotherRunsWaitsItsTurn() async throws {
        let (first, _, memory) = try await twoWindows(files: ["Documents/a.txt", "Documents/b.txt"])
        await memory.setLatency(nanoseconds: 1_000_000)
        first.run(.move(sources: [documents.appendingPathComponent("a.txt")], destinationDirectory: downloads))
        first.run(.move(sources: [documents.appendingPathComponent("b.txt")], destinationDirectory: desktop))
        XCTAssertTrue(first.isRunningOperations)
        let (busyTitle, busyEnabled) = first.title(of: .undo)
        XCTAssertEqual(busyTitle, "Undo"); XCTAssertFalse(busyEnabled, "Undo is off while the window works")
        first.perform(.undo)
        XCTAssertEqual(messages.last, BrowserWindowController.busyMessage)
        await settle(first)
        await memory.setLatency(nanoseconds: 0)
        let a = await memory.exists(downloads.appendingPathComponent("a.txt"))
        let b = await memory.exists(desktop.appendingPathComponent("b.txt"))
        XCTAssertTrue(a && b, "both moves happened, one after the other")
        XCTAssertFalse(messages.contains(OperationRowModel.message(for: .busy)))
        await first.refreshHistoryForTesting()
        let (title, enabled) = first.title(of: .undo)
        XCTAssertEqual(title, "Undo Move"); XCTAssertTrue(enabled)
    }

    /// Finder and Nautilus move a folder to the Trash with what's inside it, even when both are selected in the list.
    func testAFolderAndSomethingInsideItGoToTheTrashTogether() async throws {
        let (first, _, memory) = try await twoWindows(files: ["Documents/notes.txt", "Documents/Reports/", "Documents/Reports/q1.txt"])
        await openInList("Reports", in: first)
        select("Reports", "q1.txt", in: first)
        first.perform(.trash)
        _ = await until { !(await memory.exists(self.documents.appendingPathComponent("Reports"))) }
        await settle(first)
        let gone = await memory.exists(documents.appendingPathComponent("Reports"))
        XCTAssertFalse(gone, "the folder went to the Trash: \(messages)")
        XCTAssertFalse(messages.contains { $0.contains("overlaps") })
        XCTAssertEqual(selected(first), ["notes.txt"], "the next visible item takes the selection")
    }

    /// Inside an open folder in the list, the item after the one moved to the Trash is what's selected next, and a
    /// renamed item stays selected, as at the top level.
    func testSelectionFollowsOperationsInsideAnOpenFolder() async throws {
        let (first, _, memory) = try await twoWindows(files: ["Documents/notes.txt", "Documents/Reports/", "Documents/Reports/q1.txt",
                                                               "Documents/Reports/r2.txt"])
        await openInList("Reports", in: first)
        select("q1.txt", in: first)
        let entry = try XCTUnwrap(first.selectedEntries().first)
        first.commitRename(entry, to: "q1-renamed.txt")
        _ = await until { await memory.exists(self.documents.appendingPathComponent("Reports/q1-renamed.txt")) }
        _ = await until { self.selected(first) == ["q1-renamed.txt"] }
        XCTAssertEqual(selected(first), ["q1-renamed.txt"])
        first.perform(.trash)
        _ = await until { !(await memory.exists(self.documents.appendingPathComponent("Reports/q1-renamed.txt"))) }
        _ = await until { self.selected(first) == ["r2.txt"] }
        XCTAssertEqual(selected(first), ["r2.txt"], "the next visible row, inside the open folder")
    }

    /// Make Alias is recorded like any other change: Undo takes the alias away and leaves the rename before it alone.
    func testUndoAfterMakeAliasRemovesTheAliasOnly() async throws {
        let (first, _, memory) = try await twoWindows()
        select("notes.txt", in: first)
        first.commitRename(try XCTUnwrap(first.selectedEntries().first), to: "beta.txt")
        _ = await until { await memory.exists(self.documents.appendingPathComponent("beta.txt")) }
        await settle(first)
        select("beta.txt", in: first)
        first.perform(.makeAlias)
        let alias = documents.appendingPathComponent("beta.txt alias")
        _ = await until { await memory.exists(alias) }
        await settle(first)
        XCTAssertEqual(selected(first), ["beta.txt alias"], "the new alias is selected")
        await first.refreshHistoryForTesting()
        XCTAssertEqual(first.title(of: .undo).0, "Undo Make Alias")
        first.perform(.undo)
        _ = await until { !(await memory.exists(alias)) }
        await settle(first)
        let stillAlias = await memory.exists(alias), renamed = await memory.exists(documents.appendingPathComponent("beta.txt"))
        XCTAssertFalse(stillAlias, "Undo took the alias away")
        XCTAssertTrue(renamed, "and didn't undo the rename before it")
        await first.refreshHistoryForTesting()
        XCTAssertEqual(first.title(of: .undo).0, "Undo Rename")
    }

    /// Recent and the Trash aren't folders, so an operation used to leave them as they were until View › Refresh.
    func testRecentOnShowDropsAnItemMovedAway() async throws {
        let (first, _, memory) = try await twoWindows()
        let notes = documents.appendingPathComponent("notes.txt")
        first.dependencies.recents.recordAccess(to: notes, kind: .regular, at: Date())
        first.navigate(to: .recent)
        let listed = await until { first.activeTab?.location == .recent && self.names(first).contains("notes.txt") }
        XCTAssertTrue(listed, "Recent never listed notes.txt")
        first.run(.move(sources: [notes], destinationDirectory: downloads))
        _ = await until { await memory.exists(self.downloads.appendingPathComponent("notes.txt")) }
        let refreshed = await until { !self.names(first).contains("notes.txt") }
        XCTAssertTrue(refreshed, "Recent still lists notes.txt where it was: \(names(first))")
    }
}

@MainActor private final class HuntOperationsQuietHost: BrowserWindowHost {
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
}
#endif
