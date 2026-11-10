import Foundation
import XCTest
@testable import HelmCore

/// Permissions hunt, in the tab's own state: a card stays up while the folder under it reloads, and a folder that
/// can't be opened in place keeps why until you do something else.
final class HuntPermissionsReducerTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var privateFolder: Location { .directory(home.appendingPathComponent("Private", isDirectory: true)) }
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: home) }
    @discardableResult private func send(_ action: TabAction, _ state: inout TabState) -> [TabEffect] {
        let result = TabReducer.reduce(state, action, context: context)
        state = result.0
        return result.1
    }
    private func listing(_ names: [String], at folder: URL? = nil) -> PresentationSnapshot {
        let folder = folder ?? documents
        return SnapshotBuilder.build(location: .directory(folder), entries: names.map {
            FileEntry(url: folder.appendingPathComponent($0), kind: $0.contains(".") ? .regular : .directory)
        })
    }
    /// Documents listed with a.txt selected, then Private refused while opening it from there.
    private func cardOverDocuments() -> TabState {
        var state = TabState(location: .directory(documents), homeDirectory: home)
        send(.navigate(.directory(documents), .restore), &state)
        send(.loadFinished(state.loadGeneration, listing(["a.txt", ".hidden"])), &state)
        send(.setSelection([ItemID(url: documents.appendingPathComponent("a.txt"))], source: .user), &state)
        send(.navigate(privateFolder, .push), &state)
        send(.loadFailed(state.loadGeneration, .permissionDenied), &state)
        XCTAssertTrue(isPrivateCard(state))
        return state
    }
    private func isPrivateCard(_ state: TabState) -> Bool {
        ContentStatePresentation.failureOnShow(state).map { $0.error == .permissionDenied && $0.attempted == privateFolder } ?? false
    }

    /// Show Hidden Files, a setting changing it, or an operation finishing reloads the folder under the card. The card
    /// stays, while the reload runs and after it, and the listing behind it comes back current for when you go back.
    func testReloadingTheFolderUnderACardKeepsTheCard() {
        let settings = SettingsSnapshot(values: [SettingKey.showHiddenFiles.rawValue: .bool(true)])
        let reloads: [(String, TabAction)] = [("refresh", .refresh), ("Show Hidden Files", .toggleHidden),
                                              ("an operation finishing", .refreshSelecting([ItemID(url: documents.appendingPathComponent("b.txt"))])),
                                              ("Settings", .settingsChanged(settings))]
        for (name, reload) in reloads {
            var state = cardOverDocuments()
            send(reload, &state)
            XCTAssertTrue(state.isLoading, name)
            XCTAssertTrue(isPrivateCard(state), "\(name): the card went while the folder underneath reloads")
            XCTAssertTrue(ContentStatePresentation.hidesListing(state), name)
            XCTAssertEqual(ContentStatePresentation.placeOnShow(state), privateFolder, name)
            send(.loadFinished(state.loadGeneration, listing(["a.txt", "b.txt"])), &state)
            XCTAssertTrue(isPrivateCard(state), "\(name): the card went when the folder underneath finished loading")
            XCTAssertEqual(state.location, .directory(documents), name)
            XCTAssertEqual(state.snapshot.sortedEntries.map(\.name), ["a.txt", "b.txt"], name)
            // Back from the card shows the folder, as it is now.
            send(.returnToListing, &state)
            XCTAssertNil(ContentStatePresentation.failureOnShow(state), name)
            XCTAssertEqual(state.snapshot.sortedEntries.map(\.name), ["a.txt", "b.txt"], name)
        }
    }

    /// The folder under the card failing to reload doesn't swap the card for one about that folder: it waits until
    /// you go back to it.
    func testAFolderUnderACardThatFailsToReloadLeavesTheCard() {
        var state = cardOverDocuments()
        send(.refresh, &state)
        send(.loadFailed(state.loadGeneration, .notFound), &state)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(isPrivateCard(state))
        send(.returnToListing, &state)
        send(.refresh, &state)
        send(.loadFailed(state.loadGeneration, .notFound), &state)
        XCTAssertEqual(ContentStatePresentation.failureOnShow(state)?.error, .notFound)
        XCTAssertEqual(ContentStatePresentation.failureOnShow(state)?.attempted, .directory(documents))
    }

    /// Back is what takes the card down; with no card about another place it changes nothing.
    func testReturningToTheListingOnlyTakesDownACardAboutAnotherPlace() {
        var state = cardOverDocuments()
        send(.returnToListing, &state)
        XCTAssertEqual(state.snapshot.phase, .ready)
        XCTAssertEqual(state.selection, [ItemID(url: documents.appendingPathComponent("a.txt"))], "the selection comes back with it")
        let effects = send(.returnToListing, &state)
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(state.snapshot.phase, .ready)
        // A card about the tab's own folder isn't covering anything.
        var own = TabState(location: privateFolder, homeDirectory: home)
        send(.navigate(privateFolder, .restore), &own)
        send(.loadFailed(own.loadGeneration, .permissionDenied), &own)
        send(.returnToListing, &own)
        XCTAssertTrue(isPrivateCard(own))
    }

    /// A folder opened by its triangle that can't be read closes, and the tab keeps why, until you do something else
    /// in the listing.
    func testAFolderThatCannotOpenInPlaceKeepsWhy() {
        var state = TabState(location: .directory(documents), homeDirectory: home)
        send(.navigate(.directory(documents), .restore), &state)
        send(.loadFinished(state.loadGeneration, listing(["Locked", "Open", "a.txt"])), &state)
        let locked = ItemID(url: documents.appendingPathComponent("Locked"))
        send(.expand(locked), &state)
        send(.childrenFailed(locked, state.loadGeneration, .permissionDenied), &state)
        XCTAssertFalse(state.expandedIDs.contains(locked))
        XCTAssertEqual(state.folderProblem, FolderProblem(url: documents.appendingPathComponent("Locked"), error: .permissionDenied))
        // A refresh of the folder keeps it.
        send(.refresh, &state)
        send(.loadFinished(state.loadGeneration, listing(["Locked", "Open", "a.txt"])), &state)
        XCTAssertNotNil(state.folderProblem)
        // Opening another folder, clicking an item, or going somewhere clears it.
        send(.expand(ItemID(url: documents.appendingPathComponent("Open"))), &state)
        XCTAssertNil(state.folderProblem)
        send(.expand(locked), &state)
        send(.childrenFailed(locked, state.loadGeneration, .permissionDenied), &state)
        send(.setSelection([ItemID(url: documents.appendingPathComponent("a.txt"))], source: .user), &state)
        XCTAssertNil(state.folderProblem)
        send(.expand(locked), &state)
        send(.childrenFailed(locked, state.loadGeneration, .permissionDenied), &state)
        send(.navigate(.directory(home), .push), &state)
        send(.loadFinished(state.loadGeneration, listing(["Documents"], at: home)), &state)
        XCTAssertNil(state.folderProblem)
        // A folder that was never open, or a reply for a listing since replaced, says nothing.
        send(.childrenFailed(ItemID(url: home.appendingPathComponent("Documents")), state.loadGeneration, .permissionDenied), &state)
        XCTAssertNil(state.folderProblem)
    }

    /// A folder open inside another open folder, moved to the Trash or renamed, is read again by the refresh after it
    /// and isn't there. It closes without a word: the status bar mustn't say it no longer exists, when that's what you
    /// just did. A folder you open by its triangle that turns out to be gone does say so.
    func testAnOpenFolderThatsGoneWhenReadAgainClosesWithoutAWord() {
        var state = TabState(location: .directory(documents), homeDirectory: home)
        state.viewMode = .list  // Folders open in place only in the list.
        send(.navigate(.directory(documents), .restore), &state)
        send(.loadFinished(state.loadGeneration, listing(["Old", "Reports", "a.txt"])), &state)
        let reports = documents.appendingPathComponent("Reports", isDirectory: true)
        let year = reports.appendingPathComponent("2026", isDirectory: true)
        let q1 = ItemID(url: reports.appendingPathComponent("q1.txt"))
        send(.expand(ItemID(url: reports)), &state)
        send(.childrenLoaded(ItemID(url: reports), state.loadGeneration, [FileEntry(url: year, kind: .directory), FileEntry(url: q1.url)]), &state)
        send(.expand(ItemID(url: year)), &state)
        send(.childrenLoaded(ItemID(url: year), state.loadGeneration, [FileEntry(url: year.appendingPathComponent("q2.txt"))]), &state)
        // 2026 goes to the Trash, and the window refreshes, selecting the item after it. Each folder left open is
        // read again, 2026 included, and its read finds nothing there; either reply can come first.
        send(.refreshSelecting([q1]), &state)
        let reread = send(.loadFinished(state.loadGeneration, listing(["Old", "Reports", "a.txt"])), &state)
        XCTAssertTrue(reread.contains { if case .loadChildren(_, ItemID(url: year), _, _) = $0 { return true }; return false }, "\(reread)")
        for goneFirst in [true, false] {
            var refreshed = state
            let replies: [TabAction] = [.childrenFailed(ItemID(url: year), refreshed.loadGeneration, .notFound),
                                        .childrenLoaded(ItemID(url: reports), refreshed.loadGeneration, [FileEntry(url: q1.url)])]
            for reply in goneFirst ? replies : replies.reversed() { send(reply, &refreshed) }
            XCTAssertNil(refreshed.folderProblem, "goneFirst \(goneFirst)")
            XCTAssertNil(ContentStatePresentation.statusActivity(for: refreshed, home: home, fullDiskAccess: .unknown), "goneFirst \(goneFirst)")
            XCTAssertFalse(refreshed.expandedIDs.contains(ItemID(url: year)))
            XCTAssertEqual(refreshed.selection, [q1], "goneFirst \(goneFirst)")
        }
        // A folder left open that can't be read any more still says why when the list reads it again.
        var refused = state
        send(.childrenFailed(ItemID(url: reports), refused.loadGeneration, .permissionDenied), &refused)
        XCTAssertEqual(refused.folderProblem?.error, .permissionDenied)
        XCTAssertEqual(refused.folderProblem.map { ItemID(url: $0.url) }, ItemID(url: reports))
        // Opening a folder that has gone since it was listed says why it didn't open.
        let old = ItemID(url: documents.appendingPathComponent("Old"))
        send(.expand(old), &state)
        send(.childrenFailed(old, state.loadGeneration, .notFound), &state)
        XCTAssertEqual(state.folderProblem, FolderProblem(url: documents.appendingPathComponent("Old"), error: .notFound))
    }
}
