#if os(macOS)
import AppKit
import HelmCore
import UniformTypeIdentifiers

/// Open in Terminal, as Nautilus offers it: a new window of the terminal app chosen in Settings › General, in a
/// folder. The folder is the one selected, or the one on show when nothing is. Helm hands the folder to the app as
/// Finder's New Terminal at Folder does, through Launch Services, so it runs no shell and types nothing.
extension BrowserWindowController {
    /// The folder Open in Terminal would open: the one selected item when it's a folder, or the folder on show when
    /// nothing is selected. Nil for a file, several items, a package such as an app, or a place that isn't a folder,
    /// such as Recent or the Trash.
    func terminalFolder() -> URL? {
        guard let tab = activeTab else { return nil }
        let selected = selectedEntries()
        if selected.isEmpty {
            guard case .directory(let url) = tab.location else { return nil }
            return url
        }
        guard selected.count == 1, selected[0].isDirectoryLike else { return nil }
        return selected[0].url
    }

    /// Opens `folder` in the chosen terminal app: the Mac's default unless another is picked in Settings, and Terminal
    /// when the chosen one isn't on this Mac any more. Says what went wrong when macOS couldn't open it.
    func openInTerminal(_ folder: URL) {
        let chosen = TerminalLocator.resolve(dependencies.settings.snapshot.string(.terminalApp))
        guard let application = TerminalLocator.application(chosen) ?? TerminalLocator.application(TerminalApps.standard) else {
            show(message: "Couldn’t find \(TerminalApps.name(of: chosen)) on this Mac.")
            return
        }
        let name = TerminalApps.name(of: TerminalLocator.identifier(of: application) ?? chosen)
        dependencies.launcher.open([folder], withApplicationAt: application) { [weak self] error in
            guard let error else { return }
            self?.show(message: "Couldn’t open “\(folder.lastPathComponent)” in \(name): \(error.localizedDescription)")
        }
    }

    /// Whether a sidebar or path bar row is a folder that can open in the terminal.
    func opensInTerminal(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false
    }

    /// Open in Terminal on the selected folder or the one on show, as the menus do. False when there's neither.
    @discardableResult public func openInTerminalForTesting() -> Bool {
        guard let folder = terminalFolder() else { return false }
        openInTerminal(folder)
        return true
    }
}

/// The terminal apps on this Mac. It only asks Launch Services, which reads nothing of the apps' own data.
@MainActor public enum TerminalLocator {
    /// The bundle identifier a setting stands for: the Mac's default terminal for "default", else the setting itself.
    public static func resolve(_ setting: String) -> String {
        setting == TerminalApps.followsMac ? macDefault() : setting
    }
    /// The Mac's default terminal. macOS keeps no one setting for it, so it's the first terminal other than Terminal
    /// that the Mac opens shell scripts or executables with, as someone who prefers another terminal makes it open
    /// those. Terminal when none is: it's every Mac's own.
    public static func macDefault() -> String {
        let types = ["public.shell-script", "com.apple.terminal.shell-script", "public.unix-executable", "public.zsh-script"]
            .compactMap(UTType.init)
        let handlers = types.compactMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        let known = Set(TerminalApps.known.map(\.id)).subtracting([TerminalApps.standard])
        return handlers.compactMap(identifier(of:)).first { known.contains($0) } ?? TerminalApps.standard
    }
    /// Where the app with this bundle identifier is, if it's on this Mac.
    public static func application(_ id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }
    /// The bundle identifier of the app at `url`.
    public static func identifier(of url: URL) -> String? { Bundle(url: url)?.bundleIdentifier }
    /// The terminals Helm knows that are on this Mac and that macOS lists as able to open a folder, Terminal first.
    /// `folder` is any folder, which macOS needs to answer which apps open one.
    public static func installed(folder: URL) -> [TerminalApps.App] {
        let openers = Set(NSWorkspace.shared.urlsForApplications(toOpen: folder).compactMap(identifier(of:)))
        return TerminalApps.known.filter { $0.id == TerminalApps.standard || (openers.contains($0.id) && application($0.id) != nil) }
    }
}
#endif

#if os(macOS)
/// Properties windows, for tests and fixture runs.
extension BrowserWindowController {
    /// How many Properties windows this window has open.
    public var propertiesWindowCountForTesting: Int { propertiesWindows.count }
    /// The newest Properties window's rows, the general ones then the permissions.
    public var propertiesRowsForTesting: [PropertiesRow] {
        guard let model = propertiesWindows.last?.session.model else { return [] }
        return model.generalRows + model.permissionRows
    }
    /// The newest Properties window's title, and whether its count is done.
    public var propertiesTitleForTesting: String? { propertiesWindows.last?.window?.title }
    public var propertiesFinishedForTesting: Bool { propertiesWindows.last?.session.isFinished ?? false }
    /// Whether the newest Properties window is on show, which it is once its details are read.
    public var propertiesShownForTesting: Bool { propertiesWindows.last?.window?.isVisible ?? false }
    public var propertiesWindowForTesting: NSWindow? { propertiesWindows.last?.window }
    /// Closes the newest Properties window, as its close button does.
    public func closePropertiesForTesting() { propertiesWindows.last?.window?.performClose(nil) }
    /// A key pressed in the newest Properties window, by name: escape.
    public func propertiesKeyForTesting(_ name: String) {
        guard name == "escape" else { return }
        propertiesWindows.last?.window?.cancelOperation(nil)
    }
}
#endif
