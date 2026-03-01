import SwiftUI
import UniformTypeIdentifiers

struct SidebarPlacesView: View {
    @ObservedObject var viewModel: SidebarViewModel
    @AppStorage("helm.sidebarLiquidGlass") private var sidebarLiquidGlass = false
    @State private var isDropTargeted = false

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                PlaceRow(place: viewModel.recentsRoot)
                    .tag(viewModel.recentsRoot.id)
            }

            Section("Favorites") {
                ForEach(viewModel.favorites) { place in
                    PlaceRow(place: place)
                        .tag(place.id)
                }
            }

            if !viewModel.bookmarks.isEmpty {
                Section("Bookmarks") {
                    ForEach(viewModel.bookmarks) { place in
                        PlaceRow(place: place)
                            .tag(place.id)
                            .contextMenu {
                                Button("Remove Bookmark") {
                                    viewModel.removeBookmark(place)
                                }
                            }
                    }
                }
            }

            if !viewModel.starred.isEmpty {
                Section("Starred") {
                    ForEach(viewModel.starred) { place in
                        PlaceRow(place: place)
                            .tag(place.id)
                    }
                }
            }

            if !viewModel.devices.isEmpty {
                Section("Devices") {
                    ForEach(viewModel.devices) { place in
                        PlaceRow(place: place)
                            .tag(place.id)
                    }
                }
            }

            Section {
                PlaceRow(place: viewModel.trash)
                    .tag(viewModel.trash.id)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(sidebarLiquidGlass ? .hidden : .automatic)
        .background(sidebarLiquidGlass ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            viewModel.handleBookmarkDrop(providers: providers)
        }
        .overlay(alignment: .bottomLeading) {
            if isDropTargeted {
                Text("Drop Folder to Add Bookmark")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
            }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { viewModel.selectedPlaceID },
            set: { newSelection in
                guard let id = newSelection,
                      let place = viewModel.place(for: id) else { return }
                viewModel.selectPlace(place)
            }
        )
    }
}

struct PlaceRow: View {
    let place: Place

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: place.iconName)
                .frame(width: 18)
                .foregroundStyle(iconColor)
            Text(place.name)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var iconColor: Color {
        switch place.kind {
        case .recentRoot: return .secondary
        case .favorite: return .blue
        case .bookmark: return .orange
        case .starred: return .yellow
        case .recent: return .secondary
        case .device: return .gray
        case .network: return .green
        case .trash: return .secondary
        }
    }
}
