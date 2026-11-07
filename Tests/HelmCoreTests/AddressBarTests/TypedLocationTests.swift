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

/// Sorts read in plain words, and drives get proper names.
final class SortChoiceAndCloudDriveTests: XCTestCase {
    func testEverySortAndDirectionHasItsOwnWords() {
        for field in [ItemSort.Field.name, .size, .dateModified, .kind] {
            for ascending in [true, false] {
                let choice = SortChoice.matching(ItemSort(field: field, ascending: ascending))
                XCTAssertEqual(choice.field, field); XCTAssertEqual(choice.ascending, ascending)
            }
        }
        XCTAssertEqual(Set(SortChoice.all.map(\.title)).count, 8)
        XCTAssertEqual(SortChoice.matching(.relevance), .bestMatch)
    }
    func testChoosingASortKeepsFoldersOnTopSetting() {
        let sort = ItemSort(field: .name, ascending: true, directoriesFirst: false)
        let next = SortChoice.all[3].applied(to: sort)
        XCTAssertEqual(next.field, .dateModified); XCTAssertTrue(next.ascending); XCTAssertFalse(next.directoriesFirst)
    }
    func testCloudFolderNames() {
        XCTAssertEqual(CloudDriveNaming.provider(ofFolder: "GoogleDrive-me@example.com"), "Google Drive")
        XCTAssertEqual(CloudDriveNaming.provider(ofFolder: "OneDrive-Personal"), "OneDrive")
        XCTAssertEqual(CloudDriveNaming.provider(ofFolder: "Dropbox"), "Dropbox")
        XCTAssertEqual(CloudDriveNaming.provider(ofFolder: "Box-Box"), "Box")
    }
    func testTwoAccountsCanBeToldApart() {
        let names = CloudDriveNaming.names(forFolders: ["GoogleDrive-a@x.com", "GoogleDrive-b@x.com", "Dropbox"])
        XCTAssertEqual(names["GoogleDrive-a@x.com"], "Google Drive (a@x.com)")
        XCTAssertEqual(names["GoogleDrive-b@x.com"], "Google Drive (b@x.com)")
        XCTAssertEqual(names["Dropbox"], "Dropbox")
    }
    func testFileTextSizeIsBounded() {
        XCTAssertEqual(SettingsSchema.defaultValue(for: .fileTextSize), .double(14))
        XCTAssertEqual(SettingsSchema.validated(.double(99), for: .fileTextSize), .double(24))
        XCTAssertEqual(SettingsSchema.validated(.double(1), for: .fileTextSize), .double(11))
        XCTAssertEqual(SettingsSchema.validated(.double(140), for: .windowTransparency), .double(100))
        XCTAssertEqual(SettingsSchema.validated(.double(-5), for: .windowTransparency), .double(0))
    }
    func testPressingTheSortedFieldReversesIt() {
        let byName = ItemSort(field: .name, ascending: true, directoriesFirst: false)
        XCTAssertEqual(SortField.pressing(.name, on: byName), ItemSort(field: .name, ascending: false, directoriesFirst: false))
        XCTAssertEqual(SortField.pressing(.name, on: SortField.pressing(.name, on: byName)), byName)
        // A new field starts in its own direction: newest and largest first, names and kinds from A.
        XCTAssertEqual(SortField.pressing(.dateModified, on: byName), ItemSort(field: .dateModified, ascending: false, directoriesFirst: false))
        XCTAssertEqual(SortField.pressing(.size, on: byName), ItemSort(field: .size, ascending: false, directoriesFirst: false))
        XCTAssertEqual(SortField.pressing(.kind, on: ItemSort(field: .size, ascending: true)), ItemSort(field: .kind, ascending: true))
        XCTAssertEqual(SortField.direction(.dateModified, ascending: false), "Newest first")
        XCTAssertEqual(SortField.direction(.name, ascending: false), "Z to A")
    }
    func testTextStepsByTenPercent() {
        XCTAssertEqual(ContentZoom.textPercent(14), 100)
        XCTAssertEqual(ContentZoom.textPercent(ContentZoom.steppedText(14, by: 1)), 110)
        XCTAssertEqual(ContentZoom.textPercent(ContentZoom.steppedText(14, by: -2)), 80)
        // A size between steps moves to the next step in the direction pressed.
        XCTAssertEqual(ContentZoom.textPercent(ContentZoom.steppedText(15, by: 1)), 110)
        XCTAssertEqual(ContentZoom.textPercent(ContentZoom.steppedText(15, by: -1)), 100)
        // The ends hold, and an old size outside the steps never moves the wrong way.
        XCTAssertFalse(ContentZoom.canStepText(ContentZoom.textPoints(percent: 170), by: 1))
        XCTAssertFalse(ContentZoom.canStepText(24, by: 1))
        XCTAssertFalse(ContentZoom.canStepText(11, by: -1))
        XCTAssertTrue(ContentZoom.canStepText(24, by: -1))
        XCTAssertEqual(ContentZoom.steppedIcons(96, by: 1), 112)
        XCTAssertEqual(ContentZoom.steppedIcons(128, by: 1), 128)
        XCTAssertEqual(ContentZoom.iconPercent(48), 50)
    }
}
