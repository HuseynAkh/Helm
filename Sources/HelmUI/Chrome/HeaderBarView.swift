#if os(macOS)
import AppKit
import HelmCore

@MainActor protocol HeaderBarDelegate: AnyObject {
    func headerToggleSidebar()
    func headerBack()
    func headerForward()
    /// The Grid | List switch picked a view.
    func headerSetViewMode(_ mode: ViewMode)
    func headerShowViewOptions(from button: NSView)
    func headerMainMenu() -> NSMenu?
    func headerSearchChanged(_ text: String)
    /// You closed the search: the Search button, or Escape in the field.
    func headerSearchClosed()
    /// The search closed by itself: you clicked away from an empty field, went somewhere else, switched to a tab
    /// that isn't searching, or started typing a location.
    func headerSearchDismissed()
    /// The search moved between the folder you're in and the whole Mac.
    func headerSearchScopeChanged()
    /// The Down arrow in the search field moves the keys to the results. False when there's nothing to move to.
    func headerSearchMoveToResults() -> Bool
}

/// The Nautilus header bar: back and forward, the path in the middle, then search, the Grid | List switch, sort and
/// view options, and the main menu.
/// It's our own view rather than an `NSToolbar`, so macOS doesn't wrap each control in its own glass capsule.
@MainActor final class HeaderBarView: NSView {
    weak var delegate: HeaderBarDelegate?
    /// The home folder, so the search's scope names places as the path bar does: "Home", not the account's name.
    var home: URL?
    let pathBar = PathBarView()
    let searchField = HeaderSearchField()
    private(set) lazy var sidebarButton = FlatButton(symbol: "sidebar.leading", label: "Hide Sidebar",
        toolTip: HeaderShortcuts.tip("Hide Sidebar", .sidebar), target: self, action: #selector(toggleSidebar))
    private(set) lazy var backButton = FlatButton(symbol: "chevron.left", label: "Back",
        toolTip: HeaderShortcuts.tip("Back", .back), target: self, action: #selector(back))
    private(set) lazy var forwardButton = FlatButton(symbol: "chevron.right", label: "Forward",
        toolTip: HeaderShortcuts.tip("Forward", .forward), target: self, action: #selector(forward))
    private(set) lazy var searchButton = FlatButton(symbol: "magnifyingglass", label: "Search",
        toolTip: HeaderShortcuts.tip("Search", .find), target: self, action: #selector(toggleSearch))
    let viewSwitch = ViewModeSwitch()
    let sortButton = FlatMenuButton(symbol: "arrow.up.arrow.down", label: "Sort and View Options", title: "A to Z")
    /// Dots in a circle: the app's own menu, told apart from the path bar's plain ⋯, which is this folder's menu.
    let menuButton = FlatMenuButton(symbol: "ellipsis.circle", label: "Main Menu")
    private var leading: NSLayoutConstraint?
    private(set) var isSearching = false
    private(set) var isSidebarVisible = true
    /// What the header last showed, so it can tell another tab, a new place and a search that ended apart.
    private var shownTab: TabID?
    private var shownSearchGeneration = Generation()
    private var shownNavigation: Generation?
    private var shownSortTitle: String?
    static let height: CGFloat = 52
    /// The sort's words go when showing them would leave the path less room than this, or less than the folder you're
    /// in needs, so the path keeps its room in a narrow window.
    static let pathRoom: CGFloat = 160
    /// They come back once there's this much more room than they need, so they don't flicker at the edge.
    static let wordsReturnAfter: CGFloat = 20
    /// Between buttons in a group, between the groups on the right, and around the path and at the bar's ends.
    private static let buttonGap: CGFloat = 2
    private static let groupGap: CGFloat = 6
    private static let edgeGap: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        searchField.onChange = { [weak self] text in self?.delegate?.headerSearchChanged(text) }
        searchField.onCancel = { [weak self] in self?.endSearch(); self?.delegate?.headerSearchClosed() }
        searchField.onEndEditing = { [weak self] in self?.searchFieldLostFocus() }
        searchField.onMoveDown = { [weak self] in self?.delegate?.headerSearchMoveToResults() ?? false }
        searchField.onScope = { [weak self] everywhere in
            self?.searchesEverywhere = everywhere
            self?.delegate?.headerSearchScopeChanged()
        }
        searchField.isHidden = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchButton.isToggle = true
        viewSwitch.onChoose = { [weak self] mode in self?.delegate?.headerSetViewMode(mode) }
        sortButton.showsDisclosure = true
        // A narrowing window squeezes the sort's words for a moment, until the bar drops them, rather than grow.
        sortButton.wordsGiveWay = true
        sortButton.openHandler = { [weak self] button in self?.delegate?.headerShowViewOptions(from: button) }
        menuButton.menuProvider = { [weak self] in self?.delegate?.headerMainMenu() }
        menuButton.alignsMenuToTrailingEdge = true
        let left = NSStackView(views: [sidebarButton, backButton, forwardButton])
        left.spacing = Self.buttonGap
        // Search · Grid | List and the sort · the main menu: the switch and the sort read as one group.
        let right = NSStackView(views: [searchButton, viewSwitch, sortButton, menuButton])
        right.spacing = Self.buttonGap
        right.setCustomSpacing(Self.groupGap, after: searchButton)
        right.setCustomSpacing(Self.groupGap, after: sortButton)
        for view in [left, right, pathBar, searchField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let leadingConstraint = left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.edgeGap)
        leading = leadingConstraint
        let separator = NSBox(); separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            leadingConstraint, left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.edgeGap), right.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathBar.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: Self.edgeGap),
            pathBar.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -Self.edgeGap),
            pathBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: pathBar.trailingAnchor),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }

    /// Empty parts of the bar drag the window, as a title bar does.
    override var mouseDownCanMoveWindow: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateCompact(forWidth: newSize.width)
    }
    /// In a narrow window the sort's words go first, decided by the room there really is: with or without the sidebar,
    /// for these words and this folder. Until the bar has a width there's nothing to decide.
    func updateCompact(forWidth width: CGFloat) {
        guard width > 0 else { return }
        let needed = widthWithSortWords
        if sortButton.isCompact {
            if width >= needed + Self.wordsReturnAfter { sortButton.isCompact = false }
        } else if width < needed {
            sortButton.isCompact = true
        }
    }
    /// The narrowest the bar can be with the sort's words on show: the buttons and gaps either side, and room for the
    /// path to show the folder you're in, never less than `pathRoom`. It mirrors the constraints in `init`, so the
    /// decision doesn't wait for a layout that the words themselves would make wider.
    var widthWithSortWords: CGFloat {
        let left = [sidebarButton, backButton, forwardButton].map(\.laidOutWidth).reduce(0, +) + 2 * Self.buttonGap
        let right = searchButton.laidOutWidth + Self.groupGap + viewSwitch.intrinsicContentSize.width + Self.buttonGap
            + sortButton.widthWithWords + Self.groupGap + menuButton.laidOutWidth
        // The search field sits in the path's place, hidden or not, so its own minimum counts too.
        let path = max(Self.pathRoom, pathBar.minimumWidth, searchField.minimumWidth)
        return leadingInset + left + Self.edgeGap + path + Self.edgeGap + right + Self.edgeGap
    }

    /// With the sidebar hidden, the window buttons sit over the bar's left end, so the buttons move clear of them.
    func setSidebarVisible(_ visible: Bool, animated: Bool = false) {
        isSidebarVisible = visible
        let words = visible ? "Hide Sidebar" : "Show Sidebar"
        sidebarButton.setAccessibilityLabel(words)
        sidebarButton.toolTip = HeaderShortcuts.tip(words, .sidebar)
        let constant: CGFloat = visible ? Self.edgeGap : 84
        guard let leading, leading.constant != constant else { return }
        leading.constant = constant
        // The buttons moving over changes the room for the sort's words.
        updateCompact(forWidth: bounds.width)
        guard animated, window != nil, !HeaderMotion.isReduced else { return }
        // The buttons slide with the sidebar instead of jumping.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
    }
    /// How far the buttons sit from the bar's left end.
    var leadingInset: CGFloat { leading?.constant ?? 0 }

    func render(tab: TabState) {
        let switched = tab.id != shownTab
        followSearch(of: tab, switched: switched)
        backButton.isEnabled = !tab.history.back.isEmpty || ContentStatePresentation.coveredPlace(tab) != nil
        forwardButton.isEnabled = !tab.history.forward.isEmpty
        // The thumb slides when this tab's view changes, and snaps into place on a tab you've just switched to.
        viewSwitch.setMode(tab.viewMode, animated: !switched)
        if tab.search == nil, !isSearching { searchField.stringValue = "" }
        // The search names the place on show, as the path bar does. While a card stands in for the listing there's
        // nothing there to search, and the folder under the card is hidden, so Search waits until the card goes.
        searchButton.isEnabled = isSearching || !ContentStatePresentation.hidesListing(tab)
        let place = ContentStatePresentation.placeOnShow(tab)
        let folder = place.mutationTarget.map { url -> String in
            if let home, let last = PathBarView.segments(for: place, home: home).last { return last.title }
            return FileManager.default.displayName(atPath: url.path)
        }
        if folder == nil { searchesEverywhere = false }
        searchField.setScope(folder: folder, everywhere: searchesEverywhere)
        // During a search that's the results' order, Best Match unless another is chosen for them.
        showSort(tab.shownSort, animated: !switched)
    }

    /// The sort in words, such as "Newest first", with a chevron that says it opens something.
    private func showSort(_ sort: ItemSort, animated: Bool) {
        let direction = SortField.direction(sort.field, ascending: sort.ascending)
        let title: String
        switch sort.field {
        case .relevance: title = SortChoice.bestMatch.title
        case .kind: title = "Kind \(direction)" // "A to Z" alone would read as names.
        default: title = direction
        }
        let changed = title != shownSortTitle
        if changed {
            let first = shownSortTitle == nil
            shownSortTitle = title
            let described = Self.describe(sort)
            sortButton.toolTip = described.tip + " " + HeaderShortcuts.tip("Sort and view options", .viewOptions)
            sortButton.setAccessibilityValue(described.value)
            // The old words fade into the new ones.
            sortButton.setTitle(title, animated: animated && !first)
        }
        // New words, a new folder or a new scope can each change whether the words fit, and that's settled before
        // the button takes its new width.
        updateCompact(forWidth: bounds.width)
        // The new width takes effect now, not at the window's next display, which a window in the background can
        // wait a long time for. It isn't animated: AppKit steps an animated resize on a timer, and in a background
        // window the timer stalls with the button still at its old width.
        if changed, window != nil { layoutSubtreeIfNeeded() }
    }

    /// The sort as the tooltip and VoiceOver put it: "Name, A to Z", or Best Match for search results. A field that
    /// isn't in `fields`, such as one only some places offer, is told by its direction, never taken for Best Match.
    static func describe(_ sort: ItemSort, fields: [SortField] = SortField.all + [SortField.lastOpened]) -> (value: String, tip: String) {
        if sort.field == .relevance { return (SortChoice.bestMatch.title, "Sorted by \(SortChoice.bestMatch.title).") }
        let direction = SortField.direction(sort.field, ascending: sort.ascending)
        guard let field = fields.first(where: { $0.field == sort.field }) else { return (direction, "Sorted: \(direction).") }
        let value = "\(field.title), \(direction)"
        return (value, "Sorted by \(value).")
    }

    /// View › Show View Options (⌘J) opens the same popover as the button.
    func showViewOptions() { sortButton.openHandler?(sortButton) }
    func openViewOptionsForTesting() { showViewOptions() }
    /// The sort button stays lit while its popover is open.
    func setViewOptionsShown(_ shown: Bool) {
        sortButton.isOn = shown
        if !shown { sortButton.updateHover() }
    }

    // MARK: Search

    /// Whether searches cover the whole Mac rather than the folder you're in (P-170). Each new search starts in the folder.
    private(set) var searchesEverywhere = false
    var searchText: String { searchField.stringValue }
    /// True while the search field has the caret.
    var isSearchFieldEditing: Bool { searchField.isEditing }

    func chooseSearchScopeForTesting(everywhere: Bool) { searchField.chooseScopeForTesting(everywhere: everywhere) }
    /// Cmd+F and the Search button: opens the field, or puts the caret back in it with its words selected.
    func beginSearch() {
        // Cmd+F while typing a location swaps the location for the search.
        if pathBar.isEditingLocation { window?.makeFirstResponder(nil) }
        if !isSearching {
            isSearching = true
            showSearchField(true)
        }
        searchField.focus(selectingAll: true)
    }
    func endSearch() {
        guard isSearching else { return }
        isSearching = false
        searchesEverywhere = false
        searchField.stringValue = ""
        showSearchField(false)
    }
    private func showSearchField(_ shown: Bool) {
        searchButton.isOn = shown
        searchButton.toolTip = shown ? "Close Search (Esc)" : HeaderShortcuts.tip("Search", .find)
        pathBar.isHidden = shown; searchField.isHidden = !shown
    }
    /// A search the tab is already running: its words and where it looks, without the caret.
    private func show(_ query: SearchQuery) {
        isSearching = true
        if case .thisMac = query.scope { searchesEverywhere = true } else { searchesEverywhere = false }
        searchField.stringValue = query.text
        showSearchField(true)
    }

    /// The header follows the tab, not the other way round. A search that ended, a new place, another tab or typing a
    /// location closes the field, and a tab that's searching shows its own words and scope. Every navigation is staged
    /// with a new generation and every ended search bumps the search generation, which is how these are told apart.
    private func followSearch(of tab: TabState, switched: Bool) {
        let navigating = tab.pendingNavigation.map { $0.generation != shownNavigation } ?? false
        let ended = tab.search == nil && tab.searchGeneration != shownSearchGeneration
        shownTab = tab.id
        shownSearchGeneration = tab.searchGeneration
        shownNavigation = tab.pendingNavigation?.generation
        if tab.addressBar.isEditing {
            guard isSearching else { return }
            endSearch()
            // The location field couldn't take the caret while the search covered it.
            pathBar.focusLocationField()
            delegate?.headerSearchDismissed()
        } else if let search = tab.search {
            if switched || !isSearching { show(search.query) }
        } else if isSearching {
            // Clearing the words while you type ends the tab's search but leaves the field open for new ones. Any
            // other end closes it, such as Go › Documents while you're already in Documents, which ends the search
            // without going anywhere.
            let clearedWhileTyping = searchField.isEditing && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if switched || navigating || (ended && !clearedWhileTyping) { dismissSearch() }
        }
    }

    /// Clicking away from an empty search closes it, as Finder's toolbar search collapses. One with words stays,
    /// in the path bar's resting fill, and so do its results.
    private func searchFieldLostFocus() {
        guard isSearching, searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismissSearch()
    }
    private func dismissSearch() {
        endSearch()
        delegate?.headerSearchDismissed()
    }

    @objc private func toggleSidebar() { delegate?.headerToggleSidebar() }
    @objc private func back() { delegate?.headerBack() }
    @objc private func forward() { delegate?.headerForward() }
    @objc private func toggleSearch() {
        if isSearching { endSearch(); delegate?.headerSearchClosed() } else { beginSearch() }
    }
}

