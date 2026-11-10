import SwiftUI
import HelmCore

extension SettingsPaneView {
    /// Settings › Sidebar without a window's stores, as previews and tests build it: the drives switch alone.
    var sidebarSettings: some View {
        Section {
            Toggle(SidebarSettingsText.volumesSwitch, isOn: bool(.showAllMountedVolumes))
        } header: {
            Text("Locations")
        }
    }
}

/// The pane's words, in one place.
enum SidebarSettingsText {
    /// Recovery, Preboot and the other volumes macOS mounts for itself. One line beside its switch in the narrow column.
    static let volumesSwitch = "Show system volumes"
    /// Under both columns. Restore Defaults shows every row again, in its original order; bookmarks keep theirs.
    static let restore = "Drag to reorder, or uncheck to hide."
    static func empty(_ group: SidebarGroup) -> String {
        switch group {
        case .favorites: return "Nothing to show."
        case .bookmarks: return "Drag a folder into the sidebar, or choose Go › Add to Sidebar."
        // The header says what ⌘D does here, and one line leaves no word on its own.
        case .starred: return "Select an item and press ⌘D."
        case .locations: return "Connected drives and cloud folders appear here."
        }
    }
}

#if os(macOS)
import AppKit
import HelmPersistence
import UniformTypeIdentifiers

