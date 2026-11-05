// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

@MainActor private final class F14ReplyRunner: EffectRunner {
    var replies: [@Sendable (WindowStoreAction) -> Void] = []
    var cancellations = 0
    func run(_ effect: StoreEffect, send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation? {
        switch effect {
        case .tab(_, .refreshPaths), .tab(_, .validateNavigation):
            replies.append(send)
            return StoreEffectCancellation { self.cancellations += 1 }
        default: return nil
        }
    }
}

final class F14MonitorOrderingTests: XCTestCase {
    @MainActor func testValidationRetiresAlreadyQueuedReloadSuccessAndFailure() async throws {
        for failedValidation in [false, true] {
            let root = URL(fileURLWithPath: "/root")
            let tab = TabState(location: .directory(root), homeDirectory: root)
            let runner = F14ReplyRunner()
            let store = WindowStore(window: WindowState(tabs: [tab.id], activeTabID: tab.id), tabs: [tab],
                                    runner: runner, context: ReducerContext(now: .distantPast, homeDirectory: root))
            let generation = tab.monitorGeneration
            store.send(.tab(tab.id, .monitorEvent(generation, .rescan)))
            store.send(.tab(tab.id, .monitorEvent(generation, .rootChanged)))
            XCTAssertEqual(runner.replies.count, 2)
            XCTAssertEqual(runner.cancellations, 1)
            guard runner.replies.count == 2 else { return }
            let fresh = SnapshotBuilder.build(location: tab.location,
                                              entries: [FileEntry(url: root.appendingPathComponent("new"))])
            let stale = SnapshotBuilder.build(location: tab.location,
                                              entries: [FileEntry(url: root.appendingPathComponent("old"))])
            runner.replies[1](.tab(tab.id, failedValidation ? .monitorValidationFailed(generation, .other("missing")) : .monitorSnapshot(generation, fresh)))
            store.drain()
            let accepted = try XCTUnwrap(store.state.tabs[tab.id]).snapshot
            XCTAssertNotEqual(accepted.id, tab.snapshot.id)
            XCTAssertEqual(accepted.phase, failedValidation ? .failed(.other("missing"), attempted: tab.location) : .ready)
            XCTAssertEqual(accepted.sortedEntries.map(\.id), failedValidation ? [] : fresh.sortedEntries.map(\.id))
            runner.replies[0](.tab(tab.id, .monitorSnapshot(generation, stale)))
            runner.replies[0](.tab(tab.id, .monitorValidationFailed(generation, .other("obsolete"))))
            store.drain()
            XCTAssertEqual(store.state.tabs[tab.id]?.snapshot.id, accepted.id)
            XCTAssertEqual(store.state.tabs[tab.id]?.snapshot.phase, accepted.phase)
            XCTAssertEqual(store.state.tabs[tab.id]?.snapshot.sortedEntries, accepted.sortedEntries)
            store.send(.shutdown)
        }
    }

    @MainActor func testOrdinaryEventDoesNotSupersedePendingValidation() async {
        let root = URL(fileURLWithPath: "/root")
        let tab = TabState(location: .directory(root), homeDirectory: root)
        let runner = F14ReplyRunner()
        let store = WindowStore(window: WindowState(tabs: [tab.id], activeTabID: tab.id), tabs: [tab], runner: runner,
                                context: ReducerContext(now: .distantPast, homeDirectory: root))
        store.send(.tab(tab.id, .monitorEvent(tab.monitorGeneration, .rootChanged)))
        store.send(.tab(tab.id, .monitorEvent(tab.monitorGeneration, .rescan)))
        XCTAssertEqual(runner.replies.count, 1)
        store.send(.shutdown)
    }
}

extension F14MonitorOrderingTests {
    @MainActor func testFailedValidationReplaysOnlyInterveningInvalidation() async throws {
        for dirty in [false, true] {
            let root = URL(fileURLWithPath: "/root")
            let tab = TabState(location: .directory(root), homeDirectory: root)
            let runner = F14ReplyRunner()
            let store = WindowStore(window: WindowState(tabs: [tab.id], activeTabID: tab.id), tabs: [tab], runner: runner,
                                    context: ReducerContext(now: .distantPast, homeDirectory: root))
            defer { store.send(.shutdown) }
            let generation = tab.monitorGeneration
            store.send(.tab(tab.id, .monitorEvent(generation, .unavailable(.permissionDenied))))
            if dirty { store.send(.tab(tab.id, .monitorEvent(generation, .rescan))) }
            XCTAssertEqual(runner.replies.count, 1)
            runner.replies[0](.tab(tab.id, .monitorValidationFailed(generation, .permissionDenied)))
            store.drain()
            XCTAssertEqual(runner.replies.count, dirty ? 2 : 1)
            if dirty, runner.replies.count == 2 {
                XCTAssertFalse(try XCTUnwrap(store.state.tabs[tab.id]).monitorDirty)
                let fresh = SnapshotBuilder.build(location: tab.location, entries: [FileEntry(url: root.appendingPathComponent("recovered"))])
                runner.replies[1](.tab(tab.id, .monitorSnapshot(generation, fresh)))
                store.drain()
                XCTAssertEqual(store.state.tabs[tab.id]?.snapshot.sortedEntries.map(\.name), ["recovered"])
                XCTAssertEqual(store.state.tabs[tab.id]?.snapshot.phase, .ready)
            }
        }
    }

    @MainActor func testLatestReloadWinsWithinUnchangedWatch() async throws {
        let root = URL(fileURLWithPath: "/root")
        let tab = TabState(location: .directory(root), homeDirectory: root)
        let runner = F14ReplyRunner()
        let store = WindowStore(window: WindowState(tabs: [tab.id], activeTabID: tab.id), tabs: [tab], runner: runner,
                                context: ReducerContext(now: .distantPast, homeDirectory: root))
        defer { store.send(.shutdown) }
        let generation = tab.monitorGeneration
        store.send(.tab(tab.id, .monitorEvent(generation, .rescan)))
        store.send(.tab(tab.id, .monitorEvent(generation, .rescan)))
        XCTAssertEqual(runner.replies.count, 2)
        guard runner.replies.count == 2 else { return }
        let fresh = SnapshotBuilder.build(location: tab.location, entries: [FileEntry(url: root.appendingPathComponent("new"))])
        runner.replies[1](.tab(tab.id, .monitorSnapshot(generation, fresh)))
        store.drain()
        XCTAssertEqual(store.state.tabs[tab.id]?.snapshot.sortedEntries.map(\.name), ["new"])
        let accepted = try XCTUnwrap(store.state.tabs[tab.id]).snapshot
        runner.replies[0](.tab(tab.id, .monitorSnapshot(generation, tab.snapshot)))
        runner.replies[0](.tab(tab.id, .monitorValidationFailed(generation, .other("stale"))))
        store.drain()
        XCTAssertEqual(store.state.tabs[tab.id]?.monitorGeneration, generation)
        XCTAssertEqual(store.state.tabs[tab.id]?.snapshot, accepted)
    }
}
