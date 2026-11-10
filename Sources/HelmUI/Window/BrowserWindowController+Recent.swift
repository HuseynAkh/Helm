#if os(macOS)
import AppKit
import HelmCore

/// Recent's own order. Recent lists what you opened most recently first (Last Opened), unless you've chosen
/// another order there, and that order never follows you out: leaving Recent puts back the order the tab had.
extension BrowserWindowController {
    /// Runs as a tab arrives somewhere new. `hasSavedOptions` means the place has its own remembered view and sort,
    /// which then win, as they do for any folder.
    func settleRecentSort(_ tab: TabState, hasSavedOptions: Bool) {
        guard tab.search == nil else { return }
        let defaults = dependencies.settings.snapshot.defaultSort
        if tab.location == .recent {
            if tab.sort.field != .lastOpened { sortsBeforeRecent[tab.id] = tab.sort }
            guard !hasSavedOptions, tab.sort.field != .lastOpened else { return }
            // Recent's own Folders on top, not the one the tab brings from the folder it was in.
            store.send(.tab(tab.id, .setSort(ItemSort(field: .lastOpened, ascending: false, directoriesFirst: defaults.directoriesFirst))))
        } else {
            let before = sortsBeforeRecent.removeValue(forKey: tab.id)
            guard !hasSavedOptions else { return }
            // Whatever order Recent was in, Last Opened or one chosen there, the tab gets back the one it had.
            if let before {
                if before != tab.sort { store.send(.tab(tab.id, .setSort(before))) }
            } else if tab.sort.field == .lastOpened {
                store.send(.tab(tab.id, .setSort(defaults)))
            }
        }
    }

    /// Recent follows what you open, as Finder's and Nautilus's do: a tab showing it lists it again whenever what's
    /// recent changes, so something you've just opened moves to the top. A tab searching there catches up when its
    /// search ends, so the results on show don't start over.
    func recentsChanged() {
        for (id, tab) in store.state.tabs where tab.location == .recent {
            if tab.search == nil { store.send(.tab(id, .refresh)) } else { recentTabsBehind.insert(id) }
        }
    }
    func catchUpRecent(_ snapshot: WindowStoreSnapshot) {
        for id in recentTabsBehind {
            guard let tab = snapshot.tabs[id], tab.location == .recent else { recentTabsBehind.remove(id); continue }
            guard tab.search == nil else { continue }
            recentTabsBehind.remove(id)
            store.send(.tab(id, .refresh))
        }
    }

    /// Whether a place has a view and sort of its own. Recent has its own default order, so an order chosen there
    /// counts even when it's the same as everywhere else's defaults (Name A–Z in the grid, say). Folders keep the
    /// old rule, where options that match the defaults count as none.
    func hasSavedViewOptions(_ saved: ViewOptions, at location: Location) -> Bool {
        saved != dependencies.viewOptions.defaults || (location == .recent && dependencies.viewOptions.hasOptions(for: location))
    }

    /// Last Opened only means something in Recent, and Best Match only in search results, so a folder never
    /// remembers either.
    func storableSort(_ sort: ItemSort, at location: Location) -> ItemSort {
        guard sort.field == .relevance || (sort.field == .lastOpened && location != .recent) else { return sort }
        return dependencies.settings.snapshot.defaultSort
    }

    /// View › Sort By's Last Opened row, offered only in Recent when no search is running.
    func lastOpenedSortItem(_ current: ItemSort) -> NSMenuItem? {
        guard activeTab?.location == .recent, activeTab?.search == nil else { return nil }
        let target = ClosureMenuTarget { [weak self] in self?.pressSort(.lastOpened) }
        let item = NSMenuItem(title: SortField.lastOpened.title, action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
        item.target = target; item.representedObject = target
        item.state = current.field == .lastOpened ? .on : .off
        if current.field == .lastOpened { item.toolTip = "Choose again to reverse" }
        return item
    }
}
#endif
