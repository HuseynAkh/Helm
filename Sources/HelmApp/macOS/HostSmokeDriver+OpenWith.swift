#if os(macOS)
import AppKit
import HelmCore
import HelmUI
import UniformTypeIdentifiers

/// Smoke verbs for Open With, from every menu that offers it: the right-click menu in the list and the grid (in a folder,
/// in Recent and in search results) and File › Open With in the menu bar. They read the menus as AppKit shows them,
/// choose rows as a click would, and answer the chooser. Used by `scripts/rebuild/smoke.d/open-with.txt`.
/// A fixture run hands files to a stand-in, so no app opens and no default app changes.
extension HostSmokeDriver {
    static func performOpenWithVerb(_ verb: String, _ argument: String, step: String,
                                    window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "openwith-stand-in":
            // The run hands files to the stand-in, never to a real app.
            check(window.dependencies.launcher is MemoryAppLauncher, step, "\(type(of: window.dependencies.launcher))")
        case "openwith-context", "openwith-menubar":
            // "[default|no-default]": Open With on the selected items, from a right-click on them in the list or grid on
            // show, or from File › Open With. The row is on, and so is every row in its submenu: the default app first,
            // then the rest, each with its Option row, then Choose App… and Change Default App….
            let found = verb == "openwith-context" ? await contextOpenWith(window) : menuBarOpenWith(window, app: app)
            guard let menu = found.menu else { check(false, step, found.detail); return true }
            let result = review(menu, window: window, wantsDefault: argument.isEmpty ? nil : argument == "default")
            print("OPENWITH \(found.detail) [\(window.selectedEntries().map(\.name).joined(separator: ", "))]: \(result.summary)")
            fflush(stdout)
            check(result.problems.isEmpty, step, result.problems.joined(separator: "; "))
        case "openwith-pick", "openwith-always":
            // "<context|menubar> <default|first|second|app name>": chooses an app from Open With as a click would, or its
            // Option row. The stand-in must get exactly the selected files, for that app, and for Always the default
            // must change for each kind of file among them first.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2, let launcher = window.dependencies.launcher as? MemoryAppLauncher else { check(false, step, "usage, or no stand-in"); return true }
            let found = bits[0] == "menubar" ? menuBarOpenWith(window, app: app) : await contextOpenWith(window)
            guard let menu = found.menu else { check(false, step, found.detail); return true }
            let entries = window.selectedEntries()
            guard let chosen = pick(bits[1], in: window.openWithAppsForTesting(entries)) else { check(false, step, "no app “\(bits[1])”"); return true }
            let always = verb == "openwith-always"
            guard let (submenu, index) = row(for: chosen.name, always: always, in: menu) else {
                check(false, step, "no row for \(chosen.name) in \(titles(menu))"); return true
            }
            let opened = launcher.openings.count, changed = launcher.defaultChanges.count
            submenu.performActionForItem(at: index)
            await wait(seconds: 0.4)
            let wanted = MemoryAppLauncher.Opening(urls: originals(of: entries), application: chosen.url)
            var problems: [String] = []
            if launcher.openings.count != opened + 1 || launcher.openings.last != wanted {
                problems.append("handed over \(launcher.openings.dropFirst(opened).map(describe)), wanted \(describe(wanted))")
            }
            problems += handedLinks(launcher.openings.last)
            let kinds = Set(originals(of: entries).compactMap { (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier })
            let defaults = launcher.defaultChanges.dropFirst(changed)
            if always, Set(defaults.map(\.type)) != kinds || defaults.contains(where: { $0.application != chosen.url }) {
                problems.append("defaults \(defaults.map { "\($0.type)→\($0.application.lastPathComponent)" }), wanted \(kinds.sorted()) → \(chosen.name)")
            }
            if !always, !defaults.isEmpty { problems.append("changed a default it shouldn't have") }
            print("OPENWITH \(verb == "openwith-always" ? "always " : "")\(chosen.name) got \(entries.map(\.name).joined(separator: ", "))"); fflush(stdout)
            check(problems.isEmpty, step, problems.joined(separator: "; "))
        case "openwith-chooser":
            // "<context|menubar> <choose|change> <default|first|second|app name>": Choose App… or Change Default App…
            // brings up the chooser for the selected files, listing the same apps, the default first, with Always on
            // only for Change Default App…. Picking an app in it hands the files over, and for Change sets the default.
            let bits = argument.split(separator: " ", maxSplits: 2).map(String.init)
            guard bits.count == 3, let launcher = window.dependencies.launcher as? MemoryAppLauncher else { check(false, step, "usage, or no stand-in"); return true }
            let found = bits[0] == "menubar" ? menuBarOpenWith(window, app: app) : await contextOpenWith(window)
            guard let menu = found.menu else { check(false, step, found.detail); return true }
            let change = bits[1] == "change"
            let title = change ? "Change Default App…" : "Choose App…"
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else { check(false, step, "no \(title) in \(titles(menu))"); return true }
            let entries = window.selectedEntries()
            let expected = window.openWithAppsForTesting(entries)
            let opened = launcher.openings.count, changed = launcher.defaultChanges.count
            menu.performActionForItem(at: index)
            await wait(seconds: 0.5)
            guard let chooser = window.openWithChooserForTesting else { check(false, step, "no chooser came up"); return true }
            var problems: [String] = []
            if window.window?.attachedSheet == nil { problems.append("the chooser isn't on the window") }
            let wantedTitle = entries.count == 1 ? "Open “\(entries[0].name)” with" : "Open \(entries.count) items with"
            if chooser.title != wantedTitle { problems.append("title “\(chooser.title)”") }
            if chooser.apps != expected.apps.map(\.name) { problems.append("lists \(chooser.apps), the menu \(expected.apps.map(\.name))") }
            if chooser.always != change { problems.append("Always starts \(chooser.always ? "on" : "off")") }
            guard let chosen = pick(bits[2], in: expected), window.answerOpenWithChooserForTesting(chosen.name) else {
                check(false, step, (problems + ["can't pick “\(bits[2])”"]).joined(separator: "; ")); return true
            }
            await wait(seconds: 0.5)
            if window.openWithChooserForTesting != nil || window.window?.attachedSheet != nil { problems.append("the chooser stayed up") }
            let wanted = MemoryAppLauncher.Opening(urls: originals(of: entries), application: chosen.url)
            if launcher.openings.count != opened + 1 || launcher.openings.last != wanted {
                problems.append("handed over \(launcher.openings.dropFirst(opened).map(describe)), wanted \(describe(wanted))")
            }
            problems += handedLinks(launcher.openings.last)
            let defaults = launcher.defaultChanges.dropFirst(changed)
            if change != !defaults.isEmpty || defaults.contains(where: { $0.application != chosen.url }) {
                problems.append("defaults \(defaults.map { "\($0.type)→\($0.application.lastPathComponent)" })")
            }
            print("OPENWITH chooser “\(chooser.title)” \(chooser.apps.count) apps, Always \(chooser.always ? "on" : "off"), picked \(chosen.name)"); fflush(stdout)
            check(problems.isEmpty, step, problems.joined(separator: "; "))
        case "openwith-like":
            // "<name>": Open With on the selected link or alias lists the same apps, in the same order and with the same
            // default, as on <name>, the item it points to, and not just the few apps that open links themselves.
            guard let original = window.activeTab?.snapshot.sortedEntries.first(where: { $0.name == argument }) else {
                check(false, step, "no “\(argument)” here"); return true
            }
            let selected = window.selectedEntries()
            let link = window.openWithAppsForTesting(selected), wanted = window.openWithAppsForTesting([original])
            var problems: [String] = []
            if !selected.contains(where: { [.alias, .symlinkToFile, .symlinkToDirectory].contains($0.kind) }) { problems.append("no link selected") }
            if link.apps.map(\.name) != wanted.apps.map(\.name) { problems.append("lists \(link.apps.map(\.name)), \(argument) \(wanted.apps.map(\.name))") }
            if link.defaultName != wanted.defaultName { problems.append("default \(link.defaultName ?? "none"), \(argument)'s \(wanted.defaultName ?? "none")") }
            if wanted.apps.count < 3 { problems.append("\(argument) lists only \(wanted.apps.map(\.name))") }
            print("OPENWITH \(selected.map(\.name).joined(separator: ", ")) like \(argument): \(link.apps.count) apps, default \(link.defaultName ?? "none")"); fflush(stdout)
            check(problems.isEmpty, step, problems.joined(separator: "; "))
        default: return false
        }
        return true
    }

