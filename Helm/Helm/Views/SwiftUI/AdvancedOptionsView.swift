import SwiftUI

struct AdvancedOptionsView: View {
    @AppStorage("helm.liveMonitoringEnabled") private var liveMonitoringEnabled = true
    @AppStorage("helm.showAllMountedVolumes") private var showAllMountedVolumes = false
    @AppStorage("helm.enableDirectoryCache") private var enableDirectoryCache = true
    @AppStorage("helm.directoryCacheTTL") private var directoryCacheTTL = 1.5
    @AppStorage("helm.maxCachedIcons") private var maxCachedIcons = 800
    @AppStorage("helm.searchPreferUserFolders") private var searchPreferUserFolders = true
    @AppStorage("helm.searchIncludeSystemLocations") private var searchIncludeSystemLocations = false
    @AppStorage("helm.searchResultLimit") private var searchResultLimit = 300
    @AppStorage("helm.searchDebounceMilliseconds") private var searchDebounceMilliseconds = 180
    @AppStorage("helm.sidebarLiquidGlass") private var sidebarLiquidGlass = false

    var body: some View {
        Form {
            Section("Navigation & Monitoring") {
                Toggle("Enable live folder monitoring", isOn: $liveMonitoringEnabled)
                Text("Turn this off on slow network volumes to reduce CPU and disk wakeups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Devices") {
                Toggle("Show all mounted volumes", isOn: $showAllMountedVolumes)
                Text("When disabled, system and recovery helper volumes are filtered out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Search") {
                Toggle("Prefer user folders", isOn: $searchPreferUserFolders)
                Toggle("Include system locations", isOn: $searchIncludeSystemLocations)

                Stepper(value: $searchResultLimit, in: 100...800, step: 50) {
                    Text("Search result limit: \(searchResultLimit)")
                }

                Stepper(value: $searchDebounceMilliseconds, in: 60...500, step: 20) {
                    Text("Search typing debounce: \(searchDebounceMilliseconds) ms")
                }
            }

            Section("Caching") {
                Toggle("Enable directory caching", isOn: $enableDirectoryCache)

                HStack {
                    Text("Directory cache TTL")
                    Spacer()
                    Text("\(directoryCacheTTL, specifier: "%.1f")s")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $directoryCacheTTL, in: 0.2...5.0, step: 0.1)
                    .disabled(!enableDirectoryCache)

                Stepper(value: $maxCachedIcons, in: 100...4000, step: 100) {
                    Text("Max cached icons: \(maxCachedIcons)")
                }
            }

            Section("Appearance") {
                Toggle("Enable liquid glass sidebar", isOn: $sidebarLiquidGlass)
                Text("Applies a translucent, blurred sidebar style.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 500, height: 440)
    }
}
