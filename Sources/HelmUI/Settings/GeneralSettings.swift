// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

extension SettingsPaneView {
    var general: some View {
        Group {
            Picker("Default view mode:", selection: string(.defaultViewMode)) {
                Text("Grid").tag("grid")
                Text("List").tag("list")
            }
            Toggle("Show hidden files by default", isOn: bool(.showHiddenFiles))
            Toggle("Confirm before moving to Trash", isOn: bool(.confirmBeforeTrash))
            Picker("Sort by:", selection: string(.defaultSortField)) {
                Text("Name").tag("name")
                Text("Size").tag("size")
                Text("Date Modified").tag("dateModified")
                Text("Kind").tag("kind")
            }
            Toggle("Sort ascending", isOn: bool(.defaultSortAscending))
            Toggle("Directories first", isOn: bool(.directoriesFirst))
            Toggle("Restore session on launch", isOn: bool(.restoreSessionOnLaunch))
            Toggle("Ask when files conflict", isOn: bool(.askOnConflict))
            if supportsSingleClick {
                Toggle("Single click to open items", isOn: bool(.singleClickToOpen))
                Text("When enabled, a single click opens files and folders (like Nautilus). When disabled, double-click to open (like Finder).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
