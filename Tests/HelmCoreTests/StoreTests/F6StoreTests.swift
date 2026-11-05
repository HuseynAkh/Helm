// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

@MainActor private final class F6Runner: EffectRunner {
    var reloadCancelled = false
    func run(_ effect: StoreEffect, send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation? {
        if case .tab(_, .refreshPaths) = effect {
            return StoreEffectCancellation { self.reloadCancelled = true }
        }
        return nil
    }
}
final class F6StoreTests: XCTestCase {
    func testForegroundRefreshCancelsAuxiliaryMonitorReload() async {
        await MainActor.run {
            let root = URL(fileURLWithPath: "/a")
            let tab = TabState(location: .directory(root), homeDirectory: root)
            let runner = F6Runner()
            let store = WindowStore(window: WindowState(tabs: [tab.id], activeTabID: tab.id), tabs: [tab], runner: runner,
                                    context: ReducerContext(now: .distantPast, homeDirectory: root))
            store.send(.tab(tab.id, .monitorEvent(tab.monitorGeneration, .rescan)))
            XCTAssertFalse(runner.reloadCancelled)
            store.send(.tab(tab.id, .refresh))
            XCTAssertTrue(runner.reloadCancelled)
        }
    }
}
