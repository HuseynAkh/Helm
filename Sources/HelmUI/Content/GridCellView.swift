// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
#if canImport(AppKit)
import AppKit
import SwiftUI
import HelmCore

/// Passive F-035 cell: caller resolves icons, tags, selection and cut state by ItemID (B-009/B-056).
public struct GridCellView: View {
    private let entry: FileEntry
    private let icon: Image
    private let tags: [FinderTag]
    private let isSelected: Bool
    private let isCut: Bool
    private let iconSize: CGFloat
    public init(entry: FileEntry, icon: Image, tags: [FinderTag] = [],
                isSelected: Bool = false, isCut: Bool = false, iconSize: CGFloat = 96) {
        self.entry = entry; self.icon = icon; self.tags = tags
        self.isSelected = isSelected; self.isCut = isCut
        self.iconSize = iconSize.isFinite ? min(512, max(16, iconSize)) : 96
    }
    public var body: some View {
        VStack(spacing: 4) {
            icon.resizable().scaledToFit().frame(width: iconSize, height: iconSize)
                .overlay(alignment: .bottomTrailing) { ContentMetadataBadges(entry: entry) }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 3) {
                        ForEach(tags.indices, id: \.self) { index in TagDotView(tag: tags[index]) }
                    }
                }
            Text(entry.name).font(.system(size: 11)).lineLimit(2).truncationMode(.middle)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
        .padding(4).frame(width: iconSize + 44, height: iconSize + 44)
        .opacity(ContentLeafPresentation.opacity(isHidden: entry.isHidden, isCut: isCut))
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Shared badges preserve stars as distinct from Finder tags (F-029/F-035/F-036).
struct ContentMetadataBadges: View {
    let entry: FileEntry
    var body: some View {
        HStack(spacing: 3) {
            if entry.isStarred { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Starred") }
            if let badge = ContentLeafPresentation.cloudBadge(entry.cloudAvailability) {
                Image(systemName: badge.symbol).accessibilityLabel(badge.label).help(badge.label)
            }
        }.font(.system(size: 11))
    }
}
#endif
