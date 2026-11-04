// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

extension TabReducer {
    static func startSearch(_ query: SearchQuery, state: inout TabState, effects: inout [TabEffect]) {
        if query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            endSearch(&state, effects: &effects); return
        }
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
        state.selection = []; state.restorationIDs = nil; state.inlineRenameID = nil; state.deferredSnapshot = nil
        present(PresentationSnapshot(location: state.location, phase: .loading(loadedCount: 0), sort: .relevance,
                                     rankByID: [:]), state: &state)
        effects.append(.startSearch(query, state.searchGeneration))
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
