#if os(macOS)
import AppKit
import XCTest
import HelmCore
@testable import HelmUI

/// The search field follows the tab, and lets go of the keys the way Finder's and Nautilus's do.
@MainActor final class HeaderSearchFocusTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
    }
    override func tearDown() {
        HeaderMotion.isDisabledForTesting = false
        super.tearDown()
    }

    private func tab() -> TabState { TabState(location: .directory(documents), homeDirectory: home) }
    private func search(_ text: String, everywhere: Bool = false) -> SearchState {
        SearchState(query: SearchQuery(text: text, scope: everywhere ? .thisMac : .currentFolder(documents), bookmarkPaths: [],
                                       homeDirectory: home, lastDirectory: nil, showHidden: false, limit: 100))
    }
    private func header() -> (HeaderBarView, HeaderSpy) {
        let header = HeaderBarView()
        let spy = HeaderSpy()
        header.delegate = spy
        return (header, spy)
    }

    // MARK: The header follows the tab

    func testGoingElsewhereClosesTheSearch() {
        let (header, spy) = header()
        var current = tab()
        header.render(tab: current)
        header.beginSearch()
        XCTAssertTrue(header.isSearching)
        XCTAssertTrue(header.pathBar.isHidden)
        current.pendingNavigation = PendingNavigation(target: .directory(home.appendingPathComponent("Downloads")), intent: .push,
                                                      generation: Generation(rawValue: 7))
        header.render(tab: current)
        XCTAssertFalse(header.isSearching)
        XCTAssertFalse(header.pathBar.isHidden)
        XCTAssertTrue(header.searchField.isHidden)
        XCTAssertEqual(spy.dismissed, 1)
        // The same navigation, still loading, doesn't close anything again.
        header.render(tab: current)
        XCTAssertEqual(spy.dismissed, 1)
    }

    func testASearchEndedFromTheFilesClosesTheField() {
        let (header, spy) = header()
        var current = tab()
        current.search = search("q2")
        current.searchGeneration = current.searchGeneration.next()
        header.render(tab: current)
        XCTAssertTrue(header.isSearching)
        XCTAssertEqual(header.searchText, "q2")
        current.search = nil
        current.searchGeneration = current.searchGeneration.next()
        header.render(tab: current)
        XCTAssertFalse(header.isSearching)
        XCTAssertEqual(header.searchText, "")
        XCTAssertEqual(spy.dismissed, 1)
    }

    func testASearchStartedWithoutTheFieldIsShownWithoutTheCaret() {
        let (header, _) = header()
        var current = tab()
        header.render(tab: current)
        current.search = search("q2")
        header.render(tab: current)
        XCTAssertTrue(header.isSearching)
        XCTAssertTrue(header.searchButton.isOn)
        XCTAssertEqual(header.searchText, "q2")
        XCTAssertFalse(header.searchField.showsEditing)
        XCTAssertFalse(header.isSearchFieldEditing)
    }

    func testEachTabShowsItsOwnSearchAndScope() {
        let (header, spy) = header()
        var first = tab()
        first.search = search("q2", everywhere: true)
        let second = tab()
        header.render(tab: first)
        XCTAssertTrue(header.isSearching)
        XCTAssertEqual(header.searchText, "q2")
        XCTAssertTrue(header.searchesEverywhere)
        header.render(tab: second)
        XCTAssertFalse(header.isSearching)
        XCTAssertFalse(header.searchesEverywhere)
        XCTAssertFalse(header.pathBar.isHidden)
        header.render(tab: first)
        XCTAssertTrue(header.isSearching)
        XCTAssertEqual(header.searchText, "q2")
        XCTAssertTrue(header.searchesEverywhere)
        XCTAssertEqual(spy.dismissed, 1, "Only leaving for the tab with no search closed the field.")
    }

    func testTypingALocationTakesThePathBarBack() {
        let (header, spy) = header()
        var current = tab()
        current.search = search("q2")
        header.render(tab: current)
        XCTAssertTrue(header.isSearching)
        current.addressBar.isEditing = true
        header.render(tab: current)
        XCTAssertFalse(header.isSearching)
        XCTAssertFalse(header.pathBar.isHidden)
        XCTAssertEqual(spy.dismissed, 1)
    }

    func testOpeningSearchDuringALoadSurvivesTheLoad() {
        let (header, spy) = header()
        var current = tab()
        current.pendingNavigation = PendingNavigation(target: .directory(home.appendingPathComponent("Downloads")), intent: .push,
                                                      generation: Generation(rawValue: 1))
        header.render(tab: current)
        header.beginSearch()
        header.render(tab: current)
        XCTAssertTrue(header.isSearching)
        current.pendingNavigation = nil
        current.location = .directory(home.appendingPathComponent("Downloads"))
        header.render(tab: current)
        XCTAssertTrue(header.isSearching)
        XCTAssertEqual(spy.dismissed, 0)
    }

    func testTheEmptyStateWordsLetClicksThrough() {
        let page = ContentStatePage()
        page.view.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
        page.show(ContentStatePresentation.empty(.noResults), perform: { _ in }, retryWaiting: {})
        XCTAssertNil(page.view.hitTest(NSPoint(x: 100, y: 60)), "No results lets clicks reach the files")
        page.show(ContentStatePresentation.empty(.folder), perform: { _ in }, retryWaiting: {})
        XCTAssertNil(page.view.hitTest(NSPoint(x: 100, y: 60)), "Folder is empty lets clicks reach the files")
        page.show(ContentState(style: .problem, symbol: "lock", title: "No access"), perform: { _ in }, retryWaiting: {})
        XCTAssertFalse(page.view.passesThrough, "a card keeps its clicks for its own buttons")
    }

    // MARK: Focus, in a window

    /// A window that's never shown, holding the header and a view that can take the keys, as the files do.
    private func hosted() -> (NSWindow, HeaderBarView, HeaderSpy, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 200), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: true)
        let (header, spy) = header()
        let files = KeyTaker()
        files.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return (window, header, spy, files) }
        content.addSubview(header); content.addSubview(files)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor), header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            files.topAnchor.constraint(equalTo: header.bottomAnchor), files.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            files.leadingAnchor.constraint(equalTo: content.leadingAnchor), files.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        content.layoutSubtreeIfNeeded()
        header.render(tab: tab())
        return (window, header, spy, files)
    }
    /// The field reports the end of editing on the next turn of the run loop.
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    private func type(_ text: String, in window: NSWindow) {
        guard let editor = window.firstResponder as? NSTextView else { return XCTFail("the field hasn't got the caret") }
        editor.string = text
        editor.didChangeText()
    }

    func testOpeningSearchPutsTheCaretInTheTypingFill() {
        let (_, header, _, _) = hosted()
        header.beginSearch()
        settle()
        XCTAssertTrue(header.isSearchFieldEditing)
        XCTAssertTrue(header.searchField.showsEditing)
        XCTAssertEqual(header.searchField.layer?.backgroundColor?.alpha ?? 0, 0.14, accuracy: 0.001)
    }

    func testClickingAwayClosesAnEmptySearch() {
        let (window, header, spy, files) = hosted()
        header.beginSearch()
        settle()
        window.makeFirstResponder(files)
        settle()
        XCTAssertFalse(header.isSearching)
        XCTAssertFalse(header.pathBar.isHidden)
        XCTAssertEqual(spy.dismissed, 1)
        XCTAssertTrue(window.firstResponder === files, "The files keep the keys.")
    }

    func testClickingAwayKeepsASearchWithWordsResting() {
        let (window, header, spy, files) = hosted()
        header.beginSearch()
        type("q2", in: window)
        XCTAssertEqual(spy.changes, ["q2"])
        window.makeFirstResponder(files)
        settle()
        XCTAssertTrue(header.isSearching)
        XCTAssertTrue(header.searchButton.isOn)
        XCTAssertEqual(header.searchText, "q2")
        XCTAssertFalse(header.searchField.showsEditing)
        // The path bar's resting fill, with no caret.
        XCTAssertEqual(header.searchField.layer?.backgroundColor?.alpha ?? 0, 0.08, accuracy: 0.001)
        XCTAssertEqual(spy.dismissed, 0)
    }

    func testCommandFPutsTheCaretBackWithTheWordsSelected() {
        let (window, header, _, files) = hosted()
        header.beginSearch()
        type("q2", in: window)
        window.makeFirstResponder(files)
        settle()
        header.beginSearch()
        settle()
        XCTAssertTrue(header.isSearchFieldEditing)
        XCTAssertEqual((window.firstResponder as? NSTextView)?.selectedRange(), NSRange(location: 0, length: 2))
        // Already typing, it selects the words without starting the editing again.
        (window.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 2, length: 0))
        header.beginSearch()
        XCTAssertEqual((window.firstResponder as? NSTextView)?.selectedRange(), NSRange(location: 0, length: 2))
    }

    func testReturnAndAClickInTheFieldKeepTheSearchAndTheCaret() {
        let (window, header, spy, _) = hosted()
        header.beginSearch()
        type("q2", in: window)
        guard let editor = window.firstResponder as? NSTextView else { return XCTFail("no caret") }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        settle()
        XCTAssertTrue(header.isSearching)
        XCTAssertTrue(header.isSearchFieldEditing)
        guard let after = window.firstResponder as? NSTextView else { return XCTFail("Return took the caret away") }
        after.setSelectedRange(NSRange(location: 1, length: 0))
        // A click in the field's padding while typing leaves the caret where it was.
        header.searchField.focus(selectingAll: false)
        settle()
        XCTAssertTrue(header.isSearching)
        XCTAssertTrue(header.isSearchFieldEditing)
        XCTAssertEqual((window.firstResponder as? NSTextView)?.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertEqual(spy.dismissed, 0)
    }

    func testEscapeInTheFieldClosesIt() {
        let (window, header, spy, _) = hosted()
        header.beginSearch()
        type("q2", in: window)
        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        settle()
        XCTAssertFalse(header.isSearching)
        XCTAssertEqual(spy.closed, 1)
        XCTAssertEqual(spy.dismissed, 0)
    }

    func testTheDownArrowAsksToMoveToTheResults() {
        let (window, header, spy, _) = hosted()
        header.beginSearch()
        type("q2", in: window)
        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(spy.moves, 1)
    }

    /// Where the keys go next is the window's part: HeaderWindowTests checks that the files get them.
    func testANavigationWhileTypingClosesTheFieldAndReleasesTheCaret() {
        let (window, header, spy, _) = hosted()
        var current = tab()
        header.render(tab: current)
        header.beginSearch()
        type("q2", in: window)
        current.pendingNavigation = PendingNavigation(target: .directory(home.appendingPathComponent("Downloads")), intent: .back,
                                                      generation: Generation(rawValue: 3))
        header.render(tab: current)
        settle()
        XCTAssertFalse(header.isSearching)
        XCTAssertFalse(header.isSearchFieldEditing, "The hidden field no longer has the caret.")
        XCTAssertEqual(spy.dismissed, 1)
    }

    func testCommandLDuringASearchPutsTheCaretInTheLocation() {
        let (window, header, spy, _) = hosted()
        var current = tab()
        current.search = search("q2")
        header.render(tab: current)
        header.beginSearch()
        XCTAssertTrue(header.isSearchFieldEditing)
        // The window renders the path bar first, while the search still covers it, then the header.
        current.addressBar.isEditing = true
        header.pathBar.render(location: current.location, home: home, editor: current.addressBar)
        XCTAssertTrue(header.isSearchFieldEditing, "A hidden location field doesn't take the caret.")
        header.render(tab: current)
        settle()
        XCTAssertFalse(header.isSearching)
        XCTAssertTrue(header.pathBar.isEditingLocation)
        XCTAssertTrue(window.firstResponder is NSTextView)
        XCTAssertFalse(header.isSearchFieldEditing)
        XCTAssertEqual(spy.dismissed, 1)
    }

    func testCommandFWhileTypingALocationSwapsItForTheSearch() {
        let (window, header, _, _) = hosted()
        var current = tab()
        current.addressBar.isEditing = true
        header.pathBar.render(location: current.location, home: home, editor: current.addressBar)
        XCTAssertTrue(header.pathBar.isEditingLocation)
        XCTAssertTrue(window.firstResponder is NSTextView, "The location field has the caret.")
        header.beginSearch()
        settle()
        XCTAssertTrue(header.isSearching)
        XCTAssertTrue(header.isSearchFieldEditing)
    }
}

/// Takes the keys, as the grid and the list do.
private final class KeyTaker: NSView {
    override var acceptsFirstResponder: Bool { true }
}
#endif
