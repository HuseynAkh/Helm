// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

extension SettingsPaneView {
    var advanced: some View {
        Group {
            Section("Navigation & Monitoring") {
                Toggle("Enable live folder monitoring", isOn: bool(.liveMonitoringEnabled))
                Text("Turn this off on slow network volumes to reduce CPU and disk wakeups.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: integer(.completionDebounceMilliseconds), in: 30...1000, step: 10) {
                    Text("Path completion debounce: \(snapshot.integer(.completionDebounceMilliseconds)) ms")
                }
                Picker("Drag between volumes:", selection: string(.crossVolumeDragDefault)) {
                    Text("Copy").tag("copy")
                    Text("Move").tag("move")
                }
            }
            Section("Caching") {
                Toggle("Enable directory caching", isOn: bool(.enableDirectoryCache))
                HStack {
                    Text("Directory cache TTL")
                    Spacer()
                    Text("\(snapshot.double(.directoryCacheTTL), specifier: "%.1f")s")
                        .foregroundStyle(.secondary)
                }
                Slider(value: number(.directoryCacheTTL), in: 0.1...5, step: 0.1)
                    .accessibilityLabel("Directory cache TTL")
                    .disabled(!snapshot.bool(.enableDirectoryCache))
                Stepper(value: integer(.maxCachedIcons), in: 100...4000, step: 100) {
                    Text("Max cached icons: \(snapshot.integer(.maxCachedIcons))")
                }
                Stepper(value: integer(.maxCachedThumbnails), in: 50...4000, step: 50) {
                    Text("Max cached thumbnails: \(snapshot.integer(.maxCachedThumbnails))")
                }
            }
        }
    }
}
