// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class SharingTests: XCTestCase {
    private let enabled = SharingCapability(share: true, airDrop: true)
    private func selection(_ paths: [String]) throws -> SharingSelectionSnapshot {
        try SharingSelectionSnapshot(urls: paths.map { URL(fileURLWithPath: $0) })
    }

    func testOrderedDeduplicationAndRemoteRejection() throws {
        let snapshot = try selection(["/b", "/a/../b", "/é space", "/a", "/./b"])
        XCTAssertEqual(snapshot.urls.map(\.path), ["/b", "/a/../b", "/é space", "/a"])
        for value in ["https://example.com/a", "file://server/a", "file:///a?query", "file:///a#fragment"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertThrowsError(try SharingSelectionSnapshot(urls: [URL(fileURLWithPath: "/a"), url])) {
                XCTAssertEqual($0 as? SharingFailure, .nonLocalURL(url))
            }
        }
        XCTAssertEqual(try SharingSelectionSnapshot(urls: [XCTUnwrap(URL(string: "file://localhost/a"))]).urls.count, 1)
    }

    func testExplicitInvocationCapturesMultipleItemsWithoutRetargeting() throws {
        var state = SharingSessionState()
        XCTAssertNil(state.request)
        XCTAssertEqual(state.phase, .idle)
        let original = try selection(["/a", "/b"])
        let effects = state.invoke(kind: .share, selection: original, capability: enabled)
        let request = try XCTUnwrap(state.request)
        XCTAssertEqual(effects, [.presentPicker(request)])
        XCTAssertEqual(state.invoke(kind: .airDrop, selection: try selection(["/c"]), capability: enabled), [])
        XCTAssertEqual(state.request?.selection, original)
        XCTAssertEqual(state.phase, .presentingPicker)
    }

    func testEmptySelectionUsesFilePickerAndRetiresPickerIdentity() throws {
        var state = SharingSessionState()
        let effects = state.invoke(kind: .airDrop, selection: try selection([]), capability: enabled)
        let first = try XCTUnwrap(state.request)
        XCTAssertEqual(effects, [.presentFilePicker(first.id)])
        XCTAssertFalse(state.receive(requestID: first.id, outcome: .accepted))
        XCTAssertFalse(state.receive(requestID: first.id, outcome: .providerReportedCompletion))
        XCTAssertEqual(state.pickedFiles(requestID: UUID(), selection: try selection(["/wrong"]), capability: enabled), [])
        let picker = state.pickedFiles(requestID: first.id, selection: try selection(["/a", "/b"]), capability: enabled)
        let next = try XCTUnwrap(state.request)
        XCTAssertNotEqual(first.id, next.id)
        XCTAssertEqual(picker, [.presentPicker(next)])
        XCTAssertEqual(state.pickedFiles(requestID: first.id, selection: try selection(["/wrong"]), capability: enabled), [])
        XCTAssertFalse(state.receive(requestID: first.id, outcome: .cancelled))
        XCTAssertEqual(next.selection.urls.map(\.path), ["/a", "/b"])
    }

    func testCapabilityTableAndUnavailableAfterFilePicker() throws {
        for share in [false, true] {
            for airDrop in [false, true] {
                let capability = SharingCapability(share: share, airDrop: airDrop)
                for kind in [SharingKind.share, .airDrop] {
                    var state = SharingSessionState()
                    let effects = state.invoke(kind: kind, selection: try selection(["/a"]), capability: capability)
                    let supported = kind == .share ? share : airDrop
                    XCTAssertEqual(capability.supports(kind), supported)
                    XCTAssertEqual(effects.isEmpty, !supported)
                    XCTAssertEqual(state.phase, supported ? .presentingPicker : .failed(.unsupported))
                }
            }
        }
        var state = SharingSessionState()
        _ = state.invoke(kind: .airDrop, selection: try selection([]), capability: enabled)
        let id = try XCTUnwrap(state.request?.id)
        XCTAssertEqual(state.pickedFiles(requestID: id, selection: try selection(["/a"]), capability: SharingCapability()), [])
        XCTAssertEqual(state.phase, .failed(.unsupported))
    }

    func testDismissFailureAndCompletionAreDistinctAndTerminal() throws {
        let outcomes: [SharingOutcome] = [.cancelled, .failed(.provider("error")), .providerReportedCompletion]
        let phases: [SharingSessionState.Phase] = [.cancelled, .failed(.provider("error")), .providerReportedCompletion]
        for (outcome, phase) in zip(outcomes, phases) {
            var state = SharingSessionState()
            _ = state.invoke(kind: .share, selection: try selection(["/a"]), capability: enabled)
            let id = try XCTUnwrap(state.request?.id)
            XCTAssertTrue(state.receive(requestID: id, outcome: .accepted))
            XCTAssertEqual(state.phase, .accepted)
            XCTAssertFalse(state.receive(requestID: id, outcome: .accepted))
            XCTAssertTrue(state.receive(requestID: id, outcome: outcome))
            XCTAssertFalse(state.receive(requestID: id, outcome: .providerReportedCompletion))
            XCTAssertEqual(state.phase, phase)
            _ = state.invoke(kind: .share, selection: try selection(["/b"]), capability: enabled)
            XCTAssertFalse(state.receive(requestID: id, outcome: .cancelled))
            XCTAssertEqual(state.phase, .presentingPicker)
        }
    }

    func testEmptyFilePickerDismissAndOwnerClose() throws {
        var state = SharingSessionState()
        _ = state.invoke(kind: .share, selection: try selection([]), capability: enabled)
        let id = try XCTUnwrap(state.request?.id)
        XCTAssertEqual(state.pickedFiles(requestID: id, selection: try selection([]), capability: enabled), [])
        XCTAssertEqual(state.phase, .cancelled)
        for paths in [[], ["/a"]] {
            var owner = SharingSessionState()
            _ = owner.invoke(kind: .share, selection: try selection(paths), capability: enabled)
            let active = try XCTUnwrap(owner.request?.id)
            XCTAssertEqual(owner.close(), [.dismiss(active)])
            XCTAssertEqual(owner.close(), [])
            XCTAssertFalse(owner.receive(requestID: active, outcome: .providerReportedCompletion))
            XCTAssertEqual(owner.pickedFiles(requestID: active, selection: try selection(["/b"]), capability: enabled), [])
            XCTAssertEqual(owner.invoke(kind: .share, selection: try selection(["/c"]), capability: enabled), [])
            XCTAssertEqual(owner.phase, .closed)
        }
        var idle = SharingSessionState()
        XCTAssertEqual(idle.close(), [])
    }
}
