// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore
import HelmSearch

final class SearchSessionDriverTests: XCTestCase {
    private func query(_ text: String = "A", filters: [SearchClause] = []) -> SearchQuery {
        SearchQuery(text: text, scope: .home, bookmarkPaths: [], homeDirectory: URL(fileURLWithPath: "/home"), lastDirectory: nil, showHidden: false, limit: 30, filters: filters)
    }
    private func settled(_ driver: SearchSessionDriver) async -> SearchSessionState {
        for _ in 0..<1000 {
            let state = await driver.state
            if !state.isAcceptingEvents { return state }
            await Task.yield()
        }
        return await driver.state
    }
    func testSourceCompletionRetainsTruncation() async {
        let driver = SearchSessionDriver(source: { _ in AsyncThrowingStream { continuation in
            continuation.yield(.disclosure(index: .unavailable, fallback: .metadataUnavailable, unsupportedCriteria: false))
            continuation.yield(.search(.results(SearchRankedBatch(results: [], truncated: true, candidateLimitReached: false, consideredCount: 2), isFinal: true)))
            continuation.finish()
        } })
        await driver.start(query()); let state = await settled(driver)
        XCTAssertEqual(state.batch?.truncated, true); XCTAssertEqual(state.fallback, .metadataUnavailable); XCTAssertFalse(state.isAcceptingEvents)
    }
    func testMalformedQueryDoesNotInvokeSource() async {
        let driver = SearchSessionDriver(source: { _ in XCTFail("Invalid query reached source"); return AsyncThrowingStream { $0.finish() } })
        await driver.start(query("", filters: [.tag("")])); let state = await driver.state
        XCTAssertNotNil(state.error); XCTAssertFalse(state.isAcceptingEvents)
    }
    func testEmptyDoesNotInvokeSource() async {
        let driver = SearchSessionDriver(source: { _ in XCTFail("Empty query reached source"); return AsyncThrowingStream { $0.finish() } })
        let id = await driver.start(query(" ")); XCTAssertNil(id)
    }
    func testShutdownPreventsRestart() async {
        let driver = SearchSessionDriver(source: { _ in AsyncThrowingStream { _ in } })
        await driver.start(query()); await driver.shutdown(); let id = await driver.start(query("B")); let state = await driver.state
        XCTAssertNil(id); XCTAssertTrue(state.isShutdown); XCTAssertFalse(state.isAcceptingEvents)
    }
    func testCancelAndRefreshGetFreshIdentity() async {
        let driver = SearchSessionDriver(source: { _ in AsyncThrowingStream { _ in } })
        let first = await driver.start(query("", filters: [.kind(.regular)])); await driver.cancel()
        let cancelled = await driver.state; XCTAssertFalse(cancelled.isAcceptingEvents)
        let second = await driver.refresh(); XCTAssertNotEqual(first, second); XCTAssertNotNil(second); await driver.shutdown()
    }
    func testServiceAdapterPreservesNotIndexed() async {
        let driver = SearchSessionDriver(service: SessionServiceFixture())
        await driver.start(query()); let state = await settled(driver); XCTAssertEqual(state.index, .unavailable)
    }
    func testCancelTerminatesInjectedStream() async {
        let started = expectation(description: "source subscribed")
        let terminated = expectation(description: "source terminated")
        let driver = SearchSessionDriver(source: { _ in AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in terminated.fulfill() }
            started.fulfill()
        } })
        await driver.start(query())
        await fulfillment(of: [started], timeout: 2)
        await driver.cancel()
        await fulfillment(of: [terminated], timeout: 2)
        let state = await driver.state
        XCTAssertNil(state.generation); XCTAssertNil(state.error)
    }
    func testQuotedEmptyDoesNotInvokeSource() async {
        let driver = SearchSessionDriver(source: { _ in XCTFail("Vacuous query reached source"); return AsyncThrowingStream { $0.finish() } })
        await driver.start(query("\"\""))
        let state = await driver.state
        XCTAssertNotNil(state.error); XCTAssertFalse(state.isAcceptingEvents)
    }
    func testSourceFailureVisible() async {
        let driver = SearchSessionDriver(source: { _ in AsyncThrowingStream { $0.finish(throwing: SessionFailure.failed) } })
        await driver.start(query()); let state = await settled(driver); XCTAssertNotNil(state.error); XCTAssertFalse(state.isGathering)
    }
}
private enum SessionFailure: Error { case failed }
private struct SessionServiceFixture: SearchService {
    func search(_ query: SearchQuery) -> AsyncThrowingStream<SearchEvent, Error> {
        AsyncThrowingStream { $0.yield(.notIndexed); $0.finish() }
    }
}
