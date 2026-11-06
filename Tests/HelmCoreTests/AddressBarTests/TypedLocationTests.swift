import Foundation
import XCTest
@testable import HelmCore

/// What can be typed into the location bar (docs/rebuild/03-finder-nautilus-balance.md).
final class TypedLocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me")

    func testServerAddressesAreRecognised() {
        for text in ["smb://nas/share", "SMB://nas/share", "  afp://mac.local/Files ", "nfs://h/x", "ftp://h", "webdav://h/x", "vnc://h"] {
            XCTAssertNotNil(TypedLocation.serverURL(from: text), text)
        }
    }
    func testOrdinaryNamesAreNeverServers() {
        for text in ["smb:", "/smb://x", "a:b", "smb://", "http://example.com", "https://example.com", "~/smb://x", "notes.txt"] {
            XCTAssertNil(TypedLocation.serverURL(from: text), text)
        }
    }
    func testFileURLsBecomePaths() {
        XCTAssertEqual(TypedLocation.localPath(fromFileURL: "file:///Users/me/My%20Files"), "/Users/me/My Files")
        XCTAssertEqual(TypedLocation.localPath(fromFileURL: "file:///Users/me/My%20Files/"), "/Users/me/My Files/")
        XCTAssertEqual(TypedLocation.localPath(fromFileURL: "file://localhost/tmp"), "/tmp")
        XCTAssertNil(TypedLocation.localPath(fromFileURL: "file://server/share"))
        XCTAssertNil(TypedLocation.localPath(fromFileURL: "/Users/me"))
    }
    func testPathEntryAcceptsFileURLs() {
        let entry = PathEntry(text: "file:///Users/me/My%20Files/", currentDirectory: home, home: home)
        XCTAssertEqual(entry.resolvedURL.path, "/Users/me/My Files")
        XCTAssertTrue(entry.isSlashBrowsing)
    }
    func testEditorHandsServerAddressesToTheHost() throws {
        var state = AddressEditorState(currentDirectory: home, home: home)
        (state, _) = AddressEditor.reduce(state, .beginEditing)
        let (typed, typedEffects) = AddressEditor.reduce(state, .textChanged("smb://nas/share"))
        XCTAssertFalse(typedEffects.contains { if case .requestCompletions = $0 { return true }; return false })
        let (done, effects) = AddressEditor.reduce(typed, .returnKey)
        XCTAssertFalse(done.isEditing)
        XCTAssertTrue(effects.contains(.connect(try XCTUnwrap(URL(string: "smb://nas/share")))))
    }
    func testResolvedPathNavigatesToTheDiskSpelling() {
        var state = AddressEditorState(currentDirectory: home, home: home)
        (state, _) = AddressEditor.reduce(state, .beginEditing)
        (state, _) = AddressEditor.reduce(state, .textChanged("/users/ME"))
        let (pending, _) = AddressEditor.reduce(state, .returnKey)
        let requested = URL(fileURLWithPath: "/users/ME")
        let canonical = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        let (done, effects) = AddressEditor.reduce(pending, .resolved(pending.generation, requested: requested, canonical: canonical, .directory))
        XCTAssertFalse(done.isEditing)
        XCTAssertEqual(effects, [.navigate(canonical)])
    }
    func testCompletionMatchesEitherUnicodeSpellingAndAnyCase() {
        let parent = URL(fileURLWithPath: "/d")
        let child = CompletionCandidate(name: "Caf\u{00E9} Notes", url: parent.appendingPathComponent("Caf\u{00E9} Notes"), isDirectory: true)
        for prefix in ["caf\u{00E9}", "cafe\u{0301}", "CAF\u{00C9}"] {
            let request = CompletionRequest(parent: parent, prefix: prefix, isSlashBrowsing: false, showHidden: false, generation: Generation())
            XCTAssertEqual(PathCompletionEngine.rows(for: request, children: [child]).count, 1, prefix)
        }
    }
    func testStandardPathIsTheSameBeforeAndAfterAFileExists() throws {
        #if canImport(Darwin)
        XCTAssertEqual(PathSpelling.standardPath(URL(fileURLWithPath: "/private/tmp/helm-does-not-exist")), "/tmp/helm-does-not-exist")
        XCTAssertEqual(PathSpelling.standardPath(URL(fileURLWithPath: "/tmp/helm-does-not-exist/")), "/tmp/helm-does-not-exist")
        XCTAssertEqual(ItemID(url: URL(fileURLWithPath: "/private/var/x")), ItemID(url: URL(fileURLWithPath: "/var/x")))
        #endif
    }
}