/// What Settings › Sidebar shows: every row of every group, hidden ones too, in your order.
/// Changes go to the same shared stores the sidebars draw from, so every window follows at once, and the pane
/// follows changes made in a window.
@MainActor public final class SidebarSettingsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let place: Place
        let isShown: Bool
        var id: String { place.id }
        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.place.id == rhs.place.id && lhs.place.name == rhs.place.name && lhs.place.iconName == rhs.place.iconName
                && lhs.isShown == rhs.isShown
        }
    }
    struct GroupRows: Identifiable, Equatable {
        let group: SidebarGroup
        let rows: [Row]
        var id: String { group.rawValue }
    }
    /// The rows as the pane shows them: as they're saved, with a row being dragged where the pointer has it.
    @Published private(set) var groups: [GroupRows] = []
    @Published private(set) var showsAllVolumes = false
    /// Whether Restore Defaults would change anything.
    @Published private(set) var canRestore = false
    /// Called when a group gains or loses rows, so the window can grow or shrink to fit them.
    var rowsChanged: (() -> Void)?
    private let dependencies: WindowDependencies
    private var subscriptions: [Any] = []
    /// The rows as the stores have them.
    private var saved: [GroupRows] = []
    /// The row being dragged in the pane, and where it goes if it's let go of now. Nothing is saved until it's let
    /// go of over its own group, so a drag that's cancelled, or let go of anywhere else, changes nothing.
    private var dragging: Place?
    private var pending: SidebarMove?
    private var drags = 0

    public init(dependencies: WindowDependencies) {
        self.dependencies = dependencies
        refresh()
        subscriptions.append(dependencies.sidebarLayout.changes.subscribe { [weak self] _ in self?.refresh() })
        subscriptions.append(dependencies.bookmarks.changes.subscribe { [weak self] _ in self?.refresh() })
        subscriptions.append(dependencies.stars.changes.subscribe { [weak self] _ in self?.refresh() })
        subscriptions.append(dependencies.volumes.changes.subscribe { [weak self] _ in self?.refresh() })
        subscriptions.append(dependencies.settings.changes.subscribe { [weak self] _ in self?.refresh() })
    }

    private func refresh() {
        let places = dependencies.placesModel()
        let next = SidebarGroup.allCases.map { group in
            GroupRows(group: group, rows: places.arranged(group).map { Row(place: $0, isShown: !places.layout.isHidden($0.id)) })
        }
        let resized = next.map(\.rows.count) != saved.map(\.rows.count)
        saved = next
        publish()
        let showsAll = dependencies.settings.snapshot.bool(.showAllMountedVolumes)
        if showsAll != showsAllVolumes { showsAllVolumes = showsAll }
        if places.isCustomized != canRestore { canRestore = places.isCustomized }
        if resized { rowsChanged?() }
    }
    private func publish() {
        let next = saved.map { group -> GroupRows in
            guard let pending, group.rows.contains(where: { $0.id == pending.id }) else { return group }
            let rows = Dictionary(group.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return GroupRows(group: group.group, rows: pending.applied(to: group.rows.map(\.id)).compactMap { rows[$0] })
        }
        if next != groups { groups = next }
    }

    public func setShown(_ place: Place, _ shown: Bool) { dependencies.setSidebarRow(place, shown: shown) }
    /// Move Up and Move Down, from a row's menu and from VoiceOver.
    public func step(_ place: Place, by delta: Int) {
        apply(SidebarMove.step(place.id, by: delta, in: ids(of: place.group)), in: place.group)
    }
    func canStep(_ place: Place, by delta: Int) -> Bool { SidebarMove.step(place.id, by: delta, in: ids(of: place.group)) != nil }
    public func restoreDefaults() { dependencies.sidebarLayout.restoreDefaults() }
    public func setShowsAllVolumes(_ on: Bool) { dependencies.settings.set(.bool(on), for: .showAllMountedVolumes) }

    // MARK: Dragging a row within its group

    public func beginDrag(_ place: Place) {
        dragging = place
        pending = nil
        drags += 1
        publish()
        watchForEnd(of: drags)
    }
    /// A group takes a drop only of one of its own rows.
    public func canDrop(in group: SidebarGroup) -> Bool { dragging?.group == group }
    /// The pointer is over the row at `index` in the dragged row's group: the dragged row takes its place for now,
    /// and the others make room. Every window's sidebar stays as it is until the row is let go of.
    public func dragOver(_ group: SidebarGroup, at index: Int) {
        guard let dragging, dragging.group == group else { return }
        let next = SidebarMove.placing(dragging.id, at: index, in: ids(of: group))
        guard next != pending else { return }
        pending = next
        publish()
    }
    /// The pointer has left the group, or the drag was cancelled: the rows go back to how they're saved.
    public func dragLeft() {
        guard pending != nil else { return }
        pending = nil
        publish()
    }
    /// Let go of over its own group: the row goes where it's shown, and every window follows.
    @discardableResult public func drop(in group: SidebarGroup) -> Bool {
        guard let dragging, dragging.group == group else { endDrag(); return false }
        let move = pending
        endDrag()
        apply(move, in: group)
        return true
    }
    /// The drag is over without a drop.
    public func endDrag() {
        dragging = nil
        pending = nil
        publish()
    }
    /// SwiftUI doesn't say when a drag ends without a drop. Once the mouse button is up and a drop has had time to
    /// land, a drag that's still going was cancelled or let go of somewhere else. A scripted drag has no button down.
    private func watchForEnd(of drag: Int) {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        Task { @MainActor [weak self] in
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, self.drags == drag, self.dragging != nil else { return }
            self.endDrag()
        }
    }

    /// The group's rows as they're saved, so a move is worked out from what's saved, not from a drag on show.
    private func ids(of group: SidebarGroup) -> [String] { rows(of: group, in: saved).map(\.id) }
    private func rows(of group: SidebarGroup, in groups: [GroupRows]) -> [Row] { groups.first { $0.group == group }?.rows ?? [] }
    private func apply(_ move: SidebarMove?, in group: SidebarGroup) {
        let rows = rows(of: group, in: saved)
        guard let move, let place = rows.first(where: { $0.id == move.id })?.place else { return }
        dependencies.moveSidebarRow(place, before: move.anchor.flatMap { anchor in rows.first { $0.id == anchor }?.place })
    }

    /// Dragged rows carry their ID in a type of Helm's own, which no other app takes, so a row let go of
    /// anywhere else does nothing. It's a dynamic type, so nothing needs declaring in Info.plist.
    static let dragType = UTType(filenameExtension: "helm-sidebar-row", conformingTo: .data) ?? .data
    static func dragItem(_ place: Place) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: dragType.identifier, visibility: .all) { completion in
            completion(Data(place.id.utf8), nil)
            return nil
        }
        return provider
    }

    // MARK: For the smoke run

    /// One group's rows as the pane shows them.
    public func rowsForTesting(_ group: SidebarGroup) -> [(name: String, isShown: Bool)] {
        rows(of: group, in: groups).map { ($0.place.name, $0.isShown) }
    }
    public func placeForTesting(_ group: SidebarGroup, named name: String) -> Place? {
        rows(of: group, in: groups).first { $0.place.name == name }?.place
    }
    /// Where a row is in the pane, which is where the pointer is when it's over that row.
    public func indexForTesting(of place: Place) -> Int? {
        rows(of: place.group, in: groups).firstIndex { $0.id == place.id }
    }
    public var canRestoreForTesting: Bool { canRestore }
}

