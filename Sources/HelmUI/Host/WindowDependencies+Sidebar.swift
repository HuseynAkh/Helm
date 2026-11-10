#if os(macOS)
import Foundation
import HelmCore
import HelmOperations
import HelmPersistence

/// Sidebar changes go through here from the sidebar itself and from Settings › Sidebar, so both behave alike.
extension WindowDependencies {
    /// Every row the sidebar could show, with your order and hidden rows applied.
    public func placesModel() -> PlacesModel {
        PlacesModel(home: home,
                    bookmarks: bookmarks.records.map { URL(fileURLWithPath: $0.path, isDirectory: true) },
                    starred: stars.records.map { URL(fileURLWithPath: $0.path) },
                    volumes: volumes.volumes,
                    showAllVolumes: settings.snapshot.bool(.showAllMountedVolumes),
                    layout: sidebarLayout.layout)
    }

    /// A row let go of in the sidebar with the line just above `anchor`, a row on show, or at the end of its group
    /// when `anchor` is nil. Hidden rows keep their places, and a row let go of where it was stays put.
    public func dropSidebarRow(_ place: Place, before anchor: Place?) {
        moveSidebarRow(place, before: anchor, among: placesModel().shown(place.group))
    }

    /// A row moved in Settings › Sidebar, which lists hidden rows too: to just before `anchor`, or to the group's end.
    public func moveSidebarRow(_ place: Place, before anchor: Place?) {
        moveSidebarRow(place, before: anchor, among: placesModel().arranged(place.group))
    }

    /// Moves a row within its group to the line just above `anchor` among `listed`, the rows the move was made among.
    /// Rows that weren't listed there, such as hidden rows and drives that aren't connected, are passed over as few as
    /// possible. Bookmarks keep their order in their own store; everything else in the sidebar layout.
    private func moveSidebarRow(_ place: Place, before anchor: Place?, among listed: [Place]) {
        guard anchor.map({ $0.group == place.group }) ?? true else { return }
        let places = placesModel()
        let ids = places.fullOrder(place.group)
        guard let move = SidebarMove.dropped(place.id, before: anchor?.id, in: ids, listed: Set(listed.map(\.id))) else { return }
        if place.kind == .bookmark {
            guard let path = place.url?.path else { return }
            let anchorPath = move.anchor.flatMap { id in places.bookmarks.first { $0.id == id } }?.url?.path
            bookmarks.move(path: path, before: anchorPath)
        } else {
            let natural = places.natural(place.group).map(\.id)
            sidebarLayout.update { $0.move(place.id, before: move.anchor, in: place.group, natural: natural) }
        }
    }

    public func setSidebarRow(_ place: Place, shown: Bool) {
        sidebarLayout.update { $0.setHidden(place.id, !shown) }
    }

    /// A folder added to the sidebar again comes back into view if its bookmark was hidden.
    func showBookmark(at url: URL) {
        show(placesModel().bookmarks, matching: url)
    }
    /// An item starred again comes back into view if it was hidden.
    func showStarred(_ url: URL) {
        show(placesModel().starred, matching: url)
    }
    /// The IDs come from the rows themselves, so they match however the path was spelled.
    private func show(_ places: [Place], matching url: URL) {
        let path = url.standardizedFileURL.path
        for place in places where place.url?.standardizedFileURL.path == path {
            sidebarLayout.update { $0.setHidden(place.id, false) }
        }
    }

    /// Bookmarks and stars follow what a rename or a move took somewhere else, as Finder's sidebar does, and so do
    /// their hidden rows and places in the sidebar. Undo and Redo move them back and forth too. What went to the
    /// Trash keeps its rows where they were, so Put Back brings them back to life.
    func followMovedItems(_ outcome: Result<OperationResult, OperationCoordinator.Failure>) {
        guard case .success(let result) = outcome else { return }
        // Read once for all three: a batch can move thousands of items.
        let moves = PathMoves(result.outcomes.compactMap { outcome -> PathMove? in
            guard outcome.succeeded, let source = outcome.step.source else { return nil }
            switch outcome.step.kind {
            case .move: return (outcome.destination ?? outcome.step.destination).map { PathMove(from: source, to: $0) }
            // A move to another disk copies, then retires the original once the copy is checked.
            case .trash: return outcome.step.verificationDestination.map { PathMove(from: source, to: $0) }
            case .copy, .createDirectory, .createFile, .verifyCopy, .createAlias, .createSymbolicLink: return nil
            }
        })
        guard !moves.isEmpty else { return }
        // The rows first: a star or bookmark that goes takes its row with it, and these have only moved.
        sidebarLayout.update { $0 = $0.relocated(moves) }
        bookmarks.relocate(moves)
        stars.relocate(moves)
    }
}
#endif
