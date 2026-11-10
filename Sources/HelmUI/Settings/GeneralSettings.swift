import SwiftUI
import HelmCore

extension SettingsPaneView {
    var general: some View {
        Group {
            #if os(macOS)
            if let access { AccessSection(settings: access) }
            if let fileViewer { FileViewerSection(model: fileViewer) }
            #endif
            Section {
                Picker("New windows open", selection: string(.newWindowLocation)) {
                    ForEach(NewWindowLocation.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Reopen windows and tabs", isOn: bool(.restoreSessionOnLaunch))
                if supportsSingleClick {
                    Toggle("Open with a single click", isOn: bool(.singleClickToOpen))
                }
            } header: {
                Text("Windows")
            }
            Section {
                Toggle("Remember recent items", isOn: bool(.rememberRecentItems))
            } header: {
                Text("Privacy")
            }
            Section {
                Toggle("Ask before moving to the Trash", isOn: bool(.confirmBeforeTrash))
                // Off, Helm keeps both.
                Toggle("Ask when a name is already taken", isOn: bool(.askOnConflict))
            } header: {
                Text("Safety")
            }
        }
    }
}
