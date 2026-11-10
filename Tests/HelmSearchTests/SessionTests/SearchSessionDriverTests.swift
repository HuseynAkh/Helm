// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore
import HelmSearch

final class SearchSessionDriverTests: XCTestCase {
    private func query(_ text: String = "A", filters: [SearchClause] = []) -> SearchQuery {
        SearchQuery(text: text, scope: .home, bookmarkPaths: [], homeDirectory: URL(fileURLWithPath: "/home"), lastDirectory: nil, showHidden: false, limit: 30, filters: filters)
    }
    private func settled(_ driver: SearchSessionDriver) async -> SearchSessionState {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let state = await driver.state
            if !state.isAcceptingEvents { return state }
            await Task.yield()
        }
        XCTFail("Search session did not settle before the five-second deadline")
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
        await driver.shutdown()
    }
    func testEmptyDoesNotInvokeSource() async {
        let driver = SearchSessionDriver(source: { _ in XCTFail("Empty query reached source"); return AsyncThrowingStream { $0.finish() } })
        let id = await driver.start(query(" ")); XCTAssertNil(id)
        await driver.shutdown()
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
        await driver.shutdown()
    }
    func testTerminalEnvelopesTerminateRetainedStream() async {
        for event: SearchSessionEvent in [.finished, .failed("metadata unavailable")] {
            let terminated = expectation(description: "terminal envelope releases subscription")
            let retained = AsyncThrowingStream<SearchSessionEvent, Error>.makeStream()
            retained.continuation.onTermination = { _ in terminated.fulfill() }
            let driver = SearchSessionDriver(source: { _ in retained.stream })
            await driver.start(query())
            retained.continuation.yield(event)
            await fulfillment(of: [terminated], timeout: 2)
            let state = await driver.state
            XCTAssertFalse(state.isAcceptingEvents)
            if case .failed(let message) = event { XCTAssertEqual(state.error, message) }
            await driver.shutdown()
        }
    }
    func testOldTerminalCleanupCannotCancelReplacementAndFinalResultsStayLive() async {
        let old = AsyncThrowingStream<SearchSessionEvent, Error>.makeStream()
        let releaseOldTerminal = SessionTerminalGate()
        let oldTerminalAttempted = expectation(description: "old terminal attempted after replacement")
        let oldTerminated = expectation(description: "old subscription terminated")
        old.continuation.onTermination = { _ in oldTerminated.fulfill() }
        let oldProducer = Task {
            await releaseOldTerminal.wait()
            // Intentionally late producer: the replacement must remain live.
            old.continuation.yield(.failed("old failure"))
            old.continuation.finish()
            oldTerminalAttempted.fulfill()
        }
        let next = AsyncThrowingStream<SearchSessionEvent, Error>.makeStream()
        let oldStarted = expectation(description: "old subscribed")
        let nextStarted = expectation(description: "replacement subscribed")
        let nextTerminated = expectation(description: "replacement explicitly cancelled")
        next.continuation.onTermination = { _ in nextTerminated.fulfill() }
        let driver = SearchSessionDriver(source: { query in
            if query.text == "A" { oldStarted.fulfill(); return old.stream }
            nextStarted.fulfill(); return next.stream
        })
        await driver.start(query("A"))
        await fulfillment(of: [oldStarted], timeout: 2)
        let latest = await driver.start(query("B"))
        await fulfillment(of: [nextStarted, oldTerminated], timeout: 2)
        await releaseOldTerminal.open()
        await fulfillment(of: [oldTerminalAttempted], timeout: 2)
        await oldProducer.value
        next.continuation.yield(.search(.results(.init(results: [], truncated: true,
            candidateLimitReached: false, consideredCount: 1), isFinal: true)))
        let batchDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < batchDeadline {
            if await driver.state.batch != nil { break }
            await Task.yield()
        }
        let state = await driver.state
        XCTAssertEqual(state.generation, latest)
        XCTAssertNil(state.error)
        XCTAssertTrue(state.isAcceptingEvents)
        XCTAssertEqual(state.batch?.truncated, true)
        next.continuation.yield(.disclosure(index: .available, fallback: .none, unsupportedCriteria: false))
        let disclosureDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < disclosureDeadline {
            if await driver.state.index == .available { break }
            await Task.yield()
        }
        let updated = await driver.state
        XCTAssertEqual(updated.index, .available)
        await driver.cancel()
        await fulfillment(of: [nextTerminated], timeout: 2)
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

/// Producer gate fixes the ordering without scheduler timing or sleeps.
private actor SessionTerminalGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() {
        isOpen = true
        waiter?.resume(); waiter = nil
    }
}