/// Settings › Sidebar: each group's rows with a checkbox to show or hide them and a handle to drag them by,
/// the drives switch, and Restore Defaults. Favorites, the longest group, has the left column to itself and the
/// others follow on the right in the sidebar's order. The window grows to fit them all, up to the screen's height.
struct SidebarSettingsView: View {
    @ObservedObject var model: SidebarSettingsModel
    static let width: CGFloat = 560
    fileprivate static let columns: [[SidebarGroup]] = [[.favorites], [.bookmarks, .starred, .locations]]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Self.columns, id: \.self) { groups in SidebarSettingsColumn(model: model, groups: groups) }
            }
            SidebarSettingsBar(model: model)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
    }

    /// The pane's height with every row in view: the taller column and the bar below it, and never less than the
    /// pane's usual height. Measured from the pane's own views, so it holds whatever size the system draws rows at.
    static func height(for model: SidebarSettingsModel) -> CGFloat {
        func measured(_ view: some View, width: CGFloat) -> CGFloat {
            NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true).frame(width: width)).fittingSize.height
        }
        let tallest = columns.map { measured(SidebarSettingsColumn(model: model, groups: $0), width: width / CGFloat(columns.count)) }.max() ?? 0
        return max(SettingsPane.sidebar.height, (tallest + measured(SidebarSettingsBar(model: model), width: width)).rounded(.up))
    }
}

extension SettingsWindowController {
    /// Gives Settings › Sidebar the windows' stores: it then lists every row, and the window grows to show them all.
    public func showSidebarRows(_ model: SidebarSettingsModel) {
        guard sidebarModel == nil else { return }
        let host = NSHostingController(rootView: SidebarSettingsView(model: model))
        host.sizingOptions = []
        replacePane(.sidebar, with: host) { SidebarSettingsView.height(for: model) }
        model.rowsChanged = { [weak self] in self?.fitPane() }
    }
    /// What Settings › Sidebar shows and changes, once it has the windows' stores.
    public var sidebarModel: SidebarSettingsModel? {
        (paneController(.sidebar) as? NSHostingController<SidebarSettingsView>)?.rootView.model
    }
    /// For the smoke run: each area of Settings › Sidebar that could scroll, with the height of what it holds and of
    /// what's in view. The pane fits when every area has all of it in view.
    public var sidebarScrollAreasForTesting: [(content: CGFloat, visible: CGFloat)] {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
        }
        guard let view = paneController(.sidebar)?.view else { return [] }
        return scrollViews(in: view).compactMap { scroll in
            guard let document = scroll.documentView else { return nil }
            let insets = scroll.contentInsets
            return (document.frame.height, scroll.contentView.bounds.height - insets.top - insets.bottom)
        }
    }
}

/// One column of the pane: a grouped form with a section for each of its groups.
private struct SidebarSettingsColumn: View {
    @ObservedObject var model: SidebarSettingsModel
    let groups: [SidebarGroup]

