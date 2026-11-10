#if os(macOS)
import AppKit
import SwiftUI
import HelmCore
import HelmPersistence
import UniformTypeIdentifiers

/// One app that can open a file, and how well it fits.
struct AppChoice: Identifiable, Equatable {
    let url: URL
    let name: String
    let version: String?
    /// 3 claims this exact kind, 2 a family it belongs to (plain text for code), 1 any file, 0 unknown.
    let fit: Int
    /// From the app's own declaration: Owner 3, Default 2, Alternate 1.
    let rank: Int
    let edits: Bool
    var lastUsed: Date?
    var id: String { url.path }
    var score: Int { fit * 100 + rank * 10 + (edits ? 2 : 1) }
    /// The same app judged for several files at once: as good a fit as it is for the one it suits least.
    func weakest(with other: AppChoice) -> AppChoice {
        AppChoice(url: url, name: name, version: version, fit: min(fit, other.fit), rank: min(rank, other.rank),
                  edits: edits && other.edits)
    }
    var detail: String {
        if let lastUsed { return "Used \(RelativeDateTimeFormatter().localizedString(for: lastUsed, relativeTo: Date()))" }
        if fit <= 1 { return "Opens any file, so it may not show this one well" }
        return edits ? "Can view and edit" : "Can view"
    }
}

/// The apps for one file, in the order you're most likely to want them.
struct OpenWithChoices: Equatable {
    var standard: AppChoice?
    var recent: [AppChoice] = []
    var recommended: [AppChoice] = []
    var other: [AppChoice] = []
    var isEmpty: Bool { standard == nil && recent.isEmpty && recommended.isEmpty && other.isEmpty }
    /// Every app, in the order the chooser lists them: the default, then recently used, recommended and other apps.
    var ordered: [AppChoice] { (standard.map { [$0] } ?? []) + recent + recommended + other }
}

/// One item to open: where it is and what kind of file it is. For an alias or a link, that's its original's.
struct OpenWithTarget {
    let url: URL
    let contentType: String?
    /// Finder's Kind words for it, such as "Plain Text Document".
    var kindText = ""
}

/// Ranks apps from what each one declares in its Info.plist, the same declarations Launch Services uses.
/// The answers are kept per app, so a menu opens without rereading every bundle.
@MainActor enum ApplicationCatalog {
    private struct Claim { let types: [String]; let extensions: [String]; let rank: Int; let edits: Bool }
    private static var claims: [String: [Claim]] = [:]
    private static let generic: Set<String> = ["public.item", "public.data", "public.content", "public.composite-content", "public.archive"]

