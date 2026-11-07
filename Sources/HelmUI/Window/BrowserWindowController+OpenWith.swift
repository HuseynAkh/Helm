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
}

/// Ranks apps from what each one declares in its Info.plist, the same declarations Launch Services uses.
/// The answers are kept per app, so a menu opens without rereading every bundle.
@MainActor enum ApplicationCatalog {
    private struct Claim { let types: [String]; let extensions: [String]; let rank: Int; let edits: Bool }
    private static var claims: [String: [Claim]] = [:]
    private static let generic: Set<String> = ["public.item", "public.data", "public.content", "public.composite-content", "public.archive"]

    static func choices(for url: URL, contentType: String?, recent: [OpenWithRecord]) -> OpenWithChoices {
        let type = contentType.flatMap(UTType.init) ?? UTType(filenameExtension: url.pathExtension)
        let standardURL = NSWorkspace.shared.urlForApplication(toOpen: url)
        var byIdentity: [String: AppChoice] = [:]
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url) + (standardURL.map { [$0] } ?? []) {
            let choice = describe(app, type: type, pathExtension: url.pathExtension.lowercased())
            let identity = Bundle(url: app)?.bundleIdentifier ?? app.path
            // One row per app, even with several copies installed: the default's copy, else the one in Applications.
            if let existing = byIdentity[identity], !prefers(app, over: existing.url, standard: standardURL) { continue }
            byIdentity[identity] = choice
        }
        var all = Array(byIdentity.values)
        var result = OpenWithChoices()
        if let standardURL, let index = all.firstIndex(where: { $0.url.standardizedFileURL == standardURL.standardizedFileURL }) {
            result.standard = all.remove(at: index)
        }
        // Recently used first, newest first: apps you picked yourself for this kind of file.
        for record in recent where FileManager.default.fileExists(atPath: record.application) {
            if result.standard?.url.path == record.application { result.standard?.lastUsed = record.lastUsed; continue }
            if let index = all.firstIndex(where: { $0.url.path == record.application }) {
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
    /// Hold Option to make the app you pick the default for this kind of file, as in Finder.
    public func fillOpenWithItems(in menu: NSMenu) { fillOpenWithItems(in: menu, entries: selectedEntries()) }

    func fillOpenWithItems(in menu: NSMenu, entries: [FileEntry]) {
        menu.removeAllItems()
        guard entries.count == 1, let entry = entries.first else {
            let none = NSMenuItem(title: entries.isEmpty ? "Select a File" : "Select One File", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none); return
        }
        let choices = openWithChoices(for: entry)
        if let standard = choices.standard { addApp(standard, to: menu, entry: entry, suffix: " (default)") }
        if !choices.recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Recently Used"))
            for app in choices.recent { addApp(app, to: menu, entry: entry) }
        }
        let shown = choices.recommended.prefix(12)
        if !shown.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Recommended"))
            for app in shown { addApp(app, to: menu, entry: entry) }
        }
        let rest = Array(choices.recommended.dropFirst(12)) + choices.other
        if !rest.isEmpty {
            let submenu = NSMenu(title: "Other Apps")
            for app in rest.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                addApp(app, to: submenu, entry: entry)
            }
            let item = NSMenuItem(title: "Other Apps", action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(action("Choose App…") { [weak self] in self?.showOpenWithChooser(for: entry, makeDefault: false) })
        menu.addItem(action("Change Default App…") { [weak self] in self?.showOpenWithChooser(for: entry, makeDefault: true) })
    }

    private func addApp(_ app: AppChoice, to menu: NSMenu, entry: FileEntry, suffix: String = "") {
        let item = action(app.name + suffix) { [weak self] in self?.open([entry.url], with: app.url, entries: [entry]) }
        item.image = Self.menuIcon(app.url)
        item.toolTip = app.version.map { "\(app.name) \($0). \(app.detail)" } ?? app.detail
        menu.addItem(item)
        // Option turns it into "Always Open With", which also makes it the default for this kind of file.
        let always = action("Always Open With \(app.name)") { [weak self] in self?.makeDefault(app.url, for: entry, thenOpen: true) }
        always.image = item.image
        always.isAlternate = true
        always.keyEquivalentModifierMask = .option
        menu.addItem(always)
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
        let choices = openWithChoices(for: entry)
        let ids = ((choices.standard.map { [$0] } ?? []) + choices.recent + choices.recommended + choices.other).map(\.id)
        return (choices.standard?.name, ids.count, Set(ids).count, choices.recommended.count)
    }

    func openWithChoices(for entry: FileEntry) -> OpenWithChoices {
        let type = Self.contentType(of: entry)
        let recent = type.map { type in
            dependencies.openWith.records.filter { $0.contentType == type.identifier }.sorted { $0.lastUsed > $1.lastUsed }
        } ?? []
        return ApplicationCatalog.choices(for: entry.url, contentType: type?.identifier, recent: recent)
    }
    static func contentType(of entry: FileEntry) -> UTType? {
        entry.contentTypeIdentifier.flatMap(UTType.init) ?? UTType(filenameExtension: entry.url.pathExtension)
    }

    // MARK: Opening

    /// Opens with a chosen app and remembers the choice for this kind of file.
    func open(_ urls: [URL], with application: URL, entries: [FileEntry]) {
        let now = dependencies.clock.now()
        for entry in entries {
            dependencies.recents.recordAccess(to: entry.url, kind: entry.kind, at: now)
            if let type = Self.contentType(of: entry) { dependencies.openWith.recordUse(of: application.path, for: type.identifier, at: now) }
        }
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.show(message: "Couldn’t open the file: \(error.localizedDescription)") }
        }
    }

    /// Makes `app` the default for every file of this kind, as Finder's Get Info › Change All does.
    func makeDefault(_ app: URL, for entry: FileEntry, thenOpen: Bool) {
        guard let type = Self.contentType(of: entry) else {
            show(message: "Helm can’t tell what kind of file “\(entry.name)” is, so it can’t set a default app for it.")
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.show(message: "Couldn’t make it the default: \(error.localizedDescription)")
                } else if thenOpen {
                    self.open([entry.url], with: app, entries: [entry])
                }
            }
        }
    }

    /// File › Open With from the keyboard or the menu bar: the same menu, under the selected item.
    func showOpenWithMenu() {
        guard let view = window?.contentView, let entry = selectedEntries().first else { return }
        let menu = openWithMenu(for: [entry])
        var point = NSPoint(x: view.bounds.midX - 100, y: view.bounds.midY)
        if let screen = screenFrame(of: entry.id), let window {
            let frame = view.convert(window.convertFromScreen(screen), from: nil)
            point = NSPoint(x: frame.minX, y: frame.minY)
        }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    // MARK: Chooser

    /// Every app that can open the file, grouped and searchable, with the option to make the choice the default.
    func showOpenWithChooser(for entry: FileEntry, makeDefault: Bool) {
        guard let window else { return }
        let choices = openWithChoices(for: entry)
        let icon = NSWorkspace.shared.icon(forFile: entry.url.path)
        let view = OpenWithChooser(fileName: entry.displayName, kind: entry.kindText, icon: icon, choices: choices,
                                   always: makeDefault) { [weak self, weak window] decision in
            if let attached = window?.attachedSheet { window?.endSheet(attached) }
            guard let self else { return }
            switch decision {
            case .cancel: break
            case .open(let app, let always):
                if always { self.makeDefault(app, for: entry, thenOpen: true) } else { self.open([entry.url], with: app, entries: [entry]) }
            case .browse(let always):
                self.browseForApplication(for: entry, makeDefault: always)
            }
        }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.beginSheet(sheet, completionHandler: nil)
    }

    private func browseForApplication(for entry: FileEntry, makeDefault: Bool) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = makeDefault ? "Make Default" : "Open"
        panel.message = "Choose an app to open “\(entry.displayName)”"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let app = panel.url, let self else { return }
            if makeDefault { self.makeDefault(app, for: entry, thenOpen: true) } else { self.open([entry.url], with: app, entries: [entry]) }
        }
    }
}

