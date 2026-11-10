import SwiftUI
import HelmCore

extension SettingsPaneView {
    var search: some View {
        Group {
            Section {
                Toggle("Also search inside documents", isOn: bool(.searchFileContents))
                Toggle("Show results from Home first", isOn: bool(.searchPreferUserFolders))
                Toggle("Include system folders", isOn: bool(.searchIncludeSystemLocations))
            } header: {
                Text("Finding Files")
            }
            Section {
                Stepper(value: integer(.searchResultLimit), in: 50...800, step: 50) {
                    Text("Show up to \(snapshot.integer(.searchResultLimit)) results")
                }
                Stepper(value: integer(.searchDebounceMilliseconds), in: 40...500, step: 20) {
                    Text("Search \(snapshot.integer(.searchDebounceMilliseconds)) ms after you stop typing")
                }
            } header: {
                Text("Results")
            }
        }
    }
}
