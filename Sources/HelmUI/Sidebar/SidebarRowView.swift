// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

/// Closure-driven row retains icon colors and spacing (F-027/F-028).
/// The parent supplies Core's committed deepest-ancestor highlight.
public struct SidebarRowView: View {
    private let place: Place
    private let isSelected: Bool
    private let activate: (Place) -> Void
    private let perform: (SidebarContextAction, Place) -> Void
    public init(place: Place, isSelected: Bool, activate: @escaping (Place) -> Void,
                perform: @escaping (SidebarContextAction, Place) -> Void) {
        self.place = place; self.isSelected = isSelected
        self.activate = activate; self.perform = perform
    }
    public var body: some View {
        Button { activate(place) } label: {
            HStack(spacing: 6) {
                Image(systemName: place.iconName).frame(width: 18).foregroundStyle(iconColor)
                Text(place.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel(place.name)
        // MAC-VERIFY: selected trait announcement and keyboard activation in the hosting sidebar.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            ForEach(SidebarModel.contextActions(for: place), id: \.self) { action in
                Button(action.title) { perform(action, place) }
            }
        }
    }
    private var iconColor: Color {
        switch place.kind {
        case .favorite: return .blue
        case .bookmark: return .orange
        case .starred: return .yellow
        case .device: return .gray
        case .network: return .green
        case .recentRoot, .recent, .trash: return .secondary
        }
    }
}
