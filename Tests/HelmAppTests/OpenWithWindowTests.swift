#if os(macOS)
import AppKit
import XCTest
import HelmCore
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmApp
@testable import HelmUI

/// Open With from every menu that offers it, in a whole window over the in-memory home, never shown. Apps are made-up
/// bundles in a temporary folder, listed by a stand-in launcher, so nothing depends on what's installed, no app opens
/// and no default app changes. Every row must be on, with the default app first, then the rest.
@MainActor final class OpenWithWindowTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/helm", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var letter: URL { documents.appendingPathComponent("letter.txt") }
    private var notes: URL { documents.appendingPathComponent("notes.txt") }
    private var readme: URL { documents.appendingPathComponent("readme.md") }
    private var project: URL { documents.appendingPathComponent("Project", isDirectory: true) }
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []
    private var apps: [String: URL] = [:]

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        HostEffectRunner.spotlightAnswersForTesting = { _ in AsyncStream { $0.yield([]); $0.finish() } }
    }
    override func tearDown() {
        for controller in controllers {
            if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
            controller.window?.close()
        }
        controllers = []
        keep = []
        HeaderMotion.isDisabledForTesting = false
        HostEffectRunner.spotlightAnswersForTesting = nil
        super.tearDown()
    }

    // MARK: The cause

    /// What greyed out Open With in the build of 8a6657d. AppKit gives a row its submenu's own action when the submenu
    /// is attached; clearing the action afterwards leaves none, and automatic enabling turns a row with no action off,
    /// so its submenu can't be opened. With no action until the submenu is in place, the row stays on.
    func testARowWhoseActionIsClearedAfterItsSubmenuIsGreyedOut() {
        let target = SelectorTarget()
        let menu = NSMenu()
        let cleared = NSMenuItem(title: "Open With", action: #selector(SelectorTarget.run(_:)), keyEquivalent: "")
        cleared.target = target
        cleared.submenu = NSMenu(title: "Open With")
        cleared.action = nil
        let ordered = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        ordered.submenu = NSMenu(title: "Share")
        menu.addItem(cleared); menu.addItem(ordered)
        menu.update()
        XCTAssertFalse(cleared.isEnabled, "AppKit's rule changed: a row with no action is no longer turned off")
        XCTAssertNil(cleared.action)
        XCTAssertTrue(ordered.isEnabled)
        XCTAssertEqual(ordered.action.map(NSStringFromSelector), "submenuAction:")
    }

    // MARK: Right-click › Open With

    /// One file: the default first, marked, then the best fits, then Other Apps, then Choose App… and Change Default
    /// App…. Every row is on, and each app has its Option row, Always Open With.
    func testOneFileListsItsDefaultFirstThenTheRest() async throws {
        let (controller, _) = try await window()
        let submenu = try openWith(in: controller, for: [notes])
        XCTAssertEqual(appRows(submenu), ["Plain (default)", "Code"])
        XCTAssertEqual(otherApps(submenu), ["Viewer"])
        XCTAssertEqual(submenu.items.suffix(2).map(\.title), ["Choose App…", "Change Default App…"])
        assertEveryRowIsOn(submenu)
    }

    /// Several files: the apps that open all of them, and the default they share, first, as Finder lists them.
    func testSeveralFilesOfOneKindShareTheirDefault() async throws {
        let (controller, _) = try await window()
        let submenu = try openWith(in: controller, for: [letter, notes])
        XCTAssertEqual(appRows(submenu), ["Plain (default)", "Code"])
        assertEveryRowIsOn(submenu)
    }

    /// Files of different kinds: only the apps that open every one of them, each as good a fit as it is for the file
    /// it suits least, and no default, since they don't share one.
    func testFilesOfDifferentKindsListOnlyTheAppsThatOpenThemAll() async throws {
        let (controller, _) = try await window()
        let submenu = try openWith(in: controller, for: [notes, readme])
        XCTAssertEqual(appRows(submenu), ["Plain", "Code"], "Marker opens only the Markdown file")
        XCTAssertEqual(otherApps(submenu), ["Viewer"])
        XCTAssertFalse(submenu.items.contains { $0.title.hasSuffix("(default)") })
        assertEveryRowIsOn(submenu)
    }

    /// A folder: the apps that open folders, its default first. Nothing here changes the app for every folder on the
    /// Mac, which Helm's own file viewer switch sets: no Always Open With and no Change Default App….
    func testAFolderListsTheAppsThatOpenFolders() async throws {
        let (controller, _) = try await window()
        let submenu = try openWith(in: controller, for: [project])
        XCTAssertEqual(appRows(submenu), ["Finder (default)", "Code"])
        XCTAssertFalse(submenu.items.contains { $0.title.hasPrefix("Always Open With") })
        XCTAssertFalse(submenu.items.contains { $0.title == "Change Default App…" })
        XCTAssertTrue(submenu.items.contains { $0.title == "Choose App…" })
        assertEveryRowIsOn(submenu, always: false)
    }

    /// An alias to a folder stands for the folder, as it does everywhere in Open With, so it can't change the app for
    /// every folder either: no Always Open With and no Change Default App…, and a default asked for anyway only opens.
    func testAnAliasToAFolderNeverChangesTheAppForEveryFolder() async throws {
        let (controller, _) = try await window()
        let launcher = try XCTUnwrap(controller.dependencies.launcher as? MemoryAppLauncher)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helm-openwith-folder-alias-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Plans", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("Plans alias")
        try URL.writeBookmarkData(try folder.bookmarkData(options: .suitableForBookmarkFile), to: alias)
        let entry = FileEntry(url: alias, kind: .alias, contentTypeIdentifier: "com.apple.alias-file")
        XCTAssertEqual(BrowserWindowController.openWithTarget(of: entry).contentType, "public.folder")
        XCTAssertFalse(BrowserWindowController.canChangeDefaults(for: [entry]))
        let submenu = controller.openWithMenu(for: [entry])
        submenu.update()
        XCTAssertEqual(appRows(submenu), ["Finder (default)", "Code"])
        XCTAssertFalse(submenu.items.contains { $0.title.hasPrefix("Always Open With") }, "\(submenu.items.map(\.title))")
        XCTAssertFalse(submenu.items.contains { $0.title == "Change Default App…" })
        assertEveryRowIsOn(submenu, always: false)
        controller.makeDefault(try app("Code"), for: [entry], thenOpen: true)
        let opened = await until { !launcher.openings.isEmpty }
        XCTAssertTrue(opened, "the folder never opened")
        XCTAssertEqual(launcher.defaultChanges, [], "the app for every folder changed")
    }

    /// Choose App… for a folder has no "Always open … with this app", so the chooser can't make an app the default for
    /// every folder: picking an app, even with Always asked for, only opens the folder with it.
    func testTheChooserForAFolderOnlyOpensIt() async throws {
        let (controller, _) = try await window()
        let launcher = try XCTUnwrap(controller.dependencies.launcher as? MemoryAppLauncher)
        try choose("Choose App…", in: try openWith(in: controller, for: [project]))
        let session = try XCTUnwrap(controller.openWithChooser, "no chooser came up")
        XCTAssertFalse(session.offersAlways, "the chooser offers to always open folders with the app")
        XCTAssertFalse(session.always)
        // As if Always had been on when the app was picked.
        session.finish(.open(try app("Code"), always: true))
        let opened = await until { !launcher.openings.isEmpty }
        XCTAssertTrue(opened, "the folder never opened")
        XCTAssertEqual(launcher.openings.map { $0.urls.map(\.path) }, [[project.path]])
        XCTAssertEqual(launcher.openings.map(\.application), [try app("Code")])
        XCTAssertEqual(launcher.defaultChanges, [], "the app for every folder changed")
        // A file's chooser still offers it.
        try choose("Choose App…", in: try openWith(in: controller, for: [notes]))
        XCTAssertEqual(controller.openWithChooser?.offersAlways, true)
        XCTAssertTrue(controller.answerOpenWithChooserForTesting(nil))
    }

    /// In Recent and in search results the files aren't in the folder on show, and Open With works the same.
    func testRecentAndSearchResultsOfferOpenWith() async throws {
        let (controller, env) = try await window()
        env.recents.recordAccess(to: notes, kind: .regular, at: Date())
        controller.navigate(to: .recent)
        let listed = await until { controller.activeTab?.location == .recent && controller.activeTab?.isLoading == false
            && self.entry(self.notes, in: controller) != nil }
        XCTAssertTrue(listed, "Recent never listed notes.txt")
        XCTAssertEqual(appRows(try openWith(in: controller, for: [notes])), ["Plain (default)", "Code"])
        controller.navigate(to: .directory(documents))
        _ = await until { controller.activeTab?.location == .directory(self.documents) && controller.activeTab?.isLoading == false }
        controller.search("notes")
        let found = await until { controller.activeTab?.search?.isGathering == false && self.entry(self.notes, in: controller) != nil }
        XCTAssertTrue(found, "the search never found notes.txt")
        let submenu = try openWith(in: controller, for: [notes])
        XCTAssertEqual(appRows(submenu), ["Plain (default)", "Code"])
        assertEveryRowIsOn(submenu)
    }

    // MARK: Choosing

    /// Choosing an app hands it every selected file, records each in Recent, and remembers the app for that kind of
    /// file. It changes no default.
    func testChoosingAnAppHandsItEveryFile() async throws {
        let (controller, env) = try await window()
        let launcher = try XCTUnwrap(controller.dependencies.launcher as? MemoryAppLauncher)
        let submenu = try openWith(in: controller, for: [letter, notes])
        try choose("Code", in: submenu)
        let handed = await until { !launcher.openings.isEmpty }
        XCTAssertTrue(handed)
        XCTAssertEqual(launcher.openings, [MemoryAppLauncher.Opening(urls: [letter, notes], application: try app("Code"))])
        XCTAssertEqual(launcher.defaultChanges, [])
        let recent = Set(env.recents.records.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        XCTAssertTrue(recent.isSuperset(of: ["letter.txt", "notes.txt"]), "Recent has \(recent.sorted())")
        XCTAssertEqual(env.openWith.records.map(\.application), [try app("Code").path])
        // Code is now under Recently Used for plain text, just after the default; it was under Recommended.
        let headings = { (menu: NSMenu) in menu.items.filter { !$0.isSeparatorItem && !$0.isAlternate }.map(\.title).prefix(3) }
        XCTAssertEqual(Array(headings(submenu)), ["Plain (default)", "Recommended", "Code"])
        XCTAssertEqual(Array(headings(try openWith(in: controller, for: [notes]))), ["Plain (default)", "Recently Used", "Code"])
    }

    /// Always Open With, the Option row, makes the app the default for that kind of file, then opens the file with it.
    /// It's the default from then on.
    func testAlwaysOpenWithMakesTheAppTheDefaultThenOpens() async throws {
        let (controller, _) = try await window()
        let launcher = try XCTUnwrap(controller.dependencies.launcher as? MemoryAppLauncher)
        let submenu = try openWith(in: controller, for: [notes])
        let always = try XCTUnwrap(submenu.items.first { $0.title == "Always Open With Code" })
        XCTAssertTrue(always.isAlternate)
        XCTAssertEqual(always.keyEquivalentModifierMask, .option)
        submenu.performActionForItem(at: submenu.index(of: always))
        let opened = await until { !launcher.openings.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(launcher.defaultChanges, [MemoryAppLauncher.DefaultChange(application: try app("Code"), type: "public.plain-text")])
        XCTAssertEqual(launcher.openings, [MemoryAppLauncher.Opening(urls: [notes], application: try app("Code"))])
        XCTAssertEqual(appRows(try openWith(in: controller, for: [notes])).first, "Code (default)")
    }

    /// Choose App… brings up the chooser for the same files, listing the same apps with the default first; picking one
    /// opens the files with it. Change Default App… starts with Always on, and makes it the default first.
    func testChooseAppAndChangeDefaultAppBringUpTheChooser() async throws {
        let (controller, _) = try await window()
        let launcher = try XCTUnwrap(controller.dependencies.launcher as? MemoryAppLauncher)
        try choose("Choose App…", in: try openWith(in: controller, for: [notes]))
        let chooser = try XCTUnwrap(controller.openWithChooserForTesting, "no chooser came up")
        XCTAssertEqual(chooser.title, "Open “notes.txt” with")
        XCTAssertEqual(chooser.apps, ["Plain", "Code", "Viewer"])
        XCTAssertFalse(chooser.always)
        XCTAssertTrue(controller.answerOpenWithChooserForTesting("Viewer"))
        let opened = await until { launcher.openings.count == 1 }
        XCTAssertTrue(opened)
        XCTAssertNil(controller.openWithChooserForTesting, "the chooser stayed up")
        XCTAssertEqual(launcher.openings.last, MemoryAppLauncher.Opening(urls: [notes], application: try app("Viewer")))
        XCTAssertEqual(launcher.defaultChanges, [])

        try choose("Change Default App…", in: try openWith(in: controller, for: [letter, notes]))
        let change = try XCTUnwrap(controller.openWithChooserForTesting)
        XCTAssertEqual(change.title, "Open 2 items with")
        XCTAssertTrue(change.always)
        XCTAssertTrue(controller.answerOpenWithChooserForTesting("Code"))
        let changed = await until { launcher.openings.count == 2 }
        XCTAssertTrue(changed)
        XCTAssertEqual(launcher.defaultChanges, [MemoryAppLauncher.DefaultChange(application: try app("Code"), type: "public.plain-text")])
        XCTAssertEqual(launcher.openings.last, MemoryAppLauncher.Opening(urls: [letter, notes], application: try app("Code")))
        // Cancel closes it and hands nothing over.
        try choose("Choose App…", in: try openWith(in: controller, for: [readme]))
        XCTAssertTrue(controller.answerOpenWithChooserForTesting(nil))
        await settle()
        XCTAssertNil(controller.openWithChooserForTesting)
        XCTAssertEqual(launcher.openings.count, 2)
    }

    /// Always Open With on files of two kinds makes the app the default for both kinds.
    func testAlwaysOpenWithOnTwoKindsChangesBoth() async throws {
        let (controller, _) = try await window()
        let launcher = try XCTUnwrap(controller.dependencies.launcher as? MemoryAppLauncher)
        let submenu = try openWith(in: controller, for: [notes, readme])
        try choose("Always Open With Plain", in: submenu)
        let opened = await until { !launcher.openings.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(Set(launcher.defaultChanges.map(\.type)), ["public.plain-text", "net.daringfireball.markdown"])
        XCTAssertEqual(launcher.openings, [MemoryAppLauncher.Opening(urls: [notes, readme], application: try app("Plain"))])
    }

    /// An app that's gone says so in the window, and nothing else changes.
    func testAFailedOpenSaysSo() async throws {
        let (controller, _) = try await window()
        let launcher = try XCTUnwrap(controller.dependencies.launcher as? MemoryAppLauncher)
        launcher.failure = CocoaError(.fileNoSuchFile)
        var messages: [String] = []
        controller.messageObserver = { messages.append($0) }
        try choose("Code", in: try openWith(in: controller, for: [letter, notes]))
        let said = await until { !messages.isEmpty }
        XCTAssertTrue(said)
        XCTAssertTrue(messages.first?.hasPrefix("Couldn’t open the files:") ?? false, "\(messages)")
    }

    // MARK: The list itself

    /// Each app is listed once however many copies are installed (the default's copy wins), apps used before for any
    /// of the kinds come first, newest first, and an app is ranked by the file it suits least.
    func testTheListHasEachAppOnceAndRanksItByTheFileItSuitsLeast() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helm-openwith-list-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let plain = try makeApp("Plain", in: root, claims: [["LSItemContentTypes": ["public.plain-text"], "CFBundleTypeRole": "Editor", "LSHandlerRank": "Owner"]])
        let copy = try makeApp("Plain", in: root.appendingPathComponent("Copies", isDirectory: true),
                               claims: [["LSItemContentTypes": ["public.plain-text"], "CFBundleTypeRole": "Editor", "LSHandlerRank": "Owner"]])
        let code = try makeApp("Code", in: root, claims: [["LSItemContentTypes": ["public.text"], "CFBundleTypeRole": "Editor", "LSHandlerRank": "Alternate"]])
        let viewer = try makeApp("Viewer", in: root, claims: [["LSItemContentTypes": ["public.data"], "CFBundleTypeRole": "Viewer"]])
        let marker = try makeApp("Marker", in: root, claims: [["LSItemContentTypes": ["net.daringfireball.markdown"], "CFBundleTypeRole": "Editor", "LSHandlerRank": "Owner"]])
        let launcher = MemoryAppLauncher { url in
            url.pathExtension == "txt" ? ([plain, code, viewer, copy], copy) : ([marker, viewer, plain, code], marker)
        }
        let txt = OpenWithTarget(url: notes, contentType: "public.plain-text")
        let md = OpenWithTarget(url: readme, contentType: "net.daringfireball.markdown")

        let one = ApplicationCatalog.choices(for: [txt], recent: [], launcher: launcher)
        XCTAssertEqual(one.standard?.url, copy, "the default's own copy")
        XCTAssertEqual(one.ordered.map(\.name), ["Plain", "Code", "Viewer"], "Plain once")

        let now = Date()
        let recent = [OpenWithRecord(contentType: "net.daringfireball.markdown", application: viewer.path, lastUsed: now),
                      OpenWithRecord(contentType: "public.plain-text", application: code.path, lastUsed: now.addingTimeInterval(-60))]
        let both = ApplicationCatalog.choices(for: [txt, md], recent: recent, launcher: launcher)
        XCTAssertNil(both.standard, "the two files have different defaults")
        XCTAssertEqual(both.recent.map(\.name), ["Viewer", "Code"], "used before, newest first")
        XCTAssertEqual(both.recommended.map(\.name), ["Plain"])
        XCTAssertEqual(both.recommended.first?.fit, 2, "an owner of plain text only belongs to Markdown's family")
        XCTAssertFalse(both.ordered.contains { $0.name == "Marker" }, "Marker opens only the Markdown file")
    }

    /// A right-click on thousands of selected files opens at once: macOS is asked about each kind of file once, not
    /// about every file, and the list is the one a single file of that kind gets.
    func testManyFilesAreAskedAboutOncePerKind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helm-openwith-many-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let plain = try makeApp("Plain", in: root, claims: [["LSItemContentTypes": ["public.plain-text"], "CFBundleTypeRole": "Editor", "LSHandlerRank": "Owner"]])
        let code = try makeApp("Code", in: root, claims: [["LSItemContentTypes": ["public.text"], "CFBundleTypeRole": "Editor", "LSHandlerRank": "Alternate"]])
        let marker = try makeApp("Marker", in: root, claims: [["LSItemContentTypes": ["net.daringfireball.markdown"], "CFBundleTypeRole": "Editor", "LSHandlerRank": "Owner"]])
        var asked: [String: Int] = [:]
        let launcher = MemoryAppLauncher { url in
            asked[url.pathExtension, default: 0] += 1
            return url.pathExtension == "txt" ? ([plain, code], plain) : ([marker, code, plain], marker)
        }
        let texts = (0..<3000).map { OpenWithTarget(url: documents.appendingPathComponent("note-\($0).txt"), contentType: "public.plain-text") }
        let pages = (0..<500).map { OpenWithTarget(url: documents.appendingPathComponent("page-\($0).md"), contentType: "net.daringfireball.markdown") }

        let one = ApplicationCatalog.choices(for: [texts[0]], recent: [], launcher: launcher)
        asked = [:]
        let many = ApplicationCatalog.choices(for: texts, recent: [], launcher: launcher)
        XCTAssertEqual(many, one, "3,000 plain text files get the apps one of them gets")
        XCTAssertEqual(many.standard?.name, "Plain")
        XCTAssertEqual(asked, ["txt": 2], "once for the apps and once for the default")

        asked = [:]
        let mixed = ApplicationCatalog.choices(for: texts + pages, recent: [], launcher: launcher)
        XCTAssertEqual(asked, ["txt": 2, "md": 2])
        XCTAssertNil(mixed.standard, "plain text and Markdown have different defaults")
        XCTAssertEqual(mixed.ordered.map(\.name), ["Plain", "Code"], "Marker opens only the Markdown files")
    }

    /// An alias or a link lists the apps for the item it points to, as in Finder, not the few that open links
    /// themselves. The app gets the original, and Always Open With sets the default for the original's kind, never
    /// for every alias or link on the Mac.
    func testAnAliasOrALinkStandsForItsOriginal() async throws {
        let (controller, _) = try await window()
        let launcher = try XCTUnwrap(controller.dependencies.launcher as? MemoryAppLauncher)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helm-openwith-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("draft.txt")
        try Data("d".utf8).write(to: original)
        let link = root.appendingPathComponent("draft link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let alias = root.appendingPathComponent("draft alias")
        try URL.writeBookmarkData(try original.bookmarkData(options: .suitableForBookmarkFile), to: alias)
        // As the disk describes them: a link's and an alias's own kinds.
        let entries = [FileEntry(url: link, kind: .symlinkToFile, contentTypeIdentifier: "public.symlink"),
                       FileEntry(url: alias, kind: .alias, contentTypeIdentifier: "com.apple.alias-file")]
        // The folder's path as the disk has it, and the item's own name, so a link never passes for its original.
        let path = { (url: URL) in url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path }
        for entry in entries {
            let target = BrowserWindowController.openWithTarget(of: entry)
            XCTAssertEqual(path(target.url), path(original), entry.name)
            XCTAssertEqual(target.contentType, "public.plain-text", entry.name)
            XCTAssertNotEqual(target.kindText, "Alias", entry.name)
            // Asked about the link itself, the stand-in would answer with the apps for a name with no extension.
            XCTAssertEqual(controller.openWithAppsForTesting([entry]).apps.map(\.name), ["Plain", "Code", "Viewer"], entry.name)
        }
        controller.makeDefault(try app("Code"), for: entries, thenOpen: true)
        let opened = await until { !launcher.openings.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(launcher.defaultChanges.map(\.type), ["public.plain-text"], "the original's kind, not every alias's or link's")
        XCTAssertEqual(launcher.openings.first?.urls.map(path), [path(original), path(original)], "the originals, not the links")
    }

    /// Opening files no app claims asks which app to use for all of them, not only the first.
    func testOpeningFilesNoAppClaimsAsksAboutAllOfThem() async throws {
        let (controller, _) = try await window(extra: ["first.xyz", "second.xyz"])
        let launcher = try XCTUnwrap(controller.dependencies.launcher as? MemoryAppLauncher)
        select(controller, ["first.xyz", "second.xyz"].map(documents.appendingPathComponent))
        controller.perform(.open)
        let asked = await until { controller.openWithChooserForTesting != nil }
        XCTAssertTrue(asked, "no chooser came up")
        XCTAssertEqual(controller.openWithChooserForTesting?.title, "Open 2 items with")
        XCTAssertTrue(launcher.openings.isEmpty)
        XCTAssertTrue(controller.answerOpenWithChooserForTesting(nil))
    }

    /// File › Expand Archive hands the archive to Archive Utility through the same launcher, in the background as in
    /// Finder, so a fixture run or a test never starts the real one.
    func testExpandArchiveGoesThroughTheLauncher() async throws {
        let (controller, _) = try await window(extra: ["photos.zip"])
        let launcher = try XCTUnwrap(controller.dependencies.launcher as? MemoryAppLauncher)
        let archive = documents.appendingPathComponent("photos.zip")
        select(controller, [archive])
        controller.perform(.decompress)
        let handed = await until { !launcher.openings.isEmpty }
        XCTAssertTrue(handed)
        XCTAssertEqual(launcher.openings, [MemoryAppLauncher.Opening(urls: [archive], application: BrowserWindowController.archiveUtility, activates: false)])
    }

    // MARK: File › Open With

    /// The menu bar's row is on, its submenu is filled from the selection as it opens, one file or several, and with
    /// nothing selected it says so.
    func testFileOpenWithInTheMenuBar() async throws {
        let (controller, _) = try await window()
        let options = try XCTUnwrap(LaunchOptions.parse(["Helm", "--home", "/tmp/helm-open-with-tests"]))
        let app = AppController(options: options)
        let row = try XCTUnwrap(MenuModel.menuBar.first { $0.title == "File" }?.sections.flatMap { $0 }.first { $0.command == .openWith })
        let item = MainMenuBuilder.item(for: row, target: app)
        let file = NSMenu(title: "File")
        file.addItem(item)
        file.update()
        XCTAssertTrue(item.isEnabled, "File › Open With is greyed out, so its submenu can't be opened")
        let submenu = try XCTUnwrap(item.submenu)
        XCTAssertTrue(submenu.delegate === app, "nothing fills it as it opens")

        select(controller, [letter, notes])
        XCTAssertEqual(controller.title(of: .openWith).1, true, "Open With is on for several files")
        controller.fillOpenWithItems(in: submenu) // What the app does for the front window as it opens.
        submenu.update()
        XCTAssertEqual(appRows(submenu), ["Plain (default)", "Code"])
        assertEveryRowIsOn(submenu)

        select(controller, [])
        controller.fillOpenWithItems(in: submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["Select a File"])
    }

    // MARK: Opening by double-click

    /// Double-click goes through the same launcher: each file to its own default app, nothing to a real app here.
    func testOpeningFilesHandsEachToItsDefaultApp() async throws {
        let (controller, _) = try await window()
        let launcher = try XCTUnwrap(controller.dependencies.launcher as? MemoryAppLauncher)
        select(controller, [notes, readme])
        controller.perform(.open)
        let opened = await until { launcher.openings.count == 2 }
        XCTAssertTrue(opened)
        let byApp = Dictionary(uniqueKeysWithValues: launcher.openings.map { ($0.application.lastPathComponent, $0.urls) })
        XCTAssertEqual(byApp, ["Plain.app": [notes], "Marker.app": [readme]])
    }

    // MARK: Helpers

    /// Right-click › Open With on these items, as AppKit shows it: the row on, with its submenu brought up to date.
    private func openWith(in controller: BrowserWindowController, for urls: [URL]) throws -> NSMenu {
        let entries = try urls.map { try XCTUnwrap(entry($0, in: controller), "\($0.lastPathComponent) isn't listed") }
        select(controller, urls)
        let menu = try XCTUnwrap(controller.contextMenu(for: entries))
        menu.update()
        let item = try XCTUnwrap(menu.items.first { $0.title == "Open With" }, "no Open With in \(menu.items.map(\.title))")
        XCTAssertTrue(item.isEnabled, "Open With is greyed out")
        let submenu = try XCTUnwrap(item.submenu)
        submenu.update()
        return submenu
    }
    /// The app rows, in order, leaving out the Option rows, headings and the commands at the end.
    private func appRows(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem && !$0.isSectionHeader && !$0.isAlternate }
            .map(\.title).filter { !["Other Apps", "Choose App…", "Change Default App…"].contains($0) }
    }
    private func otherApps(_ menu: NSMenu) -> [String] {
        guard let submenu = menu.items.first(where: { $0.title == "Other Apps" })?.submenu else { return [] }
        submenu.update()
        return appRows(submenu)
    }
    /// Every row a person can choose is on, Other Apps' too, and each app is followed by its Always Open With row.
    /// Every row is on. With `always`, each app is followed by its Option row, Always Open With; folders have none.
    private func assertEveryRowIsOn(_ menu: NSMenu, always: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        let items = menu.items
        for (index, item) in items.enumerated() where !item.isSeparatorItem && !item.isSectionHeader {
            XCTAssertTrue(item.isEnabled, "“\(item.title)” is off", file: file, line: line)
            if let submenu = item.submenu { submenu.update(); assertEveryRowIsOn(submenu, always: always, file: file, line: line) }
            guard always, !item.isAlternate, item.submenu == nil, !["Choose App…", "Change Default App…"].contains(item.title) else { continue }
            let name = item.title.replacingOccurrences(of: " (default)", with: "")
            let next = index + 1 < items.count ? items[index + 1] : nil
            XCTAssertEqual(next?.title, "Always Open With \(name)", file: file, line: line)
            XCTAssertEqual(next?.isAlternate, true, file: file, line: line)
        }
    }
    private func choose(_ title: String, in menu: NSMenu) throws {
        if let index = menu.items.firstIndex(where: { $0.title == title }) { menu.performActionForItem(at: index); return }
        let other = try XCTUnwrap(menu.items.first { $0.title == "Other Apps" }?.submenu, "no “\(title)”")
        let index = try XCTUnwrap(other.items.firstIndex { $0.title == title }, "no “\(title)”")
        other.performActionForItem(at: index)
    }
    private func select(_ controller: BrowserWindowController, _ urls: [URL]) {
        controller.store.send(.tab(controller.activeTabID, .setSelection(Set(urls.map { ItemID(url: $0) }), source: .user)))
    }
    private func entry(_ url: URL, in controller: BrowserWindowController) -> FileEntry? {
        controller.activeTab?.snapshot.sortedEntries.first { $0.id == ItemID(url: url) }
    }
    private func app(_ name: String) throws -> URL { try XCTUnwrap(apps[name], "no app \(name)") }

    /// A made-up app with these claims, in a temporary folder.
    private func makeApp(_ name: String, in root: URL, claims: [[String: Any]]) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.helm.openwith.\(name)", "CFBundleName": name,
                                   "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "CFBundleDocumentTypes": claims]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        apps[name] = app
        return app
    }

    /// A window that's never shown, in Documents (letter.txt, notes.txt, readme.md, Project), with a stand-in launcher
    /// that lists made-up apps: Plain owns plain text, Marker owns Markdown, Code edits any text and opens folders,
    /// Viewer opens any file, and Finder opens folders.
    private func window(extra: [String] = []) async throws -> (BrowserWindowController, AppEnvironment) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helm-openwith-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let plain = try makeApp("Plain", in: root, claims: [["LSItemContentTypes": ["public.plain-text"], "CFBundleTypeRole": "Editor", "LSHandlerRank": "Owner"]])
        let marker = try makeApp("Marker", in: root, claims: [["LSItemContentTypes": ["net.daringfireball.markdown"], "CFBundleTypeRole": "Editor", "LSHandlerRank": "Owner"]])
        let code = try makeApp("Code", in: root, claims: [["LSItemContentTypes": ["public.text"], "CFBundleTypeRole": "Editor", "LSHandlerRank": "Alternate"],
                                                          ["LSItemContentTypes": ["public.folder"], "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate"]])
        let viewer = try makeApp("Viewer", in: root, claims: [["LSItemContentTypes": ["public.data"], "CFBundleTypeRole": "Viewer"]])
        let finder = try makeApp("Finder", in: root, claims: [["LSItemContentTypes": ["public.folder"], "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Owner"]])
        let launcher = MemoryAppLauncher { url in
            switch url.pathExtension {
            case "txt": return ([viewer, code, plain], plain)
            case "md": return ([code, marker, viewer, plain], marker)
            case "": return ([code, finder], finder)
            default: return ([], nil)
            }
        }
        let env = try await AppEnvironment.test(home: home)
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        try await memory.createDirectory(at: documents)
        try await memory.createDirectory(at: project)
        for (url, text) in [(letter, "l"), (notes, "n"), (readme, "# r")] + extra.map({ (documents.appendingPathComponent($0), "x") }) {
            try await memory.createFileExclusively(at: url, contents: Data(text.utf8))
        }
        let operations = OperationCoordinator(fileSystem: env.fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: env.directories.home) { false }
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: env.fileSystem,
            operations: operations, home: env.directories.home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.open-with.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith, launcher: launcher)
        let host = OpenWithQuietHost()
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "open-with", seeds: [], activeIndex: 0)
        keep += [host, operations, volumes]
        controllers.append(controller)
        controller.confirmsForTesting = true
        controller.messageObserver = { _ in }
        controller.navigate(to: .directory(documents))
        let arrived = await until { controller.activeTab?.location == .directory(self.documents) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "Documents never opened")
        return (controller, env)
    }

    /// Waits for a condition, as long as a busy machine needs, and no longer than it takes.
    private func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
    private func settle(_ seconds: Double = 0.2) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
}

/// The target of a row with a real action, as the window is for its commands.
private final class SelectorTarget: NSObject {
    @objc func run(_ sender: Any?) {}
}

@MainActor private final class OpenWithQuietHost: BrowserWindowHost {
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
}
#endif