    /// The apps that open every one of the items, and the default they share, if they share one, as Finder lists them
    /// for a selection of several files.
    /// Files of one kind get the same answers, so each kind is asked about once, however many files are selected: a
    /// right-click on thousands of them opens its menu at once. One file alone is asked about itself.
    static func choices(for targets: [OpenWithTarget], recent: [OpenWithRecord], launcher: any AppLaunching) -> OpenWithChoices {
        var shared: [String: AppChoice]?
        var standard: String?
        var asked: Set<String> = []
        for target in targets where asked.insert(kind(of: target)).inserted {
            let found = candidates(for: target, launcher: launcher)
            guard let sofar = shared else {
                shared = found.apps; standard = found.standard
                continue
            }
            var kept: [String: AppChoice] = [:]
            for (identity, choice) in sofar {
                if let other = found.apps[identity] { kept[identity] = choice.weakest(with: other) }
            }
            shared = kept
            if standard != found.standard { standard = nil }
            // No app opens them all, so the other kinds can't add one.
            if kept.isEmpty { break }
        }
        var common = shared ?? [:]
        var result = OpenWithChoices()
        if let standard, let choice = common.removeValue(forKey: standard) { result.standard = choice }
        var all = Array(common.values)
        // Recently used first, newest first: apps you picked yourself for these kinds of file.
        for record in recent where FileManager.default.fileExists(atPath: record.application) {
            let identity = identity(of: URL(fileURLWithPath: record.application))
            if let standard, identity == standard {
                if result.standard?.lastUsed == nil { result.standard?.lastUsed = record.lastUsed }
                continue
            }
            if let index = all.firstIndex(where: { Self.identity(of: $0.url) == identity }) {
                var choice = all.remove(at: index); choice.lastUsed = record.lastUsed
                result.recent.append(choice)
            }
            if result.recent.count == 4 { break }
        }
        all.sort { $0.score != $1.score ? $0.score > $1.score : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        result.recommended = all.filter { $0.fit >= 2 }
        result.other = all.filter { $0.fit < 2 }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    /// Each app that can open the item, once, by its bundle identifier, and its default's identifier. With several
    /// copies of an app installed, the default's copy is kept, else the one in Applications.
    private static func candidates(for target: OpenWithTarget, launcher: any AppLaunching) -> (apps: [String: AppChoice], standard: String?) {
        let type = target.contentType.flatMap(UTType.init) ?? UTType(filenameExtension: target.url.pathExtension)
        let standardURL = launcher.defaultApplication(toOpen: target.url)
        var apps: [String: AppChoice] = [:]
        for app in launcher.applications(toOpen: target.url) + (standardURL.map { [$0] } ?? []) {
            let identity = identity(of: app)
            if let existing = apps[identity], !prefers(app, over: existing.url, standard: standardURL) { continue }
            apps[identity] = describe(app, type: type, pathExtension: target.url.pathExtension.lowercased())
        }
        return (apps, standardURL.map(identity(of:)))
    }

    /// One app, however many copies are installed.
    static func identity(of app: URL) -> String { Bundle(url: app)?.bundleIdentifier ?? app.standardizedFileURL.path }

    /// What decides which apps open an item: its kind and its extension.
    private static func kind(of target: OpenWithTarget) -> String {
        "\(target.contentType ?? "")|\(target.url.pathExtension.lowercased())"
    }

    private static func prefers(_ candidate: URL, over current: URL, standard: URL?) -> Bool {
        if let standard, candidate.standardizedFileURL == standard.standardizedFileURL { return true }
        if let standard, current.standardizedFileURL == standard.standardizedFileURL { return false }
        func inApplications(_ url: URL) -> Bool { url.path.hasPrefix("/Applications/") || url.path.hasPrefix("/System/Applications/") }
        if inApplications(candidate) != inApplications(current) { return inApplications(candidate) }
        return candidate.path.count < current.path.count
    }

    static func describe(_ app: URL, type: UTType?, pathExtension: String) -> AppChoice {
        let bundle = Bundle(url: app)
        var fit = 0, rank = 0, edits = false
        for claim in claimsOf(app, bundle: bundle) {
            var claimFit = 0
            for declared in claim.types {
                if declared == type?.identifier { claimFit = max(claimFit, 3) }
                else if let declaredType = UTType(declared), type?.conforms(to: declaredType) == true {
                    claimFit = max(claimFit, generic.contains(declared) ? 1 : 2)
                }
            }
            for ext in claim.extensions {
                if !pathExtension.isEmpty, ext == pathExtension { claimFit = max(claimFit, 3) }
                else if ext == "*" { claimFit = max(claimFit, 1) }
            }
            if claimFit > fit || (claimFit == fit && claimFit > 0 && claim.rank > rank) {
                fit = claimFit; rank = claim.rank; edits = claim.edits
            }
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return AppChoice(url: app, name: name, version: version, fit: fit, rank: rank, edits: edits)
    }

    private static func claimsOf(_ app: URL, bundle: Bundle?) -> [Claim] {
        if let known = claims[app.path] { return known }
        let documents = bundle?.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        let ranks = ["Owner": 3, "Default": 2, "Alternate": 1, "None": 0]
        let parsed = documents.compactMap { document -> Claim? in
            let rank = ranks[document["LSHandlerRank"] as? String ?? "Default"] ?? 2
            let role = document["CFBundleTypeRole"] as? String ?? "Viewer"
            guard rank > 0, role != "None" else { return nil }
            return Claim(types: document["LSItemContentTypes"] as? [String] ?? [],
                         extensions: (document["CFBundleTypeExtensions"] as? [String] ?? []).map { $0.lowercased() },
                         rank: rank, edits: role == "Editor")
        }
        claims[app.path] = parsed
        return parsed
    }
}

extension BrowserWindowController {
    // MARK: Menu

    func openWithMenu(for entries: [FileEntry]) -> NSMenu {
        let menu = NSMenu(title: "Open With")
        fillOpenWithItems(in: menu, entries: entries)
        return menu
    }

    /// The default first, then what you've used for this kind of file, then the best fits, then everything else.
    /// For several items, only the apps that open all of them, and a default only if they share one, as in Finder.
    /// Hold Option to make the app you pick the default for this kind of file, as in Finder.
    public func fillOpenWithItems(in menu: NSMenu) { fillOpenWithItems(in: menu, entries: selectedEntries()) }

    func fillOpenWithItems(in menu: NSMenu, entries: [FileEntry]) {
        menu.removeAllItems()
        guard !entries.isEmpty else {
            let none = NSMenuItem(title: "Select a File", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none); return
        }
        let choices = openWithChoices(for: entries)
        // Asked once for the whole menu, since an alias is read to find what it stands for.
        let always = Self.canChangeDefaults(for: entries)
        if let standard = choices.standard { addApp(standard, to: menu, entries: entries, always: always, suffix: " (default)") }
        if !choices.recent.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: "Recently Used"))
            for app in choices.recent { addApp(app, to: menu, entries: entries, always: always) }
        }
        let shown = choices.recommended.prefix(12)
        if !shown.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: "Recommended"))
            for app in shown { addApp(app, to: menu, entries: entries, always: always) }
        }
        let rest = Array(choices.recommended.dropFirst(12)) + choices.other
        if !rest.isEmpty {
            let submenu = NSMenu(title: "Other Apps")
            for app in rest.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                addApp(app, to: submenu, entries: entries, always: always)
            }
            // No action until the submenu is in place, so AppKit gives it the submenu's own and keeps it enabled.
            let item = NSMenuItem(title: "Other Apps", action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(action("Choose App…") { [weak self] in self?.showOpenWithChooser(for: entries, makeDefault: false) })
        // A folder's default app is the one for every folder on the Mac, the setting Helm's own file viewer switch
        // uses, so it's never changed from here. Finder offers neither for folders.
        if always {
            menu.addItem(action("Change Default App…") { [weak self] in self?.showOpenWithChooser(for: entries, makeDefault: true) })
        }
    }
    /// Whether Open With may change which app opens these kinds of item: not for a folder, a link to one, or an alias
    /// to one, since an alias stands for its original here and its original's kind is what would change.
    public static func canChangeDefaults(for entries: [FileEntry]) -> Bool {
        !entries.contains { entry in
            if entry.kind == .directory || entry.kind == .symlinkToDirectory { return true }
            guard entry.kind == .alias, let type = openWithTarget(of: entry).contentType.flatMap(UTType.init) else { return false }
            return type.conforms(to: .folder)
        }
    }

    /// `always` adds the Option row, Always Open With, which also makes the app the default for this kind of file.
    private func addApp(_ app: AppChoice, to menu: NSMenu, entries: [FileEntry], always: Bool, suffix: String = "") {
        let item = action(app.name + suffix) { [weak self] in self?.hand(entries, to: app.url) }
        item.image = Self.menuIcon(app.url)
        item.toolTip = app.version.map { "\(app.name) \($0). \(app.detail)" } ?? app.detail
        menu.addItem(item)
        guard always else { return }
        let alternate = action("Always Open With \(app.name)") { [weak self] in self?.makeDefault(app.url, for: entries, thenOpen: true) }
        alternate.image = item.image
        alternate.isAlternate = true
        alternate.keyEquivalentModifierMask = .option
        menu.addItem(alternate)
    }
    private func action(_ title: String, _ body: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureMenuTarget(body)
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
        item.target = target; item.representedObject = target
        return item
    }
    private static func menuIcon(_ app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    /// For the smoke run: whether a file's Open With list has a default, and each app once.
    public func openWithSummaryForTesting(_ entry: FileEntry) -> (defaultName: String?, apps: Int, distinct: Int, recommended: Int) {
        let choices = openWithChoices(for: [entry])
        let ids = choices.ordered.map(\.id)
        return (choices.standard?.name, ids.count, Set(ids).count, choices.recommended.count)
    }
    /// For tests and scripted runs: the apps Open With offers for these items, in order, the default first, and the
    /// default's name if they share one.
    public func openWithAppsForTesting(_ entries: [FileEntry]) -> (apps: [(name: String, url: URL)], defaultName: String?) {
        let choices = openWithChoices(for: entries)
        return (choices.ordered.map { ($0.name, $0.url) }, choices.standard?.name)
    }

    func openWithChoices(for entries: [FileEntry]) -> OpenWithChoices {
        let targets = entries.map(Self.openWithTarget(of:))
        let kinds = Set(targets.compactMap(\.contentType))
        let recent = dependencies.openWith.records.filter { kinds.contains($0.contentType) }.sorted { $0.lastUsed > $1.lastUsed }
        return ApplicationCatalog.choices(for: targets, recent: recent, launcher: dependencies.launcher)
    }
    /// What the disk says the item is, else what its extension says. A folder the disk said nothing about is a folder.
    static func contentType(of entry: FileEntry) -> UTType? {
        entry.contentTypeIdentifier.flatMap(UTType.init) ?? UTType(filenameExtension: entry.url.pathExtension)
            ?? (entry.kind == .directory ? .folder : nil)
    }
    /// What Open With lists apps for, hands to the app and sets a default for: the item, or the original an alias or
    /// link points to, as in Finder. macOS lists the apps for a link's own kind, which is only Terminal.
    static func openWithTarget(of entry: FileEntry) -> OpenWithTarget {
        let original: URL?
        switch entry.kind {
        // Never a sign-in prompt or a server mounting just to fill a menu.
        case .alias: original = try? URL(resolvingAliasFileAt: entry.url, options: [.withoutUI, .withoutMounting])
        case .symlinkToFile, .symlinkToDirectory: original = CanonicalPath.resolve(entry.url)
        default: original = nil
        }
        guard let original, original.standardizedFileURL != entry.url.standardizedFileURL,
              let values = try? original.resourceValues(forKeys: [.contentTypeKey, .localizedTypeDescriptionKey]) else {
            return OpenWithTarget(url: entry.url, contentType: contentType(of: entry)?.identifier, kindText: entry.kindText)
        }
        let type = values.contentType ?? UTType(filenameExtension: original.pathExtension)
        return OpenWithTarget(url: original, contentType: type?.identifier,
                              kindText: values.localizedTypeDescription ?? type?.localizedDescription ?? entry.kindText)
    }

    // MARK: Opening

    /// Hands the items to the app, an alias's or link's original in its place, as Finder's Open With does.
    private func hand(_ entries: [FileEntry], to application: URL) {
        open(entries.map { Self.openWithTarget(of: $0).url }, with: application, entries: entries)
    }

    /// Opens with a chosen app and remembers the choice for this kind of file (an alias's, its original's kind), while
    /// Remember recent items is on.
    func open(_ urls: [URL], with application: URL, entries: [FileEntry]) {
        rememberOpening(entries, with: application)
        noteHandoff(of: urls, to: application)
        let what = urls.count == 1 ? "the file" : "the files"
        dependencies.launcher.open(urls, withApplicationAt: application) { [weak self] error in
            guard let error else { return }
            self?.show(message: "Couldn’t open \(what): \(error.localizedDescription)")
        }
    }
    /// Recent and the apps used for each kind of file keep an opening only while Remember recent items is on.
    func rememberOpening(_ entries: [FileEntry], with application: URL) {
        guard dependencies.remembersRecentItems else { return }
        let now = dependencies.clock.now()
        for entry in entries {
            dependencies.recents.recordAccess(to: entry.url, kind: entry.kind, at: now)
            if let type = Self.openWithTarget(of: entry).contentType { dependencies.openWith.recordUse(of: application.path, for: type, at: now) }
        }
    }
    /// For the smoke run: what opening the file with the app keeps, without opening anything. False if there's no such file.
    public func rememberOpeningForTesting(_ url: URL, with application: URL) async -> Bool {
        guard let entry = try? await dependencies.fileSystem.entry(at: url) else { return false }
        rememberOpening([entry], with: application)
        return true
    }

    /// Makes `app` the default for every file of these kinds, as Finder's Get Info › Change All does. For an alias or
    /// a link it's its original's kind, never every alias's. Never for folders, whichever way it's asked for: they're
    /// only opened.
    func makeDefault(_ app: URL, for entries: [FileEntry], thenOpen: Bool) {
        guard Self.canChangeDefaults(for: entries) else {
            if thenOpen { hand(entries, to: app) }
            return
        }
        var seen: Set<String> = []
        let kinds = entries.compactMap { Self.openWithTarget(of: $0).contentType.flatMap(UTType.init) }
            .filter { seen.insert($0.identifier).inserted }
        guard !kinds.isEmpty else {
            show(message: "Helm can’t tell what kind of file “\(entries.first?.name ?? "")” is, so it can’t set a default app for it.")
            return
        }
        var waiting = kinds.count
        var failure: Error?
        for kind in kinds {
            dependencies.launcher.setDefaultApplication(at: app, toOpen: kind) { [weak self] error in
                if failure == nil { failure = error }
                waiting -= 1
                guard waiting == 0, let self else { return }
                if let failure {
                    self.show(message: "Couldn’t make it the default: \(failure.localizedDescription)")
                } else if thenOpen {
                    self.hand(entries, to: app)
                }
            }
        }
    }

    /// File › Open With from the keyboard or the menu bar: the same menu, under the selected items.
    func showOpenWithMenu() {
        let entries = selectedEntries()
        guard let view = window?.contentView, let entry = entries.first else { return }
        let menu = openWithMenu(for: entries)
        var point = NSPoint(x: view.bounds.midX - 100, y: view.bounds.midY)
        if let screen = screenFrame(of: entry.id), let window {
            let frame = view.convert(window.convertFromScreen(screen), from: nil)
            point = NSPoint(x: frame.minX, y: frame.minY)
        }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    // MARK: Chooser

    /// Every app that can open the items, grouped and searchable, with the option to make the choice the default,
    /// which folders don't have.
    func showOpenWithChooser(for entries: [FileEntry], makeDefault: Bool) {
        guard let window, let first = entries.first else { return }
        let choices = openWithChoices(for: entries)
        let offersAlways = Self.canChangeDefaults(for: entries)
        let always = makeDefault && offersAlways
        let words = OpenWithChooserWords(entries, kinds: entries.map { Self.openWithTarget(of: $0).kindText })
        let finish: (OpenWithDecision) -> Void = { [weak self, weak window] decision in
            if let attached = window?.attachedSheet { window?.endSheet(attached) }
            guard let self else { return }
            self.openWithChooser = nil
            switch decision {
            case .cancel: break
            case .open(let app, let always):
                if always { self.makeDefault(app, for: entries, thenOpen: true) } else { self.hand(entries, to: app) }
            case .browse(let always):
                self.browseForApplication(for: entries, makeDefault: always)
            }
        }
        let view = OpenWithChooser(words: words, icon: icons.icon(for: first), choices: choices, always: always,
                                   offersAlways: offersAlways, finish: finish)
        openWithChooser = OpenWithChooserSession(title: words.title, choices: choices, always: always, offersAlways: offersAlways,
                                                 finish: finish)
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.beginSheet(sheet, completionHandler: nil)
    }

    /// For tests and scripted runs: the chooser on show, its title, its apps in order (the default first) and whether
    /// "Always open" starts on.
    public var openWithChooserForTesting: (title: String, apps: [String], always: Bool)? {
        openWithChooser.map { ($0.title, $0.choices.ordered.map(\.name), $0.always) }
    }
    /// Answers the chooser on show as picking the app with this name and pressing the default button would. Nil cancels.
    @discardableResult public func answerOpenWithChooserForTesting(_ name: String?) -> Bool {
        guard let session = openWithChooser else { return false }
        guard let name else { session.finish(.cancel); return true }
        guard let app = session.choices.ordered.first(where: { $0.name == name }) else { return false }
        session.finish(.open(app.url, always: session.always))
        return true
    }

    private func browseForApplication(for entries: [FileEntry], makeDefault: Bool) {
        guard let window, let first = entries.first else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = makeDefault ? "Make Default" : "Open"
        panel.message = entries.count == 1 ? "Choose an app to open “\(first.displayName)”" : "Choose an app to open \(entries.count) items"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let app = panel.url, let self else { return }
            if makeDefault { self.makeDefault(app, for: entries, thenOpen: true) } else { self.hand(entries, to: app) }
        }
    }
}

