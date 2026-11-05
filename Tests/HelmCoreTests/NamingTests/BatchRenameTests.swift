import Foundation
import XCTest
@testable import HelmCore

final class BatchRenameTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/test")
    private func pair(_ old: String, _ new: String) throws -> RenamePair {
        RenamePair(source: directory.appendingPathComponent(old), newName: try XCTUnwrap(ValidFileName(new)))
    }

    func testSwapsHaveSafeTwoPhaseOrdering() throws {
        let plan = BatchRenamePlanner.plan(renames: try [pair("a", "b"), pair("b", "a")],
                                          existingNames: [directory: ["a", "b", ".helm-rename-1"]])
        XCTAssertTrue(plan.canExecute)
        XCTAssertEqual(plan.steps.count, 4)
        var files: [String: String] = ["a": "content A", "b": "content B", ".helm-rename-1": "reserved"]
        for step in plan.steps {
            XCTAssertNil(files[step.newName.value])
            let content = try XCTUnwrap(files.removeValue(forKey: step.source.lastPathComponent))
            files[step.newName.value] = content
        }
        XCTAssertEqual(files["b"], "content A")
        XCTAssertEqual(files["a"], "content B")
        XCTAssertEqual(files[".helm-rename-1"], "reserved")
    }

    func testCollisionAndDuplicateSourcesBlockExecution() throws {
        for pairs in [try [pair("a", "x"), pair("b", "X")],
                      try [pair("a", "b"), pair("b", "b")],
                      try [pair("a", "x"), pair("a", "y")],
                      try [pair("a", "é"), pair("b", "e\u{301}")]] {
            let plan = BatchRenamePlanner.plan(renames: pairs)
            XCTAssertFalse(plan.issues.isEmpty)
            XCTAssertFalse(plan.canExecute)
            XCTAssertTrue(plan.steps.isEmpty)
        }
        let external = BatchRenamePlanner.plan(renames: try [pair("a", "x")], existingNames: [directory: ["X"]])
        XCTAssertEqual(external.issues, [.collision(directory.appendingPathComponent("x"))])
        XCTAssertTrue(BatchRenamePlanner.plan(renames: try [pair("a", "x")], existingNames: [directory: ["X"]], caseSensitive: true).canExecute)
    }

    func testCaseOnlyAndNormalizationOnlyAndUnchanged() throws {
        XCTAssertTrue(BatchRenamePlanner.plan(renames: try [pair("a", "A")], existingNames: [directory: ["a"]]).canExecute)
        XCTAssertTrue(BatchRenamePlanner.plan(renames: try [pair("é", "e\u{301}")]).canExecute)
        let unchanged = BatchRenamePlanner.plan(renames: try [pair("a", "a")])
        XCTAssertFalse(unchanged.hasChanges)
        XCTAssertFalse(unchanged.canExecute)
        XCTAssertTrue(unchanged.steps.isEmpty)
        XCTAssertEqual(unchanged.previews.count, 1)
    }

    func testRulePreviewInvalidInputsAndOverflow() {
        let items = [directory.appendingPathComponent("a.txt"), directory.appendingPathComponent("b.txt")]
        let valid = BatchRenamePlanner.plan(items: items, rule: .template("[Counter]", counterStart: 1))
        XCTAssertEqual(valid.previews.map(\.proposedName), ["1.txt", "2.txt"])
        XCTAssertTrue(valid.canExecute)
        let invalid = BatchRenamePlanner.plan(items: items, rule: .addText(prepend: "../", append: ""))
        XCTAssertEqual(invalid.issues.count, 2)
        XCTAssertEqual(invalid.previews.count, 2)
        XCTAssertTrue(invalid.steps.isEmpty)
        let overflow = BatchRenamePlanner.plan(items: items, rule: .template("[Counter]", counterStart: Int.max))
        XCTAssertEqual(overflow.issues, [.counterOverflow(items[1])])
        XCTAssertTrue(overflow.steps.isEmpty)
        XCTAssertFalse(BatchRenamePlanner.plan(items: [], rule: .addText(prepend: "", append: "")).canExecute)
    }

    func testDifferentDirectoriesDoNotConflict() throws {
        let pairs = [try pair("a", "x"), RenamePair(source: URL(fileURLWithPath: "/other/a"), newName: try XCTUnwrap(ValidFileName("x")))]
        XCTAssertTrue(BatchRenamePlanner.plan(renames: pairs).canExecute)
    }
}
