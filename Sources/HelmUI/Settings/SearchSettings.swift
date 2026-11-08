import SwiftUI
import HelmCore

extension SettingsPaneView {
    var search: some View {
        Group {
            Section {
                Toggle("Search inside documents, not just names", isOn: bool(.searchFileContents))
                Toggle("Show results from my own folders first", isOn: bool(.searchPreferUserFolders))
                Toggle("Include macOS system folders", isOn: bool(.searchIncludeSystemLocations))
            } header: {
                Text("Finding Files")
            } footer: {
                note("Searches start in the folder you're in and use Spotlight's index, as Finder does. Names that match come first.")
            }
            Section {
                Stepper(value: integer(.searchResultLimit), in: 50...800, step: 50) {
                    Text("Show up to \(snapshot.integer(.searchResultLimit)) results")
                }
                Stepper(value: integer(.searchDebounceMilliseconds), in: 40...500, step: 20) {
                    Text("Start searching \(snapshot.integer(.searchDebounceMilliseconds)) ms after you stop typing")
                }
            } header: {
                Text("Results")
            }
        }
    }
}