/// What the chooser decided.
enum OpenWithDecision { case cancel, open(URL, always: Bool), browse(always: Bool) }

/// The chooser on show, kept so tests and scripted runs can read and answer it.
struct OpenWithChooserSession {
    let title: String
    let choices: OpenWithChoices
    let always: Bool
    /// Whether it has "Always open … with this app" at all: folders don't.
    let offersAlways: Bool
    let finish: (OpenWithDecision) -> Void
}

/// What the chooser says, for one item or several.
struct OpenWithChooserWords: Equatable {
    let title: String
    let kind: String
    let always: String
    let standard: String

    /// `kinds` are Finder's Kind words for each item, an alias's original's for an alias.
    init(_ entries: [FileEntry], kinds: [String]) {
        let kinds = Set(kinds)
        let kind = kinds.count == 1 ? (kinds.first ?? "") : ""
        if entries.count == 1, let entry = entries.first {
            title = "Open “\(entry.displayName)” with"
        } else {
            title = "Open \(entries.count) items with"
        }
        self.kind = kinds.count > 1 ? "Several kinds" : kind
        always = kind.isEmpty ? (kinds.count > 1 ? "Always open files of these kinds with this app" : "Always open files like this with this app")
                              : "Always open \(kind) files with this app"
        standard = kind.isEmpty ? (kinds.count > 1 ? "Default for all of these" : "Default for this kind of file") : "Default for \(kind) files"
    }
}

