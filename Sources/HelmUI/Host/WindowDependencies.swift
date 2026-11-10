#if os(macOS)
import AppKit
import HelmCore
import HelmFileSystem
import HelmOperations
import HelmPersistence

/// Everything one window needs, supplied by the app. Stores are shared across windows (OK2-8).
@MainActor public struct WindowDependencies {
    public let settings: SettingsStore
    public let bookmarks: any AppBookmarkStoring
    public let stars: any AppStarStoring
    public let recents: any AppRecentStoring
    public let trashOrigins: any AppTrashOriginStoring
    public let viewOptions: any AppViewOptionsStoring
    public let fileSystem: any FileSystem
    public let operations: OperationCoordinator
    public let home: URL
    public let volumes: VolumeCenter
    public let icons: IconCache
    public let clock: any HelmClock
    /// Fixture runs use a private pasteboard and save no window frames, so they leave the user's clipboard and preferences alone.
    public let pasteboard: NSPasteboard
    public let persistsWindowFrames: Bool
    /// The sidebar's order and hidden rows, so every window and Settings › Sidebar show the same thing.
    public let sidebarLayout: SidebarLayoutStore
    /// The apps you've chosen for each kind of file, for Open With.
    public let openWith: OpenWithStore
    /// Which apps open what, handing files to one, and default apps. Unless the app passes the real Mac's, it's a
    /// stand-in that opens nothing and changes no default.
    public let launcher: any AppLaunching
    /// Full Disk Access and the other privacy permissions, shared by every window.
    public let permissions: PermissionCenter
    /// What was cut. The pasteboard is the app's, not a window's, so a cut made in one window moves when it's pasted in another.
    public let cut: CutClipboard
    /// Archives and disk images handed to Archive Utility or DiskImageMounter lately, so what they show comes back here.
    public let handoffs: HelperHandoffs
    public init(settings: SettingsStore, bookmarks: any AppBookmarkStoring, stars: any AppStarStoring,
                recents: any AppRecentStoring, trashOrigins: any AppTrashOriginStoring, viewOptions: any AppViewOptionsStoring, fileSystem: any FileSystem,
                operations: OperationCoordinator, home: URL, volumes: VolumeCenter, icons: IconCache,
                sidebarLayout: SidebarLayoutStore? = nil,
                clock: any HelmClock, pasteboard: NSPasteboard = .general, persistsWindowFrames: Bool = true,
                openWith: OpenWithStore? = nil, permissions: PermissionCenter? = nil, cut: CutClipboard? = nil,
                handoffs: HelperHandoffs? = nil,
                launcher: (any AppLaunching)? = nil) {
        self.cut = cut ?? CutClipboard()
        self.handoffs = handoffs ?? HelperHandoffs(clock: clock)
        self.launcher = launcher ?? MemoryAppLauncher()
        self.pasteboard = pasteboard; self.persistsWindowFrames = persistsWindowFrames
        self.openWith = openWith ?? OpenWithStore()
        self.permissions = permissions ?? PermissionCenter(provider: MemoryPrivacyAccess())
        self.settings = settings; self.bookmarks = bookmarks; self.stars = stars; self.recents = recents
        self.trashOrigins = trashOrigins; self.viewOptions = viewOptions; self.fileSystem = fileSystem; self.operations = operations
        self.home = home; self.volumes = volumes; self.icons = icons; self.clock = clock
        self.sidebarLayout = sidebarLayout ?? SidebarLayoutStore()
    }

    /// Settings › General › Remember recent items. Off, windows add nothing to Recent or to the apps you've used.
    public var remembersRecentItems: Bool { settings.snapshot.bool(.rememberRecentItems) }
    /// Go › Clear Recent: Recent, and the apps you've used for each kind of file.
    public func forgetRecentItems() {
        recents.clear()
        openWith.clear()
    }
}

/// The one cut in progress, shared by every window, as the pasteboard is. Each window draws its own cut items dimmed and
/// lets them go whenever the cut changes, so nothing stays dimmed once the cut is pasted, replaced or cleared.
@MainActor public final class CutClipboard {
    public private(set) var transaction: ClipboardTransaction?
    /// Sent whenever the cut is replaced or cleared, with the window that made the new one, if any.
    public let changes: Broadcast<ObjectIdentifier?> = Broadcast()
    public init() {}
    /// A new cut, made by `owner`. Every other cut item, in any window, stops being drawn as cut.
    public func set(_ transaction: ClipboardTransaction, by owner: AnyObject) {
        self.transaction = transaction
        changes.send(ObjectIdentifier(owner))
    }
    public func clear() {
        transaction = nil
        changes.send(nil)
    }
}

/// What a window asks of the app: its siblings and anything that outlives it.
@MainActor public protocol BrowserWindowHost: AnyObject {
    func openWindow(at location: Location, selecting: [URL])
    func windowDidClose(_ controller: BrowserWindowController)
    func windowDidBecomeKey(_ controller: BrowserWindowController)
    func showSettings()
    /// Opens Settings at one pane, as the sidebar's “Sidebar Settings…” does.
    func showSettings(pane: SettingsPane)
    func requestQuitAnyway()
}
#endif