    /// What must reach the app for each item: the item, or the original an alias or link points to, as in Finder.
    private static func originals(of entries: [FileEntry]) -> [URL] {
        entries.map { entry in
            switch entry.kind {
            case .symlinkToFile, .symlinkToDirectory:
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path) else { return entry.url }
                let path = destination.hasPrefix("/") ? destination : entry.url.deletingLastPathComponent().appendingPathComponent(destination).path
                return URL(fileURLWithPath: path, isDirectory: entry.kind == .symlinkToDirectory)
            case .alias: return (try? URL(resolvingAliasFileAt: entry.url, options: [.withoutUI, .withoutMounting])) ?? entry.url
            default: return entry.url
            }
        }
    }
    /// A link handed to an app instead of what it points to.
    private static func handedLinks(_ opening: MemoryAppLauncher.Opening?) -> [String] {
        (opening?.urls ?? []).filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])).map { $0.isSymbolicLink == true || $0.isAliasFile == true } ?? false }
            .map { "handed over the link \($0.lastPathComponent)" }
    }

    // MARK: Finding the menus

    /// Open With from a right-click on the first selected item in the list or grid on show, as a person would: scrolled
    /// into view first, then both menus brought up to date as AppKit does just before showing them.
    private static func contextOpenWith(_ window: BrowserWindowController) async -> (menu: NSMenu?, detail: String) {
        guard let frame = window.window, let content = frame.contentView else { return (nil, "no window") }
        let view: NSView, point: NSPoint, place: String
        if let outline = firstView(in: content, where: { ($0 as? NSOutlineView)?.accessibilityLabel() == "Files" && !$0.isHiddenOrHasHiddenAncestor }) as? NSOutlineView {
            guard outline.selectedRow >= 0 else { return (nil, "nothing selected in the list") }
            outline.scrollRowToVisible(outline.selectedRow)
            await wait(seconds: 0.2)
            let rect = outline.rect(ofRow: outline.selectedRow)
            view = outline; point = outline.convert(NSPoint(x: rect.minX + 40, y: rect.midY), to: nil); place = "list"
        } else if let grid = firstView(in: content, where: { ($0 as? NSCollectionView)?.accessibilityLabel() == "Files" && !$0.isHiddenOrHasHiddenAncestor }) as? NSCollectionView {
            guard let path = grid.selectionIndexPaths.sorted().first else { return (nil, "nothing selected in the grid") }
            grid.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
            grid.layoutSubtreeIfNeeded()
            await wait(seconds: 0.2)
            guard let item = grid.layoutAttributesForItem(at: path) else { return (nil, "no place for the selected item in the grid") }
            view = grid; point = grid.convert(NSPoint(x: item.frame.midX, y: item.frame.midY), to: nil); place = "grid"
        } else {
            return (nil, "no list or grid on show")
        }
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: frame.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let menu = view.menu(for: event) else { return (nil, "no right-click menu in the \(place)") }
        menu.update()
        let described = "right-click in the \(place)\(window.activeTab?.location == .recent ? " in Recent" : "")\(window.activeTab?.search != nil ? " in search results" : "")"
        guard let item = menu.items.first(where: { $0.title == "Open With" }) else {
            return (nil, "\(described): no Open With row in \(titles(menu))")
        }
        guard item.isEnabled, let submenu = item.submenu else {
            return (nil, "\(described): Open With is \(item.isEnabled ? "on" : "off"), action \(item.action.map(NSStringFromSelector) ?? "none"), submenu \(item.hasSubmenu)")
        }
        submenu.update()
        return (submenu, described)
    }

    /// File › Open With, filled from the selection the way AppKit fills it as it opens.
    private static func menuBarOpenWith(_ window: BrowserWindowController, app: AppController) -> (menu: NSMenu?, detail: String) {
        guard let file = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu,
              let item = file.items.first(where: { $0.title == "Open With" }) else { return (nil, "no File › Open With") }
        file.update()
        guard item.isEnabled, let submenu = item.submenu else {
            return (nil, "File › Open With is \(item.isEnabled ? "on" : "off"), action \(item.action.map(NSStringFromSelector) ?? "none")")
        }
        app.menuNeedsUpdate(submenu)
        submenu.update()
        return (submenu, "File › Open With")
    }

    // MARK: Reading them

    /// What's wrong with an Open With submenu, if anything, and a line saying what it shows.
    private static func review(_ menu: NSMenu, window: BrowserWindowController, wantsDefault: Bool?) -> (problems: [String], summary: String) {
        var problems: [String] = []
        let expected = window.openWithAppsForTesting(window.selectedEntries())
        // A folder's default app is the one for every folder, so its menu has no Always Open With or Change Default App….
        let changesDefaults = BrowserWindowController.canChangeDefaults(for: window.selectedEntries())
        let top = appRows(in: menu, always: changesDefaults, problems: &problems)
        var others: [String] = []
        if let other = menu.items.first(where: { $0.title == "Other Apps" }) {
            if !other.isEnabled { problems.append("Other Apps is off") }
            if let submenu = other.submenu {
                submenu.update()
                others = appRows(in: submenu, always: changesDefaults, problems: &problems)
            } else {
                problems.append("Other Apps has no submenu")
            }
        }
        for title in changesDefaults ? ["Choose App…", "Change Default App…"] : ["Choose App…"] {
            guard let item = menu.items.first(where: { $0.title == title }) else { problems.append("no \(title)"); continue }
            if !item.isEnabled { problems.append("\(title) is off") }
        }
        if !changesDefaults, menu.items.contains(where: { $0.title == "Change Default App…" || $0.title.hasPrefix("Always Open With") }) {
            problems.append("a folder offers to change the default app")
        }
        if top.isEmpty { problems.append("no apps listed") }
        let shown = top.map { $0.replacingOccurrences(of: " (default)", with: "") }
        let wanted = expected.apps.map(\.name)
        if shown != Array(wanted.prefix(shown.count)) { problems.append("order \(shown), wanted \(wanted)") }
        if Set(shown + others) != Set(wanted) || shown.count + others.count != wanted.count {
            problems.append("lists \(shown) + Other Apps \(others), wanted \(wanted)")
        }
        let marked = top.filter { $0.hasSuffix(" (default)") }
        if let name = expected.defaultName {
            if top.first != "\(name) (default)" { problems.append("first row “\(top.first ?? "none")”, default is \(name)") }
            if marked.count != 1 { problems.append("\(marked.count) rows say (default)") }
        } else if !marked.isEmpty {
            problems.append("\(marked) say (default), but these files don't share one")
        }
        if let wantsDefault, wantsDefault != (expected.defaultName != nil) {
            problems.append(wantsDefault ? "no shared default" : "a default (\(expected.defaultName ?? "")) where none was wanted")
        }
        let summary = "\(top.count) apps, first “\(top.first ?? "none")”\(others.isEmpty ? "" : ", Other Apps ▸ \(others.count)")"
            + ", every row on: \(problems.isEmpty ? "yes" : "no")"
        return (problems, summary)
    }

    /// The app rows of an Open With menu, in order, each checked to be on and, with `always`, followed by its Option row.
    private static func appRows(in menu: NSMenu, always: Bool = true, problems: inout [String]) -> [String] {
        var names: [String] = []
        let items = menu.items
        for (index, item) in items.enumerated() where !item.isSeparatorItem && !item.isSectionHeader && !item.isAlternate {
            if ["Choose App…", "Change Default App…", "Other Apps"].contains(item.title) { continue }
            names.append(item.title)
            if !item.isEnabled { problems.append("“\(item.title)” is off") }
            if item.image == nil { problems.append("“\(item.title)” has no icon") }
            let name = item.title.replacingOccurrences(of: " (default)", with: "")
            let next = index + 1 < items.count ? items[index + 1] : nil
            guard always else { continue }
            guard let alternate = next, alternate.isAlternate, alternate.title == "Always Open With \(name)" else {
                problems.append("“\(item.title)” has no Always Open With row"); continue
            }
            if !alternate.isEnabled { problems.append("“\(alternate.title)” is off") }
            if alternate.keyEquivalentModifierMask != .option || alternate.keyEquivalent != item.keyEquivalent {
                problems.append("“\(alternate.title)” doesn't come up with Option")
            }
        }
        return names
    }

    /// The app a step names: the default, the first or second app listed, or one by name.
    private static func pick(_ selector: String, in apps: (apps: [(name: String, url: URL)], defaultName: String?)) -> (name: String, url: URL)? {
        switch selector {
        case "default": return apps.defaultName == nil ? nil : apps.apps.first
        case "first": return apps.apps.first
        case "second": return apps.apps.dropFirst().first
        default: return apps.apps.first { $0.name == selector }
        }
    }

    /// The menu and position of an app's row, or of its Option row, looking in Other Apps too.
    private static func row(for name: String, always: Bool, in menu: NSMenu) -> (NSMenu, Int)? {
        let titles = always ? ["Always Open With \(name)"] : [name, "\(name) (default)"]
        if let index = menu.items.firstIndex(where: { titles.contains($0.title) && $0.isAlternate == always }) { return (menu, index) }
        if let other = menu.items.first(where: { $0.title == "Other Apps" })?.submenu,
           let index = other.items.firstIndex(where: { titles.contains($0.title) && $0.isAlternate == always }) { return (other, index) }
        return nil
    }

    private static func titles(_ menu: NSMenu) -> String {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title).joined(separator: " | ")
    }
    private static func describe(_ opening: MemoryAppLauncher.Opening) -> String {
        "\(opening.urls.map(\.lastPathComponent)) → \(opening.application.lastPathComponent)"
    }
    private static func firstView(in view: NSView, where match: (NSView) -> Bool) -> NSView? {
        for child in view.subviews {
            if match(child) { return child }
            if let found = firstView(in: child, where: match) { return found }
        }
        return nil
    }
}
#endif
