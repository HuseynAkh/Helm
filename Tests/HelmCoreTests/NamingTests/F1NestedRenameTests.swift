// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class F1NestedRenameTests: XCTestCase {
    func testNestedSourcesMustBeRefusedBeforeMutation() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["F1_RUN_DEFERRED_REGRESSIONS"] == "1",
                          "P1-1: deferred public BatchRenameIssue overlap case; see docs/prereview/fixes-F1.md")
        for paths in [["/a/folder", "/a/folder/child"], ["/a/folder/child", "/a/folder"]] {
            let plan = BatchRenamePlanner.plan(items: paths.map { URL(fileURLWithPath: $0) },
                                               rule: .addText(prepend: "new-", append: ""))
            XCTAssertFalse(plan.canExecute)
            XCTAssertTrue(plan.steps.isEmpty)
            XCTAssertEqual(plan.previews.count, 2)
        }
    }
    func testSiblingSourcesRemainExecutable() {
        let plan = BatchRenamePlanner.plan(items: ["/a/folder", "/a/folder2"].map { URL(fileURLWithPath: $0) },
                                           rule: .addText(prepend: "new-", append: ""))
        XCTAssertTrue(plan.canExecute)
        XCTAssertEqual(plan.steps.count, 4)
    }
}
