import SwiftUI
import HelmCore

extension SettingsPaneView {
    var general: some View {
        Group {
            #if os(macOS)
            if let fileViewer { FileViewerSection(model: fileViewer) }
            #endif
            Section {
                Picker("New windows open", selection: string(.newWindowLocation)) {
                    ForEach(NewWindowLocation.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Reopen windows and tabs from last time", isOn: bool(.restoreSessionOnLaunch))
                if supportsSingleClick {
                    Toggle("Open items with a single click", isOn: bool(.singleClickToOpen))
                }
            } header: {
                Text("Windows")
            }
            Section {
                Toggle("Ask before moving items to the Trash", isOn: bool(.confirmBeforeTrash))
                Toggle("Ask when an item with the same name is already there", isOn: bool(.askOnConflict))
            } header: {
                Text("Safety")
            } footer: {
                note("Edit › Undo puts items back from the Trash, and undoes moves, copies and renames.")
            }
        }
    }
}