/// What the chooser decided.
enum OpenWithDecision { case cancel, open(URL, always: Bool), browse(always: Bool) }

/// Choose an app: the default, recently used, recommended and other apps, with a search field and
/// "Always open … with this app".
struct OpenWithChooser: View {
    let fileName: String
    let kind: String
    let icon: NSImage
    let choices: OpenWithChoices
    @State var always: Bool
    let finish: (OpenWithDecision) -> Void
    @State private var query = ""
    @State private var selection: String?

    init(fileName: String, kind: String, icon: NSImage, choices: OpenWithChoices, always: Bool, finish: @escaping (OpenWithDecision) -> Void) {
        self.fileName = fileName; self.kind = kind; self.icon = icon; self.choices = choices; self.finish = finish
        _always = State(initialValue: always)
        _selection = State(initialValue: choices.standard?.id ?? choices.recent.first?.id ?? choices.recommended.first?.id)
    }

    private var sections: [(String, [AppChoice])] {
        func matching(_ apps: [AppChoice]) -> [AppChoice] {
            query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        return [("Default", matching(choices.standard.map { [$0] } ?? [])), ("Recently Used", matching(choices.recent)),
                ("Recommended", matching(choices.recommended)), ("Other Apps", matching(choices.other))]
            .filter { !$0.1.isEmpty }
    }
    private var chosen: AppChoice? {
        let all = (choices.standard.map { [$0] } ?? []) + choices.recent + choices.recommended + choices.other
        return all.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open “\(fileName)” with").font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(kind).font(.system(size: 13)).foregroundStyle(.secondary)
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
            Toggle("Always open \(kind.isEmpty ? "files like this" : kind) files with this app", isOn: $always)
                .font(.system(size: 13))
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

    private func appFor(_ id: String) -> AppChoice? {
        ((choices.standard.map { [$0] } ?? []) + choices.recent + choices.recommended + choices.other).first { $0.id == id }
    }

    private func row(_ app: AppChoice) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.name).font(.system(size: 14))
                    if let version = app.version { Text(version).font(.system(size: 11)).foregroundStyle(.tertiary) }
                }
                Text(app.id == choices.standard?.id ? "Default for \(kind.isEmpty ? "this kind of file" : kind) files" : app.detail)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
#endif
