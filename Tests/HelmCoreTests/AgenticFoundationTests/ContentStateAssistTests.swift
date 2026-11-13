import XCTest
@testable import HelmCore

/// The no-results page during a search a model can help with: it waits while the model thinks, and offers the model's
/// help only when one is ready and hasn't been asked yet.
final class ContentStateAssistTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    private var folder: Location { .directory(home.appendingPathComponent("Documents", isDirectory: true)) }

    private func query(usesAI: Bool) -> SearchQuery {
        SearchQuery(text: "plumber invoice", scope: .home, bookmarkPaths: [], homeDirectory: home, lastDirectory: nil,
                    showHidden: false, limit: 100, usesAI: usesAI)
    }
    /// A tab showing a search that found `entries`.
    private func searching(usesAI: Bool, gathering: Bool = false, assist: SearchAssist? = nil, entries: [FileEntry] = []) -> TabState {
        var tab = TabState(location: folder, homeDirectory: home)
        tab.search = SearchState(query: query(usesAI: usesAI), isGathering: gathering, assist: assist)
        tab.snapshot = PresentationSnapshot(location: folder, phase: .ready, sortedEntries: entries)
        return tab
    }
    private func state(_ tab: TabState, ready: Bool) -> ContentState? {
        ContentStatePresentation.state(for: tab, home: home, fullDiskAccess: .granted, aiSearchReady: ready)
    }

    func testNoResultsDoesNotShowWhileTheAssistIsThinking() {
        let thinking = searching(usesAI: true, assist: SearchAssist(phase: .thinking))
        XCTAssertNil(state(thinking, ready: true))
        XCTAssertNil(state(thinking, ready: false))
        // Nor while the plain search is still gathering, as before.
        XCTAssertNil(state(searching(usesAI: true, gathering: true), ready: true))
        XCTAssertNil(state(searching(usesAI: true, gathering: true, assist: SearchAssist(phase: .thinking)), ready: true))
    }

    func testNoResultsShowsOnceTheModelHasAnswered() {
        for phase in [SearchAssist.Phase.done, .failed] {
            let page = state(searching(usesAI: true, assist: SearchAssist(phase: phase)), ready: true)
            XCTAssertEqual(page?.title, "No results", phase.rawValue)
            XCTAssertEqual(page?.style, .empty, phase.rawValue)
            XCTAssertEqual(page?.buttons, [], "the model was already asked: \(phase.rawValue)")
        }
    }

    func testTheFindWithAIButtonShowsOnlyWhenAModelIsReady() {
        let plain = searching(usesAI: false)
        let ready = state(plain, ready: true)
        XCTAssertEqual(ready?.title, "No results")
        XCTAssertEqual(ready?.symbol, "magnifyingglass")
        XCTAssertEqual(ready?.buttons, [ContentStateButton(title: "Find with AI", action: .findWithAI)])

        let notReady = state(plain, ready: false)
        XCTAssertEqual(notReady, ContentStatePresentation.empty(.noResults))
        XCTAssertEqual(notReady?.buttons, [])
        // Left out, the answer is today's.
        XCTAssertEqual(ContentStatePresentation.state(for: plain, home: home, fullDiskAccess: .granted),
                       ContentStatePresentation.empty(.noResults))
    }

    func testTheButtonIsNotOfferedForASearchThatAlreadyUsedAI() {
        XCTAssertEqual(state(searching(usesAI: true), ready: true), ContentStatePresentation.empty(.noResults))
        XCTAssertEqual(state(searching(usesAI: true, assist: SearchAssist(phase: .failed)), ready: true)?.buttons, [])
    }

    func testResultsOnShowNeedNoPage() {
        let entry = FileEntry(url: home.appendingPathComponent("Documents/invoice.pdf"))
        XCTAssertNil(state(searching(usesAI: false, entries: [entry]), ready: true))
        XCTAssertNil(state(searching(usesAI: true, assist: SearchAssist(phase: .thinking), entries: [entry]), ready: true))
    }

    func testOtherEmptyPagesNeverOfferIt() {
        var tab = TabState(location: folder, homeDirectory: home)
        tab.snapshot = PresentationSnapshot(location: folder, phase: .ready)
        XCTAssertEqual(state(tab, ready: true), ContentStatePresentation.empty(.folder))
        var trash = TabState(location: .trash, homeDirectory: home)
        trash.snapshot = PresentationSnapshot(location: .trash, phase: .ready)
        XCTAssertEqual(state(trash, ready: true), ContentStatePresentation.empty(.trash))
        var recent = TabState(location: .recent, homeDirectory: home)
        recent.snapshot = PresentationSnapshot(location: .recent, phase: .ready)
        XCTAssertEqual(state(recent, ready: true), ContentStatePresentation.empty(.recent))
        for kind in [ContentStatePresentation.EmptyKind.folder, .trash, .recent, .noResults] {
            XCTAssertEqual(ContentStatePresentation.empty(kind).buttons, [])
        }
    }

    func testTheActionIsAValueOfItsOwn() {
        XCTAssertEqual(ContentStateAction.findWithAI, .findWithAI)
        XCTAssertNotEqual(ContentStateAction.findWithAI, .goHome)
        XCTAssertEqual(Set([ContentStateAction.findWithAI, .goHome, .findWithAI]).count, 2)
    }
}
