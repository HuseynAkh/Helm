#if os(macOS)
import AppKit
import XCTest
import HelmCore
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmApp
@testable import HelmUI

/// Properties windows and Open in Terminal, in a whole window over the in-memory home, never shown. Folders go to a
/// stand-in launcher, so no terminal opens.
@MainActor final class PropertiesTerminalWindowTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/helm", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var project: URL { documents.appendingPathComponent("Project", isDirectory: true) }
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        HostEffectRunner.spotlightAnswersForTesting = { _ in AsyncStream { $0.yield([]); $0.finish() } }
    }
    override func tearDown() {
        for controller in controllers {
            while controller.propertiesWindowCountForTesting > 0 { controller.closePropertiesForTesting() }
            controller.window?.close()
        }
        controllers = []; keep = []
        HeaderMotion.isDisabledForTesting = false
        HostEffectRunner.spotlightAnswersForTesting = nil
        super.tearDown()
    }

    // MARK: Properties

    /// A folder's Properties count what's inside it, files in folders inside too, and the window is handed to the
    /// app to bring in rather than shown by the browser window.
    func testAFoldersPropertiesCountWhatsInsideIt() async throws {
        let (controller, _, host) = try await window()
        select(["Project"], in: controller)
        controller.perform(.properties)
        let done = await until { controller.propertiesFinishedForTesting }
        XCTAssertTrue(done, "the count never finished")
        XCTAssertEqual(controller.propertiesTitleForTesting, "Project Properties")
        let rows = Dictionary(uniqueKeysWithValues: controller.propertiesRowsForTesting.map { ($0.label, $0.value) })
        // plan.txt (4 bytes), Drafts, Drafts/one.md (3 bytes).
        XCTAssertEqual(rows["Contents"], "3 items, totalling 7 bytes")
        XCTAssertEqual(rows["Parent Folder"], "~/Documents")
        XCTAssertNil(rows["Size"])
        XCTAssertEqual(host.presented.count, 1)
        XCTAssertFalse(host.presented.first?.isVisible ?? true, "the test host never shows it")
        XCTAssertNil(controller.window?.attachedSheet, "Properties is a window of its own, not a sheet")
    }

    /// Escape closes it, as in Nautilus, and several can be open at once.
    func testEscapeClosesItAndSeveralCanBeOpen() async throws {
        let (controller, _, _) = try await window()
        select(["Project"], in: controller)
        controller.perform(.properties)
        select(["letter.txt"], in: controller)
        controller.perform(.properties)
        let both = await until { controller.propertiesWindowCountForTesting == 2 && controller.propertiesFinishedForTesting }
        XCTAssertTrue(both)
        XCTAssertEqual(controller.propertiesRowsForTesting.first { $0.label == "Size" }?.value, "6 bytes")
        controller.propertiesKeyForTesting("escape")
        XCTAssertEqual(controller.propertiesWindowCountForTesting, 1)
        controller.closePropertiesForTesting()
        XCTAssertEqual(controller.propertiesWindowCountForTesting, 0)
    }

    /// The empty space's Properties are the folder on show's.
    func testTheFolderOnShowHasPropertiesToo() async throws {
        let (controller, _, _) = try await window()
        select([], in: controller)
        controller.perform(.directoryProperties)
        let done = await until { controller.propertiesFinishedForTesting }
        XCTAssertTrue(done)
        XCTAssertEqual(controller.propertiesTitleForTesting, "Documents Properties")
        XCTAssertEqual(controller.propertiesRowsForTesting.first { $0.label == "Contents" }?.value, "5 items, totalling 13 bytes")
    }

    // MARK: Open in Terminal

    /// A selected folder, or the folder on show when nothing is, goes to Terminal; a file or two items don't.
    func testOpenInTerminalHandsTheFolderToTerminal() async throws {
        let (controller, launcher, _) = try await window()
        select(["Project"], in: controller)
        XCTAssertTrue(controller.title(of: .openInTerminal).1)
        controller.perform(.openInTerminal)
        await settle()
        XCTAssertEqual(launcher.openings.last?.urls.map(\.path), [project.path])
        XCTAssertEqual(launcher.openings.last.flatMap { Bundle(url: $0.application)?.bundleIdentifier }, "com.apple.Terminal")
        XCTAssertEqual(launcher.openings.last?.activates, true)

        select([], in: controller)
        XCTAssertTrue(controller.title(of: .openInTerminal).1)
        controller.perform(.openInTerminal)
        await settle()
        XCTAssertEqual(launcher.openings.last?.urls.map(\.path), [documents.path])

        select(["letter.txt"], in: controller)
        XCTAssertFalse(controller.title(of: .openInTerminal).1)
        select(["letter.txt", "Project"], in: controller)
        XCTAssertFalse(controller.title(of: .openInTerminal).1)
        XCTAssertEqual(launcher.openings.count, 2)
    }

    /// The right-click menus offer it on a folder and on the empty space, and not on a file.
    func testTheRightClickMenusOfferItOnFoldersOnly() async throws {
        let (controller, _, _) = try await window()
        let entries = controller.activeTab?.snapshot.sortedEntries ?? []
        func titles(_ names: [String]) -> [String] {
            controller.contextMenu(for: entries.filter { names.contains($0.name) })?.items.map(\.title) ?? []
        }
        XCTAssertTrue(titles(["Project"]).contains("Open in Terminal"))
        XCTAssertTrue(titles([]).contains("Open in Terminal"))
        XCTAssertFalse(titles(["letter.txt"]).contains("Open in Terminal"))
        XCTAssertFalse(titles(["letter.txt", "Project"]).contains("Open in Terminal"))
    }

    /// A piece of the path bar opens its own folder in the terminal.
    func testThePathBarOpensItsFolderInTheTerminal() async throws {
        let (controller, launcher, _) = try await window()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(Self.subviews(of: PathSegmentButton.self, in: controller.pathBar).first { $0.url == home })
        let menu = try XCTUnwrap(button.onMenu?(button.url))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open in Terminal" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        await settle()
        XCTAssertEqual(launcher.openings.last?.urls.map(\.path), [home.path])
    }

    /// A terminal chosen in Settings that isn't on this Mac any more falls back to Terminal.
    func testATerminalThatsGoneFallsBackToTerminal() async throws {
        let (controller, launcher, _) = try await window()
        let gone = try XCTUnwrap(TerminalApps.known.first { TerminalLocator.application($0.id) == nil }, "every terminal is installed")
        controller.dependencies.settings.set(.string(gone.id), for: .terminalApp)
        select(["Project"], in: controller)
        controller.perform(.openInTerminal)
        await settle()
        XCTAssertEqual(launcher.openings.last.flatMap { Bundle(url: $0.application)?.bundleIdentifier }, "com.apple.Terminal")
        XCTAssertTrue(TerminalLocator.installed(folder: FileManager.default.temporaryDirectory).contains { $0.id == "com.apple.Terminal" })
    }

    // MARK: Setup

    private func window() async throws -> (BrowserWindowController, MemoryAppLauncher, PresentingHost) {
        let launcher = MemoryAppLauncher { _ in ([], nil) }
        let env = try await AppEnvironment.test(home: home)
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        try await memory.createDirectory(at: documents)
        try await memory.createDirectory(at: project)
        try await memory.createDirectory(at: project.appendingPathComponent("Drafts"))
        for (url, text) in [(documents.appendingPathComponent("letter.txt"), "letter"), (project.appendingPathComponent("plan.txt"), "plan"),
                            (project.appendingPathComponent("Drafts/one.md"), "one")] {
            try await memory.createFileExclusively(at: url, contents: Data(text.utf8))
        }
        let operations = OperationCoordinator(fileSystem: env.fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: env.directories.home) { false }
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: env.fileSystem,
            operations: operations, home: env.directories.home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.properties.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith, launcher: launcher)
        let host = PresentingHost()
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "properties", seeds: [], activeIndex: 0)
        keep += [host, operations, volumes]
        controllers.append(controller)
        controller.messageObserver = { _ in }
        controller.navigate(to: .directory(documents))
        let arrived = await until { controller.activeTab?.location == .directory(self.documents) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "Documents never opened")
        return (controller, launcher, host)
    }
    private func select(_ names: [String], in controller: BrowserWindowController) {
        guard let tab = controller.activeTab else { return }
        let ids = tab.snapshot.sortedEntries.filter { names.contains($0.name) }.map(\.id)
        controller.store.send(.tab(tab.id, .setSelection(Set(ids), source: .user)))
    }
    private func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
    private func settle(_ seconds: Double = 0.2) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private static func subviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + subviews(of: type, in: $0) }
    }
}

/// Keeps the windows it's asked to bring in, without showing them.
@MainActor private final class PresentingHost: BrowserWindowHost {
    var presented: [NSWindow] = []
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
    func present(_ window: NSWindow) { presented.append(window) }
}
#endif