    var body: some View {
        Form {
            ForEach(model.groups.filter { groups.contains($0.group) }) { group in
                Section {
                    if group.rows.isEmpty {
                        Text(SidebarSettingsText.empty(group.group)).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(group.rows) { row in
                                SidebarSettingsRow(row: row, isFirst: row.id == group.rows.first?.id, model: model)
                            }
                        }
                        .onDrop(of: [SidebarSettingsModel.dragType], delegate: SidebarGroupDrop(group: group.group, model: model))
                    }
                    if group.group == .locations {
                        Toggle(SidebarSettingsText.volumesSwitch,
                               isOn: Binding(get: { model.showsAllVolumes }, set: { model.setShowsAllVolumes($0) }))
                    }
                } header: {
                    Text(group.group.title)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// How the pane works, and Restore Defaults, under both columns.
private struct SidebarSettingsBar: View {
    @ObservedObject var model: SidebarSettingsModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            sidebarNote(SidebarSettingsText.restore)
            Button("Restore Defaults") { withAnimation(.easeInOut(duration: 0.2)) { model.restoreDefaults() } }
                .disabled(!model.canRestore)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}

/// A caption in the system's secondary style, as the other panes' notes are.
private func sidebarNote(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
}

/// One row: whether it's in the sidebar, what it is, and a handle to drag it by. The whole row can be dragged.
private struct SidebarSettingsRow: View {
    static let height: CGFloat = 28
    let row: SidebarSettingsModel.Row
    let isFirst: Bool
    let model: SidebarSettingsModel

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { row.isShown }, set: { model.setShown(row.place, $0) })) { Text(row.place.name) }
                .toggleStyle(.checkbox)
                .labelsHidden()
            // Monochrome, as in the sidebar.
            Image(systemName: row.place.iconName.replacingOccurrences(of: ".fill", with: ""))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(row.place.name)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(row.isShown ? .primary : .secondary)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
                .accessibilityHidden(true)
        }
        .frame(height: Self.height)
        .overlay(alignment: .top) { if !isFirst { Divider().padding(.leading, 54) } }
        .contentShape(Rectangle())
        .onDrag {
            model.beginDrag(row.place)
            return SidebarSettingsModel.dragItem(row.place)
        }
        .contextMenu {
            Button(row.isShown ? "Hide from Sidebar" : "Show in Sidebar") { model.setShown(row.place, !row.isShown) }
            Divider()
            Button("Move Up") { model.step(row.place, by: -1) }.disabled(!model.canStep(row.place, by: -1))
            Button("Move Down") { model.step(row.place, by: 1) }.disabled(!model.canStep(row.place, by: 1))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Move Up") { model.step(row.place, by: -1) }
        .accessibilityAction(named: "Move Down") { model.step(row.place, by: 1) }
    }
}

/// A group's rows make room as one of them is dragged over them: it takes the place of the row under the pointer.
/// Nothing is saved until it's let go of, and rows from other groups are refused.
@MainActor private struct SidebarGroupDrop: DropDelegate {
    let group: SidebarGroup
    let model: SidebarSettingsModel
    func validateDrop(info: DropInfo) -> Bool { model.canDrop(in: group) }
    func dropEntered(info: DropInfo) { hover(info) }
    func dropUpdated(info: DropInfo) -> SwiftUI.DropProposal? {
        hover(info)
        return SwiftUI.DropProposal(operation: model.canDrop(in: group) ? .move : .forbidden)
    }
    func dropExited(info: DropInfo) { withAnimation(.easeInOut(duration: 0.15)) { model.dragLeft() } }
    func performDrop(info: DropInfo) -> Bool { model.drop(in: group) }
    private func hover(_ info: DropInfo) {
        let index = Int((info.location.y / SidebarSettingsRow.height).rounded(.down))
        withAnimation(.easeInOut(duration: 0.15)) { model.dragOver(group, at: index) }
    }
}
#endif
