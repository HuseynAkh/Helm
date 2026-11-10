#if os(macOS)
import AppKit
import HelmCore
import HelmPersistence

/// Arranging the sidebar: moving rows within their group, hiding them, and Settings › Sidebar.
/// Every window and the Settings pane redraw from the shared layout store, so a change shows everywhere at once.
extension BrowserWindowController {
    /// Bookmarks folders just before `anchor`, or at the end. A folder that's already a hidden bookmark comes back into view.
    func sidebarInsertBookmarks(_ urls: [URL], before anchor: Place?) {
        let dependencies = dependencies
        let anchorPath = anchor?.kind == .bookmark ? anchor?.url?.path : nil
        Task { @MainActor in
            for url in urls {
                let directory = await dependencies.fileSystem.isDirectory(url, resolvingSymlinks: true)
                dependencies.bookmarks.insert(url, isDirectory: directory, before: anchorPath, date: dependencies.clock.now())
                dependencies.showBookmark(at: url)
            }
        }
    }
    func sidebarMove(_ place: Place, before anchor: Place?) { dependencies.dropSidebarRow(place, before: anchor) }
    func sidebarHide(_ place: Place) { dependencies.setSidebarRow(place, shown: false) }
    func sidebarShowSettings() { host?.showSettings(pane: .sidebar) }

    // MARK: For the smoke run, through the same paths as the menus, drags and drops

