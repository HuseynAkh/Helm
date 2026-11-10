// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Injected values keep navigation and search independent of defaults, clocks and I/O (F-005/F-043).
public struct ReducerContext: Sendable {
    public let now: Date
    public let homeDirectory: URL
    public let starredIDs: Set<ItemID>
    public let settings: SettingsSnapshot
    public init(now: Date, homeDirectory: URL, starredIDs: Set<ItemID> = [], settings: SettingsSnapshot = SettingsSnapshot()) {
        self.now = now; self.homeDirectory = homeDirectory; self.starredIDs = starredIDs; self.settings = settings
    }
}
/// Per-tab values isolate history, search and editing, preserving F-002/F-005/F-039 (B-020).
public struct TabState: Sendable, Equatable {
    public let id: TabID
    public var location: Location
    public var history: NavigationHistory
    public var selection: Set<ItemID> = []
    public var selectionSource: SelectionSource = .widget
    public var anchorID: ItemID?
    public var viewMode: ViewMode
    public var sort: ItemSort
    public var showHidden: Bool
    /// Show Hidden Files in Settings, as this tab last saw it. The tab follows the setting when the setting changes;
    /// a change to anything else in Settings leaves the tab's own choice alone, such as hidden items listed for a reveal.
    var hiddenFilesSetting: Bool
    public var expandedIDs: Set<ItemID> = []
    /// Children of expanded folders, re-attached whenever a new root listing arrives (FB2-10).
    var childListings: [ItemID: [FileEntry]] = [:]
    public var search: SearchState?
    public var snapshot: PresentationSnapshot
    public var loadGeneration: Generation = Generation()
    public var monitorGeneration: Generation = Generation()
    /// Shared reload/validation admission identity; adapters return through WindowStore (B-014).
    public var monitorWorkGeneration: Generation = Generation()
    /// True after watch termination; manual refresh/reactivation can retry after exhaustion (B-013).
    public var monitorDegraded: Bool = false
    /// The adapter is between attempts: no watch exists, so it would drop any read admitted now.
    var monitorRetrying: Bool = false
    var monitorValidationPending: Bool = false
    public var searchGeneration: Generation = Generation()
    public var completionGeneration: Generation { addressBar.generation }
    public var pendingNavigation: PendingNavigation?
    public var lastDirectory: URL?
    public var inlineRenameID: ItemID?
    public var snapshotCounter: UInt64 = 0
    public var cutIDs: Set<ItemID> = []
    /// A folder opened in place, by its triangle, whose listing couldn't be read. It closes again, and the status bar
    /// says why until you do something else in the listing.
    public var folderProblem: FolderProblem?
    /// Folders opened by their triangle whose listing hasn't come back yet. One of those that's gone says so; one
    /// that's gone when the list reads it again, renamed or moved to the Trash, just closes.
    var openingIDs: Set<ItemID> = []
    public var addressBar: AddressEditorState
    public var isActive: Bool = true
    public var isLoading: Bool = false
    // Kept independently so load/monitor callbacks cannot overwrite search presentation (B-009).
    var monitorDirty: Bool = false
    var monitorNeedsValidation: Bool = false
    var underlyingSnapshot: PresentationSnapshot?
    var underlyingSelection: Set<ItemID> = []
    var restorationIDs: Set<ItemID>?
    /// Open folders whose listings the last load asked for. Items to select inside them only arrive with those
    /// listings, so `restorationIDs` waits for them before it's let go.
    var awaitedChildren: Set<ItemID> = []
    var deferredSnapshot: PresentationSnapshot?
    public var mutationTarget: URL? { location.mutationTarget }
    /// The folders the view on show draws open. The grid shows only the folder's own items, so none.
    public var shownExpandedIDs: Set<ItemID> { viewMode == .grid ? [] : expandedIDs }
    /// The items on show, top to bottom: the folder's own, and in the list what's inside the folders open there.
    public var shownIDs: [ItemID] { snapshot.visibleIDs(expanding: shownExpandedIDs) }
    /// The order on show. A search's results have their own (Best Match, unless another is chosen while searching),
    /// and the folder keeps its sort for when the search ends.
    public var shownSort: ItemSort { search == nil ? sort : snapshot.sort }

    public init(id: TabID = TabID(), location: Location, homeDirectory: URL,
                history: NavigationHistory = NavigationHistory(), settings: SettingsSnapshot = SettingsSnapshot()) {
        self.id = id; self.location = location; self.history = history
        self.viewMode = settings.defaultViewMode; self.sort = settings.defaultSort
        self.showHidden = settings.showHiddenFiles; self.hiddenFilesSetting = settings.showHiddenFiles
        self.snapshot = PresentationSnapshot(location: location, sort: settings.defaultSort)
        self.lastDirectory = location.mutationTarget
        self.addressBar = AddressEditorState(currentDirectory: location.mutationTarget ?? homeDirectory,
                                             home: homeDirectory, showHidden: settings.showHiddenFiles)
    }
}

/// A folder in the listing that couldn't be opened in place, and why.
public struct FolderProblem: Sendable, Equatable {
    public let url: URL
    public let error: LoadError
    public init(url: URL, error: LoadError) { self.url = url; self.error = error }
}
