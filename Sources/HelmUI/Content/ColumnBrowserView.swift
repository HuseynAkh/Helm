// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
#if canImport(AppKit)
import AppKit
import SwiftUI
import HelmCore

/// F-038 selection and P-043 column navigation bind directly to Core; loading/preview I/O stays outside.
/// The loader must retain ColumnNavigation.load's request and pass it unchanged to push (B-009).
public struct ColumnBrowserView<Preview: View>: View {
    @Binding private var state: ColumnBrowserState
    private let columnWidth: CGFloat
    private let icon: (FileEntry) -> Image
    private let tags: (ItemID) -> [FinderTag]
    private let navigate: (ColumnNavigation) -> Void
    private let preview: (ItemID) -> Preview
    public init(state: Binding<ColumnBrowserState>, columnWidth: CGFloat = 240,
                icon: @escaping (FileEntry) -> Image, tags: @escaping (ItemID) -> [FinderTag] = { _ in [] },
                navigate: @escaping (ColumnNavigation) -> Void,
                @ViewBuilder preview: @escaping (ItemID) -> Preview) {
        self._state = state
        self.columnWidth = columnWidth.isFinite ? min(800, max(160, columnWidth)) : 240
        self.icon = icon; self.tags = tags; self.navigate = navigate; self.preview = preview
    }
    public var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(state.columns.enumerated()), id: \.element.id) { index, column in
                        self.column(at: index).frame(width: columnWidth).id(column.id)
                        Divider()
                    }
                    if let target = state.previewTarget {
                        preview(target).frame(minWidth: columnWidth, maxHeight: .infinity)
                            .id(target).accessibilityLabel("Preview")
                    }
                }
            }
            .onChange(of: state.activeColumn) { _, index in
                if state.columns.indices.contains(index) {
                    reader.scrollTo(state.columns[index].id, anchor: .trailing)
                }
            }
            .onChange(of: state.previewTarget) { _, target in
                if let target { reader.scrollTo(target, anchor: .trailing) }
            }
        }
        .onMoveCommand { direction in
            switch direction {
            case .left: state.moveLeft()
            case .right: navigate(state.moveRight())
            default: break
            }
        }
    }
    private func column(at index: Int) -> some View {
        let column: BrowserColumn = state.columns[index]
        return ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(column.snapshot.sortedIDs, id: \.self) { id in
                    if let entry = column.snapshot.entry(id) {
                        Button {
                            let flags: NSEvent.ModifierFlags = NSApp.currentEvent?.modifierFlags ?? []
                            navigate(state.select(id, in: index, command: flags.contains(.command),
                                                  shift: flags.contains(.shift)))
                        } label: {
                            HStack(spacing: 0) {
                                ListRowView(entry: entry, icon: icon(entry), tags: tags(id),
                                            isSelected: column.selection.selected.contains(id))
                                if entry.isDirectoryLike {
                                    Image(systemName: "chevron.right").font(.caption).padding(.trailing, 6)
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .accessibilityLabel("Column \(index + 1)")
    }
}
#endif