/// Choose an app: the default, recently used, recommended and other apps, with a search field and
/// "Always open … with this app", except for folders.
struct OpenWithChooser: View {
    let words: OpenWithChooserWords
    let icon: NSImage
    let choices: OpenWithChoices
    @State var always: Bool
    let offersAlways: Bool
    let finish: (OpenWithDecision) -> Void
    @State private var query = ""
    @State private var selection: String?

    init(words: OpenWithChooserWords, icon: NSImage, choices: OpenWithChoices, always: Bool, offersAlways: Bool = true,
         finish: @escaping (OpenWithDecision) -> Void) {
        self.words = words; self.icon = icon; self.choices = choices; self.offersAlways = offersAlways; self.finish = finish
        _always = State(initialValue: always && offersAlways)
        _selection = State(initialValue: choices.ordered.first?.id)
    }

    private var sections: [(String, [AppChoice])] {
        func matching(_ apps: [AppChoice]) -> [AppChoice] {
            query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        return [("Default", matching(choices.standard.map { [$0] } ?? [])), ("Recently Used", matching(choices.recent)),
                ("Recommended", matching(choices.recommended)), ("Other Apps", matching(choices.other))]
            .filter { !$0.1.isEmpty }
    }
    private var chosen: AppChoice? { choices.ordered.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(words.title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(words.kind).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            TextField("Search apps", text: $query).textFieldStyle(.roundedBorder).font(.system(size: 14))
            List(selection: $selection) {
                ForEach(sections, id: \.0) { section in
                    Section(section.0) {
                        ForEach(section.1) { app in row(app).tag(app.id) }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 300)
            .contextMenu(forSelectionType: String.self, menu: { _ in EmptyView() }, primaryAction: { ids in
                if let id = ids.first, let app = appFor(id) { finish(.open(app.url, always: always)) }
            })
            if offersAlways {
                Toggle(words.always, isOn: $always)
                    .font(.system(size: 13))
            }
            HStack {
                Button("Choose Another App…") { finish(.browse(always: always)) }
                Spacer()
                Button("Cancel", role: .cancel) { finish(.cancel) }.keyboardShortcut(.cancelAction)
                Button(always ? "Make Default and Open" : "Open") {
                    if let app = chosen { finish(.open(app.url, always: always)) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
            }
        }
        .padding(18)
        .frame(width: 480, height: 560)
    }

    private func appFor(_ id: String) -> AppChoice? { choices.ordered.first { $0.id == id } }

    private func row(_ app: AppChoice) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.name).font(.system(size: 14))
                    if let version = app.version { Text(version).font(.system(size: 11)).foregroundStyle(.tertiary) }
                }
                Text(app.id == choices.standard?.id ? words.standard : app.detail)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
#endif
