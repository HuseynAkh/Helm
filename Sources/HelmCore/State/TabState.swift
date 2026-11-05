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
    public var expandedIDs: Set<ItemID> = []
    public var search: SearchState?
    public var snapshot: PresentationSnapshot
    public var loadGeneration: Generation = Generation()
    public var monitorGeneration: Generation = Generation()
    public var searchGeneration: Generation = Generation()
    public var completionGeneration: Generation { addressBar.generation }
    public var pendingNavigation: PendingNavigation?
    public var lastDirectory: URL?
    public var inlineRenameID: ItemID?
    public var snapshotCounter: UInt64 = 0
    public var cutIDs: Set<ItemID> = []
    public var addressBar: AddressEditorState
    public var isActive: Bool = true
    public var isLoading: Bool = false
    // Kept independently so load/monitor callbacks cannot overwrite search presentation (B-009).
    var monitorDirty: Bool = false
    var monitorNeedsValidation: Bool = false
    var underlyingSnapshot: PresentationSnapshot?
    var underlyingSelection: Set<ItemID> = []
    var restorationIDs: Set<ItemID>?
    var deferredSnapshot: PresentationSnapshot?
    public var mutationTarget: URL? { location.mutationTarget }

    public init(id: TabID = TabID(), location: Location, homeDirectory: URL,
                history: NavigationHistory = NavigationHistory(), settings: SettingsSnapshot = SettingsSnapshot()) {
        self.id = id; self.location = location; self.history = history
        self.viewMode = settings.defaultViewMode; self.sort = settings.defaultSort
        self.showHidden = settings.showHiddenFiles
        self.snapshot = PresentationSnapshot(location: location, sort: settings.defaultSort)
        self.lastDirectory = location.mutationTarget
        self.addressBar = AddressEditorState(currentDirectory: location.mutationTarget ?? homeDirectory,
                                             home: homeDirectory, showHidden: settings.showHiddenFiles)
    }
}
