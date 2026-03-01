import SwiftUI

struct PreferencesView: View {

    @AppStorage("helm.defaultViewMode") private var defaultViewMode: String = "grid"
    @AppStorage("helm.showHiddenFiles") private var showHiddenFiles: Bool = false
    @AppStorage("helm.confirmBeforeTrash") private var confirmBeforeTrash: Bool = true
    @AppStorage("helm.defaultSortField") private var defaultSortField: String = "name"
    @AppStorage("helm.defaultSortAscending") private var defaultSortAscending: Bool = true
    @AppStorage("helm.directoriesFirst") private var directoriesFirst: Bool = true
    @AppStorage("helm.singleClickToOpen") private var singleClickToOpen: Bool = false
    @AppStorage("helm.gridIconSize") private var gridIconSize: Double = 64

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            behaviorTab
                .tabItem { Label("Behavior", systemImage: "hand.tap") }
        }
        .frame(width: 450, height: 300)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Picker("Default view mode:", selection: $defaultViewMode) {
                Text("Grid").tag("grid")
                Text("List").tag("list")
            }

            Toggle("Show hidden files by default", isOn: $showHiddenFiles)

            Toggle("Confirm before moving to Trash", isOn: $confirmBeforeTrash)

            Picker("Sort by:", selection: $defaultSortField) {
                Text("Name").tag("name")
                Text("Size").tag("size")
                Text("Date Modified").tag("dateModified")
                Text("Kind").tag("kind")
            }

            Toggle("Sort ascending", isOn: $defaultSortAscending)

            Toggle("Directories first", isOn: $directoriesFirst)
        }
        .padding()
    }

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        Form {
            VStack(alignment: .leading) {
                Text("Grid icon size: \(Int(gridIconSize))px")
                Slider(value: $gridIconSize, in: 48...128, step: 16) {
                    Text("Icon Size")
                }
            }

            Text("Colors follow the system appearance (Light/Dark mode)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Behavior Tab

    private var behaviorTab: some View {
        Form {
            Toggle("Single click to open items", isOn: $singleClickToOpen)

            Text("When enabled, a single click opens files and folders (like Nautilus). When disabled, double-click to open (like Finder).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
