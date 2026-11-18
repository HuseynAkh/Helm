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
            #if os(macOS)
            Section {
                Picker("Open in Terminal uses", selection: string(.terminalApp)) {
                    ForEach(terminals, id: \.id) { Text($0.name).tag($0.id) }
                }
            } header: {
                Text("Terminal")
            }
            #endif
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

#if os(macOS)
extension SettingsPaneView {
    /// The terminals on this Mac that can open a folder, and the one chosen even when it's gone, so the choice shows.
    var terminals: [TerminalApps.App] {
        var apps = TerminalLocator.installed(folder: FileManager.default.temporaryDirectory)
        let chosen = snapshot.string(.terminalApp)
        if !apps.contains(where: { $0.id == chosen }) {
            apps.append(TerminalApps.App(id: chosen, name: "\(TerminalApps.name(of: chosen)) (not on this Mac)"))
        }
        return apps
    }
}
#endif
