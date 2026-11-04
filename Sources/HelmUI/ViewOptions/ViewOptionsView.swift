// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

/// Folder-local controls; the host persists changes and defaults (F-036, F-040, F-065).
public struct ViewOptionsView: View {
    @Binding private var options: ViewOptions
    private let useAsDefaults: (ViewOptions) -> Void
    public init(options: Binding<ViewOptions>, useAsDefaults: @escaping (ViewOptions) -> Void) {
        _options = options; self.useAsDefaults = useAsDefaults
    }
    public var body: some View {
        Form {
            Picker("View Mode", selection: field(\.viewMode)) {
                ForEach(ViewMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Sort By", selection: field(\.sortField)) {
                ForEach(ItemSort.Field.allCases, id: \.self) { Text(ViewOptionsModel.label($0.rawValue)).tag($0) }
            }
            Toggle("Ascending", isOn: field(\.ascending))
            Toggle("Folders first", isOn: field(\.directoriesFirst))
            Picker("Group By", selection: field(\.groupBy)) {
                ForEach(ViewOptionsModel.groups, id: \.self) { Text(ViewOptionsModel.label($0.rawValue)).tag($0) }
            }
            Slider(value: field(\.iconSize), in: 16...512, step: 8) { Text("Icon size") }
            Slider(value: field(\.textSize), in: 9...32, step: 1) { Text("Text size") }
            Section("Show Columns") {
                ForEach(ListColumn.allCases, id: \.self) { column in
                    Toggle(ViewOptionsModel.label(column.rawValue), isOn: columnBinding(column))
                        .disabled(column == .name)
                }
            }
            Button("Use as defaults") { useAsDefaults(options) }
        }
        // MAC-VERIFY: Form sizing and slider accessibility in the hosted popover.
        .formStyle(.grouped).frame(minWidth: 300)
    }
    private func field<Value>(_ keyPath: WritableKeyPath<ViewOptionsModel, Value>) -> Binding<Value> {
        Binding(get: { ViewOptionsModel(options: options)[keyPath: keyPath] }, set: { value in
            var model = ViewOptionsModel(options: options)
            model[keyPath: keyPath] = value
            options = model.options
        })
    }
    private func columnBinding(_ column: ListColumn) -> Binding<Bool> {
        Binding(get: { options.showColumns.contains(column) }, set: { shown in
            var model = ViewOptionsModel(options: options)
            if shown { model.columns.insert(column) } else { model.columns.remove(column) }
            options = model.options
        })
    }
}
