// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class StoreSelectionBinderTests: XCTestCase {
    func testReloadSuppressesFeedbackAndDropsDeletedIDs() async {
        await MainActor.run {
            let binder = StoreSelectionBinder()
            XCTAssertNil(binder.userSelection([]))
            let url = URL(fileURLWithPath: "/a")
            let entry = FileEntry(url: url.appendingPathComponent("file"))
            var tab = TabState(location: .directory(url), homeDirectory: url)
            tab.snapshot = PresentationSnapshot(location: tab.location, sortedEntries: [entry])
            tab.selection = [entry.id]
            binder.apply(tab) { snapshot, selection in
                XCTAssertEqual(snapshot.sortedIDs, [entry.id]); XCTAssertEqual(selection, [entry.id])
                XCTAssertTrue(binder.isApplying); XCTAssertNil(binder.userSelection([]))
                binder.apply(tab) { _, _ in XCTFail("Nested application") }
            }
            XCTAssertFalse(binder.isApplying)
            XCTAssertEqual(binder.userSelection([entry.id]), [entry.id])
            tab.snapshot = PresentationSnapshot(location: tab.location)
            binder.apply(tab) { _, selection in XCTAssertTrue(selection.isEmpty) }
            XCTAssertEqual(binder.userSelection([entry.id]), [])
        }
    }

    func testCollapsedChildCannotRemainSelected() async {
        await MainActor.run {
            let binder = StoreSelectionBinder()
            let url = URL(fileURLWithPath: "/a")
            let parent = FileEntry(url: url.appendingPathComponent("folder"), kind: .directory)
            let child = FileEntry(url: parent.url.appendingPathComponent("child"))
            var tab = TabState(location: .directory(url), homeDirectory: url)
            tab.snapshot = PresentationSnapshot(location: tab.location, sortedEntries: [parent, child], rootCount: 1,
                                                children: [parent.id: TreeChildren(sortedIDs: [child.id])])
            tab.selection = [child.id]; tab.expandedIDs = [parent.id]
            binder.apply(tab) { _, selection in XCTAssertEqual(selection, [child.id]) }
            tab.expandedIDs = []
            binder.apply(tab) { _, selection in XCTAssertTrue(selection.isEmpty) }
            XCTAssertEqual(binder.userSelection([parent.id, child.id]), [parent.id])
        }
    }
}
