#if os(macOS)
import AppKit
import XCTest
import HelmCore
import HelmApp
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmUI

/// Search and Recent, in a whole window over the in-memory home. Spotlight is stood in for, so no search here
/// reaches the Mac's own index: it answers with nothing at once, unless a test holds its answer back.
@MainActor final class HuntSearchRecentTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/helm", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var downloads: URL { home.appendingPathComponent("Downloads", isDirectory: true) }
    /// A folder nobody has set a view or sort for.
    private var plain: URL { home.appendingPathComponent("Plain", isDirectory: true) }
    private var notes: URL { documents.appendingPathComponent("notes.txt") }
    private var q2: URL { documents.appendingPathComponent("q2.txt") }
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []
    private let nameAZ = ItemSort(field: .name, ascending: true, directoriesFirst: true)

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        HostEffectRunner.spotlightAnswersForTesting = { _ in AsyncStream { $0.yield([]); $0.finish() } }
    }
    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers = []
        keep = []
        HeaderMotion.isDisabledForTesting = false
        HostEffectRunner.spotlightAnswersForTesting = nil
        super.tearDown()
    }

    /// A window that's never shown, over a home with Documents (q2.txt, notes.txt), Downloads and Plain (a.txt),
    /// already in Documents unless `seeds` say otherwise. Recent lists Documents (just visited), Downloads, q2.txt and
    /// notes.txt, in that order.
    private func window(seeds: [BrowserTabSeed] = []) async throws -> BrowserWindowController {
        let env = try await AppEnvironment.test(home: home)
        for folder in ["Documents", "Downloads", "Plain"] {
            try await env.fileSystem.createDirectory(at: home.appendingPathComponent(folder, isDirectory: true))
        }
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        try await memory.createFileExclusively(at: q2, contents: Data("q2".utf8))
        try await memory.createFileExclusively(at: notes, contents: Data("n".utf8))
        try await memory.createFileExclusively(at: plain.appendingPathComponent("a.txt"), contents: Data("a".utf8))
        let operations = OperationCoordinator(fileSystem: env.fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: env.directories.home) { false }
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: env.fileSystem,
            operations: operations, home: env.directories.home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.hunt-search-recent.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith)
        let host = HuntQuietHost()
        let now = Date()
        env.recents.recordAccess(to: documents, kind: .directory, at: now.addingTimeInterval(-40))
        env.recents.recordAccess(to: downloads, kind: .directory, at: now.addingTimeInterval(-30))
        env.recents.recordAccess(to: notes, kind: .regular, at: now.addingTimeInterval(-20))
        env.recents.recordAccess(to: q2, kind: .regular, at: now.addingTimeInterval(-10))
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "hunt-search-recent",
                                                 seeds: seeds, activeIndex: 0)
        keep += [host, operations, volumes]
        controllers.append(controller)
        if seeds.isEmpty { await go(controller, .directory(documents)) }
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
    private func go(_ controller: BrowserWindowController, _ location: Location) async {
        controller.navigate(to: location)
        let arrived = await until { controller.activeTab?.location == location && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "never reached \(location)")
        await settle(0.1)
    }
    private func names(_ controller: BrowserWindowController) -> [String] {
        guard let tab = controller.activeTab else { return [] }
        return tab.snapshot.sortedEntries.prefix(tab.snapshot.rootCount).map(\.name)
    }
    private func search(_ controller: BrowserWindowController, _ text: String) async {
        controller.search(text)
        let done = await until { controller.activeTab?.search?.query.text == text && controller.activeTab?.search?.isGathering == false }
        XCTAssertTrue(done, "the search for \(text) never finished")
        await settle(0.1)
    }
    private func select(_ controller: BrowserWindowController, _ url: URL) {
        controller.store.send(.tab(controller.activeTabID, .setSelection([ItemID(url: url)], source: .user)))
    }
    private func sortMenu(_ controller: BrowserWindowController) -> [String: NSControl.StateValue] {
        let menu = NSMenu()
        controller.fillSortItems(in: menu)
        return Dictionary(menu.items.filter { !$0.isSeparatorItem }.map { ($0.title, $0.state) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: The order during a search

    /// Best Match chosen during a search used to become the folder's own sort: the folder listed in path order under
    /// a "Best Match" button once the search ended, and that order followed the tab and was saved.
    func testBestMatchStaysWithTheResults() async throws {
        let controller = try await window()
        controller.contentSetSortForTesting(nameAZ)
        await search(controller, "q2")
        XCTAssertEqual(names(controller), ["q2.txt"])
        // Best Match in the popover or in View › Sort By.
        controller.pressSort(.relevance)
        await settle()
        XCTAssertEqual(controller.activeTab?.snapshot.sort.field, .relevance)
        XCTAssertEqual(controller.activeTab?.sort, nameAZ, "the folder keeps its own sort during the search")
        controller.search("")
        let ended = await until { controller.activeTab?.search == nil }
        XCTAssertTrue(ended)
        await settle()
        XCTAssertEqual(controller.activeTab?.sort, nameAZ)
        XCTAssertEqual(controller.activeTab?.snapshot.sort, nameAZ)
        XCTAssertEqual(names(controller), ["notes.txt", "q2.txt"])
        XCTAssertEqual(controller.header.sortButton.text, "A to Z")
        // Nothing saved for Documents is Best Match, even after a change that saves its view.
        controller.perform(.list)
        XCTAssertNotEqual(controller.dependencies.viewOptions.options(for: .directory(documents)).sort.field, .relevance)
        // A late press of Best Match, with no search left, changes nothing and saves nothing.
        let kindZA = ItemSort(field: .kind, ascending: false, directoriesFirst: true)
        controller.contentSetSortForTesting(kindZA)
        controller.pressSort(.relevance)
        await settle()
        XCTAssertEqual(controller.activeTab?.sort, kindZA)
        XCTAssertEqual(controller.dependencies.viewOptions.options(for: .directory(documents)).sort, kindZA)
        controller.contentSetSortForTesting(nameAZ)
        await go(controller, .directory(plain))
        XCTAssertEqual(controller.activeTab?.sort, nameAZ, "Best Match never follows the tab into another folder")
    }

    /// A session saved while a tab was sorted by Best Match, by a build that let that happen, opens sorted as usual.
    func testASessionSortedByBestMatchOpensInTheUsualOrder() async throws {
        let controller = try await window(seeds: [BrowserTabSeed(location: .directory(documents), sort: ItemSort(field: .relevance))])
        let arrived = await until { controller.activeTab?.isLoading == false && controller.activeTab?.location == .directory(self.documents) }
        XCTAssertTrue(arrived)
        XCTAssertEqual(controller.activeTab?.sort, controller.dependencies.settings.snapshot.defaultSort)
        XCTAssertEqual(names(controller), ["notes.txt", "q2.txt"])
    }

    /// While a search is up, the sort button, View › Sort By and the popover name the order the results are in.
    func testTheSortButtonAndMenuSayWhatOrderTheResultsAreIn() async throws {
        let controller = try await window()
        controller.contentSetSortForTesting(nameAZ)
        XCTAssertEqual(controller.header.sortButton.text, "A to Z")
        await search(controller, "q")
        XCTAssertEqual(controller.activeTab?.snapshot.sort.field, .relevance, "the results are in Best Match order")
        XCTAssertEqual(controller.header.sortButton.text, "Best Match")
        var items = sortMenu(controller)
        XCTAssertEqual(items["Best Match"], .on)
        XCTAssertEqual(items["Name"], .off)
        // Name chosen for the results: the button follows, more words keep it, and the folder's sort is untouched.
        controller.pressSort(.name)
        await settle()
        XCTAssertEqual(controller.header.sortButton.text, "A to Z")
        XCTAssertEqual(sortMenu(controller)["Name"], .on)
        await search(controller, "q2")
        XCTAssertEqual(controller.activeTab?.snapshot.sort.field, .name)
        controller.chooseSortForTesting("Name Z–A")
        await settle()
        XCTAssertEqual(controller.header.sortButton.text, "Z to A")
        XCTAssertEqual(controller.activeTab?.sort, nameAZ)
        controller.search("")
        _ = await until { controller.activeTab?.search == nil }
        await settle()
        XCTAssertEqual(controller.header.sortButton.text, "A to Z")
        // In Recent too: Best Match, not Recent's own Most recent first, and no Last Opened to choose.
        await go(controller, .recent)
        XCTAssertEqual(controller.header.sortButton.text, "Most recent first")
        await search(controller, "zz")
        XCTAssertEqual(controller.header.sortButton.text, "Best Match")
        items = sortMenu(controller)
        XCTAssertEqual(items["Best Match"], .on)
        XCTAssertNil(items["Last Opened"])
        controller.search("")
        _ = await until { controller.activeTab?.search == nil }
        await settle()
        XCTAssertEqual(controller.header.sortButton.text, "Most recent first")
    }

    /// Folders on top, switched during a search, used to re-sort the results by the folder's field.
    func testFoldersOnTopDuringASearchKeepsBestMatch() async throws {
        let controller = try await window()
        controller.contentSetSortForTesting(nameAZ)
        await search(controller, "q2")
        XCTAssertEqual(controller.activeTab?.snapshot.sort.field, .relevance)
        let shown = controller.activeTab?.shownSort.directoriesFirst
        controller.toggleFoldersFirst()
        await settle()
        XCTAssertEqual(controller.activeTab?.snapshot.sort.field, .relevance, "the results stay in Best Match order")
        XCTAssertEqual(controller.activeTab?.shownSort.directoriesFirst, shown.map { !$0 })
        XCTAssertEqual(controller.activeTab?.sort, nameAZ, "the folder's Folders on top is untouched")
    }

    // MARK: Recent's order

    /// Recent keeps its folders apart from its files, under two headings, unless Folders on top is turned off there.
    /// It used to take Folders on top from whatever folder the tab came from.
    func testAFolderWithFoldersOnTopOffDoesntTakeRecentsHeadingsAway() async throws {
        let controller = try await window()
        await go(controller, .recent)
        XCTAssertEqual(controller.contentSectionsForTesting(), ["Folders 2", "Files 2"])
        // In Plain, Folders on top goes off, as its switch in the popover does. Plain remembers that.
        await go(controller, .directory(plain))
        controller.toggleFoldersFirst()
        await settle()
        XCTAssertEqual(controller.activeTab?.sort.directoriesFirst, false)
        await go(controller, .recent)
        XCTAssertEqual(controller.activeTab?.sort.field, .lastOpened)
        // Plain is in Recent now too, among the folders.
        XCTAssertEqual(controller.contentSectionsForTesting(), ["Folders 3", "Files 2"])
        // Back in Plain, its own choice is still there.
        await go(controller, .directory(plain))
        XCTAssertEqual(controller.activeTab?.sort.directoriesFirst, false)
    }

    /// RecentSort's promise: an order chosen in Recent never follows you out. It used to, unless it was Last Opened.
    func testAnOrderChosenInRecentDoesntFollowYouOut() async throws {
        let controller = try await window()
        let before = ItemSort(field: .kind, ascending: false, directoriesFirst: true)
        controller.contentSetSortForTesting(before)
        await go(controller, .directory(downloads))
        XCTAssertEqual(controller.activeTab?.sort, before, "a folder with no order of its own keeps the tab's order")
        await go(controller, .recent)
        XCTAssertEqual(controller.activeTab?.sort.field, .lastOpened)
        controller.chooseSortForTesting("Name Z–A")
        await settle()
        XCTAssertEqual(controller.activeTab?.sort.field, .name)
        await go(controller, .directory(plain))
        XCTAssertEqual(controller.activeTab?.sort, before, "leaving Recent puts back Kind Z–A")
        // Recent keeps the order chosen there.
        await go(controller, .recent)
        XCTAssertEqual(SortChoice.matching(controller.activeTab?.sort ?? .defaultSort).title, "Name Z–A")
        await go(controller, .directory(plain))
        XCTAssertEqual(controller.activeTab?.sort, before)
    }

    /// Recent lists what you opened last at the top, and something you open from it moves up at once.
    func testRecentFollowsWhatYouOpen() async throws {
        let controller = try await window()
        await go(controller, .recent)
        XCTAssertEqual(names(controller), ["Documents", "Downloads", "q2.txt", "notes.txt"])
        // Opening notes.txt records it, as opening any file does.
        controller.dependencies.recents.recordAccess(to: notes, kind: .regular, at: Date())
        let moved = await until { self.names(controller) == ["Documents", "Downloads", "notes.txt", "q2.txt"] }
        XCTAssertTrue(moved, "Recent still reads \(names(controller))")
    }

    /// A search in Recent isn't started over when something is opened, and Recent catches up once the search ends.
    func testASearchInRecentIsntStartedOverWhenSomethingOpens() async throws {
        let controller = try await window()
        await go(controller, .recent)
        await search(controller, "zz")
        let generation = controller.activeTab?.searchGeneration
        controller.dependencies.recents.recordAccess(to: notes, kind: .regular, at: Date())
        await settle(0.3)
        XCTAssertEqual(controller.activeTab?.searchGeneration, generation, "the search went on as it was")
        XCTAssertEqual(controller.activeTab?.search?.isGathering, false)
        controller.search("")
        let caughtUp = await until { self.names(controller) == ["Documents", "Downloads", "notes.txt", "q2.txt"] }
        XCTAssertTrue(caughtUp, "Recent still reads \(names(controller))")
    }

    // MARK: Rename

    /// Return and F2 rename only where Edit › Rename does. In Recent and in search results it's greyed out, yet
    /// Return used to rename anyway, and Recent then listed a file that was gone.
    func testReturnAndF2RenameOnlyWhereRenameIsOn() async throws {
        let controller = try await window()
        let renamed = HuntRenames()
        let token = controller.store.snapshots.subscribe { snapshot in
            if let id = snapshot.tabs[snapshot.window.activeTabID]?.inlineRenameID { renamed.ids.insert(id) }
        }
        defer { _ = token }
        func press(_ code: UInt16, _ text: String) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: text,
                                               charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { return false }
            return controller.handleContentKey(event)
        }
        let f2 = String(Character(UnicodeScalar(UInt32(NSF2FunctionKey)) ?? " "))
        await go(controller, .recent)
        select(controller, notes)
        XCTAssertFalse(controller.title(of: .rename).1, "Rename is greyed out in Recent")
        XCTAssertTrue(press(36, "\r"))
        XCTAssertTrue(press(120, f2))
        await settle()
        XCTAssertTrue(renamed.ids.isEmpty, "nothing started renaming in Recent")
        await go(controller, .directory(documents))
        await search(controller, "q2")
        select(controller, q2)
        XCTAssertFalse(controller.title(of: .rename).1, "Rename is greyed out in search results")
        XCTAssertTrue(press(36, "\r"))
        await settle()
        XCTAssertTrue(renamed.ids.isEmpty, "nothing started renaming in the results")
        // In the folder itself Return still renames.
        controller.search("")
        _ = await until { controller.activeTab?.search == nil }
        select(controller, notes)
        XCTAssertTrue(controller.title(of: .rename).1)
        XCTAssertTrue(press(36, "\r"))
        await settle()
        XCTAssertEqual(renamed.ids, [ItemID(url: notes)])
    }

    // MARK: No results

    /// A search only Spotlight answers (Recent, the Trash, or This Mac) used to say "No results", and stop saying
    /// Searching…, before Spotlight had answered: the folder walk it skipped was sent as an empty answer.
    func testNoResultsWaitsForSpotlightsAnswer() async throws {
        let answer = HuntHeldAnswer()
        HostEffectRunner.spotlightAnswersForTesting = { _ in AsyncStream { answer.continuation = $0 } }
        let controller = try await window()
        await go(controller, .recent)
        controller.search("zz")
        let started = await until { controller.activeTab?.search != nil && answer.continuation != nil }
        XCTAssertTrue(started)
        await settle(0.3)
        XCTAssertEqual(controller.activeTab?.search?.isGathering, true, "still Searching… until Spotlight answers")
        XCTAssertNotEqual(controller.contentStateForTesting?.title, "No results")
        answer.continuation?.yield([])
        let answered = await until { controller.activeTab?.search?.isGathering == false }
        XCTAssertTrue(answered)
        await settle(0.1)
        XCTAssertEqual(controller.contentStateForTesting?.title, "No results")
    }

    /// If Spotlight can't start at all, the search still ends, rather than say Searching… for ever.
    func testASearchSpotlightCantRunStillEnds() async throws {
        HostEffectRunner.spotlightAnswersForTesting = { _ in AsyncStream { $0.finish() } }
        let controller = try await window()
        await go(controller, .recent)
        controller.search("zz")
        let ended = await until { controller.activeTab?.search?.isGathering == false }
        XCTAssertTrue(ended)
        await settle(0.1)
        XCTAssertEqual(controller.contentStateForTesting?.title, "No results")
    }
}

/// Holds back Spotlight's answer until a test gives it.
private final class HuntHeldAnswer: @unchecked Sendable {
    var continuation: AsyncStream<[URL]>.Continuation?
}

/// The items that started renaming.
@MainActor private final class HuntRenames {
    var ids: Set<ItemID> = []
}

/// A host for a window on its own: nothing to open, close or show.
@MainActor private final class HuntQuietHost: BrowserWindowHost {
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
}
#endif