/// The search field, drawn exactly like the path bar: the same rounded 34-point field, fills, 14-point text and
/// insets, so pressing Search swaps one for the other without the header changing shape. Like the path bar, its fill
/// is stronger while you type in it and goes back to the resting fill when the caret leaves.
/// It's a plain text field rather than `NSSearchField`, whose own bezel is shorter and squarer.
@MainActor final class HeaderSearchField: NSView, NSTextFieldDelegate {
    private let field = SearchTextField()
    private let icon = NSImageView()
    private let clear = NSButton()
    /// Where the search looks: the folder you're in, or the whole Mac, as Finder's scope bar offers (P-170).
    private let scope = NSButton()
    private var folderName: String?
    private var everywhere = false
    var onChange: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onScope: ((Bool) -> Void)?
    /// The caret left the field.
    var onEndEditing: (() -> Void)?
    /// The Down arrow, which can take the keys to the results.
    var onMoveDown: (() -> Bool)?
    /// Whether the field is drawn as being typed in.
    private(set) var showsEditing = false
    /// What the empty field says, such as "Search Home".
    var placeholderStringForTesting: String? { field.placeholderString }
    /// The room the words you type always keep, about nine letters: in a narrow window the scope gives way first.
    static let minimumTextWidth: CGFloat = 64
    /// The widest the scope gets: a folder with a long name is shortened in it, leaving the room to the words you type.
    static let maximumScopeWidth: CGFloat = 160
    /// The scope with just its chevron, the narrowest it gets.
    private var compactScopeWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        setAccessibilityRole(.group)
        setAccessibilityLabel("Search")
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.placeholderString = "Search this folder"
        field.cell?.isScrollable = true; field.cell?.wraps = false; field.lineBreakMode = .byClipping
        field.delegate = self
        field.setAccessibilityLabel("Search this folder")
        field.onFocus = { [weak self] in self?.setEditing(true) }
        clear.isBordered = false; clear.title = ""
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear Search")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        clear.contentTintColor = .tertiaryLabelColor
        clear.target = self; clear.action = #selector(clearText)
        clear.isHidden = true
        scope.bezelStyle = .inline
        scope.controlSize = .small
        scope.font = .systemFont(ofSize: 12, weight: .medium)
        scope.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        scope.imagePosition = .imageTrailing
        scope.target = self; scope.action = #selector(chooseScope)
        scope.title = ""
        compactScopeWidth = ceil(scope.intrinsicContentSize.width)
        scope.lineBreakMode = .byTruncatingTail
        scope.setContentHuggingPriority(.required, for: .horizontal)
        // The folder's name gives way, down to the chevron, before the words you type do, and a long name never makes
        // the window wider. Below the priority a fitting size presses with (50), so `minimumWidth` is the fitting width.
        scope.setContentCompressionResistancePriority(.init(40), for: .horizontal)
        for view in [icon, field, clear, scope] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -4),
            clear.trailingAnchor.constraint(equalTo: scope.leadingAnchor, constant: -6), clear.centerYAnchor.constraint(equalTo: centerYAnchor),
            scope.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7), scope.centerYAnchor.constraint(equalTo: centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: 20), clear.heightAnchor.constraint(equalToConstant: 20),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumTextWidth),
            scope.widthAnchor.constraint(greaterThanOrEqualToConstant: compactScopeWidth),
            scope.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumScopeWidth)
        ])
        updateBackground()
    }
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    /// The narrowest the field can be: its icon, the room kept for the words you type, the clear button and the scope
    /// down to its chevron, with the gaps between them, as the constraints in `init` set them.
    var minimumWidth: CGFloat {
        12 + icon.intrinsicContentSize.width + 8 + max(Self.minimumTextWidth, field.intrinsicContentSize.width) + 4 + 20 + 6
            + compactScopeWidth + 7
    }
    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue; clear.isHidden = newValue.isEmpty }
    }
    /// True while the caret is in the field.
    var isEditing: Bool { field.currentEditor() != nil }
    /// The room the words you type have, and the scope's width, as laid out.
    var textRoom: CGFloat { field.frame.width }
    var scopeWidth: CGFloat { scope.frame.width }
    /// Puts the caret in the field. While you're already typing it stays where it is, unless the words are to be
    /// selected, as Cmd+F does. Focusing a field that's being edited would end the editing and start it again.
    func focus(selectingAll: Bool) {
        if let editor = field.currentEditor() {
            if selectingAll { editor.selectAll(nil) }
            return
        }
        window?.makeFirstResponder(field)
        if !selectingAll {
            field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }
    /// Clicking anywhere in the rounded field puts the caret in it, as with the path bar.
    override func mouseDown(with event: NSEvent) { focus(selectingAll: false) }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBackground() }
    private func setEditing(_ editing: Bool) {
        guard editing != showsEditing else { return }
        showsEditing = editing
        updateBackground()
    }
    /// The path bar's two fills: stronger while you type, fainter at rest.
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(showsEditing ? 0.14 : 0.08).cgColor
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        clear.isHidden = field.stringValue.isEmpty
        onChange?(field.stringValue)
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        // AppKit says editing ended while the field editor is still attached, after Return (when the caret stays),
        // and when the field is focused again, so look again on the next turn of the run loop.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setEditing(self.isEditing)
            if !self.isEditing { self.onEndEditing?() }
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) { return onMoveDown?() ?? false }
        return false
    }
    @objc private func clearText() {
        stringValue = ""
        onChange?("")
        focus(selectingAll: false)
    }

    /// Shows where the search looks. Virtual places such as Recent have no folder, so they search the Mac.
    func setScope(folder: String?, everywhere: Bool) {
        folderName = folder
        self.everywhere = everywhere || folder == nil
        let place = self.everywhere ? "This Mac" : (folder ?? "This Mac")
        scope.title = place
        scope.isHidden = folder == nil
        field.placeholderString = "Search \(place)"
        field.setAccessibilityLabel("Search \(place)")
        scope.setAccessibilityLabel("Search in \(place). Click to change.")
    }
    @objc private func chooseScope() {
        guard let folderName else { return }
        let menu = NSMenu()
        let here = NSMenuItem(title: folderName, action: #selector(searchHere), keyEquivalent: "")
        here.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        here.state = everywhere ? .off : .on
        let mac = NSMenuItem(title: "This Mac", action: #selector(searchEverywhere), keyEquivalent: "")
        mac.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        mac.state = everywhere ? .on : .off
        for item in [here, mac] { item.target = self; menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: scope.frame.minX, y: scope.frame.minY - 4), in: self)
    }
    @objc private func searchHere() { pick(everywhere: false) }
    @objc private func searchEverywhere() { pick(everywhere: true) }
    private func pick(everywhere: Bool) {
        setScope(folder: folderName, everywhere: everywhere)
        onScope?(everywhere)
        focus(selectingAll: false)
    }
    /// For scripted runs: the scope as if chosen from its menu.
    func chooseScopeForTesting(everywhere: Bool) { pick(everywhere: everywhere) }
}

/// Says when it takes the caret: a text field's delegate only hears about editing at the first keystroke.
@MainActor final class SearchTextField: NSTextField {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }
}
#endif
