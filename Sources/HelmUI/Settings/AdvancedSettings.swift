import SwiftUI
import HelmCore

extension SettingsPaneView {
    var advanced: some View {
        Group {
            Section {
                Toggle("Update folders when they change", isOn: bool(.liveMonitoringEnabled))
                Picker("Dragging between disks", selection: string(.crossVolumeDragDefault)) {
                    Text("Copies").tag("copy")
                    Text("Moves").tag("move")
                }
            } header: {
                Text("Files")
            } footer: {
                note("While dragging, hold ⌥ to copy or ⌘ to move.")
            }
            Section {
                Stepper(value: integer(.completionDebounceMilliseconds), in: 30...1000, step: 10) {
                    Text("Suggest folders \(snapshot.integer(.completionDebounceMilliseconds)) ms after you stop typing")
                }
            } header: {
                Text("Typing a Path")
            }
            // Nothing reads enableDirectoryCache or directoryCacheTTL, so they have no rows. Their keys and defaults stay,
            // so stored settings still read.
            Section {
                Stepper(value: integer(.maxCachedIcons), in: 100...4000, step: 100) {
                    Text("Keep up to \(snapshot.integer(.maxCachedIcons)) icons in memory")
                }
                Stepper(value: integer(.maxCachedThumbnails), in: 50...4000, step: 50) {
                    Text("Keep up to \(snapshot.integer(.maxCachedThumbnails)) previews in memory")
                }
            } header: {
                Text("Memory")
            } footer: {
                note("Changes apply when Helm reopens.")
            }
        }
    }
}