    /// Folders bookmarked at a position among the bookmarks on show, as dropping them between two bookmarks does:
    /// just before the bookmark at `index`, or at the end.
    public func sidebarInsertBookmarks(_ urls: [URL], at index: Int?) {
        let rows = dependencies.placesModel().shown(.bookmarks)
        sidebarInsertBookmarks(urls, before: index.flatMap { rows.indices.contains($0) ? rows[$0] : nil })
    }
    /// A bookmark let go of with the line just above the bookmark at `index`, or below them all, as dragging it within
    /// the sidebar does. `index` counts the bookmarks on show before the move.
    public func sidebarMoveBookmark(_ path: String, to index: Int) {
        let rows = dependencies.placesModel().shown(.bookmarks)
        // Spelled as the rows spell it, which drops a leading /private as the bookmark store does.
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let place = rows.first(where: { $0.url?.standardizedFileURL.path == wanted }) else { return }
        let line = max(0, index)
        dependencies.dropSidebarRow(place, before: rows.indices.contains(line) ? rows[line] : nil)
    }
    /// A row of the full catalog, shown or hidden, by group and name.
    private func sidebarPlace(_ group: SidebarGroup, named name: String) -> Place? {
        dependencies.placesModel().arranged(group).first { $0.name == name }
    }
    /// The names of one group's rows as the list draws them, read back from the outline view itself.
    public func sidebarRowNamesForTesting(_ group: SidebarGroup) -> [String] {
        sidebar.renderedPlacesForTesting.filter { $0.group == group }.map(\.name)
    }
    /// Every line of the list as drawn, with "|" for the lines between groups.
    public var sidebarDrawnForTesting: [String] { sidebar.renderedNamesForTesting }
    public var sidebarHighlightForTesting: String? { sidebar.highlightedNameForTesting }
    /// Whether AppKit hears where a row dragged from the sidebar has got to, and whether the image would slide back
    /// at a point in the sidebar and at a point over the files.
    public var sidebarSlideBackForTesting: (hooked: Bool, inside: Bool, outside: Bool)? {
        guard let inside = sidebar.screenPointForTesting(insideSidebar: true),
              let outside = sidebar.screenPointForTesting(insideSidebar: false) else { return nil }
        return (sidebar.hearsDragMovesForTesting, sidebar.slidesBack(at: inside), sidebar.slidesBack(at: outside))
    }
    @discardableResult public func sidebarSetShownForTesting(_ group: SidebarGroup, _ name: String, shown: Bool) -> Bool {
        guard let place = sidebarPlace(group, named: name) else { return false }
        if shown { dependencies.setSidebarRow(place, shown: true) } else { sidebarHide(place) }
        return true
    }
    /// As if the row were dragged and dropped with the insertion line just above `target`'s row,
    /// or below everything when `target` is nil. The sidebar keeps the line within the row's own group.
    @discardableResult public func sidebarDropForTesting(_ group: SidebarGroup, _ name: String,
                                                         onto target: (group: SidebarGroup, name: String)?) -> Bool {
        guard let place = sidebarPlace(group, named: name) else { return false }
        var index = -1
        if let target {
            guard let anchor = sidebarPlace(target.group, named: target.name), let row = sidebar.listIndexForTesting(of: anchor.id) else { return false }
            index = row
        }
        return sidebar.moveRow(place.id, toChildIndex: index)
    }
    /// A row dragged over another row's upper or lower half and let go, through the outline view's own drop handling.
    @discardableResult public func sidebarScriptedDragForTesting(_ group: SidebarGroup, _ name: String,
                                                                 over target: (group: SidebarGroup, name: String), lowerHalf: Bool) -> Bool {
        guard let place = sidebarPlace(group, named: name), let anchor = sidebarPlace(target.group, named: target.name),
              let row = sidebar.listIndexForTesting(of: anchor.id) else { return false }
        let item = NSPasteboardItem()
        item.setString(place.id, forType: .helmSidebarPlace)
        return sidebar.scriptedDropForTesting(item, overRow: row, lowerHalf: lowerHalf).taken
    }
    /// A folder dragged in from elsewhere and let go over Recent's upper or lower half, which takes no drops itself,
    /// so the folder is bookmarked. Gives the operation offered, "link" when it's bookmarked. Only Recent is allowed:
    /// over a folder row, or Trash, the drop would really move the folder.
    public func sidebarScriptedFolderDropForTesting(_ url: URL, over target: (group: SidebarGroup, name: String), lowerHalf: Bool) -> String {
        guard let anchor = sidebarPlace(target.group, named: target.name), let row = sidebar.listIndexForTesting(of: anchor.id) else { return "no such row" }
        guard anchor.kind == .recentRoot else { return "only over Recent" }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        let result = sidebar.scriptedDropForTesting(item, overRow: row, lowerHalf: lowerHalf)
        guard result.taken else { return "refused" }
        switch result.offered {
        case .link: return "link"
        case .move: return "move"
        case .copy: return "copy"
        default: return "other"
        }
    }
    /// The end of a drag of a row on show, through the same code AppKit calls when a real drag ends: let go of
    /// `inside` the sidebar or over the files, with nothing taking it, or cancelled with Escape.
    @discardableResult public func sidebarDragEndForTesting(_ group: SidebarGroup, _ name: String, inside: Bool, cancelled: Bool) -> Bool {
        guard let place = sidebar.currentModel?.sections.first(where: { $0.id == group.rawValue })?.rows.first(where: { $0.name == name }),
              let point = sidebar.screenPointForTesting(insideSidebar: inside) else { return false }
        sidebar.finishDrag(of: place, at: point, operation: [], cancelled: cancelled)
        return true
    }
    /// The row's menu as titles, with "|" for separators. A nil name is the empty space below the rows.
    public func sidebarMenuTitlesForTesting(_ group: SidebarGroup, _ name: String?) -> [String] {
        sidebarMenuForTesting(group, name)?.items.map { $0.isSeparatorItem ? "|" : $0.title } ?? []
    }
    /// Chooses an item from a row's menu.
    @discardableResult public func sidebarMenuPickForTesting(_ group: SidebarGroup, _ name: String?, _ title: String) -> Bool {
        guard let item = sidebarMenuForTesting(group, name)?.items.first(where: { $0.title == title }), let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }
    private func sidebarMenuForTesting(_ group: SidebarGroup, _ name: String?) -> NSMenu? {
        guard let name else { return sidebar.menu(forRow: -1) }
        guard let place = sidebarPlace(group, named: name), let row = sidebar.listIndexForTesting(of: place.id) else { return nil }
        return sidebar.menu(forRow: row)
    }
}
#endif
