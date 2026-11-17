#if os(macOS)
import AppKit
import XCTest
import HelmCore
@testable import HelmUI

/// The header's controls: the view button, the sort button, the spark, the menus, the search field's spark,
/// tooltips and the sidebar inset.
@MainActor final class HeaderBarTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    /// Windows a test lays the header out in, kept until it ends.
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared // Buttons send their actions through the app.
        HeaderMotion.isDisabledForTesting = true
    }
    override func tearDown() {
        windows = []
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

    // MARK: The view button

    func testTheViewButtonShowsTheViewYoudSwitchTo() {
        let header = HeaderBarView()
        var current = tab(.grid)
        header.render(tab: current)
        let button = header.viewButton
        // In the grid it offers the list: the list's icon, its key, and what pressing it does for VoiceOver.
        XCTAssertEqual(button.mode, .grid)
        XCTAssertEqual(button.offered, .list)
        XCTAssertEqual(button.symbolName, "list.bullet")
        XCTAssertEqual(button.toolTip, "List (⌘2)")
        XCTAssertEqual(button.accessibilityLabel(), "Show as List")
        XCTAssertEqual(button.accessibilityValue() as? String, "Grid")

        current.viewMode = .list
        header.render(tab: current)
        XCTAssertEqual(button.mode, .list)
        XCTAssertEqual(button.offered, .grid)
        XCTAssertEqual(button.symbolName, "square.grid.2x2")
        XCTAssertEqual(button.toolTip, "Grid (⌘1)")
        XCTAssertEqual(button.accessibilityLabel(), "Show as Grid")
        XCTAssertEqual(button.accessibilityValue() as? String, "List")

        // Another tab in the grid offers the list again.
        header.render(tab: tab(.grid))
        XCTAssertEqual(button.symbolName, "list.bullet")
        XCTAssertEqual(button.toolTip, "List (⌘2)")
    }

    func testTheViewButtonIsOneHeaderButton() {
        let button = ViewModeButton()
        XCTAssertNotEqual(button.accessibilityRole(), .radioButton, "One button, not a radio group's half.")
        XCTAssertEqual(button.laidOutWidth, 34, "As wide as the header's other icon buttons.")
        XCTAssertTrue(button.showsHover)
        XCTAssertFalse(button.mouseDownCanMoveWindow)
    }

    func testEachPressSwitchesToTheViewOnOffer() {
        let button = ViewModeButton()
        var chosen: [ViewMode] = []
        button.onChoose = { chosen.append($0) }
        button.clickForTesting()
        XCTAssertEqual(chosen, [.list])
        XCTAssertEqual(button.mode, .list)
        XCTAssertEqual(button.toolTip, "Grid (⌘1)")
        // A real click goes through the button's action, and goes back.
        button.performClick(nil)
        XCTAssertEqual(chosen, [.list, .grid])
        XCTAssertEqual(button.mode, .grid)
        XCTAssertEqual(button.toolTip, "List (⌘2)")
        // Showing the view that's already on show changes nothing and chooses nothing.
        button.setMode(.grid, animated: false)
        XCTAssertEqual(chosen, [.list, .grid])
    }

    func testTheHeaderPassesTheViewButtonOnToItsDelegate() {
        let header = HeaderBarView()
        let spy = HeaderSpy()
        header.delegate = spy
        header.render(tab: tab(.grid))
        header.viewButton.clickForTesting()
        XCTAssertEqual(spy.modes, [.list])
        header.render(tab: tab(.list))
        header.viewButton.clickForTesting()
        XCTAssertEqual(spy.modes, [.list, .grid])
    }

    // MARK: The spark

    /// The header laid out at a comfortable width in a window that's never shown.
    private func laidOut(width: CGFloat = 1000) -> (NSWindow, HeaderBarView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 120), styleMask: [.titled],
                              backing: .buffered, defer: true)
        windows.append(window)
        let header = HeaderBarView()
        if let content = window.contentView {
            content.addSubview(header)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: content.topAnchor),
                header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            ])
            header.render(tab: tab())
            content.layoutSubtreeIfNeeded()
        }
        return (window, header)
    }

    func testTheSparkSitsBetweenTheSortAndTheMainMenu() {
        let (_, header) = laidOut()
        let spark = header.sparkButton
        XCTAssertEqual(spark.frame.height, 32)
        XCTAssertEqual(spark.frame.width, 34)
        XCTAssertEqual(spark.frame.midY, header.menuButton.frame.midY, accuracy: 0.5)
        // The view and the sort, then a group's gap, then the spark and the main menu side by side, a little apart so
        // their two lit fills never meet.
        XCTAssertEqual(header.sortButton.frame.minX - header.viewButton.frame.maxX, 2, accuracy: 0.5)
        XCTAssertEqual(spark.frame.minX - header.sortButton.frame.maxX, 6, accuracy: 0.5)
        XCTAssertEqual(header.menuButton.frame.minX - spark.frame.maxX, 4, accuracy: 0.5)
        XCTAssertEqual(header.viewButton.frame.minX - header.searchButton.frame.maxX, 6, accuracy: 0.5)
        let menu = header.convert(header.menuButton.bounds, from: header.menuButton)
        XCTAssertEqual(header.bounds.width - menu.maxX, 8, accuracy: 0.5, "The main menu stays at the end.")
    }

    func testTheSparkLightsOnlyWhileThePanelIsOpen() {
        let header = HeaderBarView()
        let spark = header.sparkButton
        XCTAssertFalse(spark.isLit)
        XCTAssertFalse(spark.isOn)
        XCTAssertEqual(isSelected(spark), false)
        // A request running doesn't light it; only the panel being open does.
        header.setAIPanel(open: false, working: true, ready: true)
        XCTAssertFalse(spark.isLit)
        XCTAssertFalse(spark.isOn)
        XCTAssertTrue(spark.isWorking)
        header.setAIPanel(open: true, working: false, ready: true)
        XCTAssertTrue(spark.isLit)
        XCTAssertTrue(spark.isOn, "Lit, it has the lit fill of a toggle that's on.")
        XCTAssertEqual(isSelected(spark), true)
        XCTAssertEqual(spark.fillAlpha, 0.14, accuracy: 0.001)
        XCTAssertFalse(spark.isWorking)
        header.setAIPanel(open: false, working: false, ready: true)
        XCTAssertFalse(spark.isLit)
        XCTAssertFalse(spark.isOn)
        XCTAssertEqual(spark.fillAlpha, 0)
    }

    func testTheSparkDrawsTheGradientWhileLitOrWorkingAndNotUnderIncreaseContrast() {
        defer { SparkButton.increasesContrastForTesting = nil }
        SparkButton.increasesContrastForTesting = false
        let spark = HeaderBarView().sparkButton
        XCTAssertFalse(spark.drawsGradient, "At rest it's in the label colour.")
        spark.isLit = true
        XCTAssertTrue(spark.drawsGradient)
        spark.isLit = false
        spark.isWorking = true
        XCTAssertTrue(spark.drawsGradient)
        SparkButton.increasesContrastForTesting = true
        XCTAssertFalse(spark.drawsGradient)
        spark.isLit = true
        XCTAssertFalse(spark.drawsGradient, "Under Increase Contrast the lit fill alone says it's open.")
    }

    func testTheSparkTurnsOnlyWhileWorkingInAWindowWithMotion() throws {
        let (_, header) = laidOut()
        let spark = header.sparkButton
        // Under Reduce Motion the gradient is still.
        header.setAIPanel(open: true, working: true, ready: true)
        XCTAssertFalse(spark.isShimmering)
        header.setAIPanel(open: true, working: false, ready: true)
        HeaderMotion.isDisabledForTesting = false
        defer { HeaderMotion.isDisabledForTesting = true }
        try XCTSkipIf(HeaderMotion.isReduced, "This Mac has Reduce Motion on.")
        header.setAIPanel(open: true, working: true, ready: true)
        XCTAssertTrue(spark.isShimmering)
        let start = spark.shimmerTurn
        // The timer steps it on the main run loop; a busy machine can hold the first step back a little.
        let deadline = Date().addingTimeInterval(2)
        while spark.shimmerTurn == start, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertNotEqual(spark.shimmerTurn, start, "The gradient turns.")
        header.setAIPanel(open: true, working: false, ready: true)
        XCTAssertFalse(spark.isShimmering)
        XCTAssertEqual(spark.shimmerTurn, 0, "It rests where the still mark has it.")
        // Out of a window it doesn't turn either.
        let loose = SparkButton(target: nil, action: nil)
        loose.isWorking = true
        XCTAssertFalse(loose.isShimmering)
    }

    func testTheSparkFollowsReduceMotionAndIncreaseContrastWhenTheyChange() throws {
        let (_, header) = laidOut()
        let spark = header.sparkButton
        HeaderMotion.isDisabledForTesting = false
        defer { HeaderMotion.isDisabledForTesting = true; SparkButton.increasesContrastForTesting = nil }
        try XCTSkipIf(HeaderMotion.isReduced, "This Mac has Reduce Motion on.")
        header.setAIPanel(open: true, working: true, ready: true)
        XCTAssertTrue(spark.isShimmering)
        // Reduce Motion turned on while the request runs: the gradient stops turning at once.
        HeaderMotion.isDisabledForTesting = true
        SparkButton.increasesContrastForTesting = true
        spark.needsDisplay = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                   object: NSWorkspace.shared)
        XCTAssertFalse(spark.isShimmering)
        XCTAssertEqual(spark.shimmerTurn, 0)
        // Increase Contrast turned on: the spark is drawn again, in the label colour.
        XCTAssertTrue(spark.needsDisplay)
        XCTAssertFalse(spark.drawsGradient)
        header.setAIPanel(open: true, working: false, ready: true)
    }

    func testTheSparksTooltipSaysWhatPressingItDoes() {
        let header = HeaderBarView()
        let spark = header.sparkButton
        XCTAssertEqual(spark.accessibilityLabel(), "AI Panel")
        XCTAssertEqual(spark.accessibilityRole(), .checkBox)
        XCTAssertEqual(spark.toolTip, "Set Up AI Mode", "Until a model is ready it sets AI mode up.")
        header.setAIPanel(open: false, working: false, ready: true)
        XCTAssertEqual(spark.toolTip, "AI Panel (⌃⌘I)")
        header.setAIPanel(open: true, working: false, ready: false)
        XCTAssertEqual(spark.toolTip, "Set Up AI Mode")
    }

    func testPressingTheSparkAsksTheWindowAndLeavesTheLightToIt() {
        let header = HeaderBarView()
        let spy = HeaderSpy()
        header.delegate = spy
        header.sparkButton.performClick(nil)
        XCTAssertEqual(spy.panelToggles, 1)
        XCTAssertFalse(header.sparkButton.isLit, "Only the window says the panel is open.")
        header.sparkButton.performClick(nil)
        XCTAssertEqual(spy.panelToggles, 2)
    }

    // MARK: The search field's spark

    func testTheFieldsLeadingMarkIsTheMagnifierUntilAISearchIsAvailable() {
        let header = HeaderBarView()
        header.render(tab: tab())
        let field = header.searchField
        XCTAssertEqual(field.leadingMark, "magnifier")
        // On without being available is still the magnifier.
        header.setAISearch(available: false, on: true)
        XCTAssertEqual(field.leadingMark, "magnifier")
        XCTAssertFalse(field.isAIOn)
        header.setAISearch(available: true, on: false)
        XCTAssertEqual(field.leadingMark, "spark")
        XCTAssertEqual(field.placeholderStringForTesting, "Search Documents")
        header.setAISearch(available: true, on: true)
        XCTAssertEqual(field.leadingMark, "spark lit")
        XCTAssertEqual(field.placeholderStringForTesting, "Describe a file in Documents")
        header.chooseSearchScopeForTesting(everywhere: true)
        XCTAssertEqual(field.placeholderStringForTesting, "Describe a file on this Mac")
        header.setAISearch(available: true, on: false)
        XCTAssertEqual(field.placeholderStringForTesting, "Search This Mac")
        header.setAISearch(available: false, on: false)
        XCTAssertEqual(field.leadingMark, "magnifier")
    }

    func testANarrowFieldEndsItsPlaceholderInAnEllipsis() {
        let header = HeaderBarView()
        header.render(tab: tab())
        XCTAssertTrue(header.searchField.placeholderTruncatesForTesting, "the words end in … rather than a cut letter")
        header.setAISearch(available: true, on: true)
        XCTAssertTrue(header.searchField.placeholderTruncatesForTesting)
        XCTAssertEqual(header.searchField.placeholderStringForTesting, "Describe a file in Documents")
    }

    func testTheFieldsSparkSitsOnTheLitFillWhileOn() {
        let (_, header) = laidOut()
        header.beginSearch()
        let field = header.searchField
        header.setAISearch(available: true, on: false)
        XCTAssertFalse(field.aiLitShownForTesting)
        let width = field.frame.width
        header.setAISearch(available: true, on: true)
        XCTAssertTrue(field.aiLitShownForTesting, "on reads as a header button that is on")
        XCTAssertEqual(field.frame.width, width, "and adds no width")
        header.setAISearch(available: false, on: false)
        XCTAssertFalse(field.aiLitShownForTesting)
    }

    func testIconButtonsAreExactlyTheirWidthAndDrawTheirSymbolWhole() throws {
        let (_, header) = laidOut()
        for button in [header.sidebarButton, header.backButton, header.forwardButton, header.searchButton, header.viewButton,
                       header.sparkButton, header.menuButton] as [FlatButton] {
            XCTAssertEqual(button.frame.width, 34, accuracy: 0.5, button.accessibilityLabel() ?? "")
            XCTAssertEqual(button.frame.height, 32, accuracy: 0.5, button.accessibilityLabel() ?? "")
        }
        XCTAssertEqual(header.menuButton.imageScaling, .scaleNone, "the symbol is never scaled down to a short image rect")
        let ink = try XCTUnwrap(header.menuButton.inkRectForTesting())
        XCTAssertTrue(header.menuButton.bounds.insetBy(dx: 1, dy: 1).contains(ink), "\(ink)")
        XCTAssertEqual(ink.width, 15, accuracy: 1.5)
        XCTAssertEqual(ink.height, 15, accuracy: 1.5)
        XCTAssertEqual(header.menuButton.layerContentsPlacement, .scaleAxesIndependently,
                       "an icon on its own fills the button it was drawn for")
        XCTAssertEqual(header.sortButton.layerContentsPlacement, .center, "the sort's words stay centred as it resizes")
    }

    /// An icon on its own is drawn as dark as a plain button draws the same symbol in the label colour, in light and
    /// dark, at rest, under the pointer and lit, and as dim as one that's off: drawing it whole doesn't change its ink. A palette colour applied the
    /// label colour's transparency twice, so the darkest light-mode pixel was 72 where the button's is 39.
    func testIconButtonsDrawTheirSymbolInTheFullLabelColour() throws {
        let (window, header) = laidOut()
        let content = try XCTUnwrap(window.contentView)
        /// The strongest ink on a clear bitmap, laid on white in light and on black in dark, as a 0-255 grey.
        func strongest(_ rep: NSBitmapImageRep, dark: Bool) -> Double {
            var best: Double = dark ? 0 : 255
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.01 else { continue }
                    let grey = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    let over = grey * color.alphaComponent + (dark ? 0 : 1) * (1 - color.alphaComponent)
                    let value = (Double(over) * 255).rounded()
                    best = dark ? max(best, value) : min(best, value)
                }
            }
            return best
        }
        func cached(_ view: NSView) throws -> NSBitmapImageRep {
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        func plainButton(like button: FlatButton) -> NSButton {
            let plain = NSButton(frame: button.frame)
            plain.isBordered = false
            plain.title = ""
            plain.image = NSImage(systemSymbolName: button.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: button.symbolPointSize, weight: .regular))
            plain.imagePosition = .imageOnly
            plain.imageScaling = .scaleNone
            plain.contentTintColor = .labelColor
            plain.isEnabled = button.isEnabled
            plain.alphaValue = button.alphaValue
            content.addSubview(plain)
            return plain
        }
        for button in [header.sidebarButton, header.searchButton, header.viewButton, header.menuButton] as [FlatButton] {
            XCTAssertTrue(button.isEnabled)
            let plain = plainButton(like: button)
            defer { plain.removeFromSuperview() }
            let name = button.accessibilityLabel() ?? button.symbolName
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                let dark = appearance == .darkAqua
                let expected = strongest(try cached(plain), dark: dark)
                XCTAssertEqual(strongest(try cached(button), dark: dark), expected, accuracy: 3,
                               "\(name) at rest, \(appearance.rawValue)")
                for state in ["rest", "hover", "lit"] {
                    if state == "hover" { enter(button) }
                    if state == "lit" { button.isOn = true }
                    let drawn = try XCTUnwrap(button.drawingForTesting())
                    XCTAssertEqual(strongest(drawn, dark: dark), expected, accuracy: 3,
                                   "\(name) \(state), \(appearance.rawValue)")
                }
                button.isOn = false
                leave(button)
            }
        }
        // Back and Forward, off with no history, are dimmed as a plain button that's off dims its symbol.
        for button in [header.backButton, header.forwardButton] as [FlatButton] {
            XCTAssertFalse(button.isEnabled)
            let plain = plainButton(like: button)
            defer { plain.removeFromSuperview() }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                let dark = appearance == .darkAqua
                XCTAssertEqual(strongest(try cached(button), dark: dark), strongest(try cached(plain), dark: dark), accuracy: 3,
                               "\(button.accessibilityLabel() ?? "") off, \(appearance.rawValue)")
            }
        }
        window.appearance = nil
    }

    /// The spark's ink is measured the same way at rest, in the label colour, and lit, in the gradient: about 15
    /// points, the size of the main menu's.
    func testTheSparksInkIsTheSameSizeAtRestAndLit() throws {
        let (_, header) = laidOut()
        let spark = header.sparkButton
        let rest = try XCTUnwrap(spark.inkRectForTesting(threshold: 0.5))
        spark.isLit = true
        let lit = try XCTUnwrap(spark.inkRectForTesting(threshold: 0.5))
        spark.isLit = false
        XCTAssertEqual(rest.width, lit.width, accuracy: 0.5, "rest \(rest), lit \(lit)")
        XCTAssertEqual(rest.height, lit.height, accuracy: 0.5, "rest \(rest), lit \(lit)")
        for ink in [rest, lit] {
            XCTAssertGreaterThanOrEqual(ink.width, 13.5, "\(ink)")
            XCTAssertLessThanOrEqual(ink.width, 16.5, "\(ink)")
        }
    }

    func testTheFieldsSparkIsAToggleNamedFindWithAI() throws {
        let (_, header) = laidOut()
        header.beginSearch()
        let field = header.searchField
        let toggle = try XCTUnwrap(field.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Find with AI" })
        XCTAssertTrue(toggle.isHidden)
        header.setAISearch(available: true, on: false)
        XCTAssertFalse(toggle.isHidden)
        XCTAssertEqual(toggle.accessibilityLabel(), "Find with AI")
        XCTAssertEqual(toggle.accessibilityRole(), .checkBox)
        XCTAssertEqual((toggle.accessibilityValue() as? NSNumber)?.boolValue, false)
        XCTAssertEqual(toggle.image?.isTemplate, true, "Off, it's tinted like the magnifier.")
        header.setAISearch(available: true, on: true)
        XCTAssertEqual((toggle.accessibilityValue() as? NSNumber)?.boolValue, true)
        XCTAssertEqual(toggle.image?.isTemplate, false, "On, it's in the gradient.")
        XCTAssertTrue(toggle.refusesFirstResponder)
    }

    func testTheFieldsSparkAddsNoWidth() {
        for available in [false, true] {
            for on in [false, true] {
                let (window, header) = laidOut()
                header.beginSearch()
                header.setAISearch(available: available, on: on)
                window.contentView?.layoutSubtreeIfNeeded()
                let field = header.searchField
                let plain = HeaderSearchField()
                let label = "available \(available), on \(on)"
                XCTAssertEqual(field.minimumWidth, plain.minimumWidth, accuracy: 0.01, label)
                XCTAssertEqual(field.fittingSize.width, plain.fittingSize.width, accuracy: 0.5, label)
                XCTAssertEqual(field.minimumWidth, field.fittingSize.width, accuracy: 0.5, label)
                // The spark is centred where the magnifier is, so the words start in the same place.
                XCTAssertEqual(field.aiToggleFrame.midX, field.leadingMarkFrame.midX, accuracy: 0.5, label)
                XCTAssertEqual(field.aiToggleFrame.midY, field.leadingMarkFrame.midY, accuracy: 0.5, label)
            }
        }
    }

    func testPressingTheFieldsSparkAsksTheWindowToTurnAISearchOver() {
        let header = HeaderBarView()
        let spy = HeaderSpy()
        header.delegate = spy
        header.render(tab: tab())
        header.beginSearch()
        header.setAISearch(available: true, on: false)
        header.searchField.pressAIToggleForTesting()
        XCTAssertEqual(spy.aiToggles, [true])
        // The window owns the state: until it says so, the field still shows it off.
        XCTAssertEqual(header.searchField.leadingMark, "spark")
        header.setAISearch(available: true, on: true)
        header.searchField.pressAIToggleForTesting()
        XCTAssertEqual(spy.aiToggles, [true, false])
        // Hidden, it asks nothing.
        header.setAISearch(available: false, on: false)
        header.searchField.pressAIToggleForTesting()
        XCTAssertEqual(spy.aiToggles, [true, false])
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

    func testTheKindRowComesWithTheSearchFieldSparkOrNoSparkAndEachSearchStartsAtAny() {
        let header = HeaderBarView()
        let spy = HeaderSpy()
        header.delegate = spy
        header.render(tab: tab())
        XCTAssertTrue(header.kindBar.isHidden)
        XCTAssertEqual(header.kindBar.heightConstraint.constant, 0)
        header.beginSearch()
        XCTAssertFalse(header.kindBar.isHidden, "the row comes with the field")
        XCTAssertEqual(header.kindBar.heightConstraint.constant, SearchKindBar.height)
        XCTAssertNil(header.searchKind)
        XCTAssertTrue(header.kindBar.clickForTesting("Photo"))
        XCTAssertEqual(header.searchKind, .image)
        XCTAssertEqual(spy.kindChanges, 1, "a choice asks the window to search again")
        XCTAssertTrue(header.kindBar.clickForTesting("Photo"))
        XCTAssertEqual(spy.kindChanges, 1, "the choice on show again asks nothing")
        header.setAISearch(available: true, on: true)
        header.setAISearch(available: true, on: false)
        XCTAssertFalse(header.kindBar.isHidden)
        XCTAssertEqual(header.searchKind, .image, "the spark leaves the row and its choice alone")
        header.endSearch()
        XCTAssertTrue(header.kindBar.isHidden)
        XCTAssertEqual(header.kindBar.heightConstraint.constant, 0)
        XCTAssertNil(header.searchKind, "back to Any when the search closes")
        // A tab that's searching shows its own search's kind, and showing it asks for nothing.
        var searching = tab()
        searching.search = SearchState(query: SearchQuery(text: "beach", scope: .currentFolder(home), bookmarkPaths: [],
                                                          homeDirectory: home, lastDirectory: nil, showHidden: false, limit: 10,
                                                          kind: .video))
        header.render(tab: searching)
        XCTAssertFalse(header.kindBar.isHidden)
        XCTAssertEqual(header.searchKind, .video)
        XCTAssertEqual(spy.kindChanges, 1)
    }

    func testTooltipsNameTheShortcuts() {
        let header = HeaderBarView()
        header.render(tab: tab())
        XCTAssertEqual(header.sidebarButton.toolTip, "Hide Sidebar (⌃⌘S)")
        XCTAssertEqual(header.backButton.toolTip, "Back (⌘[)")
        XCTAssertEqual(header.forwardButton.toolTip, "Forward (⌘])")
        XCTAssertEqual(header.viewButton.toolTip, "List (⌘2)")
        XCTAssertEqual(header.sparkButton.toolTip, "Set Up AI Mode")
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
        let buttons = [header.sidebarButton, header.backButton, header.forwardButton, header.searchButton, header.viewButton,
                       header.sortButton, header.sparkButton, header.menuButton]
        // Symbol insets used to make each fill a different height, from 33 to 38 points.
        for button in buttons {
            XCTAssertEqual(button.frame.height, 32, "\(button.accessibilityLabel() ?? "")")
            XCTAssertEqual(button.frame.midY, header.menuButton.frame.midY, accuracy: 0.5, "\(button.accessibilityLabel() ?? "")")
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
    var panelToggles = 0
    var submitted: [String] = []
    var aiToggles: [Bool] = []
    var changes: [String] = []
    var closed = 0
    var dismissed = 0
    var moves = 0
    var movesToResults = true
    var kindChanges = 0
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
    func headerSearchKindChanged() { kindChanges += 1 }
    func headerSearchMoveToResults() -> Bool { moves += 1; return movesToResults }
    func headerToggleAIPanel() { panelToggles += 1 }
    func headerSearchSubmitted(_ text: String) { submitted.append(text) }
    func headerSearchAIToggled(_ on: Bool) { aiToggles.append(on) }
}
#endif
