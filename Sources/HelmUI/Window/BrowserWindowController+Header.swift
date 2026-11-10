#if os(macOS)
import AppKit
import HelmCore

/// The header's side of the window: the sidebar's place, the main menu's shortcuts, and how a search that goes away
/// hands the keys back to the files.
extension BrowserWindowController {
    /// The sidebar can be hidden by its button, the menu, or by dragging the divider all the way across. However it
    /// went, the header moves its buttons clear of the window buttons, and the window's state says so.
    func sidebarVisibilityChanged(_ visible: Bool, animated: Bool = true) {
        header.setSidebarVisible(visible, animated: animated)
        if store.state.window.isSidebarVisible != visible { store.send(.window(.setSidebarVisible(visible))) }
    }

    /// A main menu row that shows the same shortcut as the menu bar, so the menu teaches the keys.
    func shortcutItem(_ title: String, _ command: CommandID) -> NSMenuItem {
        let item = commandItem(title, command)
        guard let binding = MenuModel.defaultBindings.first(where: { $0.command == command }) else { return item }
        var flags: NSEvent.ModifierFlags = []
        if binding.modifiers.contains(.command) { flags.insert(.command) }
        if binding.modifiers.contains(.shift) { flags.insert(.shift) }
        if binding.modifiers.contains(.option) { flags.insert(.option) }
        if binding.modifiers.contains(.control) { flags.insert(.control) }
        item.keyEquivalent = binding.key
        item.keyEquivalentModifierMask = flags
        return item
    }

    // MARK: Search focus

    /// The search closed by itself. A search still waiting to start is dropped, the tab stops searching, and if the
    /// field had the keys when it went, the files get them.
    func headerSearchDismissed() {
        cancelPendingSearch()
        if activeTab?.search != nil { store.send(.tab(activeTabID, .searchEnded)) }
        if let window, window.firstResponder === window { focusContent() }
    }

    /// Showing an item in its folder leaves the search, rather than running it again around the item.
    func leaveSearch() {
        guard header.isSearching || activeTab?.search != nil else { return }
        header.endSearch()
        headerSearchDismissed()
    }

    /// The Down arrow in the search field: the keys go to the results, with the first one selected, as in Nautilus.
    func headerSearchMoveToResults() -> Bool {
        guard let tab = activeTab else { return false }
        let typed = header.searchText
        // Words typed faster than the search waits are searched now.
        if !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, tab.search?.query.text != typed {
            cancelPendingSearch()
            search(typed)
        }
        guard let current = activeTab, let running = current.search else { return false }
        focusContent()
        guard current.selection.isEmpty else { return true }
        if current.snapshot.rootCount > 0, let first = current.snapshot.sortedEntries.first {
            store.send(.tab(current.id, .setSelection([first.id], source: .user)))
        } else {
            // Nothing has come in yet, so the first result is selected when it does.
            firstResultWanted = (current.id, running.generation)
        }
        return true
    }

    /// Selects the first result for the Down arrow once the search has some. Picking something yourself, another
    /// search, another tab or the search ending first lets it go.
    func selectFirstResultIfWanted(_ tab: TabState) {
        guard let wanted = firstResultWanted else { return }
        guard wanted.tab == tab.id, tab.search?.generation == wanted.search, tab.selection.isEmpty else {
            firstResultWanted = nil
            return
        }
        guard tab.snapshot.rootCount > 0, let first = tab.snapshot.sortedEntries.first else { return }
        firstResultWanted = nil
        store.send(.tab(tab.id, .setSelection([first.id], source: .user)))
    }

    // MARK: Header test support

