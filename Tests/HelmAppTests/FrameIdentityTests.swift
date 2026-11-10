// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmPersistence
@testable import HelmApp

final class FrameIdentityTests: XCTestCase {
    func testAllocateAndReleaseFrameNames() {
        var router = LaunchRouter()
        let first = router.allocateFrameName()
        let second = router.allocateFrameName()
        XCTAssertNotEqual(first, second)
        router.releaseFrameName(first)
        XCTAssertEqual(router.allocateFrameName(), first)
        let result = router.receive([])
        XCTAssertNil(result)
    }
    func testRepairsReserveLaterValidFrameIdentities() {
        for names in [["", "HelmMainWindow"], ["custom", "custom", "HelmMainWindow-2"]] {
            let windows = names.enumerated().map { index, name in
                SessionWindow(frameAutosaveName: name,
                    tabs: [SessionTab(location: .directory(URL(fileURLWithPath: "/tab\(index)")))], activeTabIndex: 0)
            }
            let plan = SessionRestorePlan(windows: windows, home: URL(fileURLWithPath: "/home"), isAvailableDirectory: { _ in true })
            XCTAssertEqual(plan.windows.last?.frameAutosaveName, names.last)
            XCTAssertEqual(Set(plan.windows.map(\.frameAutosaveName)).count, names.count)
            XCTAssertEqual(plan.windows.map { $0.tabs.first?.tab }, windows.map { $0.tabs.first })
        }
    }
}
