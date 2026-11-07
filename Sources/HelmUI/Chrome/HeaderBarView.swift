#if os(macOS)
import AppKit
import HelmCore

@MainActor protocol HeaderBarDelegate: AnyObject {
    func headerToggleSidebar()
    func headerBack()
    func headerForward()
    func headerToggleViewMode()
    func headerShowViewOptions(from button: NSView)
    func headerMainMenu() -> NSMenu?
    func headerSearchChanged(_ text: String)
    func headerSearchClosed()
}

/// The Nautilus header bar: back and forward, the path in the middle, then search, view options and the main menu.
/// It's our own view rather than an `NSToolbar`, so macOS doesn't wrap each control in its own glass capsule.
@MainActor final class HeaderBarView: NSView {
    weak var delegate: HeaderBarDelegate?
    let pathBar = PathBarView()
    private let searchField = HeaderSearchField()
    private lazy var sidebarButton = FlatButton(symbol: "sidebar.leading", label: "Show or Hide Sidebar", target: self, action: #selector(toggleSidebar))
    private lazy var backButton = FlatButton(symbol: "chevron.left", label: "Back", target: self, action: #selector(back))
    private lazy var forwardButton = FlatButton(symbol: "chevron.right", label: "Forward", target: self, action: #selector(forward))
    private lazy var searchButton = FlatButton(symbol: "magnifyingglass", label: "Search", target: self, action: #selector(toggleSearch))
    private lazy var viewButton = FlatButton(symbol: "list.bullet", label: "Show as List", target: self, action: #selector(toggleView))
    private let sortButton = FlatMenuButton(symbol: "arrow.up.arrow.down", label: "Sort and View Options", title: "A to Z")
    private let menuButton = FlatMenuButton(symbol: "line.3.horizontal", label: "Main Menu")
    private var leading: NSLayoutConstraint?
    private(set) var isSearching = false
    static let height: CGFloat = 52

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        searchField.onChange = { [weak self] text in self?.delegate?.headerSearchChanged(text) }
        searchField.onCancel = { [weak self] in self?.endSearch(); self?.delegate?.headerSearchClosed() }
        searchField.isHidden = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        sortButton.openHandler = { [weak self] button in self?.delegate?.headerShowViewOptions(from: button) }
        menuButton.menuProvider = { [weak self] in self?.delegate?.headerMainMenu() }
        let left = NSStackView(views: [sidebarButton, backButton, forwardButton])
        left.spacing = 2
        let right = NSStackView(views: [searchButton, sortButton, viewButton, menuButton])
        right.spacing = 2
        for view in [left, right, pathBar, searchField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let leadingConstraint = left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        leading = leadingConstraint
        let separator = NSBox(); separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            leadingConstraint, left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), right.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathBar.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 8),
            pathBar.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -8),
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

    /// With the sidebar hidden, the window buttons sit over the bar's left end.
    func setSidebarVisible(_ visible: Bool) { leading?.constant = visible ? 8 : 84 }

    func render(tab: TabState) {
        backButton.isEnabled = !tab.history.back.isEmpty
        forwardButton.isEnabled = !tab.history.forward.isEmpty
        let toList = tab.viewMode == .grid
        viewButton.setSymbol(toList ? "list.bullet" : "square.grid.2x2", label: toList ? "Show as List" : "Show as Grid")
        let field = SortField.all.first { $0.field == tab.sort.field }
        let direction = SortField.direction(tab.sort.field, ascending: tab.sort.ascending)
        let described = field.map { "\($0.title), \(direction.lowercased())" } ?? SortChoice.bestMatch.title
        switch tab.sort.field {
        case .relevance: sortButton.title = SortChoice.bestMatch.title
        case .kind: sortButton.title = "Kind \(direction)" // "A to Z" alone would read as names.
        default: sortButton.title = direction
        }
        sortButton.toolTip = "Sorted by \(described). Click for sort and view options."
        sortButton.setAccessibilityLabel("Sort and view options, currently \(described)")
        if tab.search == nil, !isSearching { searchField.stringValue = "" }
    }

    func openViewOptionsForTesting() { sortButton.openHandler?(sortButton) }
    /// The sort button stays lit while its popover is open.
    func setViewOptionsShown(_ shown: Bool) { sortButton.isOn = shown }

    func beginSearch() {
        isSearching = true
        searchButton.isOn = true
        pathBar.isHidden = true; searchField.isHidden = false
        searchField.focus()
    }
    func endSearch() {
        guard isSearching else { return }
        isSearching = false
        searchButton.isOn = false
        searchField.stringValue = ""
        searchField.isHidden = true; pathBar.isHidden = false
    }

    @objc private func toggleSidebar() { delegate?.headerToggleSidebar() }
    @objc private func back() { delegate?.headerBack() }
    @objc private func forward() { delegate?.headerForward() }
    @objc private func toggleView() { delegate?.headerToggleViewMode() }
    @objc private func toggleSearch() {
        if isSearching { endSearch(); delegate?.headerSearchClosed() } else { beginSearch() }
    }
}

/// The search field, drawn exactly like the path bar: the same rounded 34-point field, fill, 14-point text and insets,
/// so pressing Search swaps one for the other without the header changing shape. It's a plain text field rather than
/// `NSSearchField`, whose own bezel is shorter and squarer.
@MainActor final class HeaderSearchField: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let icon = NSImageView()
    private let clear = NSButton()
    var onChange: ((String) -> Void)?
    var onCancel: (() -> Void)?

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
        clear.isBordered = false; clear.title = ""
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear Search")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        clear.contentTintColor = .tertiaryLabelColor
        clear.target = self; clear.action = #selector(clearText)
        clear.isHidden = true
        for view in [icon, field, clear] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -4),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), clear.centerYAnchor.constraint(equalTo: centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: 20), clear.heightAnchor.constraint(equalToConstant: 20)
        ])
        updateBackground()
    }
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue; clear.isHidden = newValue.isEmpty }
    }
    func focus() { window?.makeFirstResponder(field) }
    /// Clicking anywhere in the rounded field puts the caret in it, as with the path bar.
    override func mouseDown(with event: NSEvent) { focus() }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBackground() }
    /// The path bar's fill while you type in it.
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        clear.isHidden = field.stringValue.isEmpty
        onChange?(field.stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }
        return false
    }
    @objc private func clearText() {
        stringValue = ""
        onChange?("")
        focus()
    }
}
#endif
