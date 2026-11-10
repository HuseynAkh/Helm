#if os(macOS)
import AppKit
import HelmCore

/// The content area's status page: what replaces the listing when a place is empty or couldn't open,
/// its buttons, and trying blocked places again once access may have changed.
extension BrowserWindowController {
    func renderContentState(_ tab: TabState) {
        let access = dependencies.permissions.fullDiskAccess
        let state = statePage.preview ?? ContentStatePresentation.state(for: tab, home: dependencies.home, fullDiskAccess: access)
        let isNew = state != statePage.state
        statePage.show(state, perform: { [weak self] in self?.performContentAction($0) },
                       retryWaiting: { [weak self] in self?.retryWaitingLoad() })
        // A failure replaces the old listing rather than sitting on top of it, so nothing on show belongs elsewhere.
        setListingHidden(statePage.preview != nil || ContentStatePresentation.hidesListing(tab))
        // Full Disk Access reads as on, yet macOS refused: look again, in case it was turned off since.
        if isNew, access == .granted, ContentStatePresentation.failureOnShow(tab)?.error == .permissionDenied {
            let permissions = dependencies.permissions
            Task { await permissions.refresh() }
        }
    }

    /// The place the content area is about: a place that couldn't open, while its card is up, otherwise the tab's own.
    static func placeOnShow(_ tab: TabState) -> Location { ContentStatePresentation.placeOnShow(tab) }

    func performContentAction(_ action: ContentStateAction) {
        switch action {
        case .tryAgain(let location):
            // Access may have arrived since, which changes what a refusal says.
            let permissions = dependencies.permissions
            Task { await permissions.refresh() }
            statePage.restartRetries()
            if let tab = activeTab { go(to: location, in: tab) }
        case .grantAccess(let pane): dependencies.permissions.showGuide(pane)
        case .openTrashInFinder: dependencies.permissions.openTrashInFinder()
        case .goHome: perform(.home)
        }
    }

    /// Goes to a place from a card. The tab's own place reloads as it is, keeping its selection and open folders
    /// and staying out of Recent, and a card about another place covering it goes; any other place opens as a click
    /// on it would.
    func go(to place: Location, in tab: TabState) {
        if ContentStatePresentation.samePlace(place, tab.location) { showOwnFolder(of: tab.id, reloading: .refresh) }
        else { store.send(.tab(tab.id, .navigate(place, .push))) }
    }

    /// Shows the tab's own folder again, reloaded: a card about another place that covers it goes first. A plain
    /// reload, such as Show Hidden Files or an operation finishing, leaves such a card up.
    func showOwnFolder(of id: TabID, reloading reload: TabAction) {
        store.send(.tab(id, .returnToListing))
        store.send(.tab(id, reload))
    }

    /// View › Refresh while a card is up tries the place on show again, not the folder hidden under the card.
    func refreshPlaceOnShow() {
        guard let tab = activeTab else { return }
        if tab.pendingNavigation == nil, let shown = ContentStatePresentation.failureOnShow(tab) { go(to: shown.attempted, in: tab) }
        else { store.send(.tab(tab.id, .refresh)) }
        forgetFreeSpace()
    }

    /// Tries again in every tab that macOS refused or that timed out waiting on a macOS question, once access
    /// may have changed: Helm came back to the front, or Full Disk Access turned on. Places macOS doesn't guard
    /// are left alone, since coming back to Helm changes nothing for them.
    public func retryBlockedLoads() { retryBlockedLoads(refusedWith: dependencies.permissions.fullDiskAccess) }

    /// `access` is the Full Disk Access a refusal happened under. When access has just arrived, that's "off",
    /// so every place refused before it gets another try.
    func retryBlockedLoads(refusedWith access: PrivacyAccessStatus) {
        for id in store.state.window.tabs {
            guard let tab = store.state.tabs[id], tab.pendingNavigation == nil, !tab.isLoading,
                  ContentStatePresentation.isBlockedByPrivacy(tab, home: dependencies.home, fullDiskAccess: access),
                  let shown = ContentStatePresentation.failureOnShow(tab) else { continue }
            go(to: shown.attempted, in: tab)
        }
    }

    func subscribeToPermissions() -> Broadcast<PrivacyAccessStatus>.Token {
        dependencies.permissions.changes.subscribe { [weak self] status in
            guard let self else { return }
            if let tab = self.activeTab { self.renderContentState(tab) }
            if status == .granted { self.retryBlockedLoads(refusedWith: .denied) }
        }
    }

