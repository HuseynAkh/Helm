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
        let value = PropertiesViewModel(entries: [item, item], supplement: PropertiesSupplement(posixMode: 0o754, owner: "pat",
                                                                                                 group: "staff", ownerIsYou: true))
        XCTAssertEqual(value.title, "a.txt"); XCTAssertEqual(value.kind, "Text")
        XCTAssertEqual(value.windowTitle, "a.txt Properties")
        let rows = Dictionary(uniqueKeysWithValues: (value.generalRows + value.permissionRows).map { ($0.label, $0) })
        XCTAssertEqual(rows["Size"]?.value, "42 bytes")
        XCTAssertEqual(rows["Type"]?.value, "public.text")
        XCTAssertEqual(rows["Parent Folder"]?.value, "/fixtures")
        XCTAssertEqual(rows["Parent Folder"]?.reveals, true)
        // A date that was never read isn't shown as "Unknown".
        XCTAssertNil(rows["Created"]); XCTAssertNil(rows["Accessed"])
        XCTAssertEqual(rows["Owner"]?.value, "You"); XCTAssertEqual(rows["Owner"]?.note, "Can read and write")
        XCTAssertEqual(rows["Group"]?.note, "Can only read")
        XCTAssertEqual(rows["Others"]?.value, "Can only read")
        XCTAssertEqual(rows["Runs as Program"]?.value, "Yes")
        XCTAssertNil(rows["Contents"]); XCTAssertNil(rows["Disk"]); XCTAssertNil(rows["Locked"])
    }
    /// Nautilus's words for what a class of user can do with a folder's files, and plain ones for a file.
    func testAccessIsWordedAsNautilusWordsIt() {
        let folder = [7, 5, 4, 0, 3].map { PropertiesViewModel.access(UInt16($0), folder: true) }
        XCTAssertEqual(folder, ["Can create and delete files", "Can access files", "Can list files only", "No access", "Special (-wx)"])
        let file = [7, 6, 5, 4, 1, 0, 2].map { PropertiesViewModel.access(UInt16($0), folder: false) }
        XCTAssertEqual(file, ["Can read and write", "Can read and write", "Can only read", "Can only read", "No access", "No access", "Can only write"])
    }
    func testAggregateUnknownOverflowAndSupplementIsolation() {
        let a = FileEntry(url: URL(fileURLWithPath: "/one/a"), size: 20, creationDate: Date())
        let b = FileEntry(url: URL(fileURLWithPath: "/two/b"), size: -1)
        let value = PropertiesViewModel(entries: [a, b], supplement: PropertiesSupplement(posixMode: 0o777, locked: true))
        XCTAssertEqual(value.title, "2 Items"); XCTAssertEqual(value.windowTitle, "2 Items Properties")
        XCTAssertNil(value.supplement.posixMode); XCTAssertNil(value.supplement.locked)
        XCTAssertTrue(value.permissionRows.isEmpty, "permissions are for one item")
        XCTAssertEqual(value.generalRows.map(\.label), ["Selected", "Size", "Parent Folder"])
        XCTAssertEqual(value.generalRows.map(\.value), ["2 files", "20 bytes", "Several folders"])
        let overflow = PropertiesViewModel(entries: [a, FileEntry(url: URL(fileURLWithPath: "/one/huge"), size: .max)])
        XCTAssertEqual(overflow.generalRows.first { $0.label == "Size" }?.value.isEmpty, false)
        let empty = PropertiesViewModel(entries: [])
        XCTAssertEqual(empty.title, "0 Items"); XCTAssertTrue(empty.generalRows.isEmpty)
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
