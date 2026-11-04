// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class F1NestedRenameTests: XCTestCase {
    func testNestedSourcesMustBeRefusedBeforeMutation() throws {
        for paths in [["/a/folder", "/a/folder/child"], ["/a/folder/child", "/a/folder"]] {
            let plan = BatchRenamePlanner.plan(items: paths.map { URL(fileURLWithPath: $0) },
                                               rule: .addText(prepend: "new-", append: ""))
            XCTAssertFalse(plan.canExecute)
            XCTAssertTrue(plan.steps.isEmpty)
            XCTAssertEqual(plan.previews.count, 2)
        }
    }
    func testK29OverlapUsesStandardComponentsAndVolumeCaseRules() throws {
        let parent = URL(fileURLWithPath: "/a/FOLDER")
        let child = URL(fileURLWithPath: "/a/unused/../folder/child")
        let insensitive = BatchRenamePlanner.plan(items: [child, parent], rule: .addText(prepend: "new-", append: ""))
        XCTAssertFalse(insensitive.canExecute)
        XCTAssertTrue(insensitive.issues.contains(.overlappingSources(parent, child)))
        let sensitive = BatchRenamePlanner.plan(items: [child, parent], rule: .addText(prepend: "new-", append: ""), caseSensitive: true)
        XCTAssertTrue(sensitive.canExecute)
        let explicit = BatchRenamePlanner.plan(renames: [
            RenamePair(source: parent, newName: try XCTUnwrap(ValidFileName("FOLDER"))),
            RenamePair(source: child, newName: try XCTUnwrap(ValidFileName("changed")))])
        XCTAssertFalse(explicit.canExecute, "Conservatively refuse even unchanged selected ancestors")
        XCTAssertTrue(explicit.steps.isEmpty); XCTAssertEqual(explicit.previews.count, 2)
    }
    func testSiblingSourcesRemainExecutable() {
        let plan = BatchRenamePlanner.plan(items: ["/a/folder", "/a/folder2"].map { URL(fileURLWithPath: $0) },
                                           rule: .addText(prepend: "new-", append: ""))
        XCTAssertTrue(plan.canExecute)
        XCTAssertEqual(plan.steps.count, 4)
    }
}
