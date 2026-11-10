#if os(macOS)
import AppKit
import XCTest
import HelmCore
@testable import HelmUI

/// The header's controls: the Grid | List switch, the sort button, the menus, tooltips and the sidebar inset.
@MainActor final class HeaderBarTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared // Buttons send their actions through the app.
        HeaderMotion.isDisabledForTesting = true
    }
    override func tearDown() {
        HeaderMotion.isDisabledForTesting = false
        super.tearDown()
    }

    private func tab(_ mode: ViewMode = .grid, sort: ItemSort = .defaultSort) -> TabState {
        var tab = TabState(location: .directory(home.appendingPathComponent("Documents", isDirectory: true)), homeDirectory: home)
        tab.viewMode = mode
        tab.sort = sort
        return tab
    }
    private func isSelected(_ button: NSButton) -> Bool? { (button.accessibilityValue() as? NSNumber)?.boolValue }
    private func enter(_ button: NSView) {
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                           context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        if let event { button.mouseEntered(with: event) }
    }
    private func leave(_ button: NSView) {
        let event = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                           context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        if let event { button.mouseExited(with: event) }
    }

    // MARK: Grid | List

    func testTheSwitchShowsTheViewYoureIn() {
        let header = HeaderBarView()
        var current = tab(.grid)
        header.render(tab: current)
        let control = header.viewSwitch
        XCTAssertEqual(control.mode, .grid)
        XCTAssertEqual(control.segments.map(isSelected), [true, false])
        XCTAssertEqual(control.thumbFrameForTesting, NSRect(x: 0, y: 0, width: 32, height: 32))
        // The view you're in reads in full colour and doesn't react to the pointer; the other one is the one to press.
        XCTAssertEqual(control.segments[0].contentTintColor, .labelColor)
        XCTAssertEqual(control.segments[1].contentTintColor, .secondaryLabelColor)
        XCTAssertFalse(control.segments[0].showsHover)
        XCTAssertTrue(control.segments[1].showsHover)

        current.viewMode = .list
        header.render(tab: current)
        XCTAssertEqual(control.mode, .list)
        XCTAssertEqual(control.segments.map(isSelected), [false, true])
        XCTAssertEqual(control.thumbFrameForTesting, NSRect(x: 32, y: 0, width: 32, height: 32))
        XCTAssertEqual(control.segments[1].contentTintColor, .labelColor)
        XCTAssertTrue(control.segments[0].showsHover)
        XCTAssertFalse(control.segments[1].showsHover)

        // Another tab in grid snaps the thumb back.
        header.render(tab: tab(.grid))
        XCTAssertEqual(control.mode, .grid)
        XCTAssertEqual(control.thumbFrameForTesting.minX, 0)
    }

    func testTheSwitchIsARadioGroupWithBothViewsAlwaysOnShow() {
        let control = ViewModeSwitch()
        XCTAssertEqual(control.accessibilityRole(), .radioGroup)
        XCTAssertEqual(control.accessibilityLabel(), "View")
        XCTAssertEqual(control.segments.map(\.symbolName), ["square.grid.2x2", "list.bullet"])
        XCTAssertEqual(control.segments.map { $0.accessibilityLabel() }, ["Grid", "List"])
        XCTAssertEqual(control.segments.map { $0.accessibilityRole() }, [.radioButton, .radioButton])
        XCTAssertEqual(control.intrinsicContentSize, NSSize(width: 64, height: 32))
        XCTAssertFalse(control.mouseDownCanMoveWindow)
    }

    func testPickingTheOtherViewChoosesItOnceAndTheCurrentOneDoesNothing() {
        let control = ViewModeSwitch()
        var chosen: [ViewMode] = []
        control.onChoose = { chosen.append($0) }
        control.clickForTesting(.list)
        XCTAssertEqual(chosen, [.list])
        XCTAssertEqual(control.mode, .list)
        XCTAssertEqual(control.thumbFrameForTesting.minX, 32)
        control.clickForTesting(.list)
        XCTAssertEqual(chosen, [.list])
        // A real click on the Grid segment goes through the button's action.
        control.segments[0].performClick(nil)
        XCTAssertEqual(chosen, [.list, .grid])
        XCTAssertEqual(control.mode, .grid)
    }

    func testTheHeaderPassesTheSwitchOnToItsDelegate() {
        let header = HeaderBarView()
        let spy = HeaderSpy()
        header.delegate = spy
        header.render(tab: tab(.grid))
        header.viewSwitch.clickForTesting(.list)
        XCTAssertEqual(spy.modes, [.list])
    }

    // MARK: Sort

    func testTheSortButtonSaysTheSortAndEndsInAChevron() {
        let header = HeaderBarView()
        var current = tab()
        header.render(tab: current)
        XCTAssertEqual(header.sortButton.text, "A to Z")
        XCTAssertTrue(header.sortButton.showsDisclosure)
        assertEndsInChevron(header.sortButton)
        for field in SortField.all {
            for ascending in [true, false] {
                current.sort = ItemSort(field: field.field, ascending: ascending, directoriesFirst: true)
                header.render(tab: current)
                let direction = SortField.direction(field.field, ascending: ascending)
                XCTAssertEqual(header.sortButton.text, field.field == .kind ? "Kind \(direction)" : direction)
                XCTAssertEqual(header.sortButton.shownWords, header.sortButton.text)
                assertEndsInChevron(header.sortButton)
                XCTAssertEqual(header.sortButton.accessibilityValue() as? String, "\(field.title), \(direction)")
                XCTAssertEqual(header.sortButton.toolTip, "Sorted by \(field.title), \(direction). Sort and view options (⌘J)")
            }
        }
        current.sort = ItemSort(field: .relevance, ascending: true, directoriesFirst: true)
        header.render(tab: current)
        XCTAssertEqual(header.sortButton.text, "Best Match")
    }

    func testANarrowHeaderDropsTheSortWordsFirstAndKeepsTheChevron() {
        let header = HeaderBarView()
        header.render(tab: tab())
        let needed = header.widthWithSortWords
        header.setFrameSize(NSSize(width: needed - 1, height: HeaderBarView.height))
        XCTAssertTrue(header.sortButton.isCompact)
        XCTAssertEqual(header.sortButton.shownWords, "")
        assertEndsInChevron(header.sortButton)
        XCTAssertEqual(header.sortButton.text, "A to Z", "The words stay for the tooltip and VoiceOver.")
        // Until there's clearly room again it stays as it is, so it doesn't flicker at the edge.
        header.setFrameSize(NSSize(width: needed + HeaderBarView.wordsReturnAfter - 1, height: HeaderBarView.height))
        XCTAssertTrue(header.sortButton.isCompact)
        header.setFrameSize(NSSize(width: needed + HeaderBarView.wordsReturnAfter, height: HeaderBarView.height))
        XCTAssertFalse(header.sortButton.isCompact)
        XCTAssertEqual(header.sortButton.shownWords, "A to Z")
        header.setFrameSize(NSSize(width: needed, height: HeaderBarView.height))
        XCTAssertFalse(header.sortButton.isCompact)
    }

    func testTheRoomForTheSortWordsDependsOnTheWordsTheSidebarAndTheFolder() {
        let header = HeaderBarView()
        var current = tab()
        header.render(tab: current)
        let shortWords = header.sortButton.widthWithWords
        let short = header.widthWithSortWords
        current.sort = ItemSort(field: .size, ascending: true, directoriesFirst: true)
        header.render(tab: current)
        XCTAssertEqual(header.widthWithSortWords - short, header.sortButton.widthWithWords - shortWords, accuracy: 0.5,
                       "Longer words need that much more.")
        let withSidebar = header.widthWithSortWords
        header.setSidebarVisible(false)
        XCTAssertEqual(header.widthWithSortWords - withSidebar, 76, accuracy: 0.5, "The buttons move clear of the window buttons.")
        header.setSidebarVisible(true)
        // A folder whose name needs more than the usual room for the path asks for all of it.
        let long = home.appendingPathComponent("Documents/Photographs From The Summer Trip And More", isDirectory: true)
        current.location = .directory(long)
        header.pathBar.render(location: current.location, home: home, editor: current.addressBar)
        header.render(tab: current)
        XCTAssertGreaterThan(header.pathBar.minimumWidth, HeaderBarView.pathRoom)
        let needs = max(header.pathBar.minimumWidth, header.searchField.minimumWidth)
        XCTAssertEqual(header.widthWithSortWords - withSidebar, needs - HeaderBarView.pathRoom, accuracy: 0.5)
        // Before the bar has a width there's nothing to decide.
        XCTAssertFalse(header.sortButton.isCompact)
    }

    /// The width the bar works out for the words is the one Auto Layout gives it: at exactly that width the path gets
    /// its room and nothing is squeezed.
    func testTheWorkedOutWidthMatchesTheLayout() {
        let places = [(home.appendingPathComponent("Documents", isDirectory: true), ItemSort(field: .size, ascending: true)),
                      (home.appendingPathComponent("Documents/Reports/Quarterly", isDirectory: true), ItemSort.defaultSort),
                      (home, ItemSort(field: .dateModified, ascending: false))]
        for (location, sort) in places {
            for sidebar in [true, false] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 80), styleMask: [.titled],
                                      backing: .buffered, defer: true)
                let header = HeaderBarView()
                guard let content = window.contentView else { return XCTFail("no content view") }
                content.addSubview(header)
                let width = header.widthAnchor.constraint(equalToConstant: 1000)
                NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: content.topAnchor),
                                             header.leadingAnchor.constraint(equalTo: content.leadingAnchor), width])
                var current = TabState(location: .directory(location), homeDirectory: home)
                current.sort = sort
                header.pathBar.render(location: current.location, home: home, editor: current.addressBar)
                header.setSidebarVisible(sidebar)
                header.render(tab: current)
                width.constant = header.widthWithSortWords
                content.layoutSubtreeIfNeeded()
                let label = "\(location.lastPathComponent), sidebar \(sidebar)"
                XCTAssertFalse(header.sortButton.isCompact, label)
                XCTAssertEqual(header.frame.width, header.widthWithSortWords, accuracy: 0.5, label)
                XCTAssertEqual(header.sortButton.frame.width, header.sortButton.widthWithWords, accuracy: 0.5, label)
                let room = max(HeaderBarView.pathRoom, header.pathBar.minimumWidth, header.searchField.minimumWidth)
                XCTAssertEqual(header.pathBar.frame.width, room, accuracy: 0.5, label)
                // The search field's minimum is the one its own constraints set.
                XCTAssertEqual(header.searchField.minimumWidth, header.searchField.fittingSize.width, accuracy: 0.5, label)
            }
        }
    }

    func testThePathBarsMinimumIsWhatItNeedsAtItsNarrowest() {
        for location in [home.appendingPathComponent("Documents", isDirectory: true),
                         home.appendingPathComponent("Documents/Reports/Quarterly", isDirectory: true), home] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 80), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            let bar = PathBarView()
            guard let content = window.contentView else { return XCTFail("no content view") }
            content.addSubview(bar)
            bar.translatesAutoresizingMaskIntoConstraints = false
            let current = TabState(location: .directory(location), homeDirectory: home)
            bar.render(location: current.location, home: home, editor: current.addressBar)
            let width = bar.widthAnchor.constraint(equalToConstant: bar.minimumWidth)
            NSLayoutConstraint.activate([bar.topAnchor.constraint(equalTo: content.topAnchor),
                                         bar.leadingAnchor.constraint(equalTo: content.leadingAnchor), width])
            // The bar picks what to show from its width, which takes a second pass.
            content.layoutSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(bar.fittingSize.width, bar.minimumWidth, accuracy: 0.5, location.lastPathComponent)
        }
    }

    func testTheCompactSortButtonIsNarrower() {
        let button = FlatMenuButton(symbol: "arrow.up.arrow.down", label: "Sort and View Options", title: "Newest first")
        button.showsDisclosure = true
        let roomy = button.fittingWidth
        button.isCompact = true
        XCTAssertLessThan(button.fittingWidth, roomy - 40)
        XCTAssertGreaterThanOrEqual(button.fittingWidth, 34)
    }

    /// The chevron comes last, at the button's padded trailing edge.
    private func assertEndsInChevron(_ button: FlatMenuButton, file: StaticString = #filePath, line: UInt = #line) {
        let size = NSSize(width: button.fittingWidth, height: 32)
        let parts = button.parts(in: NSRect(x: 0, y: 0, width: size.width, height: 32))
        guard let chevron = parts.chevron else { return XCTFail("no chevron", file: file, line: line) }
        XCTAssertGreaterThanOrEqual(chevron.minX, parts.words?.maxX ?? parts.icon.maxX, file: file, line: line)
        XCTAssertEqual(chevron.maxX, size.width - 8, accuracy: 1, file: file, line: line)
    }

    func testEverySortTitleFitsOnOneLineInsideThePadding() {
        let button = FlatMenuButton(symbol: "arrow.up.arrow.down", label: "Sort and View Options", title: "A to Z")
        button.showsDisclosure = true
        let titles = SortField.all.flatMap { field in [true, false].map { SortField.direction(field.field, ascending: $0) } }
            + ["Kind A to Z", "Kind Z to A", "Best Match"]
        for title in titles {
            button.setTitle(title, animated: false)
            let size = NSSize(width: button.fittingWidth, height: 32)
            let parts = button.parts(in: NSRect(x: 0, y: 0, width: size.width, height: 32))
            XCTAssertEqual(parts.icon.minX, 8, accuracy: 1, title)
            guard let words = parts.words, let chevron = parts.chevron else { XCTFail(title); continue }
            // One line of 13-point text, 4 points after the icon and 4 before the chevron.
            XCTAssertLessThanOrEqual(words.height, 17, title)
            XCTAssertEqual(words.minX - parts.icon.maxX, 4, accuracy: 0.5, title)
            XCTAssertEqual(chevron.minX - words.maxX, 4, accuracy: 0.5, title)
            XCTAssertEqual(chevron.maxX, size.width - 8, accuracy: 1, title)
            XCTAssertEqual(words.midY, 16, accuracy: 1, title)
            XCTAssertEqual(chevron.midY, 16, accuracy: 1, title)
        }
    }

    func testTheSortButtonWidensAndNarrowsWithItsWordsAtOnce() {
        // Without waiting for the window to display, and with motion on: the words used to spill out of the old
        // width until the window displayed, and an animated resize could stall at the old width.
        HeaderMotion.isDisabledForTesting = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 80), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let header = HeaderBarView()
        guard let content = window.contentView else { return XCTFail("no content view") }
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor), header.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        var current = tab()
        header.render(tab: current)
        content.layoutSubtreeIfNeeded()
        let sorts = [ItemSort(field: .dateModified, ascending: false), ItemSort(field: .name, ascending: true),
                     ItemSort(field: .size, ascending: true), ItemSort(field: .kind, ascending: false), ItemSort(field: .name, ascending: false)]
        var widths: Set<CGFloat> = []
        for sort in sorts {
            current.sort = sort
            header.render(tab: current)
            XCTAssertEqual(header.sortButton.frame.width, header.sortButton.fittingWidth, accuracy: 0.5, header.sortButton.text)
            widths.insert(header.sortButton.frame.width)
        }
        XCTAssertGreaterThan(widths.count, 2, "Different words, different widths.")
    }

    // MARK: Menus

    func testTheMainMenuIsDotsLitWhileOpenAndHangsFromItsTrailingEdge() {
        let header = HeaderBarView()
        let button = header.menuButton
        XCTAssertEqual(button.symbolName, "ellipsis.circle")
        XCTAssertEqual(button.accessibilityLabel(), "Main Menu")
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: "")
        button.menuProvider = { menu }
        XCTAssertEqual(button.accessibilityRole(), .menuButton)
        button.frame = NSRect(x: 0, y: 0, width: 34, height: 32)
        var litWhileOpen = false
        var origin: NSPoint?
        button.presentMenu = { _, point, _ in
            litWhileOpen = button.isOn
            origin = point
        }
        button.openForTesting()
        XCTAssertTrue(litWhileOpen)
        XCTAssertFalse(button.isOn)
        XCTAssertEqual(origin?.x ?? 0, 34 - menu.size.width, accuracy: 0.5)
        XCTAssertEqual(origin?.y ?? 0, 36, accuracy: 0.5)
    }

    func testThePathBarsFolderMenuOpensInwardsAndNamesTheFolder() {
        let bar = PathBarView()
        let current = tab()
        bar.render(location: current.location, home: home, editor: current.addressBar)
        let button = bar.folderMenuButtonForTesting
        XCTAssertEqual(button.symbolName, "ellipsis")
        XCTAssertTrue(button.alignsMenuToTrailingEdge)
        XCTAssertEqual(button.toolTip, "Actions for “Documents”")
        XCTAssertEqual(button.accessibilityLabel(), "Actions for “Documents”")
    }

    // MARK: Buttons

    func testButtonsLightOnHoverPressAndWhileOn() {
        let button = FlatButton(symbol: "magnifyingglass", label: "Search", target: nil, action: nil)
        XCTAssertEqual(button.fillAlpha, 0)
        enter(button)
        XCTAssertEqual(button.fillAlpha, 0.09, accuracy: 0.001)
        button.cell?.highlight(true, withFrame: button.bounds, in: button)
        XCTAssertTrue(button.isPressed)
        XCTAssertEqual(button.fillAlpha, 0.20, accuracy: 0.001)
        button.cell?.highlight(false, withFrame: button.bounds, in: button)
        XCTAssertEqual(button.fillAlpha, 0.09, accuracy: 0.001)
        button.isOn = true
        XCTAssertEqual(button.fillAlpha, 0.17, accuracy: 0.001)
        leave(button)
        XCTAssertEqual(button.fillAlpha, 0.14, accuracy: 0.001)
        XCTAssertEqual(button.layer?.backgroundColor?.alpha ?? 0, 0.14, accuracy: 0.001)
        button.isOn = false
        XCTAssertEqual(button.fillAlpha, 0)
        button.isEnabled = false
        XCTAssertEqual(button.alphaValue, 0.35, accuracy: 0.001)
        enter(button)
        XCTAssertEqual(button.fillAlpha, 0, "A disabled button doesn't light up.")
    }

    func testAChoiceAlreadyMadeNeitherLightsNorPresses() {
        let button = FlatButton(symbol: "square.grid.2x2", label: "Grid", minimumWidth: 32, target: nil, action: nil)
        button.showsHover = false
        enter(button)
        XCTAssertEqual(button.fillAlpha, 0)
        button.cell?.highlight(true, withFrame: button.bounds, in: button)
        XCTAssertEqual(button.fillAlpha, 0)
    }

    func testSearchIsAToggleThatSaysHowToClose() {
        let header = HeaderBarView()
        header.render(tab: tab())
        XCTAssertEqual(header.searchButton.accessibilityRole(), .checkBox)
        XCTAssertEqual(header.searchButton.accessibilitySubrole(), .toggle)
        XCTAssertEqual(isSelected(header.searchButton), false)
        XCTAssertEqual(header.searchButton.toolTip, "Search (⌘F)")
        header.beginSearch()
        XCTAssertTrue(header.searchButton.isOn)
        XCTAssertEqual(isSelected(header.searchButton), true)
        XCTAssertEqual(header.searchButton.toolTip, "Close Search (Esc)")
        header.endSearch()
        XCTAssertEqual(isSelected(header.searchButton), false)
        XCTAssertEqual(header.searchButton.toolTip, "Search (⌘F)")
    }

    func testTooltipsNameTheShortcuts() {
        let header = HeaderBarView()
        header.render(tab: tab())
        XCTAssertEqual(header.sidebarButton.toolTip, "Hide Sidebar (⌃⌘S)")
        XCTAssertEqual(header.backButton.toolTip, "Back (⌘[)")
        XCTAssertEqual(header.forwardButton.toolTip, "Forward (⌘])")
        XCTAssertEqual(header.viewSwitch.segments.map(\.toolTip), ["Grid (⌘1)", "List (⌘2)"])
        XCTAssertEqual(header.sortButton.toolTip, "Sorted by Name, A to Z. Sort and view options (⌘J)")
        // VoiceOver hears the name without the keys.
        XCTAssertEqual(header.backButton.accessibilityLabel(), "Back")
    }

    func testEveryHeaderButtonFillIsExactlyItsLayoutSize() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 120), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let header = HeaderBarView()
        guard let content = window.contentView else { return XCTFail("no content view") }
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor), header.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        header.render(tab: tab())
        content.layoutSubtreeIfNeeded()
        let buttons = [header.sidebarButton, header.backButton, header.forwardButton, header.searchButton, header.sortButton,
                       header.menuButton] + header.viewSwitch.segments
        // Symbol insets used to make each fill a different height, from 33 to 38 points.
        for button in buttons {
            XCTAssertEqual(button.frame.height, 32, "\(button.accessibilityLabel() ?? "")")
            XCTAssertEqual(button.frame.midY, header.viewSwitch.frame.midY, accuracy: 0.5, "\(button.accessibilityLabel() ?? "")")
        }
        XCTAssertEqual(header.pathBar.folderMenuButtonForTesting.frame.height, 26)
    }

    // MARK: Sidebar

    func testTheSidebarButtonSaysWhichWayItGoesAndTheButtonsClearTheWindowButtons() {
        let header = HeaderBarView()
        XCTAssertEqual(header.leadingInset, 8)
        header.setSidebarVisible(false)
        XCTAssertEqual(header.leadingInset, 84)
        XCTAssertFalse(header.isSidebarVisible)
        XCTAssertEqual(header.sidebarButton.toolTip, "Show Sidebar (⌃⌘S)")
        XCTAssertEqual(header.sidebarButton.accessibilityLabel(), "Show Sidebar")
        header.setSidebarVisible(false)
        XCTAssertEqual(header.leadingInset, 84)
        header.setSidebarVisible(true)
        XCTAssertEqual(header.leadingInset, 8)
        XCTAssertEqual(header.sidebarButton.toolTip, "Hide Sidebar (⌃⌘S)")
    }

    // MARK: Popover

    func testThePopoverHintNamesWhatPressingAgainDoes() {
        XCTAssertEqual(HeaderViewOptionsView.hint(for: ItemSort(field: .name, ascending: true)), "Press Name again for Z to A.")
        XCTAssertEqual(HeaderViewOptionsView.hint(for: ItemSort(field: .name, ascending: false)), "Press Name again for A to Z.")
        XCTAssertEqual(HeaderViewOptionsView.hint(for: ItemSort(field: .dateModified, ascending: false)), "Press Modified again for oldest first.")
        XCTAssertEqual(HeaderViewOptionsView.hint(for: ItemSort(field: .size, ascending: false)), "Press Size again for smallest first.")
        XCTAssertEqual(HeaderViewOptionsView.hint(for: ItemSort(field: .kind, ascending: true)), "Press Kind again for Z to A.")
        XCTAssertEqual(HeaderViewOptionsView.hint(for: ItemSort(field: .relevance, ascending: true)), "Best Match puts the closest results first.")
    }

    /// A field the popover doesn't list, such as an order only some places offer, is never taken for Best Match.
    func testASortTheListDoesntNameIsToldByItsDirection() {
        let unlisted = SortField.all.filter { $0.field != .dateModified }
        let newest = ItemSort(field: .dateModified, ascending: false)
        XCTAssertEqual(HeaderViewOptionsView.hint(for: newest, fields: unlisted), "Press the current sort again to reverse it.")
        let described = HeaderBarView.describe(newest, fields: unlisted)
        XCTAssertEqual(described.value, "Newest first")
        XCTAssertEqual(described.tip, "Sorted: Newest first.")
        // Listed fields and Best Match read as before.
        XCTAssertEqual(HeaderBarView.describe(newest).value, "Modified, Newest first")
        XCTAssertEqual(HeaderBarView.describe(newest).tip, "Sorted by Modified, Newest first.")
        XCTAssertEqual(HeaderBarView.describe(ItemSort(field: .relevance, ascending: true), fields: []).value, "Best Match")
    }

    func testTheSearchScopeNamesHomeAsThePathBarDoes() {
        let header = HeaderBarView()
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        header.home = home
        header.render(tab: TabState(location: .directory(home), homeDirectory: home))
        XCTAssertEqual(header.searchField.placeholderStringForTesting, "Search Home")
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        header.render(tab: TabState(location: .directory(documents), homeDirectory: home))
        XCTAssertEqual(header.searchField.placeholderStringForTesting, "Search Documents")
    }

    func testRecentsLastOpenedIsNamedInTheTooltipAndHint() {
        let recent = ItemSort(field: .lastOpened, ascending: false)
        let described = HeaderBarView.describe(recent)
        XCTAssertTrue(described.value.hasPrefix("Last Opened, "), described.value)
        XCTAssertTrue(described.tip.hasPrefix("Sorted by Last Opened, "), described.tip)
        XCTAssertTrue(HeaderViewOptionsView.hint(for: recent).hasPrefix("Press Last Opened again for "),
                      HeaderViewOptionsView.hint(for: recent))
    }
}

/// Records what the header asks of its window.
@MainActor final class HeaderSpy: HeaderBarDelegate {
    var modes: [ViewMode] = []
    var changes: [String] = []
    var closed = 0
    var dismissed = 0
    var moves = 0
    var movesToResults = true
    func headerToggleSidebar() {}
    func headerBack() {}
    func headerForward() {}
    func headerSetViewMode(_ mode: ViewMode) { modes.append(mode) }
    func headerShowViewOptions(from button: NSView) {}
    func headerMainMenu() -> NSMenu? { nil }
    func headerSearchChanged(_ text: String) { changes.append(text) }
    func headerSearchClosed() { closed += 1 }
    func headerSearchDismissed() { dismissed += 1 }
    func headerSearchScopeChanged() {}
    func headerSearchMoveToResults() -> Bool { moves += 1; return movesToResults }
}
#endif
