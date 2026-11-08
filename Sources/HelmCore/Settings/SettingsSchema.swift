import Foundation

/// One schema preserves F-065 keys, with reviewed grid/trash defaults (B-059).
public enum SettingsSchema {
    public static func defaultValue(for key: SettingKey) -> SettingValue {
        switch key {
        case .defaultViewMode: return .string("grid")
        case .defaultSortField: return .string("name")
        case .crossVolumeDragDefault: return .string("copy")
        case .newWindowLocation: return .string("current") // Where the front window is, as before.
        case .gridIconSize: return .double(96)
        case .fileTextSize: return .double(14)
        case .windowTransparency: return .double(50) // Percent. 50 is Helm's own look.
        case .directoryCacheTTL: return .double(1.5)
        case .maxCachedIcons: return .integer(800)
        case .maxCachedThumbnails: return .integer(400)
        case .searchResultLimit: return .integer(300)
        case .searchDebounceMilliseconds: return .integer(180)
        case .completionDebounceMilliseconds: return .integer(100)
        case .defaultSortAscending, .directoriesFirst, .liveMonitoringEnabled,
             .enableDirectoryCache, .searchPreferUserFolders, .restoreSessionOnLaunch,
             .searchFileContents, // Finder matches names and contents.
             .sidebarLiquidGlass, // Transparency is part of Helm's look; this turns it off.
             .askOnConflict: return .bool(true) // Finder asks; a surprise "name 2" isn't what it does (Q9).
        default: return .bool(false)
        }
    }

    public static func appliesLive(_ key: SettingKey) -> Bool {
        switch key {
        case .defaultViewMode, .showHiddenFiles, .defaultSortField, .defaultSortAscending,
             .directoriesFirst, .restoreSessionOnLaunch, .searchPreferUserFolders,
             .searchIncludeSystemLocations, .searchResultLimit, .searchDebounceMilliseconds,
             .completionDebounceMilliseconds, .newWindowLocation, .searchFileContents: return false
        default: return true
        }
    }

    /// Invalid types/enum strings use defaults; numeric values are clamped, never coerced.
    public static func validated(_ value: SettingValue?, for key: SettingKey) -> SettingValue {
        let fallback = defaultValue(for: key)
        guard let value else { return fallback }
        switch (fallback, value) {
        case (.bool, .bool): return value
        case (.string, .string(let text)):
            let allowed: [String]
            switch key {
            case .defaultViewMode: allowed = ["grid", "list"]
            case .defaultSortField: allowed = ["name", "size", "dateModified", "kind"]
            case .crossVolumeDragDefault: allowed = ["copy", "move"]
            case .newWindowLocation: allowed = NewWindowLocation.allCases.map(\.rawValue)
            default: allowed = []
            }
            return allowed.contains(text) ? value : fallback
        case (.integer, .integer(let number)):
            switch key {
            case .maxCachedIcons: return .integer(max(100, number))
            case .maxCachedThumbnails: return .integer(max(50, number))
            case .searchResultLimit: return .integer(min(800, max(50, number)))
            case .searchDebounceMilliseconds: return .integer(min(500, max(40, number)))
            default: return .integer(max(30, number))
            }
        case (.double, .double(let number)):
            guard number.isFinite else { return fallback }
            switch key {
            case .gridIconSize: return .double(min(128, max(48, number)))
            case .fileTextSize: return .double(min(24, max(11, number)))
            case .windowTransparency: return .double(min(100, max(0, number)))
            default: return .double(min(5, max(0.1, number)))
            }
        default: return fallback
        }
    }
}
