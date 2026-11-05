// DRAFT: pending Opus review. AK1 regression coverage for F-047/F-048/F-050/F-067.
import Foundation
import XCTest
@testable import HelmCore

final class AK1RegressionTests: XCTestCase {
    private func entry(_ path: String, kind: FileEntryKind = .regular, children: Int? = nil) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: path, isDirectory: false), kind: kind, childCount: children)
    }
    private func gallery() -> GalleryState {
        let entries = [entry("/a"), entry("/b")]
        return GalleryState(snapshot: PresentationSnapshot(location: .recent, sortedEntries: entries),
            selection: [entries[0].id], eligibleIDs: Set(entries.map(\.id)), viewport: GalleryViewport(width: 192))
    }
    private func spring() -> SpringNavigationSession {
        SpringNavigationSession(original: SpringNavigationContext(tabID: TabID(), location: .recent),
            clock: SystemHelmClock(), delay: 0, sources: [DraggedItem(url: entry("/source/a").url)])
    }
    func testFilmstripDemandSurvivesSelectionChange() {
        var state = gallery()
        let requests = state.filmstripRequests
        let preview = state.previewRequest
        state.move(.right)
        XCTAssertEqual(state.filmstripRequests, requests)
        XCTAssertNotEqual(state.previewRequest, preview)
    }
    func testUnchangedSnapshotPreservesCompletedPreview() throws {
        var state = gallery()
        let request = try XCTUnwrap(state.previewRequest)
        XCTAssertTrue(state.previewCompleted(request))
        state.replaceSnapshot(PresentationSnapshot(location: .recent, sortedEntries: [entry("/b", children: 3), entry("/a")]),
                              eligibleIDs: [entry("/a").id, entry("/b").id])
        XCTAssertEqual(state.previewRequest, request)
        XCTAssertEqual(state.completedPreview, request)
    }
    func testFilmstripHasSmallerDefaultDimensions() throws {
        let state = gallery()
        XCTAssertNotEqual(try XCTUnwrap(state.filmstripRequests.first).key.dimensions,
                          try XCTUnwrap(state.previewRequest).key.dimensions)
    }
    func testAliasIsNotAdvertisedByDefault() {
        let sources = [DraggedItem(url: entry("/source/a").url)]
        let target = DropDestination(location: .directory(entry("/target").url))
        for modifiers: DropModifiers in [.control, [.option, .command]] {
            XCTAssertEqual(DropPlanner.proposal(sources: sources, destination: target, modifiers: modifiers).rejection, .unsupportedOperation)
            XCTAssertEqual(DropSession(sources: sources).proposal(destination: target, modifiers: modifiers).rejection, .unsupportedOperation)
        }
    }
    func testSpringAcceptsEquivalentLocalDestinationSpellings() throws {
        for spelling in ["file:///target/", "file://localhost/target", "file://localhost/target/"] {
            var state = spring()
            let destination = DropDestination(location: .directory(try XCTUnwrap(URL(string: spelling))))
            XCTAssertNotNil(state.acceptDrop(target: entry("/target", kind: .directory), destination: destination, allowedOperations: [.copy, .move]), spelling)
        }
    }
    func testSpecialIconKindsDefaultToFileIdentity() {
        let dimensions = ImageDimensions(widthPoints: 32, heightPoints: 32, backingScale: 1)
        for kind: FileEntryKind in [.package, .alias, .symlinkToDirectory, .symlinkToFile, .danglingSymlink] {
            let value = entry("/special", kind: kind)
            XCTAssertEqual(IconRequest(entry: value, dimensions: dimensions).identity, .file(value.id, value.changeToken), "\(kind)")
        }
    }
    func testEarlyInspectorEditProducesVisibleRejection() throws {
        var registry = InspectorSessionRegistry()
        _ = registry.reduce(event: .present(InfoPresentationRequest(ownerID: UUID(), mode: .summary, entries: [entry("/a")])) )
        let session = try XCTUnwrap(registry.sessions.first)
        XCTAssertEqual(registry.reduce(event: .edit(sessionID: session.id, .name("draft"))),
                       [.editRejectedAwaitingMetadata(sessionID: session.id)])
        XCTAssertFalse(registry.sessions[0].edits.isDirty)
    }
    func testSpringHonorsRequiredSourceMask() {
        for mask: Set<DropOperation> in [[], [.copy]] {
            var state = spring()
            let target = entry("/target", kind: .directory)
            XCTAssertNil(state.acceptDrop(target: target, destination: DropDestination(location: .directory(target.url)),
                                         modifiers: .command, allowedOperations: mask))
            XCTAssertNil(state.acceptedDrop)
        }
        var state = spring()
        let target = entry("/target", kind: .directory)
        XCTAssertEqual(state.acceptDrop(target: target, destination: DropDestination(location: .directory(target.url)),
                                       modifiers: .option, allowedOperations: [.copy])?.proposal.operation, .copy)
    }
    func testTrashSourcesAreRejectedAsNoOpIncludingMixedBatch() {
        let trashed = DraggedItem(url: entry("/trash/a").url, isInTrash: true)
        let normal = DraggedItem(url: entry("/source/b").url)
        for sources in [[trashed], [normal, trashed], [trashed, normal]] {
            XCTAssertEqual(DropPlanner.proposal(sources: sources, destination: DropDestination(location: .trash)).rejection,
                           .sameParentNoOp)
        }
        XCTAssertEqual(DropPlanner.proposal(sources: [normal], destination: DropDestination(location: .trash)).operation, .moveToTrash)
        XCTAssertEqual(DropPlanner.proposal(sources: [trashed], destination: DropDestination(location: .directory(entry("/target").url)),
                                           modifiers: .command).operation, .move)
    }

    func testFilmstripSizeChangesDoNotInvalidateLargePreview() throws {
        var state = gallery()
        let preview = try XCTUnwrap(state.previewRequest)
        let oldCells = state.filmstripRequests
        let size = ImageDimensions(widthPoints: 48, heightPoints: 48, backingScale: 2)
        state.updateViewport(state.viewport, dimensions: state.dimensions, filmstripDimensions: size)
        XCTAssertEqual(state.filmstripDimensions, size)
        XCTAssertNotEqual(state.filmstripRequests, oldCells)
        XCTAssertEqual(state.filmstripRequests.first?.key.dimensions, size)
        XCTAssertTrue(state.previewCompleted(preview))
    }
    func testFilmstripFullTokenAndEligibilityInvalidateOnlyAffectedDemand() {
        var state = gallery()
        let oldCells = state.filmstripRequests
        state.replaceSnapshot(PresentationSnapshot(location: .recent, sortedEntries: [entry("/a"), entry("/b", children: 1)]),
                              eligibleIDs: [entry("/a").id, entry("/b").id])
        XCTAssertEqual(state.filmstripRequests[0], oldCells[0])
        XCTAssertEqual(state.filmstripRequests[1].key, oldCells[1].key)
        XCTAssertNotEqual(state.filmstripRequests[1], oldCells[1])
        state.replaceSnapshot(state.snapshot, eligibleIDs: [entry("/b").id])
        XCTAssertEqual(state.filmstripRequests.count, 1)
        XCTAssertNil(state.previewRequest)
    }
    func testEligibilityABARetiresCompletedPreview() throws {
        var state = gallery()
        let request = try XCTUnwrap(state.previewRequest)
        XCTAssertTrue(state.previewCompleted(request))
        state.replaceSnapshot(state.snapshot, eligibleIDs: [])
        XCTAssertNil(state.completedPreview)
        state.replaceSnapshot(state.snapshot, eligibleIDs: [entry("/a").id])
        XCTAssertFalse(state.previewCompleted(request))
    }
    func testSpringRejectsUnsafeDestinationEvenWhenTargetIsLocal() throws {
        let target = entry("/target", kind: .directory)
        for raw in ["file://server/target", "file:///target?q", "file:///target#f", "file://user@localhost/target",
                    "file:///other/../target", "https://localhost/target"] {
            var state = spring()
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertNil(state.acceptDrop(target: target, destination: DropDestination(location: .directory(url)),
                                         allowedOperations: [.copy, .move]), raw)
        }
    }
    func testIconPolicyOverridesAndContentInvalidation() {
        let size = ImageDimensions(widthPoints: 32, heightPoints: 32, backingScale: 1)
        let app = entry("/app", kind: .package)
        XCTAssertEqual(IconRequest(entry: app, dimensions: size, policy: .generic).identity, .genericFile)
        let folder = entry("/folder", kind: .directory)
        XCTAssertEqual(IconRequest(entry: folder, dimensions: size, policy: .fileSpecific).identity, .file(folder.id, folder.changeToken))
        let changed = entry("/app", kind: .package, children: 1)
        XCTAssertNotEqual(IconRequest(entry: app, dimensions: size), IconRequest(entry: changed, dimensions: size))
        for kind: FileEntryKind in [.regular, .directory, .other] {
            let value = entry("/plain", kind: kind)
            if case .fileSpecific = IconPolicy.recommended(for: value) { XCTFail("Unexpected per-file lookup for \(kind)") }
        }
    }
    func testTrashMembershipSurvivesEntryConversionAndSessionReplacement() {
        let value = entry("/trash/a")
        let trashed = DraggedItem(entry: value, isInTrash: true)
        XCTAssertTrue(trashed.isInTrash)
        var session = DropSession(sources: [DraggedItem(entry: value)])
        XCTAssertEqual(session.proposal(destination: DropDestination(location: .trash)).operation, .moveToTrash)
        session.replaceSources([trashed])
        XCTAssertEqual(session.proposal(destination: DropDestination(location: .trash)).rejection, .sameParentNoOp)
    }
    func testInspectorPartialEnrichmentRejectsThenAcceptsEdit() throws {
        var registry = InspectorSessionRegistry()
        let effects = registry.reduce(event: .present(InfoPresentationRequest(ownerID: UUID(), mode: .summary,
            entries: [entry("/a"), entry("/b")])))
        let reads = effects.compactMap { effect -> InspectorReadRequest? in
            if case .read(let request) = effect { return request }; return nil
        }
        XCTAssertEqual(reads.count, 2)
        let first = try XCTUnwrap(reads.first)
        _ = registry.reduce(event: .enriched(first, InspectorItem(url: first.url, attributes: [.comment("")], editableFields: [.comment])))
        XCTAssertEqual(registry.reduce(event: .edit(sessionID: first.sessionID, .comment("draft"))),
                       [.editRejectedAwaitingMetadata(sessionID: first.sessionID)])
        XCTAssertFalse(registry.sessions[0].edits.isDirty)
        let last = try XCTUnwrap(reads.last)
        _ = registry.reduce(event: .enriched(last, InspectorItem(url: last.url, attributes: [.comment("")], editableFields: [.comment])))
        XCTAssertTrue(registry.reduce(event: .edit(sessionID: first.sessionID, .comment("draft"))).isEmpty)
        XCTAssertTrue(registry.sessions[0].edits.isDirty)
        _ = registry.reduce(event: .close(first.sessionID))
        XCTAssertTrue(registry.reduce(event: .edit(sessionID: first.sessionID, .comment("late"))).isEmpty)
    }

}
