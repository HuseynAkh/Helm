// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmUI

final class BatchRenameViewModelTests: XCTestCase {
    private func model(_ names: [String]) -> BatchRenameViewModel {
        BatchRenameViewModel(items: names.map { URL(fileURLWithPath: "/fixtures/\($0)") },
                             existingNames: [:], caseSensitive: true, date: Date(timeIntervalSince1970: 0),
                             timeZone: TimeZone(secondsFromGMT: 0) ?? .current)
    }
    func testModesPreserveFinalExtensionAndTokens() {
        var value = model(["archive.tar.gz", "photo.jpg"])
        XCTAssertFalse(value.canRename)
        value.prepend = "A-"; value.append = "-B"
        XCTAssertEqual(value.preview.map(\.proposedName), ["A-archive.tar-B.gz", "A-photo-B.jpg"])
        value.mode = .findReplace; value.find = "photo"; value.replacement = "image"
        XCTAssertEqual(value.preview.last?.proposedName, "image.jpg")
        value.find = ""; XCTAssertFalse(value.canRename)
        value.mode = .template; value.template = "[Original Name]-[Counter]-[Date]"; value.counterStart = "3"
        XCTAssertEqual(value.preview.last?.proposedName, "photo-4-1970-01-01.jpg")
    }
    func testPreviewLimitDoesNotLimitValidationOrPlan() {
        var value = model((0..<25).map { "file\($0).txt" })
        value.append = "-new"
        XCTAssertEqual(value.preview.count, 20)
        XCTAssertEqual(value.plan?.renames.count, 25)
        XCTAssertEqual(value.plan?.steps.count, 50)
        XCTAssertEqual(value.evaluationCount, 1)
        _ = value.validationMessages; _ = value.canRename; _ = value.preview
        XCTAssertEqual(value.evaluationCount, 1)
        value.mode = .template; value.template = "same"
        XCTAssertFalse(value.canRename)
        XCTAssertFalse(value.validationMessages.isEmpty)
    }
    func testInvalidCountersTraversalAndOverflowAreBlocked() {
        var value = model(["a.txt", "b.txt"])
        value.mode = .template; value.counterStart = "1.5"
        XCTAssertNil(value.plan); XCTAssertFalse(value.canRename)
        XCTAssertEqual(value.validationMessages, ["Enter a whole number for Start at."])
        value.counterStart = String(Int.max)
        XCTAssertFalse(value.canRename)
        XCTAssertTrue(value.validationMessages.contains { $0.contains("Counter is too large") })
        value.mode = .addText; value.prepend = "../"
        XCTAssertFalse(value.canRename)
        XCTAssertTrue(value.validationMessages.contains { $0.contains("slash") })
    }
    func testOccupancyDuplicatesAndEmptySelection() {
        var value = BatchRenameViewModel(items: [URL(fileURLWithPath: "/fixtures/a.txt")],
            existingNames: [URL(fileURLWithPath: "/fixtures"): ["A-new.txt"]], caseSensitive: false,
            date: Date(), timeZone: .current)
        value.append = "-new"
        XCTAssertFalse(value.canRename)
        XCTAssertTrue(value.validationMessages.contains { $0.contains("already exists") })
        var duplicate = model(["a.txt", "a.txt"]); duplicate.append = "x"
        XCTAssertTrue(duplicate.validationMessages.contains { $0.contains("more than once") })
        XCTAssertFalse(model([]).canRename)
    }
    func testAllNameValidationMessagesAndAllowedColon() {
        let cases: [(String, FileNameError)] = [(" ", .empty), ("a/b", .separator), ("a\0b", .nul),
                                               (".", .dot), ("..", .dot), (String(repeating: "é", count: 128), .tooLong)]
        for (input, error) in cases {
            XCTAssertEqual(NewItemNameValidation.message(for: input), NewItemNameValidation.message(for: error))
        }
        XCTAssertNil(NewItemNameValidation.message(for: " report: final.txt "))
    }
    func testEditsInvalidateCopiesAndRejectObsoleteCompletion() {
        var value = model(["a.txt"])
        value.append = "-old"
        let old = value
        value.append = "-new"
        let newest = value.evaluation
        // Deliver the older computation after the newest one.
        let obsolete = old.evaluation
        XCTAssertNil(obsolete.executablePlan(for: value.revision))
        XCTAssertNotNil(newest.executablePlan(for: value.revision))
        XCTAssertEqual(value.preview.first?.proposedName, "a-new.txt")
        XCTAssertEqual(old.preview.first?.proposedName, "a-old.txt")
        XCTAssertEqual(old.evaluationCount, 1)
        XCTAssertEqual(value.evaluationCount, 1)
        let edits: [(inout BatchRenameViewModel) -> Void] = [
            { $0.mode = .template }, { $0.prepend = "p" }, { $0.append = "a" },
            { $0.find = "f" }, { $0.replacement = "r" }, { $0.template = "[Counter]" },
            { $0.counterStart = "5" }
        ]
        for edit in edits {
            let previous = value.revision
            edit(&value)
            XCTAssertNotEqual(value.revision, previous)
            XCTAssertEqual(value.evaluationCount, 0)
            _ = value.preview; _ = value.plan; _ = value.validationMessages
            XCTAssertEqual(value.evaluationCount, 1)
        }
    }
    func testConcurrentReadsShareOneEvaluation() async {
        var value = model((0..<100).map { "file\($0).txt" })
        value.append = "-new"
        let snapshot = value
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { _ = snapshot.evaluation } }
        }
        XCTAssertEqual(snapshot.evaluationCount, 1)
        XCTAssertEqual(snapshot.plan?.renames.count, 100)
    }

}
