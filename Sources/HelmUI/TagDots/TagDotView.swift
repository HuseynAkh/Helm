// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import SwiftUI
import HelmCore

/// Finder tag color with a spoken name, separate from Helm stars (F-029, M18).
/// Uncolored and unknown tags use an outline without inventing a stored color.
public struct TagDotView: View {
    private let tag: FinderTag
    public init(tag: FinderTag) { self.tag = tag }
    public var body: some View {
        Circle().fill(color ?? Color.clear)
            .overlay { Circle().strokeBorder(Color.secondary, lineWidth: color == nil ? 1 : 0) }
            .frame(width: 8, height: 8)
            .accessibilityLabel(tag.name)
            .help(tag.name)
    }
    private var color: Color? {
        switch tag.color {
        case .gray: return .gray
        case .green: return .green
        case .purple: return .purple
        case .blue: return .blue
        case .yellow: return .yellow
        case .red: return .red
        case .orange: return .orange
        case nil, .some(.none): return nil
        }
    }
}
