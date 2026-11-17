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
    case fileTextSize = "helm.fileTextSize"
    case windowTransparency = "helm.windowTransparency"
    case newWindowLocation = "helm.newWindowLocation"
    case searchFileContents = "helm.searchFileContents"
    /// The welcome window has been seen (or closed), so it doesn't open by itself again.
    case onboardingCompleted = "helm.onboardingCompleted"
    /// The rows Set Up left for the copy it moved into Applications, as "viewer,access,move", or empty. That copy
    /// carries on with them when it opens, even when it's opened by hand rather than by the copy that moved it.
    case setupCarriedRows = "helm.setupCarriedRows"
    /// Recent and the apps you've used for each kind of file. Off, Helm keeps neither.
    case rememberRecentItems = "helm.rememberRecentItems"
    /// AI mode. Off, which it is until the person turns it on, Helm connects to nothing.
    case aiModeEnabled = "helm.aiModeEnabled"
    /// The AI mode screen has been shown once, so it doesn't open by itself again.
    case aiIntroSeen = "helm.aiIntroSeen"
    /// The AI panel's width, as the person last dragged its edge. The panel still starts shut at every launch.
    case agentPanelWidth = "helm.agentPanelWidth"
    /// The code signature's designated requirement of the build that last went through setup, or empty. Another build
    /// is new to macOS, which has forgotten its folder access and Full Disk Access, so setup comes first again.
    case setupBuild = "helm.setupBuild"
    /// How far an onboarding that hasn't finished got: its step, its steps and what was done, as
    /// "access:welcome,access,viewer,ai,done:asked", or empty. The next launch carries on there, as after macOS's
    /// Quit & Reopen once Full Disk Access is switched on.
    case setupProgress = "helm.setupProgress"
}

/// Typed preferences cross actor boundaries without defaults objects (F-065).
public enum SettingValue: Sendable, Equatable, Codable {
    case bool(Bool), integer(Int), double(Double), string(String)
}

/// An injected synchronous reader builds an immutable snapshot (F-065).
public protocol SettingsReading {
    func value(for key: SettingKey) -> SettingValue?
}
