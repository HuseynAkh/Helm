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
    public init(settings: SettingsStore, bookmarks: any AppBookmarkStoring, stars: any AppStarStoring,
                recents: any AppRecentStoring, trashOrigins: any AppTrashOriginStoring, viewOptions: any AppViewOptionsStoring, fileSystem: any FileSystem,
                operations: OperationCoordinator, home: URL, volumes: VolumeCenter, icons: IconCache,
                clock: any HelmClock, pasteboard: NSPasteboard = .general, persistsWindowFrames: Bool = true) {
        self.pasteboard = pasteboard; self.persistsWindowFrames = persistsWindowFrames
        self.settings = settings; self.bookmarks = bookmarks; self.stars = stars; self.recents = recents
        self.trashOrigins = trashOrigins; self.viewOptions = viewOptions; self.fileSystem = fileSystem; self.operations = operations
        self.home = home; self.volumes = volumes; self.icons = icons; self.clock = clock
    }
}

/// What a window asks of the app: its siblings and anything that outlives it.
@MainActor public protocol BrowserWindowHost: AnyObject {
    func openWindow(at location: Location, selecting: [URL])
    func windowDidClose(_ controller: BrowserWindowController)
    func windowDidBecomeKey(_ controller: BrowserWindowController)
    func showSettings()
    func requestQuitAnyway()
}
#endif
