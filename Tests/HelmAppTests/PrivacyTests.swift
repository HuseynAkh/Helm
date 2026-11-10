#if os(macOS)
import AppKit
import XCTest
import HelmCore
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmApp
@testable import HelmUI

/// Privacy: Helm keeps less about you, and reads the clipboard only when you paste. Windows run over the in-memory
/// home with a pasteboard of their own; stores that save run in temporary folders, removed afterwards.
@MainActor final class PrivacyTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/privacy", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var trash: URL { home.appendingPathComponent(".Trash", isDirectory: true) }
    private var controllers: [BrowserWindowController] = []
    private var pasteboards: [NSPasteboard] = []
    private var keep: [AnyObject] = []
    private var folders: [URL] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }
    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        controllers = []; pasteboards = []; keep = []; folders = []
        super.tearDown()
    }

    // MARK: The clipboard

    /// ⌘C writes the items, and their names as text, as Finder does: no paths, so no account name or folder layout.
    /// Cut does the same. Copy as Pathname is the one that writes full paths.
    func testCopyWritesTheItemsAndTheirNamesNotTheirPaths() async throws {
        let (controller, _, _) = try await window(files: ["Documents/alpha.txt", "Documents/beta.txt"])
        let pasteboard = controller.dependencies.pasteboard
        select(["alpha.txt", "beta.txt"], in: controller)
        for command in [CommandID.copy, .cut] {
            controller.perform(command)
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            XCTAssertEqual(Set(urls), [documents.appendingPathComponent("alpha.txt"), documents.appendingPathComponent("beta.txt")], "\(command)")
            let texts = (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }
            XCTAssertEqual(texts.count, 1, "\(command)")
            XCTAssertEqual(Set(texts.first?.split(separator: "\n").map(String.init) ?? []), ["alpha.txt", "beta.txt"], "\(command)")
            XCTAssertFalse(texts.contains { $0.contains("/") }, "\(command) put a path on the clipboard")
        }
        controller.perform(.copyAsPathname)
        let paths = pasteboard.string(forType: .string)?.split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(Set(paths), [documents.appendingPathComponent("alpha.txt").path, documents.appendingPathComponent("beta.txt").path])
    }

    /// Menus are checked all the time. They look only at what kind of thing is on the clipboard, never at what it
    /// says, which could be a password; macOS can tell people when an app reads it. Pasting is when it's read.
    func testMenusCheckOnlyWhatKindOfThingIsOnTheClipboard() async throws {
        let (controller, _, memory) = try await window(files: ["Documents/notes.txt", "Inbox/", "Inbox/gamma.txt"])
        let pasteboard = controller.dependencies.pasteboard
        let text = LazyContents("a password")
        put(text, as: .string, on: pasteboard)
        XCTAssertEqual(controller.commandContext().clipboard, .text)
        XCTAssertFalse(controller.title(of: .paste).1, "text isn't pasted as files")
        XCTAssertEqual(text.reads, 0, "checking the menus read the clipboard's text")
        let gamma = home.appendingPathComponent("Inbox/gamma.txt")
        let files = LazyContents(gamma.absoluteString)
        put(files, as: .fileURL, on: pasteboard)
        XCTAssertEqual(controller.commandContext().clipboard, .files)
        XCTAssertTrue(controller.title(of: .paste).1)
        XCTAssertEqual(files.reads, 0, "checking the menus read the clipboard's files")
        controller.perform(.paste)
        XCTAssertGreaterThan(files.reads, 0, "pasting reads them")
        let pasted = await until { await memory.exists(self.documents.appendingPathComponent("gamma.txt")) }
        XCTAssertTrue(pasted, "the file was pasted")
    }

    /// The path bar's Copy Path writes to the window's pasteboard like every other copy, so a fixture run or a test
    /// never writes to the person's own clipboard.
    func testThePathBarsCopyPathUsesTheWindowsPasteboard() async throws {
        let (controller, _, _) = try await window(files: [])
        // The pieces join the path bar when it lays out, and this window is never shown.
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(Self.subviews(of: PathSegmentButton.self, in: controller.pathBar).last)
        XCTAssertEqual(button.url?.path, documents.path)
        let menu = try XCTUnwrap(button.onMenu?(button.url))
        let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy Path" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(copy.action), to: copy.target, from: copy))
        XCTAssertEqual(controller.dependencies.pasteboard.string(forType: .string), documents.path)
    }

    // MARK: Where trashed items came from

    /// Put Back forgets where the item came from. Undo puts it back in the Trash with its record, so Put Back
    /// works on it again.
    func testPutBackForgetsWhereTheItemCameFromAndUndoRemembersAgain() async throws {
        let (controller, env, memory) = try await window(files: [".Trash/notes.txt"])
        let trashed = trash.appendingPathComponent("notes.txt"), original = documents.appendingPathComponent("notes.txt")
        await env.trashOrigins.record([TrashedItem(trashedURL: trashed, originalURL: original)])
        try await openTrash(listing: "notes.txt", in: controller)
        select(["notes.txt"], in: controller)
        controller.perform(.putBack)
        let back = await until { await memory.exists(original) }
        XCTAssertTrue(back, "Put Back didn't happen")
        await settle(controller)
        XCTAssertTrue(env.trashOrigins.records.isEmpty, "the item has left the Trash, so its record goes")
        controller.perform(.undo)
        let returned = await until { await memory.exists(trashed) }
        XCTAssertTrue(returned, "Undo didn't put it back in the Trash")
        await settle(controller)
        let origin = await env.trashOrigins.originalURL(forTrashed: trashed)
        XCTAssertEqual(origin, original)
    }

    func testEmptyTrashForgetsWhereTheErasedItemsCameFrom() async throws {
        let (controller, env, memory) = try await window(files: [".Trash/notes.txt"])
        let trashed = trash.appendingPathComponent("notes.txt")
        let away = URL(fileURLWithPath: "/Volumes/Away/.Trashes/501/other.txt")
        await env.trashOrigins.record([TrashedItem(trashedURL: trashed, originalURL: documents.appendingPathComponent("notes.txt")),
                                       TrashedItem(trashedURL: away, originalURL: URL(fileURLWithPath: "/Volumes/Away/other.txt"))])
        controller.emptyTrashForTesting()
        let erased = await until { !(await memory.exists(trashed)) }
        XCTAssertTrue(erased, "the Trash wasn't emptied")
        _ = await until { env.trashOrigins.records.count == 1 }
        XCTAssertEqual(env.trashOrigins.records.map(\.trashedPath), [away.path], "only what was erased is forgotten")
    }

    func testDeleteImmediatelyInTheTrashForgetsWhereTheItemCameFrom() async throws {
        let (controller, env, memory) = try await window(files: [".Trash/notes.txt"])
        let trashed = trash.appendingPathComponent("notes.txt")
        await env.trashOrigins.record([TrashedItem(trashedURL: trashed, originalURL: documents.appendingPathComponent("notes.txt"))])
        try await openTrash(listing: "notes.txt", in: controller)
        select(["notes.txt"], in: controller)
        controller.perform(.permanentDelete)
        let erased = await until { !(await memory.exists(trashed)) }
        XCTAssertTrue(erased, "the item wasn't deleted")
        _ = await until { env.trashOrigins.records.isEmpty }
        XCTAssertTrue(env.trashOrigins.records.isEmpty)
    }

    /// At launch, records for items that left the Trash while Helm wasn't looking, as when Finder emptied it, go.
    /// A record whose Trash can't be reached stays: its disk may just not be plugged in.
    func testLaunchForgetsItemsGoneFromTheTrashButNotFromADiskThatIsAway() async throws {
        let root = try folder()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: trash.appendingPathComponent("still-here.txt"))
        let env = try await liveEnvironment(in: root)
        let away = root.appendingPathComponent("Volumes/Away/.Trashes/501/away.txt")
        await env.trashOrigins.record([
            TrashedItem(trashedURL: trash.appendingPathComponent("still-here.txt"), originalURL: home.appendingPathComponent("still-here.txt")),
            TrashedItem(trashedURL: trash.appendingPathComponent("emptied.txt"), originalURL: home.appendingPathComponent("emptied.txt")),
            TrashedItem(trashedURL: away, originalURL: root.appendingPathComponent("Volumes/Away/away.txt"))])
        await env.forgetItemsGoneFromTrash()
        let kept = Set(env.trashOrigins.records.map { URL(fileURLWithPath: $0.trashedPath).lastPathComponent })
        XCTAssertEqual(kept, ["still-here.txt", "away.txt"])
        _ = await env.flushStores()
    }

    // MARK: Recent

    func testWithRememberRecentItemsOffWindowsAddNothingToRecent() async throws {
        let (controller, env, _) = try await window(files: ["Documents/Reports/"])
        let reports = documents.appendingPathComponent("Reports", isDirectory: true)
        XCTAssertTrue(env.recents.records.contains { $0.path == documents.path }, "on, a visit is recorded")
        env.settings.set(.bool(false), for: .rememberRecentItems)
        controller.navigate(to: .directory(reports))
        let arrived = await until { controller.activeTab?.location == .directory(reports) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived)
        XCTAssertFalse(env.recents.records.contains { $0.path == reports.path }, "off, a visit isn't")
        env.settings.set(.bool(true), for: .rememberRecentItems)
        controller.navigate(to: .directory(documents))
        _ = await until { controller.activeTab?.location == .directory(self.documents) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(env.recents.records.contains { $0.path == documents.path })
    }

    /// Opening a file with an app adds it to Recent and to the apps used for that kind of file, but only while
    /// Remember recent items is on. Nothing is opened here: this is what opening keeps.
    func testWithRememberRecentItemsOffOpeningAFileAddsNothing() async throws {
        let (controller, env, _) = try await window(files: ["Documents/notes.txt"])
        let entry = try XCTUnwrap(controller.activeTab?.snapshot.sortedEntries.first { $0.name == "notes.txt" })
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        env.settings.set(.bool(false), for: .rememberRecentItems)
        controller.rememberOpening([entry], with: textEdit)
        XCTAssertFalse(env.recents.records.contains { $0.path == entry.url.path }, "off, the file isn't added to Recent")
        XCTAssertTrue(env.openWith.records.isEmpty, "off, the app isn't kept")
        env.settings.set(.bool(true), for: .rememberRecentItems)
        controller.rememberOpening([entry], with: textEdit)
        XCTAssertTrue(env.recents.records.contains { $0.path == entry.url.path })
        XCTAssertEqual(env.openWith.records.map(\.application), [textEdit.path])
    }

    func testClearRecentForgetsTheAppsYouveUsedToo() async throws {
        let (controller, env, _) = try await window(files: [])
        env.openWith.recordUse(of: "/System/Applications/TextEdit.app", for: "public.plain-text", at: Date())
        XCTAssertFalse(env.recents.records.isEmpty)
        controller.perform(.clearRecent)
        XCTAssertTrue(env.recents.records.isEmpty)
        XCTAssertTrue(env.openWith.records.isEmpty)
    }

    /// Turning Remember recent items off clears recent.json and the apps you've used in open-with.json. Off at
    /// launch, anything left from before is cleared too.
    func testRememberRecentItemsOffClearsWhatWasKept() async throws {
        let root = try folder()
        let env = try await liveEnvironment(in: root)
        env.followPrivacySettings()
        env.recents.recordAccess(to: root.appendingPathComponent("home/Documents"), kind: .directory, at: Date())
        env.openWith.recordUse(of: "/System/Applications/TextEdit.app", for: "public.plain-text", at: Date())
        _ = await env.flushStores()
        env.settings.set(.bool(false), for: .rememberRecentItems)
        XCTAssertTrue(env.recents.records.isEmpty)
        XCTAssertTrue(env.openWith.records.isEmpty)
        _ = await env.flushStores()
        XCTAssertFalse(try text(of: root.appendingPathComponent("support/recent.json")).contains("Documents"))
        XCTAssertFalse(try text(of: root.appendingPathComponent("support/open-with.json")).contains("TextEdit"))
        env.recents.recordAccess(to: root.appendingPathComponent("home/Documents"), kind: .directory, at: Date())
        _ = await env.flushStores()
        let next = try await liveEnvironment(in: root, off: [.rememberRecentItems])
        XCTAssertFalse(next.recents.records.isEmpty)
        next.followPrivacySettings()
        XCTAssertTrue(next.recents.records.isEmpty)
        _ = await next.flushStores()
    }

    // MARK: The saved session

    /// With Reopen windows and tabs off, session.json is deleted, and closing a window or quitting doesn't write it.
    func testWithReopenWindowsOffNoSessionIsKept() async throws {
        let root = try folder()
        let session = root.appendingPathComponent("support/session.json")
        let windows = [SessionWindow(frameAutosaveName: "HelmMainWindow", tabs: [SessionTab(location: .recent)])]
        let env = try await liveEnvironment(in: root)
        env.followPrivacySettings()
        env.saveSession(windows)
        _ = await env.flushStores()
        XCTAssertTrue(exists(session))
        env.settings.set(.bool(false), for: .restoreSessionOnLaunch)
        _ = await env.flushStores()
        XCTAssertFalse(exists(session), "turning the switch off deletes it")
        env.saveSession(windows)
        _ = await env.flushStores()
        XCTAssertFalse(exists(session), "with the switch off, nothing is saved")
        env.settings.set(.bool(true), for: .restoreSessionOnLaunch)
        env.saveSession(windows)
        _ = await env.flushStores()
        XCTAssertTrue(exists(session), "turned on again, it's saved as before")
        // A session left from before is deleted when Helm starts with the switch off.
        let next = try await liveEnvironment(in: root, off: [.restoreSessionOnLaunch])
        next.followPrivacySettings()
        _ = await next.flushStores()
        XCTAssertFalse(exists(session))
    }

    // MARK: The sidebar

    /// sidebar.json keeps where a starred item sits, and whether it's hidden, only while it's starred. Moved by dragging
    /// its row or in Settings › Sidebar, and hidden from its menu or there, then unstarred in the listing, it leaves
    /// nothing behind. Starred again, it's a new row in its natural place, on show.
    func testUnstarringForgetsWhereTheRowWasAndThatItWasHidden() async throws {
        let names = ["alpha.txt", "beta.txt", "gamma.txt"]
        let (controller, env, _) = try await window(files: names.map { "Documents/" + $0 })
        for name in names { env.stars.star(documents.appendingPathComponent(name), at: Date()) }
        let layout = env.sidebarLayout
        let id = { (name: String) in Place.id(.starred, path: self.documents.appendingPathComponent(name).path) }
        // beta is dragged to the end of Starred and hidden from its menu. gamma is moved up and unchecked in Settings.
        XCTAssertTrue(controller.sidebarDropForTesting(.starred, "beta.txt", onto: nil))
        let dropped = await until { layout.layout.starred == [id("alpha.txt"), id("gamma.txt"), id("beta.txt")] }
        XCTAssertTrue(dropped, "the drag left Starred as \(layout.layout.starred)")
        XCTAssertTrue(controller.sidebarMenuPickForTesting(.starred, "beta.txt", "Hide from Sidebar"))
        let settings = SidebarSettingsModel(dependencies: controller.dependencies)
        let gamma = try XCTUnwrap(settings.placeForTesting(.starred, named: "gamma.txt"))
        settings.step(gamma, by: -1)
        settings.setShown(gamma, false)
        XCTAssertEqual(layout.layout.starred, [id("gamma.txt"), id("alpha.txt"), id("beta.txt")])
        XCTAssertEqual(Set(layout.layout.hidden), [id("beta.txt"), id("gamma.txt")])
        select(["beta.txt", "gamma.txt"], in: controller)
        controller.perform(.star)
        XCTAssertFalse(env.stars.isStarred(documents.appendingPathComponent("beta.txt")))
        XCTAssertEqual(layout.layout.starAndBookmarkIDs, [id("alpha.txt")], "sidebar.json still names the unstarred items")
        XCTAssertTrue(layout.layout.hidden.isEmpty)
        controller.perform(.star)
        XCTAssertEqual(controller.sidebarRowNamesForTesting(.starred), names)
        XCTAssertEqual(settings.rowsForTesting(.starred).map(\.isShown), [true, true, true])
    }

    /// The same for a bookmark: hidden, then removed with Go › Remove Bookmark, it leaves nothing in sidebar.json, and
    /// bookmarked again it's on show, at the end. Removed from its own menu, it leaves nothing either.
    func testRemovingABookmarkForgetsThatItWasHidden() async throws {
        let (controller, env, _) = try await window(files: ["Documents/Reports/", "Documents/Inbox/"])
        let reports = documents.appendingPathComponent("Reports", isDirectory: true)
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
        XCTAssertTrue(env.bookmarks.add(reports, isDirectory: true, at: Date()))
        XCTAssertTrue(env.bookmarks.add(inbox, isDirectory: true, at: Date()))
        let layout = env.sidebarLayout
        let settings = SidebarSettingsModel(dependencies: controller.dependencies)
        settings.setShown(try XCTUnwrap(settings.placeForTesting(.bookmarks, named: "Reports")), false)
        XCTAssertTrue(layout.layout.isHidden(Place.id(.bookmark, path: reports.path)))
        XCTAssertEqual(controller.sidebarRowNamesForTesting(.bookmarks), ["Inbox"])
        controller.navigate(to: .directory(reports))
        let arrived = await until { controller.activeTab?.location == .directory(reports) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "Reports never opened")
        controller.perform(.removeBookmark)
        XCTAssertEqual(env.bookmarks.records.map(\.path), [inbox.path])
        XCTAssertTrue(layout.layout.isDefault, "sidebar.json still names the removed bookmark")
        controller.sidebarAddBookmarks([reports])
        let added = await until { controller.sidebarRowNamesForTesting(.bookmarks) == ["Inbox", "Reports"] }
        XCTAssertTrue(added, "bookmarked again, the rows are \(controller.sidebarRowNamesForTesting(.bookmarks))")
        XCTAssertTrue(controller.sidebarMenuPickForTesting(.bookmarks, "Reports", "Remove Bookmark"))
        XCTAssertEqual(env.bookmarks.records.map(\.path), [inbox.path])
        XCTAssertTrue(layout.layout.isDefault)
    }

    // MARK: Saved window state and the test driver

    /// Neither Settings nor a browser window leaves state for macOS to restore, and any state is read back securely.
    func testNothingIsLeftForMacOSToRestore() async throws {
        let options = try XCTUnwrap(LaunchOptions.parse(["Helm", "--home", "/tmp/helm-privacy-home", "--support", "/tmp/helm-privacy-support"]))
        let app = AppController(options: options)
        XCTAssertTrue(app.applicationSupportsSecureRestorableState(NSApplication.shared))
        let settings = SettingsWindowController(store: SettingsStore(storage: IsolatedSettings()), fileViewer: nil, persistsFrame: false)
        XCTAssertEqual(settings.window?.isRestorable, false)
        XCTAssertEqual(settings.window?.frameAutosaveName, "", "a test leaves the preferences alone")
        settings.window?.close()
        let (controller, _, _) = try await window(files: [])
        XCTAssertEqual(controller.window?.isRestorable, false)
    }

    /// A script may drive only fixture folders: `--smoke` without both `--home` and `--support` is refused, and
    /// Helm prints the usage line instead of starting.
    func testASmokeScriptNeedsBothFixtureFolders() throws {
        XCTAssertNil(LaunchOptions.parse(["Helm", "--smoke", "/tmp/steps.txt"]))
        XCTAssertNil(LaunchOptions.parse(["Helm", "--home", "/tmp/home", "--smoke", "/tmp/steps.txt"]))
        XCTAssertNil(LaunchOptions.parse(["Helm", "--smoke", "/tmp/steps.txt", "--support", "/tmp/support"]))
        let options = try XCTUnwrap(LaunchOptions.parse(["Helm", "--home", "/tmp/home", "--support", "/tmp/support",
                                                         "--smoke", "/tmp/steps.txt"]))
        XCTAssertEqual(options.smokeScript?.path, "/tmp/steps.txt")
        XCTAssertTrue(options.isIsolated)
        XCTAssertNotNil(LaunchOptions.parse(["Helm"]))
        XCTAssertNotNil(LaunchOptions.parse(["Helm", "--home", "/tmp/home"]), "without a script, one folder is still fine")
        XCTAssertTrue(LaunchOptions.usage.contains("Helm --home PATH --support PATH --smoke SCRIPT"))
    }

    // MARK: Helpers

    /// A window over the in-memory home with Documents and the Trash, never shown, with a pasteboard of its own.
    /// A path ending in "/" is a folder.
    private func window(files: [String]) async throws -> (BrowserWindowController, AppEnvironment, InMemoryFileSystem) {
        let env = try await AppEnvironment.test(home: home)
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        for folder in [documents, trash] { try await memory.createDirectory(at: folder) }
        for path in files {
            let url = home.appendingPathComponent(path)
            if path.hasSuffix("/") { try await memory.createDirectory(at: url) }
            else { try await memory.createFileExclusively(at: url, contents: Data("hello".utf8)) }
        }
        let operations = OperationCoordinator(fileSystem: env.fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: home) { false }
        let pasteboard = NSPasteboard(name: .init("helm.privacy-tests.\(UUID().uuidString)"))
        pasteboards.append(pasteboard)
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: env.fileSystem,
            operations: operations, home: home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            sidebarLayout: env.sidebarLayout,
            clock: env.clock, pasteboard: pasteboard, persistsWindowFrames: false, openWith: env.openWith)
        env.settings.set(.bool(false), for: .askOnConflict)
        let host = PrivacyQuietHost()
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "privacy", seeds: [], activeIndex: 0)
        controller.confirmsForTesting = true
        keep += [host, operations, volumes]
        controllers.append(controller)
        controller.navigate(to: .directory(documents))
        let arrived = await until { controller.activeTab?.location == .directory(self.documents) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "Documents never opened")
        return (controller, env, memory)
    }

    /// Stores that save, in a temporary folder: home/ and support/. `off` lists switches that start off.
    /// Its Trash is home/.Trash, so a test never reaches the real one.
    private func liveEnvironment(in root: URL, off: [SettingKey] = []) async throws -> AppEnvironment {
        let settings = IsolatedSettings()
        for key in off { settings.set(false, forKey: key.rawValue) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        return try await AppEnvironment.live(
            directories: AppDirectories(home: home, applicationSupport: root.appendingPathComponent("support", isDirectory: true)),
            settingsStorage: settings, legacyReader: NoLegacyDefaults(), trash: { url in
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                let destination = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            })
    }

    private func openTrash(listing name: String, in controller: BrowserWindowController) async throws {
        controller.navigate(to: .trash)
        let listed = await until { controller.activeTab?.location == .trash && self.names(controller).contains(name) }
        XCTAssertTrue(listed, "the Trash doesn't list \(name)")
    }
    private func put(_ contents: LazyContents, as type: NSPasteboard.PasteboardType, on pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setDataProvider(contents, forTypes: [type])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
    private func select(_ chosen: [String], in controller: BrowserWindowController) {
        guard let tab = controller.activeTab else { return XCTFail("no tab") }
        let entries = tab.snapshot.sortedEntries.filter { chosen.contains($0.name) }
        XCTAssertEqual(entries.count, chosen.count, "not all of \(chosen) are listed")
        controller.store.send(.tab(tab.id, .setSelection(Set(entries.map(\.id)), source: .user)))
    }
    private func names(_ controller: BrowserWindowController) -> [String] {
        controller.activeTab.map { tab in tab.snapshot.sortedEntries.map(\.name) } ?? []
    }
    private func until(_ timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
    /// Waits for the window's operations to finish and its listing to settle.
    private func settle(_ controller: BrowserWindowController) async {
        _ = await until { !controller.isRunningOperations && controller.activeTab?.isLoading == false }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("helm-privacy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private static func subviews<View: NSView>(of type: View.Type, in view: NSView) -> [View] {
        view.subviews.flatMap { ([$0 as? View].compactMap { $0 }) + subviews(of: type, in: $0) }
    }
    private func text(of url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
}

/// Gives its contents only when something reads them, and counts the reads.
private final class LazyContents: NSObject, NSPasteboardItemDataProvider {
    let contents: String
    private(set) var reads = 0
    init(_ contents: String) { self.contents = contents }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        reads += 1
        item.setString(contents, forType: type)
    }
}

@MainActor private final class PrivacyQuietHost: BrowserWindowHost {
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
}
#endif
