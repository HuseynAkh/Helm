// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmOperations
@testable import HelmUI

final class LeafPresentationTests: XCTestCase {
    func testProgressIsClampedAndUnknownIsIndeterminate() {
        let id = OperationID()
        XCTAssertNil(OperationRowModel(id: id, title: "Copy").fraction)
        for (done, expected) in [(-1, 0.0), (1, 0.5), (9, 1.0)] {
            let row = OperationRowModel(id: id, title: "Copy",
                progress: OperationProgress(id: id, itemsDone: done, itemsTotal: 2, currentName: "a"))
            XCTAssertEqual(row.fraction, expected)
            XCTAssertTrue(row.status.contains(" of ")); XCTAssertTrue(row.canCancel)
        }
        let cancelling = OperationRowModel(id: id, title: "Copy", cancellationRequested: true)
        XCTAssertFalse(cancelling.canCancel); XCTAssertEqual(cancelling.status, "Cancelling…")
        let invalid = OperationRowModel(id: id, title: "Copy",
            progress: OperationProgress(id: id, itemsDone: 1, itemsTotal: 0, currentName: nil))
        XCTAssertNil(invalid.fraction); XCTAssertEqual(invalid.status, "Preparing…")
    }
    func testPartialOutcomesIncludePathsAndUncertainty() {
        let id = OperationID()
        let step = PlannedStep(kind: .copy, source: URL(fileURLWithPath: "/a"), destination: URL(fileURLWithPath: "/b"))
        let result = OperationResult(id: id, command: .recovery, outcomes: [
            ItemOutcome(step: step, destination: URL(fileURLWithPath: "/b 2"), result: .success(nil)),
            ItemOutcome(step: step, destination: nil, result: .failure(.timedOut)),
            ItemOutcome(step: step, destination: nil, result: .failure(.notAttempted))
        ], error: .timedOut)
        let row = OperationRowModel(id: id, title: "Copy", result: result)
        XCTAssertFalse(row.canCancel); XCTAssertEqual(row.details.count, 3)
        XCTAssertTrue(row.details[0].contains("/b 2"))
        XCTAssertTrue(row.details[1].contains("partly done"))
        XCTAssertFalse(row.details[2].contains("partly done"))
        XCTAssertTrue(row.status.contains("1 of 3 done"))
        XCTAssertNil(OperationRowModel(id: OperationID(), title: "Other", result: result).result)
        let wrongProgress = OperationProgress(id: OperationID(), itemsDone: 1, itemsTotal: 2, currentName: nil)
        XCTAssertNil(OperationRowModel(id: id, title: "Other", progress: wrongProgress).progress)
    }
    func testEveryOperationErrorHasDisplayText() {
        let errors: [OperationError] = [.cancelled, .notAttempted, .invalidPlan, .busy,
            .verificationUnavailable, .verificationFailed, .conflict, .timedOut,
            .sourceChanged(URL(fileURLWithPath: "/a")), .other("Specific error")]
        for error in errors { XCTAssertFalse(OperationRowModel.message(for: error).isEmpty) }
        XCTAssertEqual(OperationRowModel.message(for: .other("Specific error")), "Specific error")
    }
    func testSinglePropertiesPermissionsAndUnknownDates() {
        let item = FileEntry(url: URL(fileURLWithPath: "/fixtures/a.txt"), size: 42,
                             contentTypeIdentifier: "public.text", localizedKindDescription: "Text")
        let value = PropertiesViewModel(entries: [item, item], supplement: PropertiesSupplement(posixMode: 0o754))
        XCTAssertEqual(value.title, "a.txt"); XCTAssertEqual(value.kind, "Text")
        XCTAssertEqual(value.size, "42 bytes (42 bytes)"); XCTAssertEqual(value.location, "/fixtures")
        XCTAssertEqual(value.created, "Unknown"); XCTAssertEqual(value.contentType, "public.text")
        XCTAssertEqual(value.permissionRows.map { $0.1 }, ["Read, Write, Execute", "Read, Execute", "Read", "754"])
        XCTAssertEqual(PropertiesViewModel.permissionText(0), "None")
        XCTAssertEqual(PropertiesViewModel.permissionText(2), "Write")
    }
    func testAggregateUnknownOverflowAndSupplementIsolation() {
        let a = FileEntry(url: URL(fileURLWithPath: "/one/a"), size: 20, creationDate: Date())
        let b = FileEntry(url: URL(fileURLWithPath: "/two/b"), kind: .directory, size: -1)
        let value = PropertiesViewModel(entries: [a, b], supplement: PropertiesSupplement(posixMode: 0o777, locked: true))
        XCTAssertEqual(value.title, "2 Items"); XCTAssertEqual(value.kind, "Multiple kinds")
        XCTAssertEqual(value.location, "Multiple locations"); XCTAssertEqual(value.created, "Multiple dates")
        XCTAssertEqual(value.size, "20 bytes (20 bytes) (known contents only)")
        XCTAssertNil(value.supplement.posixMode); XCTAssertNil(value.supplement.locked)
        XCTAssertEqual(value.permissionRows.first?.1, "Multiple items — unavailable")
        let overflow = PropertiesViewModel(entries: [a, FileEntry(url: URL(fileURLWithPath: "/huge"), size: .max)])
        XCTAssertEqual(overflow.size, "Size exceeds supported total")
        let empty = PropertiesViewModel(entries: [])
        XCTAssertEqual(empty.title, "0 Items"); XCTAssertEqual(empty.size, "Unknown")
        XCTAssertEqual(empty.location, "Unknown"); XCTAssertEqual(empty.modified, "Unknown")
    }
    func testLargeOperationDetailsAreLazyBoundedAndCached() {
        let id = OperationID()
        let step = PlannedStep(kind: .copy, source: URL(fileURLWithPath: "/source"), destination: URL(fileURLWithPath: "/target"))
        let outcome = ItemOutcome(step: step, destination: nil, result: .failure(.notAttempted))
        let result = OperationResult(id: id, command: .recovery,
            outcomes: Array(repeating: outcome, count: 100_001), error: nil)
        let row = OperationRowModel(id: id, title: "Copy", result: result)
        for _ in 0..<100 { XCTAssertTrue(row.hasDetails) }
        XCTAssertEqual(row.formattedDetailCount, 0)
        XCTAssertEqual(row.detailPageCount, 2_001)
        XCTAssertEqual(row.detailPage(0).count, 50)
        XCTAssertEqual(row.formattedDetailCount, 50)
        for _ in 0..<100 { XCTAssertEqual(row.detailPage(0).count, 50) }
        XCTAssertEqual(row.formattedDetailCount, 50)
        XCTAssertEqual(row.detailPage(2_000).count, 1)
        XCTAssertEqual(row.formattedDetailCount, 51)
        XCTAssertTrue(row.detailPage(-1).isEmpty)
        XCTAssertTrue(row.detailPage(Int.max).isEmpty)
        XCTAssertEqual(row.formattedDetailCount, 51)
        let empty = OperationRowModel(id: OperationID(), title: "Pending")
        XCTAssertFalse(empty.hasDetails)
        XCTAssertTrue(empty.detailPage(0).isEmpty)
        XCTAssertEqual(empty.detailPageCount, 0)
    }

}
