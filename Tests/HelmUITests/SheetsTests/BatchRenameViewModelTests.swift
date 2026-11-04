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
}
