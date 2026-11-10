// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
@testable import HelmCore

final class AF2bRegressionTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/test", isDirectory: false)
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: home) }

    func testStageCanonicalizesBeforeLoadingAndAcceptsEchoedSnapshot() throws {
        let state = TabState(location: .recent, homeDirectory: home)
        let raw = Location.directory(URL(fileURLWithPath: "/a//b/../b", isDirectory: false))
        let canonical = Location.directory(URL(fileURLWithPath: "/a/b", isDirectory: true))
        let (staged, effects) = TabReducer.reduce(state, .navigate(raw, .push), context: context)
        let request = try XCTUnwrap(effects.compactMap { effect -> Location? in
            if case .load(let location, _, _) = effect { return location }
            return nil
        }.first)
        XCTAssertEqual(request, canonical)
        XCTAssertEqual(staged.pendingNavigation?.target, canonical)
        let (rejected, rejectedEffects) = TabReducer.reduce(staged,
            .loadFinished(staged.loadGeneration, PresentationSnapshot(location: raw)), context: context)
        XCTAssertEqual(rejected, staged)
        XCTAssertTrue(rejectedEffects.isEmpty)
        // Echo the actual request, as DirectoryLoadPipeline does; admission stays strict.
        let (committed, committedEffects) = TabReducer.reduce(staged,
            .loadFinished(staged.loadGeneration, PresentationSnapshot(location: request)), context: context)
        XCTAssertEqual(committed.location, canonical)
        XCTAssertEqual(committed.snapshot.location, canonical)
        XCTAssertFalse(committed.isLoading)
        XCTAssertNil(committed.pendingNavigation)
        XCTAssertEqual(committedEffects.filter { if case .recordRecent = $0 { return true }; return false }.count, 1)
    }

    func testPushWithoutSlashAfterDirectoryURLDoesNotChangeHistoryOrRecordRecentAgain() throws {
        var state = TabState(location: .recent, homeDirectory: home)
        let enumerated = Location.directory(URL(fileURLWithPath: "/a/b/", isDirectory: true))
        state = TabReducer.reduce(state, .navigate(enumerated, .push), context: context).0
        let target = try XCTUnwrap(state.pendingNavigation?.target)
        let (committed, effects) = TabReducer.reduce(state,
            .loadFinished(state.loadGeneration, PresentationSnapshot(location: target)), context: context)
        XCTAssertEqual(effects.filter { if case .recordRecent = $0 { return true }; return false }.count, 1)
        let (next, repeatedEffects) = TabReducer.reduce(committed,
            .navigate(.directory(URL(fileURLWithPath: "/a/b", isDirectory: false)), .push), context: context)
        XCTAssertEqual(next.history.back, committed.history.back)
        XCTAssertEqual(next, committed)
        XCTAssertTrue(repeatedEffects.isEmpty)
    }

    func testTypedAndEnumeratedDirectoryProduceSamePendingLocation() throws {
        let typed = try XCTUnwrap(PathEntry.commitURL(text: "/a/b", currentDirectory: home, home: home))
        let enumerated = URL(fileURLWithPath: "/a/b/", isDirectory: true)
        let state = TabState(location: .recent, homeDirectory: home)
        let fromText = TabReducer.reduce(state, .navigate(.directory(typed), .push), context: context).0
        let fromEnumeration = TabReducer.reduce(state, .navigate(.directory(enumerated), .push), context: context).0
        XCTAssertEqual(fromText.pendingNavigation?.target, fromEnumeration.pendingNavigation?.target)
        XCTAssertEqual(fromText.pendingNavigation?.target, .directory(enumerated))
    }

    func testDefaultTabsCanonicalizeHomeAtInitAndBareAdd() async {
        await MainActor.run {
            let initial = TabID()
            let store = WindowStore(window: WindowState(tabs: [initial], activeTabID: initial), tabs: [],
                                    runner: AF2bNoopRunner(), context: context)
            let added = TabID()
            store.send(.window(.add(added, activate: true)))
            let canonical = URL(fileURLWithPath: home.standardizedFileURL.path, isDirectory: true)
            for id in [initial, added] {
                XCTAssertEqual(store.state.tabs[id]?.location, .directory(canonical))
                XCTAssertEqual(store.state.tabs[id]?.snapshot.location, .directory(canonical))
                XCTAssertEqual(store.state.tabs[id]?.lastDirectory, canonical)
                XCTAssertEqual(store.state.tabs[id]?.addressBar.currentDirectory, canonical)
            }
        }
    }

    func testAddressBarValidatedTypedPathDeduplicatesEnumeratedDirectory() throws {
        let enumerated = URL(fileURLWithPath: "/a/b/", isDirectory: true)
        var state = TabState(location: .directory(enumerated), homeDirectory: home)
        state.selection = [ItemID(url: enumerated.appendingPathComponent("selected"))]
        let history = state.history
        state = TabReducer.reduce(state, .addressBar(.beginEditing), context: context).0
        state = TabReducer.reduce(state, .addressBar(.textChanged("/a/b")), context: context).0
        state = TabReducer.reduce(state, .addressBar(.returnKey), context: context).0
        let typed = try XCTUnwrap(state.addressBar.pendingCommit)
        XCTAssertEqual(typed.path, enumerated.path)
        let (next, effects) = TabReducer.reduce(state,
            .addressBar(.validated(state.addressBar.generation, typed, .directory)), context: context)
        XCTAssertEqual(next.location, .directory(enumerated))
        XCTAssertEqual(next.history, history)
        XCTAssertEqual(next.selection, state.selection)
        XCTAssertNil(next.pendingNavigation)
        XCTAssertFalse(next.isLoading)
        XCTAssertFalse(effects.contains { effect in
            switch effect { case .load, .recordRecent: return true; default: return false }
        })
    }

    func testVirtualTargetsAndSnapshotMismatchGuardRemainUnchanged() {
        for target: Location in [.recent, .trash] {
            let initial = TabState(location: .directory(home), homeDirectory: home)
            let staged = TabReducer.reduce(initial, .navigate(target, .push), context: context).0
            XCTAssertEqual(staged.pendingNavigation?.target, target)
            let (rejected, effects) = TabReducer.reduce(staged,
                .loadFinished(staged.loadGeneration, PresentationSnapshot(location: .directory(home))), context: context)
            XCTAssertEqual(rejected, staged)
            XCTAssertTrue(effects.isEmpty)
        }
    }
}

@MainActor private final class AF2bNoopRunner: EffectRunner {
    func run(_ effect: StoreEffect, send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation? {
        nil
    }
}
