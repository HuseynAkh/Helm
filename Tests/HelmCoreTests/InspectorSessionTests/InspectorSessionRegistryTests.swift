// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class InspectorSessionRegistryTests: XCTestCase {
    let owner = UUID()
    func entry(_ name: String, kind: FileEntryKind = .regular, size: Int64 = 12) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/" + name), kind: kind, size: size)
    }
    func reads(_ effects: [InspectorSessionEffect]) -> [InspectorReadRequest] {
        effects.compactMap { if case .read(let request) = $0 { return request }; return nil }
    }
    func open(_ registry: inout InspectorSessionRegistry, _ entries: [FileEntry],
              mode: InfoPresentationRequest.Mode = .followSelection) -> [InspectorReadRequest] {
        reads(registry.reduce(event: .present(InfoPresentationRequest(ownerID: owner, mode: mode, entries: entries))))
    }
    func testDuplicatesPreserveFirstAndReuseWindow() throws {
        var registry = InspectorSessionRegistry()
        let a = entry("a")
        let request = InfoPresentationRequest(ownerID: owner, mode: .perItem, entries: [a, a])
        XCTAssertEqual(request.entries, [a])
        _ = registry.reduce(event: .present(request))
        let session = try XCTUnwrap(registry.sessions.first)
        XCTAssertEqual(registry.reduce(event: .present(request)), [.reuse(session.id)])
        XCTAssertEqual(registry.sessions.count, 1)
    }
    func testTenOpensWithoutConfirmation() {
        var registry = InspectorSessionRegistry()
        XCTAssertEqual(open(&registry, (0..<10).map { entry("\($0)") }, mode: .perItem).count, 10)
        XCTAssertEqual(registry.sessions.count, 10)
    }
    func testElevenConfirmationCancellationAndDuplicateReply() throws {
        var registry = InspectorSessionRegistry()
        let request = InfoPresentationRequest(ownerID: owner, mode: .perItem, entries: (0..<11).map { entry("\($0)") })
        let effects = registry.reduce(event: .present(request))
        guard case .confirmMany(let token, let captured) = try XCTUnwrap(effects.first) else { return XCTFail() }
        XCTAssertEqual(captured, request)
        XCTAssertTrue(registry.sessions.isEmpty)
        XCTAssertTrue(registry.reduce(event: .confirmMany(token, approved: false)).isEmpty)
        XCTAssertTrue(registry.reduce(event: .confirmMany(token, approved: true)).isEmpty)
        XCTAssertTrue(registry.sessions.isEmpty)
    }
    func testApprovalOpensExactlyOnce() throws {
        var registry = InspectorSessionRegistry()
        let effects = registry.reduce(event: .present(InfoPresentationRequest(ownerID: owner, mode: .perItem,
            entries: (0..<11).map { entry("\($0)") })))
        guard case .confirmMany(let token, _) = try XCTUnwrap(effects.first) else { return XCTFail() }
        XCTAssertEqual(reads(registry.reduce(event: .confirmMany(token, approved: true))).count, 11)
        XCTAssertTrue(registry.reduce(event: .confirmMany(token, approved: true)).isEmpty)
    }
    func testSummaryDoesNotConfirmMany() {
        var registry = InspectorSessionRegistry()
        XCTAssertEqual(open(&registry, (0..<11).map { entry("\($0)") }, mode: .summary).count, 11)
        XCTAssertEqual(registry.sessions.count, 1)
    }
    func testEmptyRequestDoesNothing() {
        var registry = InspectorSessionRegistry()
        XCTAssertTrue(open(&registry, []).isEmpty)
        XCTAssertTrue(registry.sessions.isEmpty)
    }
    func testOwnerIsolationAndCloseCancellation() throws {
        var registry = InspectorSessionRegistry()
        let a = entry("a")
        let old = try XCTUnwrap(open(&registry, [a]).first)
        _ = registry.reduce(event: .present(InfoPresentationRequest(ownerID: UUID(), mode: .followSelection, entries: [a])))
        XCTAssertEqual(registry.sessions.count, 2)
        XCTAssertEqual(registry.reduce(event: .ownerClosed(owner)), [.cancel(old), .close(old.sessionID)])
        XCTAssertEqual(registry.sessions.count, 1)
        XCTAssertTrue(open(&registry, [a]).isEmpty)
        XCTAssertTrue(registry.reduce(event: .size(old, .final(InspectorSizeTotal(bytes: 99, itemCount: 1)))).isEmpty)
        XCTAssertTrue(registry.sessions[0].sizes.isEmpty)
    }
    func testOwnerCloseInvalidatesPendingConfirmation() throws {
        var registry = InspectorSessionRegistry()
        let effects = registry.reduce(event: .present(InfoPresentationRequest(ownerID: owner, mode: .perItem,
            entries: (0..<11).map { entry("\($0)") })))
        guard case .confirmMany(let token, _) = try XCTUnwrap(effects.first) else { return XCTFail() }
        _ = registry.reduce(event: .ownerClosed(owner))
        XCTAssertTrue(registry.reduce(event: .confirmMany(token, approved: true)).isEmpty)
    }
    func testABARejectsOldSizeAndEnrichment() throws {
        var registry = InspectorSessionRegistry()
        let a = entry("a", kind: .package)
        let first = try XCTUnwrap(open(&registry, [a]).first)
        _ = registry.reduce(event: .selectionChanged(sessionID: first.sessionID, entries: [entry("b")]))
        let latest = try XCTUnwrap(reads(registry.reduce(event: .selectionChanged(sessionID: first.sessionID, entries: [a]))).first)
        XCTAssertNotEqual(first.generation, latest.generation)
        _ = registry.reduce(event: .size(first, .final(InspectorSizeTotal(bytes: 900, itemCount: 1))))
        _ = registry.reduce(event: .enriched(first, InspectorItem(url: a.url, attributes: [.name("old")])))
        XCTAssertEqual(registry.sessions[0].sizeProjection.contents, .calculating)
        XCTAssertTrue(registry.sessions[0].edits.originals.isEmpty)
        _ = registry.reduce(event: .size(latest, .final(InspectorSizeTotal(bytes: 50, itemCount: 2))))
        XCTAssertEqual(registry.sessions[0].sizeProjection.contents, .final(InspectorSizeTotal(bytes: 50, itemCount: 2)))
    }
    func testCloseRejectsLateCallbacksAndIsIdempotent() throws {
        var registry = InspectorSessionRegistry()
        let token = try XCTUnwrap(open(&registry, [entry("a")]).first)
        XCTAssertEqual(registry.reduce(event: .close(token.sessionID)), [.cancel(token), .close(token.sessionID)])
        XCTAssertTrue(registry.reduce(event: .close(token.sessionID)).isEmpty)
        _ = registry.reduce(event: .enriched(token, InspectorItem(url: token.url, attributes: [])))
        XCTAssertTrue(registry.sessions.isEmpty)
    }
    func testTerminalSizeCannotRegressToPartial() throws {
        var registry = InspectorSessionRegistry()
        let token = try XCTUnwrap(open(&registry, [entry("a")]).first)
        let final = InspectorSizeState.final(InspectorSizeTotal(bytes: 99, itemCount: 1))
        _ = registry.reduce(event: .size(token, .partial(InspectorSizeTotal(bytes: 1, itemCount: 1))))
        _ = registry.reduce(event: .size(token, final))
        _ = registry.reduce(event: .size(token, .calculating))
        XCTAssertEqual(registry.sessions[0].sizeProjection.contents, final)
    }
    func testWrongItemAndGenerationAreRejected() throws {
        var registry = InspectorSessionRegistry()
        let token = try XCTUnwrap(open(&registry, [entry("a")]).first)
        _ = registry.reduce(event: .enriched(token, InspectorItem(url: entry("b").url, attributes: [])))
        let wrong = InspectorReadRequest(sessionID: token.sessionID, generation: UUID(), itemID: token.itemID, url: token.url)
        _ = registry.reduce(event: .size(wrong, .unavailable))
        XCTAssertTrue(registry.sessions[0].edits.originals.isEmpty)
        XCTAssertTrue(registry.sessions[0].sizes.isEmpty)
    }
    func testDirtySelectionRequiresCurrentDecisionAndPreservesDraft() throws {
        var registry = InspectorSessionRegistry()
        let token = try XCTUnwrap(open(&registry, [entry("a")]).first)
        let item = InspectorItem(url: token.url, attributes: [.name("a")], editableFields: [.name])
        _ = registry.reduce(event: .enriched(token, item))
        _ = registry.reduce(event: .edit(sessionID: token.sessionID, .name("draft")))
        _ = registry.reduce(event: .enriched(token, item))
        XCTAssertTrue(registry.sessions[0].edits.isDirty)
        let effects = registry.reduce(event: .selectionChanged(sessionID: token.sessionID, entries: [entry("b")]))
        guard case .decideSelection(_, let first) = try XCTUnwrap(effects.first) else { return XCTFail() }
        let newer = registry.reduce(event: .selectionChanged(sessionID: token.sessionID, entries: [entry("c")]))
        guard case .decideSelection(_, let latest) = try XCTUnwrap(newer.first) else { return XCTFail() }
        XCTAssertTrue(registry.reduce(event: .decideSelection(sessionID: token.sessionID, decisionID: first, .discardEdits)).isEmpty)
        XCTAssertEqual(registry.sessions[0].entries, [entry("a")])
        _ = registry.reduce(event: .decideSelection(sessionID: token.sessionID, decisionID: latest, .keepSelection))
        XCTAssertTrue(registry.sessions[0].edits.isDirty)
        let retry = registry.reduce(event: .selectionChanged(sessionID: token.sessionID, entries: [entry("b")]))
        guard case .decideSelection(_, let discard) = try XCTUnwrap(retry.first) else { return XCTFail() }
        XCTAssertEqual(reads(registry.reduce(event: .decideSelection(sessionID: token.sessionID, decisionID: discard, .discardEdits))).count, 1)
        XCTAssertFalse(registry.sessions[0].edits.isDirty)
        XCTAssertEqual(registry.sessions[0].entries, [entry("b")])
    }
    func testSameSelectionDoesNotRestartAndEmptyFollowCancels() throws {
        var registry = InspectorSessionRegistry()
        let a = entry("a")
        let token = try XCTUnwrap(open(&registry, [a]).first)
        XCTAssertTrue(registry.reduce(event: .selectionChanged(sessionID: token.sessionID, entries: [a])).isEmpty)
        XCTAssertEqual(registry.reduce(event: .selectionChanged(sessionID: token.sessionID, entries: [])), [.cancel(token)])
        XCTAssertEqual(registry.sessions[0].sizeProjection.contents, .unavailable)
    }
    func testPerItemIgnoresSelectionChanges() throws {
        var registry = InspectorSessionRegistry()
        let token = try XCTUnwrap(open(&registry, [entry("a")], mode: .perItem).first)
        XCTAssertTrue(registry.reduce(event: .selectionChanged(sessionID: token.sessionID, entries: [entry("b")])).isEmpty)
        XCTAssertEqual(registry.sessions[0].entries, [entry("a")])
    }
    func testEditsWaitForAllMetadata() throws {
        var registry = InspectorSessionRegistry()
        let tokens = open(&registry, [entry("a"), entry("b")])
        let token = try XCTUnwrap(tokens.first)
        _ = registry.reduce(event: .enriched(token, InspectorItem(url: token.url, attributes: [.comment("")], editableFields: [.comment])))
        _ = registry.reduce(event: .edit(sessionID: token.sessionID, .comment("draft")))
        XCTAssertFalse(registry.sessions[0].edits.isDirty)
    }
}
