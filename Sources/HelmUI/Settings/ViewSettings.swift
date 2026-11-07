// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

extension SettingsPaneView {
    var viewSettings: some View {
        Group {
            VStack(alignment: .leading) {
                Text("File and folder text size: \(ContentZoom.textPercent(snapshot.double(.fileTextSize)))%")
                Slider(value: textPercent, in: 80...170, step: 10) { Text("Text Size") }
            }
            VStack(alignment: .leading) {
                Text("Grid icon size: \(ContentZoom.iconPercent(snapshot.double(.gridIconSize)))%")
                Slider(value: number(.gridIconSize), in: 48...128, step: 16) { Text("Icon Size") }
            }
            Toggle("Transparent window", isOn: bool(.sidebarLiquidGlass))
            VStack(alignment: .leading) {
                Text("Transparency: \(Int(snapshot.double(.windowTransparency).rounded()))%")
                Slider(value: number(.windowTransparency), in: 0...100, step: 5) {
                    Text("Transparency")
                } minimumValueLabel: {
                    Text("Solid").font(.caption)
                } maximumValueLabel: {
                    Text("Clear").font(.caption)
                }
                Text("50% is Helm's own look. The sidebar clears first, then the files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!snapshot.bool(.sidebarLiquidGlass))
            Text("Colors follow the system appearance (Light/Dark mode)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    /// Text size as a percentage, stored in points.
    private var textPercent: Binding<Double> {
        Binding(get: { Double(ContentZoom.textPercent(snapshot.double(.fileTextSize))) },
                set: { change(.fileTextSize, .double(ContentZoom.textPoints(percent: Int($0.rounded())))) })
    }
}
