import Foundation

/// Exact persisted preference names retained for F-065 and B-059.
public enum SettingKey: String, CaseIterable, Sendable, Codable {
    case defaultViewMode = "helm.defaultViewMode"
    case showHiddenFiles = "helm.showHiddenFiles"
    case confirmBeforeTrash = "helm.confirmBeforeTrash"
    case defaultSortField = "helm.defaultSortField"
    case defaultSortAscending = "helm.defaultSortAscending"
    case directoriesFirst = "helm.directoriesFirst"
    case singleClickToOpen = "helm.singleClickToOpen"
    case gridIconSize = "helm.gridIconSize"
    case liveMonitoringEnabled = "helm.liveMonitoringEnabled"
    case showAllMountedVolumes = "helm.showAllMountedVolumes"
    case enableDirectoryCache = "helm.enableDirectoryCache"
    case directoryCacheTTL = "helm.directoryCacheTTL"
    case maxCachedIcons = "helm.maxCachedIcons"
    case maxCachedThumbnails = "helm.maxCachedThumbnails"
    case searchPreferUserFolders = "helm.searchPreferUserFolders"
    case searchIncludeSystemLocations = "helm.searchIncludeSystemLocations"
    case searchResultLimit = "helm.searchResultLimit"
    case searchDebounceMilliseconds = "helm.searchDebounceMilliseconds"
    case sidebarLiquidGlass = "helm.sidebarLiquidGlass"
    case completionDebounceMilliseconds = "helm.completionDebounceMilliseconds"
    case crossVolumeDragDefault = "helm.crossVolumeDragDefault"
    case askOnConflict = "helm.askOnConflict"
    case restoreSessionOnLaunch = "helm.restoreSessionOnLaunch"
}

/// Typed preferences cross actor boundaries without defaults objects (F-065).
public enum SettingValue: Sendable, Equatable, Codable {
    case bool(Bool), integer(Int), double(Double), string(String)
}

/// An injected synchronous reader builds an immutable snapshot (F-065).
public protocol SettingsReading {
    func value(for key: SettingKey) -> SettingValue?
}
