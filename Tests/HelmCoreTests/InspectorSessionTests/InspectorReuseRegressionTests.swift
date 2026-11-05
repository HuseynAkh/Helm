// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class InspectorReuseRegressionTests: XCTestCase {
    func testChangedMetadataReusesWindowButRetiresReads() throws {
        for mode: InfoPresentationRequest.Mode in [.perItem, .summary] {
            var registry = InspectorSessionRegistry()
            let owner = UUID()
            let a = FileEntry(url: URL(fileURLWithPath: "/same"), size: 12)
            let b = FileEntry(url: a.url, size: 99)
            _ = registry.reduce(event: .present(.init(ownerID: owner, mode: mode, entries: [a])))
            let old = try XCTUnwrap(registry.sessions.first?.reads.first)
            _ = registry.reduce(event: .size(old, .final(.init(bytes: 12, itemCount: 1))))
            let effects = registry.reduce(event: .present(.init(ownerID: owner, mode: mode, entries: [b])))
            XCTAssertTrue(effects.contains(.reuse(old.sessionID)))
            XCTAssertTrue(effects.contains(.cancel(old)))
            XCTAssertEqual(registry.sessions[0].entries, [b])
            XCTAssertNotEqual(registry.sessions[0].generation, old.generation)
            _ = registry.reduce(event: .size(old, .final(.init(bytes: 1000, itemCount: 1))))
            _ = registry.reduce(event: .enriched(old, .init(url: a.url, attributes: [.name("obsolete")])))
            XCTAssertTrue(registry.sessions[0].sizes.isEmpty)
            XCTAssertTrue(registry.sessions[0].edits.originals.isEmpty)
        }
    }

    func testReplacementIdentityAloneRestartsEveryReuseMode() throws {
        for mode: InfoPresentationRequest.Mode in [.perItem, .summary, .followSelection] {
            var registry = InspectorSessionRegistry()
            let owner = UUID()
            let url = URL(fileURLWithPath: "/same")
            let a = FileEntry(url: url, objectIdentity: .init(scope: "disk", object: "first"))
            let b = FileEntry(url: url, objectIdentity: .init(scope: "disk", object: "replacement"))
            _ = registry.reduce(event: .present(.init(ownerID: owner, mode: mode, entries: [a])))
            let old = try XCTUnwrap(registry.sessions.first?.reads.first)
            _ = registry.reduce(event: .present(.init(ownerID: owner, mode: mode, entries: [b])))
            XCTAssertEqual(registry.sessions[0].id, old.sessionID)
            XCTAssertNotEqual(registry.sessions[0].generation, old.generation)
            XCTAssertEqual(registry.sessions[0].entries, [b])
            let generation = registry.sessions[0].generation
            XCTAssertEqual(registry.reduce(event: .present(.init(ownerID: owner, mode: mode, entries: [b]))), [.reuse(old.sessionID)])
            XCTAssertEqual(registry.sessions[0].generation, generation)
        }
    }

    func testDirtyReuseRequiresCurrentDecision() throws {
        for mode: InfoPresentationRequest.Mode in [.perItem, .summary] {
            var registry = InspectorSessionRegistry()
            let owner = UUID()
            let a = FileEntry(url: URL(fileURLWithPath: "/same"), size: 12)
            let b = FileEntry(url: a.url, size: 99)
            _ = registry.reduce(event: .present(.init(ownerID: owner, mode: mode, entries: [a])))
            let old = try XCTUnwrap(registry.sessions.first?.reads.first)
            _ = registry.reduce(event: .enriched(old, .init(url: a.url, attributes: [.name("same")], editableFields: [.name])))
            _ = registry.reduce(event: .edit(sessionID: old.sessionID, .name("draft")))
            _ = registry.reduce(event: .present(.init(ownerID: owner, mode: mode, entries: [b])))
            let first = try XCTUnwrap(registry.sessions[0].decisionID)
            XCTAssertTrue(registry.sessions[0].edits.isDirty)
            XCTAssertEqual(registry.sessions[0].entries, [a])
            _ = registry.reduce(event: .decideSelection(sessionID: old.sessionID, decisionID: first, .keepSelection))
            XCTAssertTrue(registry.sessions[0].edits.isDirty)
            _ = registry.reduce(event: .present(.init(ownerID: owner, mode: mode, entries: [b])))
            let latest = try XCTUnwrap(registry.sessions[0].decisionID)
            _ = registry.reduce(event: .decideSelection(sessionID: old.sessionID, decisionID: first, .discardEdits))
            XCTAssertEqual(registry.sessions[0].entries, [a])
            _ = registry.reduce(event: .decideSelection(sessionID: old.sessionID, decisionID: latest, .discardEdits))
            XCTAssertEqual(registry.sessions[0].entries, [b])
            XCTAssertFalse(registry.sessions[0].edits.isDirty)
        }
    }

    func testAdmissionChecksEveryTokenComponent() throws {
        let entry = FileEntry(url: URL(fileURLWithPath: "/item"))
        let session = InspectorSession(request: .init(ownerID: UUID(), mode: .summary, entries: [entry]))
        let read = try XCTUnwrap(session.reads.first)
        XCTAssertTrue(session.accepts(read))
        XCTAssertFalse(session.accepts(.init(sessionID: UUID(), generation: read.generation, itemID: read.itemID, url: read.url)))
        XCTAssertFalse(session.accepts(.init(sessionID: read.sessionID, generation: UUID(), itemID: read.itemID, url: read.url)))
        let other = URL(fileURLWithPath: "/other")
        XCTAssertFalse(session.accepts(.init(sessionID: read.sessionID, generation: read.generation, itemID: ItemID(url: other), url: read.url)))
        XCTAssertFalse(session.accepts(.init(sessionID: read.sessionID, generation: read.generation, itemID: read.itemID, url: other)))
    }

    func testSummaryProjectsOnlyCompleteEnrichmentAtScale() throws {
        for count in [64, 2048] {
            var registry = InspectorSessionRegistry()
            let entries = (0..<count).map { FileEntry(url: URL(fileURLWithPath: "/item\($0)")) }
            _ = registry.reduce(event: .present(.init(ownerID: UUID(), mode: .summary, entries: entries)))
            let reads = try XCTUnwrap(registry.sessions.first).reads
            var projectedItemVisits = 0
            for read in reads.reversed() {
                _ = registry.reduce(event: .enriched(read, .init(url: read.url, attributes: [.comment("")], editableFields: [.comment])))
                projectedItemVisits += registry.sessions[0].edits.originals.count
                _ = registry.reduce(event: .size(read, .final(.init(bytes: 1, itemCount: 1))))
            }
            XCTAssertEqual(projectedItemVisits, count, "Only one complete projection may be built")
            XCTAssertEqual(registry.sessions[0].edits.originals.map(\.id), entries.map(\.id))
            XCTAssertEqual(registry.sessions[0].sizes.count, count)
        }
    }
}
