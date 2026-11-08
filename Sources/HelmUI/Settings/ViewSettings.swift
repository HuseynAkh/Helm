import SwiftUI
import HelmCore

extension SettingsPaneView {
    var viewSettings: some View {
        Group {
            Section {
                Picker("View as", selection: string(.defaultViewMode)) {
                    Text("Grid").tag("grid")
                    Text("List").tag("list")
                }
                .pickerStyle(.segmented)
                Picker("Sort by", selection: string(.defaultSortField)) {
                    ForEach(SortField.all) { Text($0.title).tag($0.field.rawValue) }
                }
                Picker("Order", selection: bool(.defaultSortAscending)) {
                    Text(SortField.direction(sortField, ascending: true)).tag(true)
                    Text(SortField.direction(sortField, ascending: false)).tag(false)
                }
                Toggle("Keep folders on top", isOn: bool(.directoriesFirst))
                Toggle("Show hidden files", isOn: bool(.showHiddenFiles))
            } header: {
                Text("Folders")
            } footer: {
                note("Folders start out this way. A folder you've changed keeps its own view.")
            }
            Section {
                Toggle("Show system and recovery volumes", isOn: bool(.showAllMountedVolumes))
            } header: {
                Text("Sidebar")
            } footer: {
                note("macOS mounts helper volumes of its own. Helm leaves them out unless this is on.")
            }
        }
    }
    var appearance: some View {
        Group {
            Section {
                sliderRow("Text size", value: textPercent, range: 80...170, step: 10,
                          label: "\(ContentZoom.textPercent(snapshot.double(.fileTextSize)))%")
                sliderRow("Icon size", value: number(.gridIconSize), range: 48...128, step: 16,
                          label: "\(ContentZoom.iconPercent(snapshot.double(.gridIconSize)))%")
            } header: {
                Text("Size")
            } footer: {
                note("⌘+ and ⌘− change these too. Click the percentage in View Options to go back to 100%.")
            }
            Section {
                Toggle("Transparent window", isOn: bool(.sidebarLiquidGlass))
                sliderRow("Transparency", value: number(.windowTransparency), range: 0...100, step: 5,
                          label: "\(Int(snapshot.double(.windowTransparency).rounded()))%")
                    .disabled(!snapshot.bool(.sidebarLiquidGlass))
            } header: {
                Text("Window")
            } footer: {
                note("50% is Helm's own look. The sidebar clears first, then the files. Colors follow Light and Dark mode.")
            }
        }
    }
    private var sortField: ItemSort.Field { ItemSort.Field(rawValue: snapshot.string(.defaultSortField)) ?? .name }
    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step).frame(minWidth: 160)
                Text(label).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
        }
    }
    /// Text size as a percentage, stored in points.
    private var textPercent: Binding<Double> {
        Binding(get: { Double(ContentZoom.textPercent(snapshot.double(.fileTextSize))) },
                set: { change(.fileTextSize, .double(ContentZoom.textPoints(percent: Int($0.rounded())))) })
    }
}
