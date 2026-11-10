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
    func testAClosedFolderKeepsItsListingSoItReopensAtOnce() {
        let (tab, folder) = loaded()
        let (expanded, _) = TabReducer.reduce(tab, .expand(folder.id), context: context())
        let child = FileEntry(url: folder.url.appendingPathComponent("inner.txt"))
        let (listed, _) = TabReducer.reduce(expanded, .childrenLoaded(folder.id, tab.loadGeneration, [child]), context: context())
        let (collapsed, _) = TabReducer.reduce(listed, .collapse(folder.id), context: context())
        // Something else is published while the folder is closed: here, a fresh root listing.
        var refreshing = collapsed
        refreshing.isLoading = true
        let fresh = SnapshotBuilder.build(location: .directory(root), entries: [folder])
        let (refreshed, _) = TabReducer.reduce(refreshing, .loadFinished(refreshing.loadGeneration, fresh), context: context())
        XCTAssertNotEqual(refreshed.snapshot.id, collapsed.snapshot.id)
        // The listing is kept, but a publication doesn't carry (or sort) a closed folder's rows.
        XCTAssertEqual(refreshed.childListings[folder.id], [child])
        XCTAssertNil(refreshed.snapshot.children[folder.id])
        XCTAssertEqual(refreshed.snapshot.sortedEntries.count, 1)
        XCTAssertEqual(refreshed.snapshot.visibleIDs(expanding: refreshed.expandedIDs), [folder.id])
        // Opening it again shows the rows straight away, and still asks for a fresh listing.
        let (reopened, effects) = TabReducer.reduce(refreshed, .expand(folder.id), context: context())
        XCTAssertNotEqual(reopened.snapshot.id, refreshed.snapshot.id)
        XCTAssertEqual(reopened.snapshot.visibleIDs(expanding: reopened.expandedIDs), [folder.id, child.id])
        XCTAssertTrue(effects.contains { if case .loadChildren = $0 { return true }; return false })
        // Closed and opened with nothing published between, the rows never left the snapshot, so nothing is published.
        let (closedAgain, _) = TabReducer.reduce(reopened, .collapse(folder.id), context: context())
        let (openedAgain, _) = TabReducer.reduce(closedAgain, .expand(folder.id), context: context())
        XCTAssertEqual(openedAgain.snapshot.id, reopened.snapshot.id)
        XCTAssertEqual(openedAgain.snapshot.visibleIDs(expanding: openedAgain.expandedIDs), [folder.id, child.id])
    }
    /// However many folders were opened and closed, a publication costs what the open ones cost.
    func testClosedListingsCostAPublicationNothing() {
        var (tab, _) = loaded()
        let folders = (0..<3).map { FileEntry(url: root.appendingPathComponent("big \($0)"), kind: .directory) }
        tab.isLoading = true
        tab = TabReducer.reduce(tab, .loadFinished(tab.loadGeneration, SnapshotBuilder.build(location: .directory(root), entries: folders)), context: context()).0
        for folder in folders {
            tab = TabReducer.reduce(tab, .expand(folder.id), context: context()).0
            let kids = (0..<500).map { FileEntry(url: folder.url.appendingPathComponent("item \($0).txt")) }
            tab = TabReducer.reduce(tab, .childrenLoaded(folder.id, tab.loadGeneration, kids), context: context()).0
            tab = TabReducer.reduce(tab, .collapse(folder.id), context: context()).0
        }
        XCTAssertEqual(tab.childListings.count, 3)
        tab.isLoading = true
        let (refreshed, _) = TabReducer.reduce(tab, .loadFinished(tab.loadGeneration, SnapshotBuilder.build(location: .directory(root), entries: folders)), context: context())
        XCTAssertTrue(refreshed.snapshot.children.isEmpty)
        XCTAssertEqual(refreshed.snapshot.sortedEntries.count, 3)
    }
    /// Closed folders keep their listings up to a budget; past it, the folder just closed keeps its own.
    func testClosedListingsStayWithinABudget() {
        let outer = FileEntry(url: root.appendingPathComponent("outer"), kind: .directory)
        let inner = FileEntry(url: outer.url.appendingPathComponent("inner"), kind: .directory)
        let big = (0..<3).map { FileEntry(url: root.appendingPathComponent("big \($0)"), kind: .directory) }
        var tab = TabState(location: .directory(root), homeDirectory: root)
        tab.isLoading = true
        tab = TabReducer.reduce(tab, .loadFinished(tab.loadGeneration, SnapshotBuilder.build(location: .directory(root), entries: [outer] + big)), context: context()).0
        func listing(_ folder: FileEntry, _ count: Int) -> [FileEntry] {
            (0..<count).map { FileEntry(url: folder.url.appendingPathComponent("item \($0).txt")) }
        }
        // A folder that stays open inside a closed one keeps its listing: it comes back open with its parent.
        tab = TabReducer.reduce(tab, .expand(outer.id), context: context()).0
        tab = TabReducer.reduce(tab, .childrenLoaded(outer.id, tab.loadGeneration, [inner]), context: context()).0
        tab = TabReducer.reduce(tab, .expand(inner.id), context: context()).0
        tab = TabReducer.reduce(tab, .childrenLoaded(inner.id, tab.loadGeneration, listing(inner, 3)), context: context()).0
        tab = TabReducer.reduce(tab, .collapse(outer.id), context: context()).0
        // Any two of these together are over the budget.
        let share = TabReducer.closedListingBudget / 2 + 1
        tab = TabReducer.reduce(tab, .expand(big[0].id), context: context()).0
        tab = TabReducer.reduce(tab, .childrenLoaded(big[0].id, tab.loadGeneration, listing(big[0], share)), context: context()).0
        tab = TabReducer.reduce(tab, .collapse(big[0].id), context: context()).0
        XCTAssertNotNil(tab.childListings[big[0].id], "one big folder alone fits")
        for folder in big.dropFirst() {
            tab = TabReducer.reduce(tab, .expand(folder.id), context: context()).0
            tab = TabReducer.reduce(tab, .childrenLoaded(folder.id, tab.loadGeneration, listing(folder, share)), context: context()).0
            tab = TabReducer.reduce(tab, .collapse(folder.id), context: context()).0
        }
        XCTAssertNil(tab.childListings[big[0].id])
        XCTAssertNil(tab.childListings[big[1].id])
        XCTAssertEqual(tab.childListings[big[2].id]?.count, share)
        XCTAssertEqual(tab.childListings[inner.id]?.count, 3)
        // The folder that lost its listing opens with nothing under it until a fresh read arrives.
        let (reopened, effects) = TabReducer.reduce(tab, .expand(big[0].id), context: context())
        XCTAssertTrue(reopened.expandedIDs.contains(big[0].id))
        XCTAssertNil(reopened.snapshot.children[big[0].id])
        XCTAssertTrue(effects.contains { if case .loadChildren(_, big[0].id, _, _) = $0 { return true }; return false })
    }
    /// Turning hidden files off must not let a closed folder flash its dotfiles from an old listing when it opens.
    func testChangingShowHiddenForgetsClosedFoldersListings() {
        let other = FileEntry(url: root.appendingPathComponent("open"), kind: .directory)
        let secret = FileEntry(url: root.appendingPathComponent("folder/.secret"), isHidden: true)
        let visible = FileEntry(url: root.appendingPathComponent("folder/visible.txt"))
        let staysOpen = FileEntry(url: other.url.appendingPathComponent("kept.txt"))
        for viaSettings in [false, true] {
            var (tab, folder) = loaded()
            // Show Hidden Files is on, so the tab lists hidden files.
            tab.showHidden = true; tab.hiddenFilesSetting = true
            tab.isLoading = true
            tab = TabReducer.reduce(tab, .loadFinished(tab.loadGeneration, SnapshotBuilder.build(location: .directory(root), entries: [folder, other])), context: context()).0
            tab = TabReducer.reduce(tab, .expand(other.id), context: context()).0
            tab = TabReducer.reduce(tab, .childrenLoaded(other.id, tab.loadGeneration, [staysOpen]), context: context()).0
            tab = TabReducer.reduce(tab, .expand(folder.id), context: context()).0
            tab = TabReducer.reduce(tab, .childrenLoaded(folder.id, tab.loadGeneration, [secret, visible]), context: context()).0
            tab = TabReducer.reduce(tab, .collapse(folder.id), context: context()).0
            XCTAssertNotNil(tab.snapshot.children[folder.id], "closed since the last publication, so still in the snapshot")
            let change: TabAction = viaSettings ? .settingsChanged(SettingsSnapshot(values: [SettingKey.showHiddenFiles.rawValue: .bool(false)])) : .toggleHidden
            tab = TabReducer.reduce(tab, change, context: context()).0
            XCTAssertFalse(tab.showHidden)
            // The closed folder's listing is gone at once, from the cache and from what's on show.
            XCTAssertNil(tab.childListings[folder.id])
            XCTAssertNil(tab.snapshot.children[folder.id])
            // The open folder keeps its rows until its fresh read comes.
            XCTAssertEqual(tab.childListings[other.id], [staysOpen])
            tab = TabReducer.reduce(tab, .loadFinished(tab.loadGeneration, SnapshotBuilder.build(location: .directory(root), entries: [folder, other])), context: context()).0
            let (reopened, effects) = TabReducer.reduce(tab, .expand(folder.id), context: context())
            XCTAssertFalse(reopened.snapshot.visibleIDs(expanding: reopened.expandedIDs).contains(secret.id))
            XCTAssertNil(reopened.snapshot.children[folder.id])
            let asked = effects.compactMap { effect -> Bool? in
                if case .loadChildren(_, folder.id, _, let options) = effect { return options.showHidden }
                return nil
            }
            XCTAssertEqual(asked, [false])
        }
    }
    /// A settings change that leaves Show Hidden alone keeps every listing.
    func testOtherSettingsChangesKeepClosedListings() {
        let (tab, folder) = loaded()
        var state = TabReducer.reduce(tab, .expand(folder.id), context: context()).0
        let child = FileEntry(url: folder.url.appendingPathComponent("inner.txt"))
        state = TabReducer.reduce(state, .childrenLoaded(folder.id, state.loadGeneration, [child]), context: context()).0
        state = TabReducer.reduce(state, .collapse(folder.id), context: context()).0
        state = TabReducer.reduce(state, .settingsChanged(SettingsSnapshot(values: [SettingKey.showHiddenFiles.rawValue: .bool(state.showHidden)])), context: context()).0
        XCTAssertEqual(state.childListings[folder.id], [child])
    }
    /// A typed `~/.zshrc`, or another app's Show in Finder, lists hidden items in that tab only. Text zoom, icon zoom
    /// and every other change in Settings leave them listed; only Show Hidden Files itself changing resets them.
    func testHiddenItemsListedForARevealStayThroughOtherSettingsChanges() {
        let (tab, _) = loaded()
        var state = TabReducer.reduce(tab, .showHiddenItems, context: context()).0
        XCTAssertTrue(state.showHidden)
        for (key, value) in [(SettingKey.fileTextSize, SettingValue.double(18)), (.gridIconSize, .double(64)), (.rememberRecentItems, .bool(false))] {
            let other = SettingsSnapshot(values: [SettingKey.showHiddenFiles.rawValue: .bool(false), key.rawValue: value])
            let (next, effects) = TabReducer.reduce(state, .settingsChanged(other), context: context())
            XCTAssertTrue(next.showHidden, "\(key) hid the items listed for the reveal")
            XCTAssertTrue(effects.isEmpty, "\(key) reloaded the folder: \(effects)")
            XCTAssertEqual(next.addressBar.showHidden, true, "\(key)")
            state = next
        }
        // Turning Show Hidden Files on and then off again is the setting changing, which every tab follows.
        let on = SettingsSnapshot(values: [SettingKey.showHiddenFiles.rawValue: .bool(true)])
        state = TabReducer.reduce(state, .settingsChanged(on), context: context()).0
        XCTAssertTrue(state.showHidden)
        let off = SettingsSnapshot(values: [SettingKey.showHiddenFiles.rawValue: .bool(false)])
        let (hidden, effects) = TabReducer.reduce(state, .settingsChanged(off), context: context())
        XCTAssertFalse(hidden.showHidden)
        XCTAssertFalse(hidden.addressBar.showHidden)
        XCTAssertTrue(effects.contains { if case .load(_, _, let options) = $0 { return !options.showHidden }; return false }, "\(effects)")
    }
    func testAClosedFolderKeepsItsRowsOutOfTheSelection() {
        let (tab, folder) = loaded()
        let (expanded, _) = TabReducer.reduce(tab, .expand(folder.id), context: context())
        let child = FileEntry(url: folder.url.appendingPathComponent("inner.txt"))
        let (listed, _) = TabReducer.reduce(expanded, .childrenLoaded(folder.id, tab.loadGeneration, [child]), context: context())
        let (collapsed, _) = TabReducer.reduce(listed, .collapse(folder.id), context: context())
        let (selected, _) = TabReducer.reduce(collapsed, .setSelection([child.id, folder.id], source: .user), context: context())
        XCTAssertEqual(selected.selection, [folder.id])
    }
    func testAFailedListingIsForgotten() {
        let (tab, folder) = loaded()
        let (expanded, _) = TabReducer.reduce(tab, .expand(folder.id), context: context())
        let child = FileEntry(url: folder.url.appendingPathComponent("inner.txt"))
        let (listed, _) = TabReducer.reduce(expanded, .childrenLoaded(folder.id, tab.loadGeneration, [child]), context: context())
        let (again, _) = TabReducer.reduce(listed, .expand(folder.id), context: context())
        let (failed, _) = TabReducer.reduce(again, .childrenFailed(folder.id, tab.loadGeneration, .permissionDenied), context: context())
        XCTAssertFalse(failed.expandedIDs.contains(folder.id))
        XCTAssertNil(failed.snapshot.children[folder.id])
        XCTAssertNil(failed.snapshot.entry(child.id))
        XCTAssertNotEqual(failed.snapshot.id, again.snapshot.id)
    }
    func testAFirstListingThatFailsOnlyClosesTheFolder() {
        let (tab, folder) = loaded()
        let (expanded, _) = TabReducer.reduce(tab, .expand(folder.id), context: context())
        let (failed, _) = TabReducer.reduce(expanded, .childrenFailed(folder.id, tab.loadGeneration, .permissionDenied), context: context())
        XCTAssertTrue(failed.expandedIDs.isEmpty)
        XCTAssertEqual(failed.snapshot.id, expanded.snapshot.id)
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
    func testLastOpenedIsRecentsOwnOrder() {
        XCTAssertEqual(SortChoice.matching(ItemSort(field: .lastOpened, ascending: false)), .mostRecentFirst)
        XCTAssertEqual(SortChoice.matching(ItemSort(field: .lastOpened, ascending: true)), .leastRecentFirst)
        XCTAssertEqual(SortChoice.mostRecentFirst.title, "Most Recent First")
        // Folders never offer it.
        XCTAssertFalse(SortChoice.all.contains { $0.field == .lastOpened })
        XCTAssertFalse(SortField.all.contains { $0.field == .lastOpened })
        XCTAssertEqual(SortField.lastOpened.title, "Last Opened")
        XCTAssertEqual(SortField.direction(.lastOpened, ascending: false), "Most recent first")
        XCTAssertEqual(SortField.direction(.lastOpened, ascending: true), "Least recent first")
        // It starts most recent first, and pressing it again reverses it, keeping Folders on top as it was.
        let first = SortField.pressing(.lastOpened, on: ItemSort(field: .name, ascending: true, directoriesFirst: false))
        XCTAssertEqual(first, ItemSort(field: .lastOpened, ascending: false, directoriesFirst: false))
        XCTAssertEqual(SortField.pressing(.lastOpened, on: first), ItemSort(field: .lastOpened, ascending: true, directoriesFirst: false))
    }
    func testLastOpenedPutsTheNewestFirstAndUndatedItemsLast() {
        func entry(_ name: String, _ seconds: TimeInterval?, kind: FileEntryKind = .regular) -> FileEntry {
            var value = FileEntry(url: URL(fileURLWithPath: "/r/" + name), kind: kind)
            value.lastOpenedDate = seconds.map { Date(timeIntervalSince1970: $0) }
            return value
        }
        let items = [entry("old folder", 1, kind: .directory), entry("old.txt", 2), entry("new folder", 3, kind: .directory),
                     entry("new.txt", 4), entry("b-undated.txt", nil), entry("a-undated.txt", nil)]
        let newest = ItemSort(field: .lastOpened, ascending: false)
        XCTAssertEqual(newest.sorted(items).map(\.name),
                       ["new folder", "old folder", "new.txt", "old.txt", "a-undated.txt", "b-undated.txt"])
        let mixed = ItemSort(field: .lastOpened, ascending: false, directoriesFirst: false)
        XCTAssertEqual(mixed.sorted(items).map(\.name).prefix(4), ["new.txt", "new folder", "old.txt", "old folder"])
    }
    /// Items with the same date, or none, read A to Z in both directions, never in reverse path order.
    func testLastOpenedReadsItemsWithTheSameDateAToZ() {
        func entry(_ name: String, _ seconds: TimeInterval?) -> FileEntry {
            var value = FileEntry(url: URL(fileURLWithPath: "/r/" + name))
            value.lastOpenedDate = seconds.map { Date(timeIntervalSince1970: $0) }
            return value
        }
        let undated = ["file10.txt", "cherry.txt", "file2.txt", "apple.txt"].map { entry($0, nil) }
        let sameMoment = ["b.txt", "c.txt", "a.txt"].map { entry($0, 7) }
        for ascending in [false, true] {
            let sort = ItemSort(field: .lastOpened, ascending: ascending)
            XCTAssertEqual(sort.sorted(undated).map(\.name), ["apple.txt", "cherry.txt", "file2.txt", "file10.txt"])
            XCTAssertEqual(sort.sorted(sameMoment).map(\.name), ["a.txt", "b.txt", "c.txt"])
        }
        // Dates still lead; only the ties read by name.
        let mixed = [entry("z-new.txt", 9), entry("b.txt", 7), entry("a.txt", 7), entry("y-old.txt", 1)]
        XCTAssertEqual(ItemSort(field: .lastOpened, ascending: false).sorted(mixed).map(\.name), ["z-new.txt", "a.txt", "b.txt", "y-old.txt"])
        XCTAssertEqual(ItemSort(field: .lastOpened, ascending: true).sorted(mixed).map(\.name), ["y-old.txt", "a.txt", "b.txt", "z-new.txt"])
    }
    func testTheLastOpenedDateSurvivesEncoding() throws {
        var entry = FileEntry(url: URL(fileURLWithPath: "/r/a.txt"))
        XCTAssertNil(entry.lastOpenedDate)
        entry.lastOpenedDate = Date(timeIntervalSince1970: 42)
        let decoded = try JSONDecoder().decode(FileEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.lastOpenedDate, Date(timeIntervalSince1970: 42))
        XCTAssertEqual(decoded, entry)
    }
    /// Last Opened is saved so a build from before it still reads the file, as Newest First; this build reads it back
    /// as Last Opened. Every other sort is saved exactly as before.
    func testLastOpenedIsSavedSoOlderBuildsCanStillReadIt() throws {
        struct OlderSort: Decodable, Equatable {
            enum Field: String, Decodable { case name, size, dateModified, kind, relevance }
            let field: Field, ascending: Bool, directoriesFirst: Bool
        }
        for ascending in [false, true] {
            let sort = ItemSort(field: .lastOpened, ascending: ascending, directoriesFirst: false)
            let data = try JSONEncoder().encode(sort)
            XCTAssertEqual(try JSONDecoder().decode(ItemSort.self, from: data), sort)
            XCTAssertEqual(try JSONDecoder().decode(OlderSort.self, from: data),
                           OlderSort(field: .dateModified, ascending: ascending, directoriesFirst: false))
        }
        for field in ItemSort.Field.allCases where field != .lastOpened {
            let sort = ItemSort(field: field, ascending: false, directoriesFirst: true)
            let data = try JSONEncoder().encode(sort)
            XCTAssertEqual(try JSONDecoder().decode(ItemSort.self, from: data), sort)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(object?.keys.sorted(), ["ascending", "directoriesFirst", "field"], "\(field)")
        }
        // A field from a newer build falls back to the stand-in written beside it; a file with no stand-in still fails.
        let newer = Data(#"{"field":"dateModified","ascending":false,"directoriesFirst":true,"exactField":"dateAdded"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ItemSort.self, from: newer), ItemSort(field: .dateModified, ascending: false))
        let unknown = Data(#"{"field":"dateAdded","ascending":false,"directoriesFirst":true}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ItemSort.self, from: unknown))
        // What this branch wrote before the stand-in still reads.
        let plain = Data(#"{"field":"lastOpened","ascending":false,"directoriesFirst":true}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ItemSort.self, from: plain), ItemSort(field: .lastOpened, ascending: false))
    }
    func testDescribingNamesEveryChoosableField() {
        XCTAssertEqual(SortField.describing(.lastOpened), SortField.lastOpened)
        XCTAssertEqual(SortField.describing(.kind)?.title, "Kind")
        XCTAssertNil(SortField.describing(.relevance))
        for field in SortField.all { XCTAssertEqual(SortField.describing(field.field), field) }
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
