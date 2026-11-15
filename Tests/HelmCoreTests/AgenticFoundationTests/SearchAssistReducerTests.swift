import XCTest
@testable import HelmCore

/// What a model adds to a search reaches the tab only while that search is still the one on show.
final class SearchAssistReducerTests: XCTestCase {
    private let folder: Location = .directory(URL(fileURLWithPath: "/a", isDirectory: true))
    private let context = ReducerContext(now: .distantPast, homeDirectory: URL(fileURLWithPath: "/home"))

    private func entry(_ path: String) -> FileEntry { FileEntry(url: URL(fileURLWithPath: path)) }
    private func send(_ action: TabAction, to state: inout TabState) {
        state = TabReducer.reduce(state, action, context: context).0
    }
    private func query(_ text: String, usesAI: Bool = true) -> SearchQuery {
        SearchQuery(text: text, scope: .userFolders, bookmarkPaths: [], homeDirectory: context.homeDirectory,
                    lastDirectory: nil, showHidden: false, limit: 100, usesAI: usesAI)
    }
    private func loaded() -> TabState {
        var state = TabState(location: folder, homeDirectory: context.homeDirectory)
        send(.refresh, to: &state)
        send(.loadFinished(state.loadGeneration, SnapshotBuilder.build(location: folder, entries: [entry("/a/one")], sort: state.sort)),
             to: &state)
        return state
    }
    private let done = SearchAssist(phase: .done, reasons: [ItemID(url: URL(fileURLWithPath: "/x/invoice.pdf")):
                                                              SearchReason(codes: [.name, .kind], line: "Name has “invoice” · PDF")],
                                    readAs: "1 match · PDF · “invoice”", queriesRead: ["PDF · “invoice”"], coverage: .onThisMacOnly)

    func testASearchStartsWithNothingFromAModel() {
        var state = loaded()
        send(.searchStarted(query("invoice")), to: &state)
        XCTAssertNotNil(state.search)
        XCTAssertNil(state.search?.assist)
        XCTAssertEqual(state.search?.query.usesAI, true)
    }

    func testAnAssistForTheSearchOnShowIsKept() {
        var state = loaded()
        send(.searchStarted(query("invoice")), to: &state)
        send(.searchAssist(state.searchGeneration, SearchAssist(phase: .thinking)), to: &state)
        XCTAssertEqual(state.search?.assist, SearchAssist(phase: .thinking))
        XCTAssertEqual(state.search?.assist?.phase, .thinking)

        // A later one for the same search replaces it.
        send(.searchAssist(state.searchGeneration, done), to: &state)
        XCTAssertEqual(state.search?.assist, done)
        XCTAssertEqual(state.search?.assist?.reasons.count, 1)
        XCTAssertEqual(state.search?.assist?.coverage, .onThisMacOnly)
    }

    func testAnAssistChangesNothingElseAndStartsNoWork() {
        var state = loaded()
        send(.searchStarted(query("invoice")), to: &state)
        send(.searchResults(state.searchGeneration, [SearchResult(entry: entry("/x/invoice.pdf"), rank: 0)]), to: &state)
        let before = state
        let (after, effects) = TabReducer.reduce(state, .searchAssist(state.searchGeneration, done), context: context)
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(after.search?.results, before.search?.results)
        XCTAssertEqual(after.search?.isGathering, before.search?.isGathering)
        XCTAssertEqual(after.search?.query, before.search?.query)
        XCTAssertEqual(after.searchGeneration, before.searchGeneration)
        XCTAssertEqual(after.snapshot, before.snapshot)
        XCTAssertEqual(after.selection, before.selection)
        // Results that arrive afterwards leave the reasons in place.
        var next = after
        send(.searchResults(next.searchGeneration, [SearchResult(entry: entry("/x/invoice.pdf"), rank: 0),
                                                    SearchResult(entry: entry("/x/bill.pdf"), rank: 1)]), to: &next)
        XCTAssertEqual(next.search?.assist, done)
    }

    func testAStaleAssistIsDropped() {
        var state = loaded()
        send(.searchStarted(query("invoice")), to: &state)
        let first = state.searchGeneration
        // The words changed while the model was thinking: its answer was for the old words.
        send(.searchStarted(query("invoices 2026")), to: &state)
        XCTAssertNotEqual(state.searchGeneration, first)
        let before = state
        let (after, effects) = TabReducer.reduce(state, .searchAssist(first, done), context: context)
        XCTAssertNil(after.search?.assist)
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(after.search, before.search)
        // The answer for the new words is kept.
        send(.searchAssist(state.searchGeneration, done), to: &state)
        XCTAssertEqual(state.search?.assist, done)
        // And a late one for the first search still changes nothing.
        send(.searchAssist(first, SearchAssist(phase: .failed)), to: &state)
        XCTAssertEqual(state.search?.assist, done)
    }

    func testAnAssistAfterTheSearchClosedIsDropped() {
        var state = loaded()
        send(.searchStarted(query("invoice")), to: &state)
        let generation = state.searchGeneration
        send(.searchEnded, to: &state)
        XCTAssertNil(state.search)
        send(.searchAssist(generation, done), to: &state)
        XCTAssertNil(state.search)
        // Even with the tab's current generation, there is no search to add to.
        send(.searchAssist(state.searchGeneration, done), to: &state)
        XCTAssertNil(state.search)
    }

    func testANewSearchStartsWithoutTheOldOnesAssist() {
        var state = loaded()
        send(.searchStarted(query("invoice")), to: &state)
        send(.searchAssist(state.searchGeneration, done), to: &state)
        send(.searchStarted(query("invoice march")), to: &state)
        XCTAssertNil(state.search?.assist, "reasons for the old words don't describe the new results")
    }

    func testSearchValuesKeepTheirOldDefaults() {
        let plain = SearchQuery(text: "x", scope: .home, bookmarkPaths: [], homeDirectory: context.homeDirectory,
                                lastDirectory: nil, showHidden: false, limit: 10)
        XCTAssertFalse(plain.usesAI)
        XCTAssertNotEqual(plain, query("x").with(scope: .home, limit: 10))
        XCTAssertNil(SearchState(query: plain).assist)
        XCTAssertEqual(SearchState(query: plain, assist: done).assist, done)
        let assist = SearchAssist(phase: .failed)
        XCTAssertEqual(assist.reasons, [:])
        XCTAssertNil(assist.readAs)
        XCTAssertEqual(assist.queriesRead, [])
        XCTAssertEqual(assist.coverage, .full)
        XCTAssertEqual(AISearchStatus(text: "Thinking…").queries, [])
        XCTAssertNotEqual(AISearchStatus(text: "12 matches", queries: ["PDF"]), AISearchStatus(text: "12 matches"))
        XCTAssertEqual(SearchReasonCode.allCases.map(\.rawValue), ["name", "content", "kind", "date", "folder", "size"])
        XCTAssertEqual(SearchAssist.Phase(rawValue: "thinking"), .thinking)
        XCTAssertEqual(SearchAssist.Coverage(rawValue: "namesOnly"), .namesOnly)
    }
}

private extension SearchQuery {
    func with(scope: SearchScope, limit: Int) -> SearchQuery {
        var copy = self
        copy.scope = scope; copy.limit = limit
        return copy
    }
}