    /// Back from a place that couldn't open returns to the folder its card covered, since that's the step you
    /// just took. The folder reloads as it was, selection and open folders included, and history doesn't change:
    /// the failed place never entered it.
    func returnFromFailedPlace() -> Bool {
        guard let tab = activeTab, ContentStatePresentation.coveredPlace(tab) != nil else { return false }
        showOwnFolder(of: tab.id, reloading: .refresh)
        return true
    }

    /// Up from a place that couldn't open goes to the folder holding it, which is often the folder its card covered.
    func goUpFromFailedPlace() -> Bool {
        guard let tab = activeTab, ContentStatePresentation.coveredPlace(tab) != nil,
              let attempted = ContentStatePresentation.failureOnShow(tab)?.attempted else { return false }
        if let parent = ContentStatePresentation.enclosingFolder(of: attempted) { go(to: parent, in: tab) } else { NSSound.beep() }
        return true
    }

    /// While a card stands in for the listing, commands see the place on show: nothing is selected, there's no
    /// folder to put things in or to search, and the listing isn't focused, so no command reaches the hidden listing.
    /// Back and Up start from the place on show.
    func applyContentState(to context: inout CommandContext) {
        guard let tab = activeTab, ContentStatePresentation.hidesListing(tab) else { return }
        context.selectionCount = 0
        context.hasMutationTarget = false
        context.paneFocused = false
        context.canSearch = false
        let place = ContentStatePresentation.placeOnShow(tab)
        context.locationKind = place.kind
        if ContentStatePresentation.coveredPlace(tab) != nil {
            context.canGoBack = true
            context.canGoUp = ContentStatePresentation.enclosingFolder(of: place) != nil
        }
    }

    /// While macOS's question is on screen the read waits; once it's answered, the next try goes through.
    private func retryWaitingLoad() {
        guard let tab = activeTab, tab.pendingNavigation == nil, !tab.isLoading,
              let shown = ContentStatePresentation.failureOnShow(tab), shown.error == .timedOut else { return }
        go(to: shown.attempted, in: tab)
    }

    /// Keyboard focus never stays in a listing nobody can see: it moves to the card, where Tab reaches the buttons
    /// when Full Keyboard Access is on, and it comes back to the listing with it, including from a card button
    /// that was just pressed.
    private func setListingHidden(_ hidden: Bool) {
        if hidden {
            moveFocusOutOfListing()
            // A view-mode switch, a closed search or a cancelled path edit hands focus back to the listing just
            // after a render like this one, so look again once they're done.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.contentContainer.isHidden else { return }
                self.moveFocusOutOfListing()
            }
        }
        guard contentContainer.isHidden != hidden else { return }
        contentContainer.isHidden = hidden
        guard !hidden else { return }
        let responder = window?.firstResponder
        if responder == nil || responder === window || (responder as? NSView)?.isDescendant(of: statePage.view) == true { focusContent() }
    }

    private func moveFocusOutOfListing() {
        guard let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: contentContainer) else { return }
        if statePage.view.isHidden || !window.makeFirstResponder(statePage.view) { window.makeFirstResponder(nil) }
    }

    // MARK: Test support

    public var contentStateForTesting: ContentState? { statePage.state }
    public var isListingHiddenForTesting: Bool { contentContainer.isHidden }
    /// What VoiceOver was last told about a card.
    public var cardAnnouncementForTesting: String? { statePage.lastAnnouncement }
    /// Whether keyboard focus is inside the listing, hidden or not.
    public var focusIsInListingForTesting: Bool {
        (window?.firstResponder as? NSView)?.isDescendant(of: contentContainer) == true
    }
    /// The highlighted sidebar row's name, read from the sidebar itself, or "none".
    public var sidebarSelectionForTesting: String {
        guard let outline = Self.firstDescendant(NSOutlineView.self, of: sidebar.view), outline.selectedRow >= 0,
              let cell = outline.view(atColumn: 0, row: outline.selectedRow, makeIfNecessary: true) as? NSTableCellView,
              let name = cell.textField?.stringValue else { return "none" }
        return name
    }
    private static func firstDescendant<T: NSView>(_ type: T.Type, of view: NSView) -> T? {
        for child in view.subviews {
            if let match = child as? T { return match }
            if let match = firstDescendant(type, of: child) { return match }
        }
        return nil
    }
    /// Presses a status page button by its title, as a click would.
    public func pressContentButtonForTesting(_ title: String) -> Bool {
        guard let button = statePage.state?.buttons.first(where: { $0.title == title }) else { return false }
        performContentAction(button.action)
        return true
    }
    /// Shows a state that a fixture can't produce, such as a disk that stopped responding, for a screenshot. Nil clears it.
    public func previewContentStateForTesting(_ state: ContentState?) {
        statePage.preview = state
        if let tab = activeTab { renderContentState(tab) }
    }
}
#endif
