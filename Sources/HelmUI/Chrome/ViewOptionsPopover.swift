#if os(macOS)
import AppKit
import SwiftUI
import HelmCore

/// What the view options popover shows. The window rebuilds it after every change, so the popover stays open and current.
struct HeaderViewOptionsState: Equatable {
    var sort: ItemSort = .defaultSort
    var searching = false
    var showHidden = false
    var isGrid = true
    var textPoints = ContentZoom.defaultTextPoints
    var iconPixels = ContentZoom.defaultIconPixels
}

@MainActor final class HeaderViewOptionsModel: ObservableObject {
    @Published var state = HeaderViewOptionsState()
    var pressSort: (ItemSort.Field) -> Void = { _ in }
    var toggleFoldersFirst: () -> Void = {}
    var toggleHidden: () -> Void = {}
    var stepText: (Int) -> Void = { _ in }
    var resetText: () -> Void = {}
    var stepIcons: (Int) -> Void = { _ in }
    var resetIcons: () -> Void = {}
}

/// Nautilus's view options popover: sort by a field and press it again to reverse it, then sizes you can step through
/// with the current percentage between the buttons.
struct HeaderViewOptionsView: View {
    @ObservedObject var model: HeaderViewOptionsModel

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 2) {
            heading("Sort by")
            if state.searching {
                SortRow(title: "Best Match", active: state.sort.field == .relevance, detail: nil, ascending: nil) { model.pressSort(.relevance) }
            }
            ForEach(SortField.all) { field in
                let active = state.sort.field == field.field
                SortRow(title: field.title, active: active,
                        detail: active ? SortField.direction(field.field, ascending: state.sort.ascending) : nil,
                        ascending: active ? state.sort.ascending : nil) { model.pressSort(field.field) }
            }
            Text("Press the current sort again to reverse it.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 2)
            Divider().padding(.vertical, 8)
            SwitchRow(title: "Folders on top", isOn: state.sort.directoriesFirst) { model.toggleFoldersFirst() }
            SwitchRow(title: "Show hidden files", isOn: state.showHidden) { model.toggleHidden() }
            Divider().padding(.vertical, 8)
            ZoomRow(title: "Text size", percent: ContentZoom.textPercent(state.textPoints),
                    canShrink: ContentZoom.canStepText(state.textPoints, by: -1), canGrow: ContentZoom.canStepText(state.textPoints, by: 1),
                    step: model.stepText, reset: model.resetText)
            if state.isGrid {
                ZoomRow(title: "Icon size", percent: ContentZoom.iconPercent(state.iconPixels),
                        canShrink: ContentZoom.canStepIcons(state.iconPixels, by: -1), canGrow: ContentZoom.canStepIcons(state.iconPixels, by: 1),
                        step: model.stepIcons, reset: model.resetIcons)
            }
        }
        .padding(10)
        .frame(width: 290)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.bottom, 4)
    }
}

/// A row that lights up under the pointer, like a libadwaita popover row.
private struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SortRow: View {
    let title: String
    let active: Bool
    let detail: String?
    let ascending: Bool?
    let action: () -> Void
    var body: some View {
        HoverRow(action: action) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).opacity(active ? 1 : 0).frame(width: 14)
            Text(title).font(.system(size: 14, weight: active ? .semibold : .regular))
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if let ascending {
                Image(systemName: ascending ? "arrow.up" : "arrow.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(active ? "Press again to reverse" : "Sort by \(title.lowercased())")
    }
}

private struct SwitchRow: View {
    let title: String
    let isOn: Bool
    let toggle: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.system(size: 14))
            Spacer()
            Toggle(title, isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
    }
}

/// − 100% +, where the percentage itself resets to 100%.
private struct ZoomRow: View {
    let title: String
    let percent: Int
    let canShrink: Bool
    let canGrow: Bool
    let step: (Int) -> Void
    let reset: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 14))
            Spacer()
            RoundButton(symbol: "minus", label: "Smaller \(title.lowercased())", enabled: canShrink) { step(-1) }
            Button(action: reset) {
                Text("\(percent)%").font(.system(size: 13, weight: .medium).monospacedDigit())
                    .frame(width: 50, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(percent == 100 ? 0 : 0.06)))
            }
            .buttonStyle(.plain)
            .help(percent == 100 ? "\(title) is at the default" : "Reset \(title.lowercased()) to 100%")
            .accessibilityLabel("\(title) \(percent) percent. Reset to 100 percent.")
            RoundButton(symbol: "plus", label: "Larger \(title.lowercased())", enabled: canGrow) { step(1) }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
    }
}

private struct RoundButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hovering && enabled ? 0.14 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Owns the popover so the window can refresh it while it's open.
@MainActor final class ViewOptionsPopover: NSObject, NSPopoverDelegate {
    let model = HeaderViewOptionsModel()
    private var popover: NSPopover?
    var onClose: (() -> Void)?
    var isShown: Bool { popover?.isShown == true }

    func show(from view: NSView) {
        if isShown { popover?.performClose(nil); return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: HeaderViewOptionsView(model: model))
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        self.popover = popover
    }
    func close() { popover?.performClose(nil) }
    var contentView: NSView? { popover?.contentViewController?.view }
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        onClose?()
    }
}
#endif
