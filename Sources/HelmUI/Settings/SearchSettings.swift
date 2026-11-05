// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

extension SettingsPaneView {
    var search: some View {
        Group {
            Toggle("Prefer user folders", isOn: bool(.searchPreferUserFolders))
            Toggle("Include system locations", isOn: bool(.searchIncludeSystemLocations))
            Stepper(value: integer(.searchResultLimit), in: 50...800, step: 50) {
                Text("Search result limit: \(snapshot.integer(.searchResultLimit))")
            }
            Stepper(value: integer(.searchDebounceMilliseconds), in: 40...500, step: 20) {
                Text("Search typing debounce: \(snapshot.integer(.searchDebounceMilliseconds)) ms")
            }
        }
    }
}