    public func focusFilesForTesting() { focusContent() }
    /// Who has the keys: files, search, path, sidebar, window or other.
    public var focusOwnerForTesting: String {
        guard let window else { return "none" }
        let responder = window.firstResponder
        if responder === window { return "window" }
        if let files = contentKeyResponder, responder === files { return "files" }
        if header.isSearchFieldEditing { return "search" }
        if pathBar.isEditingLocation, responder is NSTextView { return "path" }
        if let view = responder as? NSView, view.isDescendant(of: sidebar.view) { return "sidebar" }
        return "other"
    }
    public var searchTextForTesting: String { header.searchText }
    /// The room the search field leaves for the words you type, and its scope's width, as laid out.
    public var searchTextRoomForTesting: CGFloat { header.searchField.textRoom }
    public var searchScopeWidthForTesting: CGFloat { header.searchField.scopeWidth }
    /// Whether the search field is drawn as being typed in (the darker fill).
    public var searchFieldLooksEditingForTesting: Bool { header.searchField.showsEditing }
    /// Types into the header's search field as a person would, opening it first.
    public func typeIntoSearchForTesting(_ text: String) {
        header.beginSearch()
        guard header.isSearchFieldEditing, let editor = window?.firstResponder as? NSTextView else { return }
        editor.string = text
        editor.didChangeText()
    }
    /// A key for the search field's editor, by name: down, escape or return. False if the field hasn't the caret.
    public func searchFieldKeyForTesting(_ name: String) -> Bool {
        guard header.isSearchFieldEditing, let editor = window?.firstResponder as? NSTextView else { return false }
        switch name {
        case "down": editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        case "escape": editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        case "return": editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        default: return false
        }
        return true
    }
    /// Escape, pressed while the files have the keys.
    public func pressEscapeInFilesForTesting() {
        focusContent()
        guard let files = contentKeyResponder,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
                                           charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { return }
        files.keyDown(with: event)
    }
    public var headerViewModeForTesting: ViewMode { header.viewSwitch.mode }
    /// A click on one half of the header's Grid | List switch.
    public func clickHeaderViewForTesting(_ mode: ViewMode) { header.viewSwitch.clickForTesting(mode) }
    public var headerLeadingForTesting: CGFloat { header.leadingInset }
    /// How wide the sidebar is as laid out; 0 while it's collapsed.
    public var sidebarWidthForTesting: CGFloat {
        guard let item = split.splitViewItems.first, !item.isCollapsed else { return 0 }
        return item.viewController.view.frame.width
    }
    /// The sort's words as the button shows them; empty when a narrow window has dropped them.
    public var headerSortTitleForTesting: String { header.sortButton.isCompact ? "" : header.sortButton.text }
    public var headerSortIsCompactForTesting: Bool { header.sortButton.isCompact }
    /// The sort button's width as laid out, and the width its icon, words and chevron need.
    public var headerSortWidthsForTesting: (shown: CGFloat, needed: CGFloat) {
        (header.sortButton.frame.width, header.sortButton.fittingWidth)
    }
    /// Every header tooltip, left to right.
    public var headerToolTipsForTesting: [String] {
        [header.sidebarButton, header.backButton, header.forwardButton, header.searchButton]
            .map { $0.toolTip ?? "" } + header.viewSwitch.segments.map { $0.toolTip ?? "" }
            + [header.sortButton.toolTip ?? "", header.menuButton.toolTip ?? ""]
    }
    /// Collapses or opens the sidebar the way dragging the divider does, without the header's button.
    public func setSidebarCollapsedForTesting(_ collapsed: Bool) { split.splitViewItems.first?.isCollapsed = collapsed }
    /// Moves the divider through the split view, as a drag does. Returns whether the sidebar ended up collapsed.
    public func moveSidebarDividerForTesting(to position: CGFloat) -> Bool {
        split.splitView.setPosition(position, ofDividerAt: 0)
        split.splitView.layoutSubtreeIfNeeded()
        return split.splitViewItems.first?.isCollapsed ?? false
    }
    public var isSidebarVisibleForTesting: Bool { store.state.window.isSidebarVisible }
    /// Where the header bar is, in window coordinates.
    public var headerFrameForTesting: NSRect { header.convert(header.bounds, to: nil) }
    /// Lights the main menu button as an open menu does. A real menu would hold a scripted run until it closed.
    public func lightMainMenuForTesting(_ lit: Bool) { header.menuButton.isOn = lit }
}

#endif
