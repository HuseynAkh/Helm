#if os(macOS)
import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Which app answers "Show in Finder" across the Mac, opens folders, and starts at login.
///
/// macOS asks the app named by the global `NSFileViewer` preference to show a file, and hands it the
/// file as an ordinary open request. Folders opened from other apps go to the default app for
/// `public.folder`. Making Helm the default sets both; restoring Finder clears both.
@MainActor public protocol FileViewerRegistering: AnyObject {
    /// False when Helm isn't running as an app bundle, so there's nothing to register.
    var canRegister: Bool { get }
    var isHelmDefault: Bool { get }
    var opensAtLogin: Bool { get }
    func makeHelmDefault(_ done: @escaping @MainActor (String?) -> Void)
    func restoreFinder(_ done: @escaping @MainActor (String?) -> Void)
    /// Returns a message when macOS refuses.
    func setOpensAtLogin(_ on: Bool) -> String?
    /// Whether Helm's tile is the first app in the Dock, right after Finder's, which macOS keeps first.
    var isFirstInDock: Bool { get }
    /// Moves Helm's tile first, or puts it back where it was. Returns a message when it can't.
    func setFirstInDock(_ on: Bool) -> String?
}

/// The real thing: the user's global preferences, Launch Services and the login items.
@MainActor public final class SystemFileViewerRole: FileViewerRegistering {
    static let viewerKey = "NSFileViewer" as CFString
    static let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    private let bundle: Bundle
    public init(bundle: Bundle = .main) { self.bundle = bundle }

