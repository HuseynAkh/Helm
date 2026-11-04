// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
#if canImport(AppKit)
import AppKit
import SwiftUI
import HelmCore

/// Passive F-036 name-column leaf; the outline adapter owns disclosure, sorting and other columns.
public struct ListRowView: View {
    private let entry: FileEntry
    private let icon: Image
    private let tags: [FinderTag]
    private let isSelected: Bool
    private let isCut: Bool
    public init(entry: FileEntry, icon: Image, tags: [FinderTag] = [],
                isSelected: Bool = false, isCut: Bool = false) {
        self.entry = entry; self.icon = icon; self.tags = tags
        self.isSelected = isSelected; self.isCut = isCut
    }
    public var body: some View {
        HStack(spacing: 6) {
            icon.resizable().scaledToFit().frame(width: 18, height: 18)
            Text(entry.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            ContentMetadataBadges(entry: entry)
            Spacer(minLength: 0)
            ForEach(tags.indices, id: \.self) { index in TagDotView(tag: tags[index]) }
        }
        .padding(.horizontal, 4).frame(height: 24)
        .opacity(ContentLeafPresentation.opacity(isHidden: entry.isHidden, isCut: isCut))
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
