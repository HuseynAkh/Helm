// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmPersistence
@testable import HelmApp

final class LaunchTests: XCTestCase {
    let home = URL(fileURLWithPath: "/home/test")
    func testColdRequestsWinAndReachFirstContents() {
        var router = LaunchRouter()
        let folder = URL(fileURLWithPath: "/requested")
        let file = URL(fileURLWithPath: "/other/file.txt")
        XCTAssertNil(router.receive([ExternalOpenRequest(url: folder, kind: .folder)]))
        XCTAssertNil(router.receive([ExternalOpenRequest(url: file, kind: .file)]))
        let saved = [SessionWindow(frameAutosaveName: "saved", tabs: [SessionTab(location: .recent)])]
        let result = router.finishLaunch(session: saved, restoreSession: true, home: home) { _ in true }
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows.first?.tabs.first?.tab.location, .directory(folder))
        XCTAssertEqual(result.windows.last?.tabs.first?.tab.location, .directory(file.deletingLastPathComponent()))
        XCTAssertEqual(result.windows.last?.tabs.first?.selectedURLs, [file])
        XCTAssertTrue(router.bufferedRequests.isEmpty)
        XCTAssertTrue(router.finishLaunch(session: [], restoreSession: true, home: home) { _ in true }.windows.isEmpty)
    }
    func testDefaultRestoreAndDisabledRestore() {
        for enabled in [false, true] {
            var router = LaunchRouter()
            let saved = [SessionWindow(frameAutosaveName: "saved", tabs: [SessionTab(location: .recent)])]
            let result = router.finishLaunch(session: saved, restoreSession: enabled, home: home) { _ in true }
            XCTAssertEqual(result.windows.first?.tabs.first?.tab.location, enabled ? .recent : .directory(home))
        }
        var router = LaunchRouter()
        XCTAssertEqual(router.finishLaunch(session: [], restoreSession: true, home: home) { _ in true }.windows.count, 1)
        XCTAssertEqual(router.receive([ExternalOpenRequest(url: home, kind: .folder)])?.windows.count, 1)
    }
    func testInvalidRequestsDoNotSilentlyRestoreOrOpenHome() throws {
        var router = LaunchRouter()
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/folder"))
        let requests = [ExternalOpenRequest(url: remote, kind: .folder), ExternalOpenRequest(url: home, kind: .unavailable)]
        XCTAssertNil(router.receive(requests))
        let result = router.finishLaunch(session: [], restoreSession: true, home: home) { _ in true }
        XCTAssertEqual(result.rejectedRequests, requests)
        XCTAssertTrue(result.windows.isEmpty)
    }
    func testRestorationFallbackAndPreferences() {
        let missing = URL(fileURLWithPath: "/unmounted")
        let tab = SessionTab(location: .directory(missing), viewMode: .list, showHidden: true)
        let saved = [SessionWindow(frameAutosaveName: "same", tabs: [tab, SessionTab(location: .trash)], activeTabIndex: 99),
                     SessionWindow(frameAutosaveName: "same", tabs: []),
                     SessionWindow(frameAutosaveName: "", tabs: [SessionTab(location: .directory(home))])]
        let result = SessionRestorePlan(windows: saved, home: home) { $0 == self.home }
        XCTAssertEqual(result.windows.count, 3)
        XCTAssertEqual(Set(result.windows.map(\.frameAutosaveName)).count, 3)
        XCTAssertEqual(result.windows[0].activeTabIndex, 1)
        let restored = result.windows[0].tabs[0]
        XCTAssertEqual(restored.tab.location, .directory(home))
        XCTAssertEqual(restored.tab.viewMode, .list)
        XCTAssertTrue(restored.tab.showHidden)
        XCTAssertEqual(restored.unavailableLocation, .directory(missing))
        XCTAssertEqual(result.windows[0].tabs[1].tab.location, .trash)
        XCTAssertEqual(result.windows[1].tabs.count, 1)
        XCTAssertNil(result.windows[2].tabs[0].unavailableLocation)
    }
    func testLateOpenFrameNamesDoNotCollideWithRestoredWindows() {
        var router = LaunchRouter()
        let saved = [SessionWindow(frameAutosaveName: "HelmMainWindow", tabs: []),
                     SessionWindow(frameAutosaveName: "HelmMainWindow-2", tabs: [])]
        _ = router.finishLaunch(session: saved, restoreSession: true, home: home) { _ in true }
        let first = router.receive([ExternalOpenRequest(url: home, kind: .folder)])
        let second = router.receive([ExternalOpenRequest(url: home, kind: .folder)])
        XCTAssertEqual(first?.windows.first?.frameAutosaveName, "HelmMainWindow-3")
        XCTAssertEqual(second?.windows.first?.frameAutosaveName, "HelmMainWindow-4")
    }
    func testNonFileSessionLocationFallsBackWithoutAvailabilityLookup() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/folder"))
        let saved = [SessionWindow(frameAutosaveName: "", tabs: [SessionTab(location: .directory(url))])]
        let result = SessionRestorePlan(windows: saved, home: home) { _ in
            XCTFail("Non-file location must not reach filesystem lookup"); return true
        }
        XCTAssertEqual(result.windows.first?.tabs.first?.unavailableLocation, .directory(url))
        XCTAssertEqual(result.windows.first?.tabs.first?.tab.location, .directory(home))
        XCTAssertEqual(SessionRestorePlan.frameName(ordinal: 0), "HelmMainWindow")
        XCTAssertEqual(WindowCreationRequest(frameAutosaveName: "empty", tabs: [], activeTabIndex: -1).activeTabIndex, 0)
    }
    func testRegistryMaintainsCreationAndActivationOrder() {
        var registry = WindowRegistry()
        let a = AppWindowID(), b = AppWindowID(), unknown = AppWindowID()
        XCTAssertTrue(registry.register(a)); XCTAssertTrue(registry.register(b))
        XCTAssertFalse(registry.register(a)); XCTAssertFalse(registry.activate(unknown))
        XCTAssertEqual(registry.first, a); XCTAssertEqual(registry.frontmost, b)
        XCTAssertTrue(registry.activate(a)); XCTAssertEqual(registry.closeOrder, [a, b])
        XCTAssertFalse(registry.close(unknown)); XCTAssertTrue(registry.close(a))
        XCTAssertEqual(registry.frontmost, b); XCTAssertTrue(registry.close(b))
        XCTAssertNil(registry.frontmost); XCTAssertTrue(registry.needsWindowOnReopen(hasVisibleWindows: false))
        XCTAssertFalse(registry.needsWindowOnReopen(hasVisibleWindows: true))
    }
    func testQuitWaitFlushFailureRetryAndCancel() {
        var quit = QuitCoordinator()
        XCTAssertEqual(quit.flushCompleted(succeeded: true), .none)
        XCTAssertEqual(quit.requestQuit(inFlightOperations: 2), .waitForOperations)
        XCTAssertEqual(quit.requestQuit(inFlightOperations: 0), .none)
        XCTAssertEqual(quit.operationsChanged(inFlightOperations: 1), .none)
        XCTAssertEqual(quit.cancel(), .cancelQuit)
        XCTAssertEqual(quit.requestQuit(inFlightOperations: 1), .waitForOperations)
        XCTAssertEqual(quit.operationsChanged(inFlightOperations: 0), .flushStores)
        XCTAssertEqual(quit.cancel(), .none)
        XCTAssertEqual(quit.flushCompleted(succeeded: false), .none)
        XCTAssertEqual(quit.state, .failed)
        XCTAssertEqual(quit.requestQuit(inFlightOperations: 0), .flushStores)
        XCTAssertEqual(quit.flushCompleted(succeeded: true), .terminate)
        XCTAssertEqual(quit.state, .ready)
        XCTAssertEqual(quit.cancel(), .none)
    }
}