    private var identifier: String? {
        guard bundle.bundleURL.pathExtension == "app" else { return nil }
        return bundle.bundleIdentifier
    }
    public var canRegister: Bool { identifier != nil }
    /// What each switch says when Helm runs from Terminal rather than as an app bundle.
    static let needsApp = "Works only when Helm runs as an app."
    public var isHelmDefault: Bool {
        guard let identifier else { return false }
        return CFPreferencesCopyAppValue(Self.viewerKey, kCFPreferencesAnyApplication) as? String == identifier
    }
    public func makeHelmDefault(_ done: @escaping @MainActor (String?) -> Void) {
        guard let identifier else { done(Self.needsApp); return }
        setViewer(identifier)
        // Folders opened from Spotlight, Dock stacks and `open` go to the app for `public.folder`. macOS 26 refuses
        // to hand that to any app (both NSWorkspace and Launch Services answer with an error, even for Finder), so it's
        // asked for and a refusal isn't treated as a failure. If a later macOS allows it, folders come to Helm too.
        NSWorkspace.shared.setDefaultApplication(at: bundle.bundleURL, toOpen: .folder) { _ in
            Task { @MainActor in done(nil) }
        }
    }
    public func restoreFinder(_ done: @escaping @MainActor (String?) -> Void) {
        setViewer(nil)
        guard opensFolders else { done(nil); return }
        NSWorkspace.shared.setDefaultApplication(at: Self.finder, toOpen: .folder) { error in
            Task { @MainActor in done(error.map { "Finder couldn’t take back folders: \($0.localizedDescription)" }) }
        }
    }
    /// Whether folders opened from other apps come to Helm as well.
    public var opensFolders: Bool {
        guard let identifier else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: .folder).flatMap { Bundle(url: $0)?.bundleIdentifier } == identifier
    }
    private func setViewer(_ identifier: String?) {
        CFPreferencesSetValue(Self.viewerKey, identifier as CFString?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    // MARK: The Dock

    /// macOS keeps Finder's tile first and won't let it go, so Helm can only be the first app after it.
    /// Where Helm was before is remembered, so turning this off puts it back (or out of the Dock, if it wasn't there).
    static let dock = "com.apple.dock" as CFString
    static let dockApps = "persistent-apps" as CFString
    static let dockBackupKey = "helm.dockPlacementBefore"

    private func readDock() -> [[String: Any]] {
        CFPreferencesAppSynchronize(Self.dock)
        return CFPreferencesCopyAppValue(Self.dockApps, Self.dock) as? [[String: Any]] ?? []
    }
    private func isHelm(_ tile: [String: Any]) -> Bool { Self.isHelm(tile, identifier: identifier, app: bundle.bundleURL) }
    /// Helm's tile is first, and it opens this copy: one left pointing at a disk image or an older download doesn't count.
    public var isFirstInDock: Bool {
        guard canRegister, let first = readDock().first else { return false }
        return isHelm(first) && Self.opens(first, app: bundle.bundleURL)
    }
    public func setFirstInDock(_ on: Bool) -> String? {
        guard let identifier else { return Self.needsApp }
        var apps = readDock()
        let defaults = UserDefaults.standard
        if on {
            guard let placed = Self.placingFirst(apps, identifier: identifier, app: bundle.bundleURL) else { return nil }
            // Where Helm was, so turning this off puts it back. A tile that was first already only had its file fixed.
            if placed.from != 0 { defaults.set(placed.from ?? -1, forKey: Self.dockBackupKey) }
            apps = placed.apps
        } else {
            guard let index = apps.firstIndex(where: isHelm) else { return nil }
            let tile = apps.remove(at: index)
            if let before = defaults.object(forKey: Self.dockBackupKey) as? Int, before >= 0 {
                apps.insert(tile, at: min(before, apps.count))
            }
            defaults.removeObject(forKey: Self.dockBackupKey)
        }
        if let problem = writeDock(apps) { return problem }
        settleDock(apps, attempts: 3)
        return nil
    }
    /// Saves the Dock's tiles and restarts it, as `killall Dock` does; it comes straight back and reads them.
    private func writeDock(_ apps: [[String: Any]]) -> String? {
        CFPreferencesSetAppValue(Self.dockApps, apps as CFArray, Self.dock)
        guard CFPreferencesAppSynchronize(Self.dock) else { return "macOS didn’t save the Dock’s settings." }
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["Dock"]
        do { try restart.run() } catch { return "The Dock didn’t restart: \(error.localizedDescription)" }
        return nil
    }
    /// A Dock that restarted moments ago can save its old tiles over the new ones as it quits. Check once it's back,
    /// and write again if it did.
    private func settleDock(_ apps: [[String: Any]], attempts: Int) {
        let helm = identifier
        let wanted = apps.compactMap { Self.tileKey($0, helm: helm) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, attempts > 0, self.readDock().compactMap({ Self.tileKey($0, helm: helm) }) != wanted else { return }
            _ = self.writeDock(apps)
            self.settleDock(apps, attempts: attempts - 1)
        }
    }
    /// What identifies a tile when comparing two lists: its app, or its file. Helm's own tile adds its file, so an old
    /// tile saved back over one that was just pointed at this copy shows up too.
    static func tileKey(_ tile: [String: Any], helm: String? = nil) -> String? {
        guard let data = tile["tile-data"] as? [String: Any] else { return nil }
        if let identifier = data["bundle-identifier"] as? String {
            guard identifier == helm, let path = tilePath(tile) else { return identifier }
            return identifier + " " + BundlePath.normalized(path)
        }
        return (data["file-data"] as? [String: Any])?["_CFURLString"] as? String
    }
    /// The app a tile opens, as a path, when the tile says.
    static func tilePath(_ tile: [String: Any]) -> String? {
        guard let data = tile["tile-data"] as? [String: Any], let file = data["file-data"] as? [String: Any],
              let text = file["_CFURLString"] as? String else { return nil }
        if text.hasPrefix("/") { return text }
        guard let url = URL(string: text), url.isFileURL else { return nil }
        return url.path
    }
    /// Whether a tile is Helm's: by its app's identifier, or by the file it opens.
    static func isHelm(_ tile: [String: Any], identifier: String?, app: URL) -> Bool {
        guard let data = tile["tile-data"] as? [String: Any] else { return false }
        if let identifier, data["bundle-identifier"] as? String == identifier { return true }
        return tilePath(tile).map { BundlePath.normalized($0) == BundlePath.normalized(app.path) } ?? false
    }
    /// Whether a tile opens this copy of the app, however the path is spelled. A tile that doesn't say which file it
    /// opens is taken at its word.
    static func opens(_ tile: [String: Any], app: URL) -> Bool {
        guard let path = tilePath(tile) else { return true }
        let spelled = { (url: URL) in BundlePath.normalized(url.resolvingSymlinksInPath().path) }
        return spelled(URL(fileURLWithPath: path)) == spelled(app)
    }
    /// The Dock's apps with this copy of Helm first, right after Finder. Helm's tile moves up, and one that opens another
    /// copy (on a disk image since ejected, or macOS's temporary copy) is replaced by a tile for this one. `from` is where
    /// Helm's tile was, or nil if it wasn't in the Dock. Nil when this copy is first already.
    static func placingFirst(_ apps: [[String: Any]], identifier: String, app: URL) -> (apps: [[String: Any]], from: Int?)? {
        var apps = apps
        let index = apps.firstIndex { isHelm($0, identifier: identifier, app: app) }
        if index == 0, opens(apps[0], app: app) { return nil }
        let old = index.map { apps.remove(at: $0) }
        let kept = old.flatMap { opens($0, app: app) ? $0 : nil }
        apps.insert(kept ?? tile(for: app, identifier: identifier), at: 0)
        return (apps, index)
    }
    /// A Dock tile for an app, as the Dock writes one when you drag an app in.
    static func tile(for app: URL, identifier: String) -> [String: Any] {
        ["tile-type": "file-tile",
         "tile-data": ["bundle-identifier": identifier, "file-label": "Helm",
                       "file-data": ["_CFURLString": app.absoluteString, "_CFURLStringType": 15] as [String: Any]] as [String: Any]]
    }

    public var opensAtLogin: Bool { canRegister && SMAppService.mainApp.status == .enabled }
    public func setOpensAtLogin(_ on: Bool) -> String? {
        guard canRegister else { return Self.needsApp }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch { return error.localizedDescription }
    }
}

/// A fixture run: nothing outside Helm changes.
@MainActor public final class MemoryFileViewerRole: FileViewerRegistering {
    public private(set) var isHelmDefault = false
    public private(set) var opensAtLogin = false
    public init() {}
    public var canRegister: Bool { true }
    public func makeHelmDefault(_ done: @escaping @MainActor (String?) -> Void) { isHelmDefault = true; done(nil) }
    public func restoreFinder(_ done: @escaping @MainActor (String?) -> Void) { isHelmDefault = false; done(nil) }
    public func setOpensAtLogin(_ on: Bool) -> String? { opensAtLogin = on; return nil }
    public private(set) var isFirstInDock = false
    public func setFirstInDock(_ on: Bool) -> String? { isFirstInDock = on; return nil }
}

/// What the General pane shows and changes.
@MainActor public final class FileViewerModel: ObservableObject {
    @Published public private(set) var isHelmDefault: Bool
    @Published public private(set) var opensAtLogin: Bool
    @Published public private(set) var isFirstInDock: Bool
    @Published public private(set) var problem: String?
    @Published public private(set) var isWorking = false
    public let canRegister: Bool
    private let role: any FileViewerRegistering
    public init(role: any FileViewerRegistering) {
        self.role = role
        canRegister = role.canRegister
        isHelmDefault = role.isHelmDefault
        opensAtLogin = role.opensAtLogin
        isFirstInDock = role.isFirstInDock
    }
    public func refresh() { isHelmDefault = role.isHelmDefault; opensAtLogin = role.opensAtLogin; isFirstInDock = role.isFirstInDock }
    /// `then` hears how it went once macOS has answered: nil, or what went wrong.
    public func setHelmDefault(_ on: Bool, then: (@MainActor (String?) -> Void)? = nil) {
        isWorking = true; problem = nil
        let finish: @MainActor (String?) -> Void = { [weak self] message in
            if let self { self.isWorking = false; self.problem = message; self.refresh() }
            then?(message)
        }
        if on { role.makeHelmDefault(finish) } else { role.restoreFinder(finish) }
    }
    public func setOpensAtLogin(_ on: Bool) {
        problem = role.setOpensAtLogin(on)
        refresh()
    }
    public func setFirstInDock(_ on: Bool) {
        problem = role.setFirstInDock(on)
        // The Dock answers from its saved settings straight away; the restart only redraws it.
        isFirstInDock = problem == nil ? on : role.isFirstInDock
    }
}

/// The General pane's first section.
struct FileViewerSection: View {
    @ObservedObject var model: FileViewerModel
    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: model.isHelmDefault ? "checkmark.seal.fill" : "folder")
                    .font(.system(size: 22)).foregroundStyle(model.isHelmDefault ? Color.accentColor : .secondary)
                    .frame(width: 28)
                    // The headline says which it is.
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isHelmDefault ? "Helm is the default" : "Finder is the default").font(.headline)
                    Text(model.isHelmDefault ? "“Show in Finder” opens Helm." : "“Show in Finder” opens Finder.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if model.isWorking { ProgressView().controlSize(.small) }
                Button(model.isHelmDefault ? "Restore Finder" : "Make Default") { model.setHelmDefault(!model.isHelmDefault) }
                    .disabled(!model.canRegister || model.isWorking)
            }
            Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                .disabled(!model.canRegister)
            // macOS keeps Finder's tile first, so Helm goes right after it. Off puts Helm back where it was.
            Toggle("Show next to Finder in the Dock", isOn: Binding(get: { model.isFirstInDock }, set: { model.setFirstInDock($0) }))
                .disabled(!model.canRegister)
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
        } header: {
            Text("Default File Viewer")
        } footer: {
            // Apps read the file viewer as they start. Finder keeps the desktop, and folders opened from Spotlight or Dock stacks.
            Text("Apps already open keep using Finder until you reopen them.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.refresh() }
    }
}
#endif
