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
    public var isHelmDefault: Bool {
        guard let identifier else { return false }
        return CFPreferencesCopyAppValue(Self.viewerKey, kCFPreferencesAnyApplication) as? String == identifier
    }
    public func makeHelmDefault(_ done: @escaping @MainActor (String?) -> Void) {
        guard let identifier else { done("Helm can only become the default file viewer when it runs as an app."); return }
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
    private func isHelm(_ tile: [String: Any]) -> Bool {
        guard let data = tile["tile-data"] as? [String: Any] else { return false }
        if let identifier, data["bundle-identifier"] as? String == identifier { return true }
        if let file = data["file-data"] as? [String: Any], let text = file["_CFURLString"] as? String,
           let url = URL(string: text), url.isFileURL {
            return url.standardizedFileURL.path == bundle.bundleURL.standardizedFileURL.path
        }
        return false
    }
    public var isFirstInDock: Bool { canRegister && readDock().first.map(isHelm) == true }
    public func setFirstInDock(_ on: Bool) -> String? {
        guard let identifier else { return "Helm can only go in the Dock when it runs as an app." }
        var apps = readDock()
        let index = apps.firstIndex(where: isHelm)
        let defaults = UserDefaults.standard
        if on {
            guard index != 0 else { return nil }
            defaults.set(index ?? -1, forKey: Self.dockBackupKey)
            let tile = index.map { apps.remove(at: $0) } ?? Self.tile(for: bundle.bundleURL, identifier: identifier)
            apps.insert(tile, at: 0)
        } else {
            guard let index else { return nil }
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
        let wanted = apps.compactMap(Self.tileKey)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, attempts > 0, self.readDock().compactMap(Self.tileKey) != wanted else { return }
            _ = self.writeDock(apps)
            self.settleDock(apps, attempts: attempts - 1)
        }
    }
    /// What identifies a tile when comparing two lists: its app, or its file.
    static func tileKey(_ tile: [String: Any]) -> String? {
        guard let data = tile["tile-data"] as? [String: Any] else { return nil }
        if let identifier = data["bundle-identifier"] as? String { return identifier }
        return (data["file-data"] as? [String: Any])?["_CFURLString"] as? String
    }
    /// A Dock tile for an app, as the Dock writes one when you drag an app in.
    static func tile(for app: URL, identifier: String) -> [String: Any] {
        ["tile-type": "file-tile",
         "tile-data": ["bundle-identifier": identifier, "file-label": "Helm",
                       "file-data": ["_CFURLString": app.absoluteString, "_CFURLStringType": 15] as [String: Any]] as [String: Any]]
    }

    public var opensAtLogin: Bool { canRegister && SMAppService.mainApp.status == .enabled }
    public func setOpensAtLogin(_ on: Bool) -> String? {
        guard canRegister else { return "Helm can only open at login when it runs as an app." }
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
    public func setHelmDefault(_ on: Bool) {
        isWorking = true; problem = nil
        let finish: @MainActor (String?) -> Void = { [weak self] message in
            guard let self else { return }
            self.isWorking = false; self.problem = message; self.refresh()
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isHelmDefault ? "Helm is your file viewer" : "Finder is your file viewer").font(.headline)
                    Text(model.isHelmDefault
                         ? "“Show in Finder” and “Reveal in Finder” in other apps come to Helm."
                         : "Make Helm the default to send “Show in Finder” from other apps here.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if model.isWorking { ProgressView().controlSize(.small) }
                Button(model.isHelmDefault ? "Restore Finder" : "Make Default") { model.setHelmDefault(!model.isHelmDefault) }
                    .disabled(!model.canRegister || model.isWorking)
            }
            Toggle("Open Helm when you log in", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                .disabled(!model.canRegister)
            Toggle("Show Helm first in the Dock", isOn: Binding(get: { model.isFirstInDock }, set: { model.setFirstInDock($0) }))
                .disabled(!model.canRegister)
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
        } header: {
            Text("Default File Viewer")
        } footer: {
            Text("Apps that are already open keep asking Finder until you quit and reopen them. macOS keeps a few things for Finder: the desktop, its own Dock tile, which stays first (Helm goes right after it), and folders opened from Spotlight or Dock stacks. Turning the Dock switch off puts Helm back where it was.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.refresh() }
    }
}
#endif
