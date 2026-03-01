import Foundation

enum AppSettings {
    private static let defaults: [String: Any] = [
        "helm.liveMonitoringEnabled": true,
        "helm.showAllMountedVolumes": false,
        "helm.enableDirectoryCache": true,
        "helm.directoryCacheTTL": 1.5,
        "helm.maxCachedIcons": 800,
        "helm.searchPreferUserFolders": true,
        "helm.searchIncludeSystemLocations": false,
        "helm.searchResultLimit": 300,
        "helm.searchDebounceMilliseconds": 180,
        "helm.sidebarLiquidGlass": false,
        "helm.maxCachedThumbnails": 400
    ]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: defaults)
    }

    static var liveMonitoringEnabled: Bool {
        UserDefaults.standard.bool(forKey: "helm.liveMonitoringEnabled")
    }

    static var showAllMountedVolumes: Bool {
        UserDefaults.standard.bool(forKey: "helm.showAllMountedVolumes")
    }

    static var directoryCacheEnabled: Bool {
        UserDefaults.standard.bool(forKey: "helm.enableDirectoryCache")
    }

    static var directoryCacheTTL: TimeInterval {
        max(0.1, UserDefaults.standard.double(forKey: "helm.directoryCacheTTL"))
    }

    static var maxCachedIcons: Int {
        let value = UserDefaults.standard.integer(forKey: "helm.maxCachedIcons")
        return max(100, value)
    }

    static var searchPreferUserFolders: Bool {
        UserDefaults.standard.bool(forKey: "helm.searchPreferUserFolders")
    }

    static var searchIncludeSystemLocations: Bool {
        UserDefaults.standard.bool(forKey: "helm.searchIncludeSystemLocations")
    }

    static var searchResultLimit: Int {
        max(50, UserDefaults.standard.integer(forKey: "helm.searchResultLimit"))
    }

    static var searchDebounceNanoseconds: UInt64 {
        let milliseconds = max(40, UserDefaults.standard.integer(forKey: "helm.searchDebounceMilliseconds"))
        return UInt64(milliseconds) * 1_000_000
    }

    static var sidebarLiquidGlassEnabled: Bool {
        UserDefaults.standard.bool(forKey: "helm.sidebarLiquidGlass")
    }

    static var maxCachedThumbnails: Int {
        let value = UserDefaults.standard.integer(forKey: "helm.maxCachedThumbnails")
        return max(50, value)
    }
}
