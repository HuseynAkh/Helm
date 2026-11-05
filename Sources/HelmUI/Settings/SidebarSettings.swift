// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

extension SettingsPaneView {
    var sidebar: some View {
        Group {
            Toggle("Show all mounted volumes", isOn: bool(.showAllMountedVolumes))
            Text("When disabled, system and recovery helper volumes are filtered out.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Enable liquid glass sidebar", isOn: bool(.sidebarLiquidGlass))
            Text("Applies a translucent, blurred sidebar style.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
