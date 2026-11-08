import SwiftUI
import HelmCore

extension SettingsPaneView {
    var advanced: some View {
        Group {
            Section {
                Toggle("Update folders when they change on disk", isOn: bool(.liveMonitoringEnabled))
                Picker("Dragging between disks", selection: string(.crossVolumeDragDefault)) {
                    Text("Copies").tag("copy")
                    Text("Moves").tag("move")
                }
            } header: {
                Text("Files")
            } footer: {
                note("Turn updates off on slow network disks to save battery. While dragging, ⌥ copies and ⌘ moves whatever this says.")
            }
            Section {
                Stepper(value: integer(.completionDebounceMilliseconds), in: 30...1000, step: 10) {
                    Text("Suggest folders \(snapshot.integer(.completionDebounceMilliseconds)) ms after you stop typing a path")
                }
            } header: {
                Text("Typing a Path")
            }
            Section {
                Toggle("Remember folder contents briefly", isOn: bool(.enableDirectoryCache))
                LabeledContent("Remember for") {
                    HStack(spacing: 10) {
                        Slider(value: number(.directoryCacheTTL), in: 0.5...5, step: 0.5).frame(minWidth: 160)
                            .accessibilityLabel("Remember folder contents for")
                        Text("\(snapshot.double(.directoryCacheTTL), specifier: "%.1f") s").monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!snapshot.bool(.enableDirectoryCache))
                Stepper(value: integer(.maxCachedIcons), in: 100...4000, step: 100) {
                    Text("Keep up to \(snapshot.integer(.maxCachedIcons)) icons in memory")
                }
                Stepper(value: integer(.maxCachedThumbnails), in: 50...4000, step: 50) {
                    Text("Keep up to \(snapshot.integer(.maxCachedThumbnails)) previews in memory")
                }
            } header: {
                Text("Memory")
            } footer: {
                note("More memory makes going back to a folder faster. Icon and preview limits apply the next time Helm opens.")
            }
        }
    }
}
