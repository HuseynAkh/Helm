// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

extension SettingsPaneView {
    var viewSettings: some View {
        Group {
            VStack(alignment: .leading) {
                Text("Grid icon size: \(Int(snapshot.double(.gridIconSize)))px")
                Slider(value: number(.gridIconSize), in: 48...128, step: 16) { Text("Icon Size") }
            }
            Text("Colors follow the system appearance (Light/Dark mode)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
