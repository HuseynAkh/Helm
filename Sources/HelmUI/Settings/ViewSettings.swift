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
                note(Self.foldersNote)
            }
        }
    }
    /// What the Folders choices apply to. As in Finder, a tab keeps its view as you go from folder to folder, and a new
    /// tab takes the one it came from, so only a new window starts from here (BrowserWindowController.applyRememberedViewOptions).
    static let foldersNote = "New windows use these, except in folders you’ve changed."
    var appearance: some View {
        Group {
            Section {
                sliderRow("Text size", value: textPercent, range: 80...170, step: 10,
                          label: "\(ContentZoom.textPercent(snapshot.double(.fileTextSize)))%")
                sliderRow("Icon size", value: number(.gridIconSize), range: 48...128, step: 16,
                          label: "\(ContentZoom.iconPercent(snapshot.double(.gridIconSize)))%")
            } header: {
                Text("Size")
            }
            Section {
                Toggle("Transparent window", isOn: bool(.sidebarLiquidGlass))
                sliderRow("Transparency", value: number(.windowTransparency), range: 0...100, step: 5,
                          label: "\(Int(snapshot.double(.windowTransparency).rounded()))%")
                    .disabled(!snapshot.bool(.sidebarLiquidGlass))
            } header: {
                Text("Window")
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
