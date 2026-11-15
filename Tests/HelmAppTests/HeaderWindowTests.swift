#if os(macOS)
import AppKit
import XCTest
import HelmAgent
import HelmCore
import HelmApp
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmUI

/// The header and its search in a whole window over the in-memory home: what only a real window shows, such as how
/// narrow it can go and which view has the keys after the search goes away.
@MainActor final class HeaderWindowTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/helm", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var downloads: URL { home.appendingPathComponent("Downloads", isDirectory: true) }
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []
    /// The host of the last window made, which records what the window asks of the app.
    private var host: QuietHost?

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

    /// A folder whose name alone is wider than the path's usual room.
    private var longName: URL { documents.appendingPathComponent("Photographs From The Summer Trip", isDirectory: true) }

    /// A window that's never shown, over a home with Documents (holding q2.txt), Downloads and deeper folders,
    /// already in Documents.
    private func documentsWindow(agent: AgentServices? = nil) async throws -> BrowserWindowController {
        let env = try await AppEnvironment.test(home: home)
        for folder in ["Documents", "Downloads", "Documents/Reports", "Documents/Reports/Quarterly",
                       "Documents/\(longName.lastPathComponent)"] {
            try await env.fileSystem.createDirectory(at: home.appendingPathComponent(folder, isDirectory: true))
        }
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        try await memory.createFileExclusively(at: documents.appendingPathComponent("q2.txt"), contents: Data("q2".utf8))
        let operations = OperationCoordinator(fileSystem: env.fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: env.directories.home) { false }
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: env.fileSystem,
            operations: operations, home: env.directories.home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.header-tests.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith, agent: agent)
        let host = QuietHost()
        self.host = host
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "header-tests",
                                                 seeds: [], activeIndex: 0)
        keep += [host, operations, volumes]
        controllers.append(controller)
        controller.navigate(to: .directory(documents))
        let arrived = await until { controller.activeTab?.location == .directory(self.documents) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "Documents never opened")
        return controller
    }

    /// Waits for something that happens a little later, such as a search's results.
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
        window.displayIfNeeded()
        await settle(0.1)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
    }
    private func selectedNames(_ controller: BrowserWindowController) -> [String] {
        controller.selectedEntries().map(\.name)
    }

    // MARK: Narrow windows

    func testWithTheSidebarHiddenANarrowWindowDropsTheSortWordsRatherThanGrow() async throws {
        let controller = try await documentsWindow()
        controller.toggleSidebar()
        await settle(0.3)
        XCTAssertEqual(controller.headerLeadingForTesting, 84)
        let quarterly = documents.appendingPathComponent("Reports/Quarterly", isDirectory: true)
        for place in [documents, quarterly] {
            controller.navigate(to: .directory(place))
            _ = await until { controller.activeTab?.location == .directory(place) }
            for sort in [ItemSort(field: .size, ascending: true), ItemSort(field: .dateModified, ascending: false)] {
                controller.contentSetSortForTesting(sort)
                await resize(controller, to: 620)
                let label = "\(place.lastPathComponent), \(sort.field)"
                XCTAssertEqual(controller.window?.frame.width ?? 0, 620, accuracy: 0.5, "The window kept its minimum: \(label)")
                XCTAssertTrue(controller.headerSortIsCompactForTesting, label)
                let widths = controller.headerSortWidthsForTesting
                XCTAssertEqual(widths.shown, widths.needed, accuracy: 0.5, "Nothing is squeezed once the words are gone: \(label)")
                await resize(controller, to: 1040)
                XCTAssertFalse(controller.headerSortIsCompactForTesting, "The words come back: \(label)")
            }
        }
    }

    func testAFolderWithALongNameStillDropsTheSortWordsFirst() async throws {
        // The name alone needs more than the path's usual room, so the words only go if the window can be made
        // narrower than they need, which takes them giving way for a moment.
        let controller = try await documentsWindow()
        controller.toggleSidebar()
        await settle(0.3)
        controller.navigate(to: .directory(longName))
        _ = await until { controller.activeTab?.location == .directory(self.longName) }
        controller.contentSetSortForTesting(ItemSort(field: .name, ascending: true))
        await resize(controller, to: 1040)
        XCTAssertFalse(controller.headerSortIsCompactForTesting)
        await resize(controller, to: 620)
        XCTAssertTrue(controller.headerSortIsCompactForTesting)
        let widths = controller.headerSortWidthsForTesting
        XCTAssertEqual(widths.shown, widths.needed, accuracy: 0.5)
        // The folder's name sets how narrow the window goes, and the words aren't part of it any more.
        XCTAssertLessThan(controller.window?.frame.width ?? .infinity, controller.header.widthWithSortWords - 20)
        await resize(controller, to: 1040)
        XCTAssertFalse(controller.headerSortIsCompactForTesting)
    }

    func testWithTheSidebarShownTheSortWordsGoBeforeTheSidebarNarrows() async throws {
        let controller = try await documentsWindow()
        controller.contentSetSortForTesting(ItemSort(field: .dateModified, ascending: false))
        await resize(controller, to: 1040)
        let sidebar = controller.sidebarWidthForTesting
        XCTAssertGreaterThan(sidebar, 190)
        XCTAssertFalse(controller.headerSortIsCompactForTesting)
        await resize(controller, to: 760)
        XCTAssertEqual(controller.window?.frame.width ?? 0, 760, accuracy: 0.5)
        XCTAssertTrue(controller.headerSortIsCompactForTesting)
        XCTAssertEqual(controller.sidebarWidthForTesting, sidebar, accuracy: 0.5, "The sidebar keeps its width.")
        await resize(controller, to: 1040)
        XCTAssertFalse(controller.headerSortIsCompactForTesting)
        XCTAssertEqual(controller.sidebarWidthForTesting, sidebar, accuracy: 0.5)
    }

    // MARK: The main menu, whole

    /// The main menu's dots in a circle keep their 34-by-32 button 8 points from the trailing edge, and their ink stays
    /// inside it, whatever the width, with the sidebar shown or hidden, with the search open, and after the window
    /// is made narrow and wide again.
    func testTheMainMenuIsDrawnWholeAtEveryWidth() async throws {
        let controller = try await documentsWindow()
        func check(_ label: String) {
            let measure = controller.headerMenuMeasureForTesting
            XCTAssertEqual(measure.size.width, 34, accuracy: 0.5, label)
            XCTAssertEqual(measure.size.height, 32, accuracy: 0.5, label)
            XCTAssertEqual(measure.trailingGap, 8, accuracy: 0.5, label)
            guard let ink = measure.ink else { return XCTFail("no ink: \(label)") }
            XCTAssertTrue(measure.bounds.insetBy(dx: 1, dy: 1).contains(ink), "\(ink) in \(measure.bounds): \(label)")
            XCTAssertEqual(ink.width, 15, accuracy: 1.5, label)
            XCTAssertEqual(ink.height, 15, accuracy: 1.5, label)
            if let spark = measure.sparkInk { XCTAssertEqual(spark.width, 15, accuracy: 1.5, "the spark's ink: \(label)") }
        }
        let widths: [CGFloat] = [560, 620, 700, 760, 900, 1040, 1240, 1600]
        for sidebar in [true, false] {
            if controller.isSidebarVisibleForTesting != sidebar { controller.toggleSidebar(); await settle(0.3) }
            for searching in [false, true] {
                if searching { controller.beginSearch() } else if controller.isSearchingForTesting {
                    _ = controller.searchFieldKeyForTesting("escape")
                }
                for width in widths {
                    await resize(controller, to: width)
                    check("\(Int(width)), sidebar \(sidebar), search \(searching)")
                }
            }
        }
        await resize(controller, to: 620)
        await resize(controller, to: 1600)
        check("narrowed and widened")
    }

    // MARK: Showing and hiding the sidebar

    func testHidingTheSidebarNeverWidensTheWindowAndShowingAddsOnlyWhatItNeeds() async throws {
        let controller = try await documentsWindow()
        await resize(controller, to: 700)
        XCTAssertTrue(controller.isSidebarVisibleForTesting)
        let sidebar = controller.sidebarWidthForTesting
        controller.toggleSidebar()
        await settle(0.4)
        XCTAssertFalse(controller.isSidebarVisibleForTesting)
        XCTAssertEqual(controller.headerLeadingForTesting, 84)
        XCTAssertEqual(controller.window?.frame.width ?? 0, 700, accuracy: 0.5, "hiding the sidebar widened the window")
        await resize(controller, to: 640)
        controller.toggleSidebar()
        await settle(0.4)
        XCTAssertTrue(controller.isSidebarVisibleForTesting)
        XCTAssertEqual(controller.headerLeadingForTesting, 8)
        let width = controller.window?.frame.width ?? 0
        // As wide as the sidebar at its narrowest and the header without the sort's words need: no wider.
        let needed = 190 + 1 + controller.header.compactWidth(sidebarVisible: true)
        XCTAssertLessThanOrEqual(width, ceil(needed) + 1, "showing the sidebar added more than it needed: \(width) for \(needed)")
        XCTAssertLessThan(width, 640 + sidebar, "it added the whole sidebar on top")
        XCTAssertGreaterThanOrEqual(controller.sidebarWidthForTesting, min(sidebar, 190) - 0.5)
        // In a wide window nothing changes size.
        await resize(controller, to: 1040)
        controller.toggleSidebar(); await settle(0.4)
        XCTAssertEqual(controller.window?.frame.width ?? 0, 1040, accuracy: 0.5)
        controller.toggleSidebar(); await settle(0.4)
        XCTAssertEqual(controller.window?.frame.width ?? 0, 1040, accuracy: 0.5)
    }

    // MARK: Where the keys go

    func testANavigationWhileTypingGivesTheFilesTheKeys() async throws {
        let controller = try await documentsWindow()
        controller.typeIntoSearchForTesting("q2")
        XCTAssertEqual(controller.focusOwnerForTesting, "search")
        controller.navigate(to: .directory(downloads))
        let arrived = await until { controller.activeTab?.location == .directory(self.downloads) }
        XCTAssertTrue(arrived)
        XCTAssertFalse(controller.isSearchingForTesting)
        XCTAssertEqual(controller.focusOwnerForTesting, "files")
        // The search typed just before going doesn't start late in the new folder.
        await settle(0.4)
        XCTAssertNil(controller.activeTab?.search)
        XCTAssertEqual(controller.activeTab?.location, .directory(downloads))
    }

    func testGoingToTheFolderYoureInWhileTypingClosesTheSearch() async throws {
        let controller = try await documentsWindow()
        controller.typeIntoSearchForTesting("q2")
        let searching = await until { controller.activeTab?.search != nil }
        XCTAssertTrue(searching)
        XCTAssertEqual(controller.focusOwnerForTesting, "search")
        // Go › Documents in Documents goes nowhere, but it ends the search.
        controller.perform(.documents)
        await settle()
        XCTAssertNil(controller.activeTab?.search)
        XCTAssertFalse(controller.isSearchingForTesting)
        XCTAssertEqual(controller.searchTextForTesting, "")
        XCTAssertEqual(controller.focusOwnerForTesting, "files")
        XCTAssertEqual(controller.activeTab?.location, .directory(documents))
    }

    func testClearingTheWordsWhileTypingKeepsTheFieldOpen() async throws {
        let controller = try await documentsWindow()
        controller.typeIntoSearchForTesting("q2")
        _ = await until { controller.activeTab?.search != nil }
        controller.typeIntoSearchForTesting("")
        let ended = await until { controller.activeTab?.search == nil }
        XCTAssertTrue(ended)
        XCTAssertTrue(controller.isSearchingForTesting, "The empty field stays open for new words.")
        XCTAssertEqual(controller.focusOwnerForTesting, "search")
    }

    func testTheDownArrowBeforeTheResultsSelectsTheFirstWhenTheyCome() async throws {
        let controller = try await documentsWindow()
        controller.typeIntoSearchForTesting("q2")
        // At once, before the search would have started.
        XCTAssertTrue(controller.searchFieldKeyForTesting("down"))
        XCTAssertEqual(controller.focusOwnerForTesting, "files")
        let selected = await until { !(controller.activeTab?.selection.isEmpty ?? true) }
        XCTAssertTrue(selected, "The first result was never selected.")
        XCTAssertEqual(selectedNames(controller), ["q2.txt"])
        XCTAssertNil(controller.firstResultWanted)
    }

    func testTheDownArrowLetsGoOfTheFirstResultWhenTheSearchEnds() async throws {
        let controller = try await documentsWindow()
        controller.typeIntoSearchForTesting("q2")
        XCTAssertTrue(controller.searchFieldKeyForTesting("down"))
        // Escape in the files before anything comes in ends the search, and nothing is selected later.
        controller.pressEscapeInFilesForTesting()
        await settle(0.6)
        XCTAssertNil(controller.activeTab?.search)
        XCTAssertNil(controller.firstResultWanted)
        XCTAssertTrue(controller.activeTab?.selection.isEmpty ?? false)
    }

    func testChoosingAViewWhileTypingKeepsTheCaretInTheSearch() async throws {
        let controller = try await documentsWindow()
        let other: ViewMode = controller.activeTab?.viewMode == .grid ? .list : .grid
        controller.beginSearch()
        XCTAssertEqual(controller.focusOwnerForTesting, "search")
        controller.clickHeaderViewForTesting(other)
        await settle()
        XCTAssertEqual(controller.activeTab?.viewMode, other)
        XCTAssertEqual(controller.headerViewModeForTesting, other)
        XCTAssertEqual(controller.focusOwnerForTesting, "search", "The caret stays in the search.")
        XCTAssertTrue(controller.isSearchingForTesting, "An empty search that kept the caret stays open.")
        // From the files, the new view takes the keys.
        controller.focusFilesForTesting()
        await settle()
        controller.clickHeaderViewForTesting(other == .grid ? .list : .grid)
        await settle()
        XCTAssertEqual(controller.focusOwnerForTesting, "files")
    }

    // MARK: The view button and the spark

    func testTheViewButtonOffersTheOtherViewAndAClickForTheShownOneDoesNothing() async throws {
        let controller = try await documentsWindow()
        controller.perform(.grid)
        await settle()
        XCTAssertEqual(controller.headerViewModeForTesting, .grid)
        XCTAssertEqual(controller.headerViewOfferedForTesting, .list)
        XCTAssertTrue(controller.headerToolTipsForTesting.contains("List (⌘2)"))
        XCTAssertFalse(controller.headerToolTipsForTesting.contains { $0.contains("⌘1") })
        // Asking for the view on show is not what the button offers, so nothing changes.
        controller.clickHeaderViewForTesting(.grid)
        await settle()
        XCTAssertEqual(controller.activeTab?.viewMode, .grid)
        controller.clickHeaderViewForTesting(.list)
        await settle()
        XCTAssertEqual(controller.activeTab?.viewMode, .list)
        XCTAssertEqual(controller.headerViewOfferedForTesting, .grid)
        XCTAssertTrue(controller.headerToolTipsForTesting.contains("Grid (⌘1)"))
        // ⌘1 and the menu still pick the view, and the button follows.
        controller.perform(.grid)
        await settle()
        XCTAssertEqual(controller.headerViewOfferedForTesting, .list)
    }

    func testTheSparkSitsBesideTheMainMenuAndAsksForTheAIScreenUntilAModelIsReady() async throws {
        let controller = try await documentsWindow()
        let spark = controller.headerSparkForTesting
        XCTAssertFalse(spark.lit)
        XCTAssertFalse(spark.working)
        XCTAssertEqual(spark.toolTip, "Set Up AI Mode")
        let tips = controller.headerToolTipsForTesting
        XCTAssertEqual(Array(tips.suffix(2)), ["Set Up AI Mode", "Main Menu"], "The spark comes just before the main menu.")
        XCTAssertEqual(host?.aiScreens, 0)
        controller.clickSparkForTesting()
        XCTAssertEqual(host?.aiScreens, 1, "AI mode is off, so the spark opens the AI mode screen.")
        XCTAssertFalse(controller.isAgentPanelOpen)
        XCTAssertFalse(controller.headerSparkForTesting.lit)
    }

    /// AI mode on with no model connected yet: the search field shows its spark as the header does, and a press on
    /// it, File › Find with AI or the no-results button opens the AI mode screen, and the spark never turns on.
    func testWithAIModeOnAndNoModelReadyTheSearchSparkAsksForTheAIScreen() async throws {
        let secrets = MemorySecretStore()
        let disk = MemoryAgentDisk(home: home.path)
        // No scripted model and no way to make a live one: on, it's never ready.
        let runtime = AgentRuntime(parts: AgentRuntimeParts(secrets: secrets, disk: disk, home: home.path,
                                                            supportFolder: home.appendingPathComponent(".support").path,
                                                            clock: SystemHelmClock(), buildStamp: ""))
        let agent = AgentServices(runtime: runtime, config: AIConfigStore(), secrets: secrets, disk: disk,
                                  storage: MemoryStorageFactsReader(home: home), connector: MemoryServerConnector())
        let controller = try await documentsWindow(agent: agent)
        controller.beginSearch()
        // AI mode off: the magnifier, nothing to press, and Find with AI is off.
        XCTAssertEqual(controller.searchFieldMarkForTesting, "magnifier")
        XCTAssertFalse(controller.pressSearchSparkForTesting())
        XCTAssertFalse(controller.title(of: .findWithAI).1)
        XCTAssertEqual(host?.aiScreens, 0)

        runtime.setOn(true)
        XCTAssertEqual(runtime.state, .notReady)
        XCTAssertEqual(controller.searchFieldMarkForTesting, "spark", "AI mode is on, so the field shows its spark")
        XCTAssertTrue(controller.pressSearchSparkForTesting())
        XCTAssertEqual(host?.aiScreens, 1, "with no model ready, the spark opens the AI mode screen")
        XCTAssertFalse(controller.isAISearchOnForTesting, "and never turns on")
        XCTAssertEqual(controller.searchFieldMarkForTesting, "spark")
        XCTAssertNil(controller.aiSearchStatusForTesting)
        XCTAssertTrue(controller.title(of: .findWithAI).1, "File › Find with AI is there whenever AI mode is on")
        controller.perform(.findWithAI)
        XCTAssertEqual(host?.aiScreens, 2)
        XCTAssertFalse(controller.isAISearchOnForTesting)

        // Typing still searches names, and the no-results page's Find with AI asks for the screen too.
        controller.typeIntoSearchForTesting("zzz-nothing")
        let offered = await until { controller.contentStateForTesting?.buttons.contains { $0.action == .findWithAI } == true }
        XCTAssertTrue(offered, "the no-results page offers Find with AI")
        XCTAssertTrue(controller.pressContentButtonForTesting(AgentText.searchToggle))
        XCTAssertEqual(host?.aiScreens, 3)
        XCTAssertFalse(controller.isAISearchOnForTesting)
        XCTAssertEqual(controller.activeTab?.search?.query.usesAI, false)

        // AI mode off again: the magnifier is back.
        runtime.setOn(false)
        XCTAssertEqual(controller.searchFieldMarkForTesting, "magnifier")
        XCTAssertEqual(controller.header.searchField.aiToggleToolTipForTesting, AgentText.searchToggle)
    }

    func testTheSearchFieldShowsTheMagnifierUntilTheWindowSaysAISearchIsAvailable() async throws {
        let controller = try await documentsWindow()
        controller.beginSearch()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.searchFieldMarkForTesting, "magnifier")
        let room = controller.searchTextRoomForTesting
        controller.header.setAISearch(available: true, on: true)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.searchFieldMarkForTesting, "spark lit")
        XCTAssertEqual(controller.searchTextRoomForTesting, room, accuracy: 0.5, "The spark takes no room from the words.")
        XCTAssertEqual(controller.focusOwnerForTesting, "search")
    }

    func testAHiddenListingDoesntGetTheKeysBack() async throws {
        let controller = try await documentsWindow()
        // A page saying a place couldn't open hides the listing, and the keys leave it.
        controller.previewContentStateForTesting(ContentState(style: .problem, symbol: "lock", title: "No access"))
        await settle()
        XCTAssertTrue(controller.isListingHiddenForTesting)
        XCTAssertFalse(controller.focusIsInListingForTesting)
        let entry = try XCTUnwrap(controller.activeTab?.snapshot.sortedEntries.first)
        controller.store.send(.tab(controller.activeTabID, .setSelection([entry.id], source: .user)))
        XCTAssertFalse(controller.focusIsInListingForTesting, "A render doesn't put the keys in a hidden listing.")
        controller.focusFilesForTesting()
        XCTAssertFalse(controller.focusIsInListingForTesting)
        // The search going away doesn't either.
        controller.beginSearch()
        XCTAssertTrue(controller.searchFieldKeyForTesting("escape"))
        XCTAssertFalse(controller.isSearchingForTesting)
        await settle()
        XCTAssertFalse(controller.focusIsInListingForTesting)
        // Once the page goes, the files take the keys again.
        controller.previewContentStateForTesting(nil)
        await settle()
        XCTAssertFalse(controller.isListingHiddenForTesting)
        controller.focusFilesForTesting()
        XCTAssertEqual(controller.focusOwnerForTesting, "files")
    }
}

/// A host for a window on its own: nothing to open, close or show.
@MainActor private final class QuietHost: BrowserWindowHost {
    /// How many times a window asked for the AI mode screen.
    private(set) var aiScreens = 0
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    /// Not asked for yet; a host that opens Settings at one pane will need it.
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
    func showAIModeScreen(from window: BrowserWindowController?) { aiScreens += 1 }
}
#endif
