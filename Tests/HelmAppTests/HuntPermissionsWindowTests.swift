#if os(macOS)
import AppKit
import Quartz
import XCTest
import HelmCore
import HelmApp
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmUI

/// Permissions hunt: a whole window over the in-memory home, never shown. Each test keeps a bug found in the merged
/// build fixed: menus that couldn't open, a card that named one place while the window named another, a card that
/// went away when the folder under it reloaded, and what still reached the files hidden under a card.
@MainActor final class HuntPermissionsWindowTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/helm", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var downloads: URL { home.appendingPathComponent("Downloads", isDirectory: true) }
    private var refused: URL { home.appendingPathComponent("Private", isDirectory: true) }
    private let refusedTitle = "You don’t have permission to see inside “Private”"
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

    // MARK: Open With, Share and New File in the menus

    /// Right-click › Open With and Share open submenus. A row whose action was cleared after its submenu was set is
    /// greyed out by AppKit's automatic enabling, so its submenu couldn't be opened: Open With, Choose App… and
    /// Change Default App… were out of reach.
    func testOpenWithAndShareCanBeOpenedFromTheContextMenu() async throws {
        let controller = try await documentsWindow()
        let file = try XCTUnwrap(entry(named: "q2.txt", in: controller))
        let menu = try XCTUnwrap(controller.contextMenu(for: [file]))
        menu.update() // What AppKit does as the menu opens.
        for title in ["Open With", "Share"] {
            let item = try XCTUnwrap(menu.items.first { $0.title == title }, "no \(title) row")
            XCTAssertTrue(item.hasSubmenu, title)
            XCTAssertTrue(item.isEnabled, "\(title) is greyed out, so its submenu can't be opened")
        }
        // The folder's own menu (right-click in empty space, and the path bar's ⋯) has the same problem with New File.
        let background = try XCTUnwrap(controller.contextMenu(for: []))
        background.update()
        let newFile = try XCTUnwrap(background.items.first { $0.title == "New File" })
        XCTAssertTrue(newFile.isEnabled, "New File is greyed out, so its templates can't be reached")
    }

    // MARK: What reaches the listing hidden under a card

    /// File › Open With is filled from the selection when it opens. Under a card nothing counts as selected, so it
    /// doesn't offer to open a file nobody can see, as every other selection command already doesn't.
    func testFileOpenWithDoesNotReachTheListingUnderACard() async throws {
        let controller = try await cardOverDocuments(selecting: "q2.txt")
        XCTAssertEqual(controller.title(of: .openWith).1, false, "the command itself is off under the card")
        let menu = NSMenu(title: "Open With")
        controller.fillOpenWithItems(in: menu)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles.first, "Select a File", "File › Open With offers \(titles)")
        XCTAssertFalse(titles.contains("Change Default App…"), "Change Default App… would act on the hidden q2.txt")
    }

    /// Quick Look previews the selection. Under a card there's none, so it has nothing hidden to show. (An open panel
    /// also closes as the card comes up; a panel can't be put on screen from a test.)
    func testQuickLookHasNothingHiddenToShowUnderACard() async throws {
        let controller = try await documentsWindow()
        let file = try XCTUnwrap(entry(named: "q2.txt", in: controller))
        controller.store.send(.tab(controller.activeTabID, .setSelection([file.id], source: .user)))
        let panel = try XCTUnwrap(QLPreviewPanel.shared())
        controller.beginPreviewPanelControl(panel)
        defer { controller.endPreviewPanelControl(panel) }
        XCTAssertEqual(controller.numberOfPreviewItems(in: panel), 1)
        controller.navigate(to: .directory(refused))
        let shown = await until { controller.contentStateForTesting?.title == self.refusedTitle }
        XCTAssertTrue(shown)
        controller.beginPreviewPanelControl(panel)
        XCTAssertEqual(controller.numberOfPreviewItems(in: panel), 0, "Quick Look would preview the hidden q2.txt")
    }

    /// The system's Services menu asks the responder chain for the selection. Under a card there's none to give.
    func testServicesAreNotOfferedTheListingUnderACard() async throws {
        let controller = try await cardOverDocuments(selecting: "q2.txt")
        XCTAssertNil(controller.validRequestor(forSendType: .fileURL, returnType: nil),
                     "Services would act on \(controller.selectedEntries().map(\.name)), hidden under the card")
    }

    // MARK: The rest of the window while a card is up

    /// The sidebar follows the card (Home, which holds Private), and so do the window title, the path bar and the
    /// proxy icon: the window names one place. Search, which would look in the hidden folder, waits until the card
    /// goes, and New Tab opens the place on show.
    func testTheTitleAndPathBarNameThePlaceTheCardIsAbout() async throws {
        let controller = try await cardOverDocuments(selecting: "q2.txt")
        XCTAssertEqual(controller.sidebarSelectionForTesting, "Home", "the sidebar already follows the card")
        XCTAssertEqual(controller.window?.title, "Private")
        XCTAssertEqual(TabStripView.title(controller.activeTab), "Private", "the tab's own name")
        XCTAssertEqual(controller.pathSegmentsForTesting().last, "Private")
        XCTAssertEqual(controller.window?.representedURL.map { PathSpelling.standardPath($0) }, PathSpelling.standardPath(refused))
        XCTAssertEqual(controller.title(of: .find).1, false, "Find would search the hidden Documents")
        XCTAssertFalse(controller.header.searchButton.isEnabled)
        XCTAssertEqual(controller.newWindowLocation, .directory(refused))
        controller.perform(.newTab)
        let opened = await until { controller.activeTab?.isLoading == false }
        XCTAssertTrue(opened)
        XCTAssertEqual(controller.activeTab.map { PathSpelling.standardPath($0.location.mutationTarget ?? self.home) }, PathSpelling.standardPath(refused))
        XCTAssertEqual(controller.contentStateForTesting?.title, refusedTitle)
    }

    /// Search names the place on show and comes back with the listing.
    func testSearchComesBackWithTheListing() async throws {
        let controller = try await cardOverDocuments(selecting: "q2.txt")
        controller.perform(.back)
        let back = await until { controller.contentStateForTesting == nil && controller.activeTab?.isLoading == false }
        XCTAssertTrue(back)
        XCTAssertEqual(controller.title(of: .find).1, true)
        XCTAssertTrue(controller.header.searchButton.isEnabled)
        XCTAssertEqual(controller.window?.title, "Documents")
        XCTAssertEqual(controller.selectedEntries().map(\.name), ["q2.txt"], "the selection comes back with the listing")
    }

    /// New File's templates are checked like New Folder, so none lands in the folder hidden under a card.
    func testTemplatesAreOffUnderACard() async throws {
        let controller = try await documentsWindow()
        let template = NSMenuItem(title: "Letter", action: #selector(BrowserWindowController.newFromTemplate(_:)), keyEquivalent: "")
        template.target = controller
        template.representedObject = home.appendingPathComponent("Templates/Letter.txt")
        XCTAssertTrue(controller.validateMenuItem(template))
        controller.navigate(to: .directory(refused))
        let shown = await until { controller.contentStateForTesting?.title == self.refusedTitle }
        XCTAssertTrue(shown)
        XCTAssertFalse(controller.validateMenuItem(template))
    }

    /// Reloading the folder under the card leaves the card up; only Back takes it down. Show Hidden Files (⇧⌘.)
    /// reloads it, and so does any operation finishing, since the window refreshes its active tab after each one.
    func testShowHiddenFilesKeepsTheCard() async throws {
        let controller = try await cardOverDocuments(selecting: "q2.txt")
        controller.perform(.hidden)
        _ = await until { controller.activeTab?.isLoading == false }
        await settle()
        XCTAssertEqual(controller.contentStateForTesting?.title, refusedTitle, "the card went away")
        XCTAssertTrue(controller.isListingHiddenForTesting, "the hidden folder's listing came back")
        XCTAssertEqual(controller.sidebarSelectionForTesting, "Home")
    }

    func testAnOperationFinishingElsewhereKeepsTheCard() async throws {
        let controller = try await cardOverDocuments(selecting: "q2.txt")
        let memory = try XCTUnwrap(controller.dependencies.fileSystem as? InMemoryFileSystem)
        let note = home.appendingPathComponent("note.txt")
        try await memory.createFileExclusively(at: note, contents: Data("n".utf8))
        // A file dropped on the sidebar's Downloads row, say from Finder, while the card is up.
        XCTAssertTrue(controller.dropForTesting([note], into: downloads))
        let moved = await until { await memory.exists(self.downloads.appendingPathComponent("note.txt")) }
        XCTAssertTrue(moved)
        _ = await until { controller.activeTab?.isLoading == false }
        await settle(0.4)
        XCTAssertEqual(controller.contentStateForTesting?.title, refusedTitle, "the card went away when the move finished")
        XCTAssertTrue(controller.isListingHiddenForTesting)
    }

    // MARK: A disk that's gone

    /// A folder on a disk that's been ejected or unplugged, whether you were in it or reach it from a bookmark or
    /// Recent, says the disk was disconnected, with Try Again for when it's back. It used to say the folder "no longer
    /// exists" and "may have been moved, renamed or deleted", with only Go to Home, which read as data loss.
    func testAFolderOnAnUnpluggedDiskSaysTheDiskIsDisconnected() async throws {
        let controller = try await documentsWindow()
        let memory = try XCTUnwrap(controller.dependencies.fileSystem as? InMemoryFileSystem)
        let disk = URL(fileURLWithPath: "/Volumes/Backup", isDirectory: true)
        let projects = disk.appendingPathComponent("Projects", isDirectory: true)
        for folder in [URL(fileURLWithPath: "/Volumes", isDirectory: true), disk, projects] { try await memory.createDirectory(at: folder) }
        controller.navigate(to: .directory(projects))
        let opened = await until { controller.activeTab?.location == .directory(projects) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(opened)
        // The disk is unplugged: its mount point goes, and the folder is read again (the monitor's unmount event
        // validates the folder the same way).
        try await memory.removeItem(at: disk)
        controller.perform(.refresh)
        let carded = await until { controller.contentStateForTesting != nil }
        XCTAssertTrue(carded)
        let card = controller.contentStateForTesting
        XCTAssertEqual(card?.title, "The disk holding “Projects” was disconnected", "\(card?.title ?? "") / \(card?.message ?? "")")
        XCTAssertTrue(card?.buttons.contains { $0.title == "Try Again" } ?? false, "\(card?.buttons.map(\.title) ?? [])")
    }

    // MARK: A folder that can't open in place

    /// Opening a refused folder by its triangle used to close it again without a word. The status bar now says why.
    func testAFolderThatCannotOpenInPlaceSaysWhy() async throws {
        let controller = try await documentsWindow()
        controller.navigate(to: .directory(home))
        let listed = await until { controller.activeTab?.location == .directory(self.home) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(listed)
        let folder = try XCTUnwrap(entry(named: "Private", in: controller))
        controller.contentExpand(folder.id)
        let said = await until { controller.statusTextForTesting.contains("“Private”") }
        XCTAssertTrue(said, controller.statusTextForTesting)
        XCTAssertEqual(controller.activeTab?.expandedIDs.contains(folder.id), false)
        XCTAssertTrue(controller.statusTextForTesting.hasPrefix("You don’t have permission to see inside “Private”"), controller.statusTextForTesting)
        // Clicking an item clears it.
        controller.contentSelectionChanged([try XCTUnwrap(entry(named: "Documents", in: controller)).id])
        let cleared = await until { !controller.statusTextForTesting.contains("“Private”") }
        XCTAssertTrue(cleared, controller.statusTextForTesting)
    }

    // MARK: Empty Trash without access

    /// Without Full Disk Access Helm can't see a single item in the Trash, so Empty Trash shows the guide straight away.
    /// It used to ask "Are you sure you want to permanently erase the items in the Trash?" first, about items that
    /// were never going to be erased.
    func testEmptyTrashWithoutAccessDoesNotAskToEraseFirst() async throws {
        let controller = try await documentsWindow()
        let memory = try XCTUnwrap(controller.dependencies.fileSystem as? InMemoryFileSystem)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        try await memory.createDirectory(at: trash)
        await memory.setFailure(.permissionDenied, at: trash)
        let stand = try XCTUnwrap(controller.dependencies.permissions.provider as? MemoryPrivacyAccess)
        await controller.dependencies.permissions.refresh()
        XCTAssertEqual(controller.dependencies.permissions.fullDiskAccess, .denied)
        controller.confirmsForTesting = false // As for a person: the question is a real sheet.
        controller.emptyTrashForTesting()
        let guided = await until { stand.openedPanes == [.fullDiskAccess] || controller.window?.attachedSheet != nil }
        XCTAssertTrue(guided, "neither the guide nor a question came up")
        let question = (controller.window?.attachedSheet?.contentViewController == nil) ? controller.window?.attachedSheet : nil
        let alertText = question.flatMap { sheet in
            sheet.contentView.map { Self.texts(in: $0) }?.first { $0.contains("permanently erase") }
        }
        XCTAssertNil(alertText, "asked to erase the Trash before finding Helm can't see it")
        XCTAssertEqual(stand.openedPanes, [.fullDiskAccess], "the guide (here its row) should come up instead")
        if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
    }

    private static func texts(in view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { texts(in: $0) }
    }

    // MARK: Helpers

    private func entry(named name: String, in controller: BrowserWindowController) -> FileEntry? {
        controller.activeTab?.snapshot.sortedEntries.first { $0.name == name }
    }

    /// Documents with q2.txt selected, then a click on Private, which refuses: its card covers Documents.
    private func cardOverDocuments(selecting name: String) async throws -> BrowserWindowController {
        let controller = try await documentsWindow()
        let file = try XCTUnwrap(entry(named: name, in: controller))
        controller.store.send(.tab(controller.activeTabID, .setSelection([file.id], source: .user)))
        XCTAssertEqual(controller.selectedEntries().map(\.name), [name])
        controller.navigate(to: .directory(refused))
        let shown = await until { controller.contentStateForTesting?.title == self.refusedTitle }
        XCTAssertTrue(shown, "no card for Private: \(controller.contentStateForTesting?.title ?? "none")")
        XCTAssertTrue(controller.isListingHiddenForTesting)
        return controller
    }

    /// A window that's never shown, over a home with Documents (holding q2.txt), Downloads and a Private folder that
    /// refuses to open, already in Documents.
    private func documentsWindow() async throws -> BrowserWindowController {
        let env = try await AppEnvironment.test(home: home)
        for folder in ["Documents", "Downloads", "Private"] {
            try await env.fileSystem.createDirectory(at: home.appendingPathComponent(folder, isDirectory: true))
        }
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        try await memory.createFileExclusively(at: documents.appendingPathComponent("q2.txt"), contents: Data("q2".utf8))
        try await memory.createFileExclusively(at: refused.appendingPathComponent("plans.txt"), contents: Data("p".utf8))
        await memory.setFailure(.permissionDenied, at: refused)
        let operations = OperationCoordinator(fileSystem: env.fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: env.directories.home) { false }
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: env.fileSystem,
            operations: operations, home: env.directories.home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.hunt-permissions.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith)
        let host = HuntPermissionsHost()
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "hunt-permissions",
                                                 seeds: [], activeIndex: 0)
        keep += [host, operations, volumes]
        controllers.append(controller)
        controller.confirmsForTesting = true
        controller.messageObserver = { _ in }
        controller.navigate(to: .directory(documents))
        let arrived = await until { controller.activeTab?.location == .directory(self.documents) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "Documents never opened")
        return controller
    }

    /// Waits for a condition, as long as a busy machine needs, and no longer than it takes.
    private func until(_ timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
    private func settle(_ seconds: Double = 0.2) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
}

@MainActor private final class HuntPermissionsHost: BrowserWindowHost {
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
}
#endif
