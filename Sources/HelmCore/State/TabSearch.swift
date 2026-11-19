import Foundation

extension TabReducer {
    static func startSearch(_ query: SearchQuery, state: inout TabState, effects: inout [TabEffect]) {
        // A kind chosen in the kind row is a search of its own: with no words, every file of that kind.
        if query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && query.filters.isEmpty && query.kind == nil {
            endSearch(&state, effects: &effects); return
        }
        // New words keep the order chosen for the results; a new search starts with Best Match.
        let order: ItemSort = state.search == nil ? .relevance : state.snapshot.sort
        if state.search == nil {
            state.underlyingSnapshot = state.snapshot; state.underlyingSelection = state.selection
        }
        if state.pendingNavigation != nil {
            effects.append(.cancel(.load, state.loadGeneration))
            state.loadGeneration = state.loadGeneration.next(); state.isLoading = false; state.pendingNavigation = nil
        }
        effects.append(.cancel(.search, state.searchGeneration))
        state.searchGeneration = state.searchGeneration.next()
        state.search = SearchState(query: query, generation: state.searchGeneration)
        state.selection = []; state.restorationIDs = nil; state.awaitedChildren = []
        state.inlineRenameID = nil; state.deferredSnapshot = nil
        if query.inViewOnly {
            // Answered at once from the listing on show: nothing to gather, so no effect.
            filterView(&state)
            return
        }
        present(PresentationSnapshot(location: state.location, phase: .loading(loadedCount: 0), sort: order,
                                     rankByID: [:]), state: &state)
        effects.append(.startSearch(query, state.searchGeneration))
    }
    /// The kind row on the view as it is (`SearchQuery.inViewOnly`): the items on show at the top of the listing
    /// under the search, of the chosen kind, in the listing's own order, so it reads as the folder sorted down to
    /// that kind. Run again whenever that listing changes, so the view stays live.
    static func filterView(_ state: inout TabState) {
        guard let search = state.search, search.query.inViewOnly else { return }
        let base = state.underlyingSnapshot ?? state.snapshot
        let kind = search.query.kind
        let kept = base.sortedEntries.prefix(base.rootCount).filter { entry in
            guard let kind else { return true }
            guard let found = AISearchKind.of(typeIdentifier: entry.contentTypeIdentifier, extension: entry.url.pathExtension,
                                              kind: entry.kind) else { return false }
            return kind.covers(found)
        }
        let results = kept.enumerated().map { SearchResult(entry: $1, rank: $0) }
        state.search?.results = results; state.search?.isGathering = false
        var ranks: [ItemID: Int] = [:]
        for result in results { ranks[result.entry.id] = result.rank }
        // The order chosen for the results while they're on show, otherwise the folder's own.
        let shown = state.snapshot
        let order = shown.rankByID != nil && shown.sort.field != .relevance ? shown.sort : base.sort
        present(SnapshotBuilder.build(location: state.location, entries: Array(kept), sort: order, rankByID: ranks), state: &state)
    }
    static func endSearch(_ state: inout TabState, effects: inout [TabEffect]) {
        guard state.search != nil else { return }
        effects.append(.cancel(.search, state.searchGeneration))
        state.searchGeneration = state.searchGeneration.next(); state.search = nil
        state.selection = state.underlyingSelection
        if let base = state.underlyingSnapshot { present(base, state: &state) }
        state.underlyingSnapshot = nil; state.underlyingSelection = []
    }
}