/// Expanded folders load their children and keep them across refreshes (FB2-10).
final class ExpandedChildrenTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/root")
    private func context() -> ReducerContext { ReducerContext(now: .distantPast, homeDirectory: root) }
    private func loaded() -> (TabState, FileEntry) {
        let folder = FileEntry(url: root.appendingPathComponent("folder"), kind: .directory)
        var tab = TabState(location: .directory(root), homeDirectory: root)
        tab.isLoading = true
        let (next, _) = TabReducer.reduce(tab, .loadFinished(tab.loadGeneration, SnapshotBuilder.build(location: .directory(root), entries: [folder])), context: context())
        return (next, folder)
    }
    func testExpandAsksForChildrenAndTheyAppear() {
        let (tab, folder) = loaded()
        let (expanded, effects) = TabReducer.reduce(tab, .expand(folder.id), context: context())
        guard case .loadChildren(let url, let id, let generation, _)? = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(url, folder.url); XCTAssertEqual(id, folder.id)
        let child = FileEntry(url: folder.url.appendingPathComponent("inner.txt"))
        let (done, _) = TabReducer.reduce(expanded, .childrenLoaded(id, generation, [child]), context: context())
        XCTAssertEqual(done.snapshot.visibleIDs(expanding: done.expandedIDs), [folder.id, child.id])
    }
    func testStaleChildrenAreIgnoredAfterCollapse() {
        let (tab, folder) = loaded()
        let (expanded, _) = TabReducer.reduce(tab, .expand(folder.id), context: context())
        let (collapsed, _) = TabReducer.reduce(expanded, .collapse(folder.id), context: context())
        let child = FileEntry(url: folder.url.appendingPathComponent("inner.txt"))
        let (done, _) = TabReducer.reduce(collapsed, .childrenLoaded(folder.id, tab.loadGeneration, [child]), context: context())
        XCTAssertNil(done.snapshot.entry(child.id))
    }
    func testChildrenSurviveARootRefresh() {
        let (tab, folder) = loaded()
        let (expanded, _) = TabReducer.reduce(tab, .expand(folder.id), context: context())
        let child = FileEntry(url: folder.url.appendingPathComponent("inner.txt"))
        var (state, _) = TabReducer.reduce(expanded, .childrenLoaded(folder.id, tab.loadGeneration, [child]), context: context())
        state.isLoading = true
        let fresh = SnapshotBuilder.build(location: .directory(root), entries: [folder])
        let (refreshed, effects) = TabReducer.reduce(state, .loadFinished(state.loadGeneration, fresh), context: context())
        XCTAssertEqual(refreshed.snapshot.visibleIDs(expanding: refreshed.expandedIDs), [folder.id, child.id])
        XCTAssertTrue(effects.contains { if case .loadChildren = $0 { return true }; return false })
    }
    func testRefreshSelectingSelectsWhatArrives() {
        let (tab, folder) = loaded()
        let added = FileEntry(url: root.appendingPathComponent("new.txt"))
        let (loading, _) = TabReducer.reduce(tab, .refreshSelecting([added.id]), context: context())
        let fresh = SnapshotBuilder.build(location: .directory(root), entries: [folder, added])
        let (done, _) = TabReducer.reduce(loading, .loadFinished(loading.loadGeneration, fresh), context: context())
        XCTAssertEqual(done.selection, [added.id])
    }
}
