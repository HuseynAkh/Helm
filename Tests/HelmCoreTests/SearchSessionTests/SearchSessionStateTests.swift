// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore

final class SearchSessionStateTests: XCTestCase {
    private func query(_ text: String = "A", filters: [SearchClause] = []) -> SearchQuery {
        SearchQuery(text: text, scope: .home, bookmarkPaths: [], homeDirectory: URL(fileURLWithPath: "/home"), lastDirectory: nil, showHidden: false, limit: 30, filters: filters)
    }
    private let emptyBatch = SearchRankedBatch(results: [], truncated: false, candidateLimitReached: false, consideredCount: 0)
    func testKindOnly() { var state = SearchSessionState(); XCTAssertNotNil(state.start(query(" ", filters: [.kind(.regular)]))); XCTAssertTrue(state.isGathering) }
    func testTagOnly() { var state = SearchSessionState(); XCTAssertNotNil(state.start(query("", filters: [.tag("Project")]))); XCTAssertEqual(state.query?.filters, [.tag("Project")]) }
    func testTrulyEmptyExits() { var state = SearchSessionState(); state.start(query()); XCTAssertNil(state.start(query(" \n"))); XCTAssertNil(state.query); XCTAssertFalse(state.isGathering) }
    func testRefreshCriteria() throws {
        var state = SearchSessionState(); let first = try XCTUnwrap(state.start(query("", filters: [.kind(.regular)])))
        XCTAssertNotEqual(state.refresh(), first); XCTAssertEqual(state.query?.filters, [.kind(.regular)])
        XCTAssertFalse(state.receive(.search(.notIndexed), generation: first))
    }
    func testRefreshIdle() { var state = SearchSessionState(); XCTAssertNil(state.refresh()) }
    func testABARejectsOldRequest() throws {
        var state = SearchSessionState(); let a = try XCTUnwrap(state.start(query()))
        state.start(query("B")); let latest = try XCTUnwrap(state.start(query()))
        XCTAssertNotEqual(a, latest); XCTAssertFalse(state.receive(.search(.results(emptyBatch, isFinal: true)), generation: a)); XCTAssertNil(state.batch)
    }
    func testCancelRejectsLate() throws {
        var state = SearchSessionState(); let id = try XCTUnwrap(state.start(query())); state.cancel()
        XCTAssertFalse(state.receive(.search(.gathering), generation: id)); XCTAssertFalse(state.isGathering)
    }
    func testShutdownTerminal() { var state = SearchSessionState(); state.start(query()); state.shutdown(); state.shutdown(); XCTAssertNil(state.start(query())); XCTAssertNil(state.refresh()); XCTAssertTrue(state.isShutdown) }
    func testFinalGatheringAllowsLiveUpdates() throws {
        var state = SearchSessionState(); let id = try XCTUnwrap(state.start(query()))
        XCTAssertTrue(state.receive(.search(.results(emptyBatch, isFinal: true)), generation: id)); XCTAssertFalse(state.isGathering); XCTAssertTrue(state.isAcceptingEvents)
        XCTAssertTrue(state.receive(.search(.results(emptyBatch, isFinal: false)), generation: id)); XCTAssertFalse(state.isGathering)
    }
    func testGatheringEvent() throws { var state = SearchSessionState(); let id = try XCTUnwrap(state.start(query())); state.receive(.search(.results(emptyBatch, isFinal: true)), generation: id); state.receive(.search(.gathering), generation: id); XCTAssertTrue(state.isGathering) }
    func testUnavailableIsNotEmptyAvailable() throws {
        var state = SearchSessionState(); let id = try XCTUnwrap(state.start(query())); state.receive(.search(.results(emptyBatch, isFinal: true)), generation: id)
        XCTAssertEqual(state.index, .unknown)
        state.receive(.disclosure(index: .available, fallback: .none, unsupportedCriteria: false), generation: id); XCTAssertEqual(state.index, .available)
        state.receive(.search(.notIndexed), generation: id); XCTAssertEqual(state.index, .unavailable); XCTAssertEqual(state.batch, emptyBatch)
    }
    func testTruncationAndDisclosure() throws {
        var state = SearchSessionState(); let id = try XCTUnwrap(state.start(query()))
        let batch = SearchRankedBatch(results: [], truncated: true, candidateLimitReached: true, consideredCount: 450)
        state.receive(.search(.results(batch, isFinal: true)), generation: id)
        state.receive(.disclosure(index: .unavailable, fallback: .knownUnindexed, unsupportedCriteria: true), generation: id)
        XCTAssertEqual(state.batch, batch); XCTAssertEqual(state.fallback, .knownUnindexed); XCTAssertTrue(state.unsupportedCriteria)
    }
    func testFinishClosesAdmission() throws { var state = SearchSessionState(); let id = try XCTUnwrap(state.start(query())); state.receive(.finished, generation: id); XCTAssertFalse(state.receive(.search(.notIndexed), generation: id)); XCTAssertFalse(state.isGathering) }
    func testFailureKeepsPartialBatch() throws { var state = SearchSessionState(); let id = try XCTUnwrap(state.start(query())); state.receive(.search(.results(emptyBatch, isFinal: false)), generation: id); state.receive(.failed("denied"), generation: id); XCTAssertEqual(state.error, "denied"); XCTAssertEqual(state.batch, emptyBatch); XCTAssertFalse(state.isAcceptingEvents) }
    func testStartResetsDisclosureAndError() throws { var state = SearchSessionState(); let id = try XCTUnwrap(state.start(query())); state.receive(.search(.notIndexed), generation: id); state.receive(.failed("error"), generation: id); state.start(query("B")); XCTAssertNil(state.error); XCTAssertEqual(state.index, .unknown) }
}
