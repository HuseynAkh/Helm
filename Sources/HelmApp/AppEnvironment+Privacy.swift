import Foundation
import HelmCore
import HelmFileSystem
import HelmPersistence

/// What Helm keeps about you follows Settings › General:
/// - With "Reopen windows and tabs" off, no session is saved and session.json is deleted.
/// - With "Remember recent items" off, Recent and the apps you've used are cleared, and windows add nothing new.
/// Where a trashed item came from is kept only while the item is in the Trash. Where a starred item or bookmark sits
/// in the sidebar, and whether it's hidden, is kept only while it's starred or bookmarked.
extension AppEnvironment {
    /// Applies the switches now, then whenever one changes. Turning one off forgets that record straight away.
    public func followPrivacySettings() {
        guard !followsPrivacySettings else { return }
        followsPrivacySettings = true
        var previous: SettingsSnapshot?
        let apply: @MainActor (SettingsSnapshot) -> Void = { [weak self] snapshot in
            self?.forgetWhatIsTurnedOff(snapshot, was: previous)
            previous = snapshot
        }
        apply(settings.snapshot)
        _ = settings.changes.subscribe(apply)
    }

    private func forgetWhatIsTurnedOff(_ now: SettingsSnapshot, was before: SettingsSnapshot?) {
        if !now.bool(.restoreSessionOnLaunch), before?.bool(.restoreSessionOnLaunch) != false { session.remove() }
        if !now.bool(.rememberRecentItems), before?.bool(.rememberRecentItems) != false { recents.clear(); openWith.clear() }
    }

    /// Keeps the windows to reopen next time, but only while "Reopen windows and tabs" is on.
    public func saveSession(_ windows: [SessionWindow]) {
        guard settings.snapshot.bool(.restoreSessionOnLaunch) else { session.remove(); return }
        if !windows.isEmpty { session.replace(windows: windows) }
    }

    /// Forgets where trashed items came from once they've left the Trash, for example when Finder emptied it.
    /// A record stays while its Trash can't be reached, as on a disk that isn't plugged in.
    public func forgetItemsGoneFromTrash() async {
        var gone: [TrashOriginRecord] = []
        var reachable: [URL: Bool] = [:]
        for record in trashOrigins.records {
            let item = URL(fileURLWithPath: record.trashedPath)
            guard await isMissing(item) else { continue }
            let trash = item.deletingLastPathComponent()
            if reachable[trash] == nil { reachable[trash] = await isReachable(trash) }
            if reachable[trash] == true { gone.append(record) }
        }
        // A record made for the same place while this looked is about a new item, so it stays.
        let current = trashOrigins.records
        let unchanged = gone.filter { current.contains($0) }
        if !unchanged.isEmpty { trashOrigins.removeOrigins(for: unchanged.map { URL(fileURLWithPath: $0.trashedPath) }) }
    }

    /// However a star or a bookmark goes, sidebar.json forgets its row: where you'd moved it and whether you'd hidden
    /// it. Starring or bookmarking it again then shows a new row in its natural place. A drive keeps its row while it's
    /// unplugged, so it comes back to its place. Set up as the environment is made.
    func forgetSidebarRowsThatGo() {
        var rows = starAndBookmarkRows
        let follow: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let now = self.starAndBookmarkRows
            let gone = rows.subtracting(now)
            rows = now
            if !gone.isEmpty { self.sidebarLayout.update { $0.forget(gone) } }
        }
        _ = stars.changes.subscribe { _ in follow() }
        _ = bookmarks.changes.subscribe { _ in follow() }
    }

    /// Forgets the rows an earlier Helm kept after their star or bookmark went. `live` calls it only when no document
    /// failed to load, so a stars.json or bookmarks.json left untouched in `loadFailures` keeps its rows. A damaged one
    /// that the store set aside as .corrupt-… and started over counts as read and empty, so its rows go.
    func forgetSidebarRowsAlreadyGone() {
        let gone = sidebarLayout.layout.starAndBookmarkIDs.subtracting(starAndBookmarkRows)
        if !gone.isEmpty { sidebarLayout.update { $0.forget(gone) } }
    }

    /// The starred items' and bookmarks' rows, with the IDs the sidebar gives them (WindowDependencies.placesModel).
    /// A row's ID comes from its path alone, so a star's URL is made without asking the disk whether it's a folder,
    /// which a server that has stopped answering could hold up. PlacesModel still standardizes each path, which can.
    private var starAndBookmarkRows: Set<String> {
        let places = PlacesModel(home: directories.home,
                                 bookmarks: bookmarks.records.map { URL(fileURLWithPath: $0.path, isDirectory: true) },
                                 starred: stars.records.map { URL(fileURLWithPath: $0.path, isDirectory: false) })
        return Set((places.bookmarks + places.starred).map(\.id))
    }

    /// Only a definite "not there" counts. A refusal, such as the Trash without Full Disk Access, keeps the record.
    private func isMissing(_ url: URL) async -> Bool {
        do { _ = try await fileSystem.entry(at: url); return false }
        catch { return FileSystemError.mapping(error) == .notFound }
    }
    private func isReachable(_ url: URL) async -> Bool { (try? await fileSystem.entry(at: url)) != nil }
}
