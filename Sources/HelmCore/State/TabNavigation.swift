// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

extension TabState {
    /// A monitor read cannot be admitted now; the request is recorded and replayed when this clears.
    var monitorIsBusy: Bool { isLoading || monitorValidationPending || monitorDegraded || monitorRetrying }
}

extension TabReducer {
    static func stage(_ target: Location, intent: NavigationIntent, restoring: Set<ItemID> = [], expanding: Set<ItemID> = [],
                      steps: Int = 1, state: inout TabState, effects: inout [TabEffect]) {
        // F-005/B-019: typed and enumerated directories share one URL spelling.
        // The loader echoes this target, preserving strict acceptLoad matching.
        let target: Location = target.canonicalNavigationLocation
        let base: PresentationSnapshot = state.underlyingSnapshot ?? state.deferredSnapshot ?? state.snapshot
        let failed: Bool
        if case .failed = base.phase { failed = true } else { failed = false }
        if state.pendingNavigation == nil, intent == .push, !failed,
           case .directory(let targetURL) = target,
           case .directory(let currentURL) = state.location,
           targetURL.standardizedFileURL.path == currentURL.standardizedFileURL.path {
            endSearch(&state, effects: &effects)
            return
        }
        endSearch(&state, effects: &effects)
        effects.append(.cancel(.load, state.loadGeneration))
        state.loadGeneration = state.loadGeneration.next(); state.isLoading = true
        state.pendingNavigation = PendingNavigation(target: target, intent: intent, restoredSelection: restoring,
                                                     restoredExpansion: expanding, generation: state.loadGeneration, steps: steps)
        effects.append(.load(target, state.loadGeneration, options(state, useCache: true)))
    }
    static func options(_ state: TabState, useCache: Bool) -> LoadOptions {
        LoadOptions(showHidden: state.showHidden, sort: state.sort, useCache: useCache)
    }
    static func startLoad(_ state: inout TabState, useCache: Bool, effects: inout [TabEffect]) {
        // Retire queued monitor snapshots captured before this foreground/options epoch.
        effects.append(.cancel(.monitor, state.monitorGeneration))
        state.monitorGeneration = state.monitorGeneration.next()
        if state.isActive { effects.append(.startMonitor(state.location, state.monitorGeneration)) }
        effects.append(.cancel(.load, state.loadGeneration))
        state.loadGeneration = state.loadGeneration.next(); state.isLoading = true
        // Same-location restarts must retain history IDs absent from an early batch.
        // Explicit selection and navigation commits replace this intent separately.
        state.restorationIDs = state.restorationIDs ?? (state.search == nil ? state.selection : state.underlyingSelection)
        state.awaitedChildren = []
        effects.append(.load(state.location, state.loadGeneration, options(state, useCache: useCache)))
    }
    static func restart(_ state: inout TabState, effects: inout [TabEffect]) {
        if let pending = state.pendingNavigation {
            stage(pending.target, intent: pending.intent, restoring: pending.restoredSelection, expanding: pending.restoredExpansion,
                  steps: pending.steps, state: &state, effects: &effects)
        } else { startLoad(&state, useCache: false, effects: &effects) }
        if var query = state.search?.query {
            query.showHidden = state.showHidden
            startSearch(query, state: &state, effects: &effects)
        }
    }
    static func acceptLoad(_ generation: Generation, snapshot: PresentationSnapshot, finished: Bool,
                           state: inout TabState, effects: inout [TabEffect]) {
        guard generation == state.loadGeneration, state.isLoading,
              snapshot.location == (state.pendingNavigation?.target ?? state.location) else { return }
        // A producer must report errors through loadFailed, never commit a failed snapshot.
        if case .failed(let error, _) = snapshot.phase {
            failLoad(error, state: &state, effects: &effects)
            return
        }
        // A reload of the tab's own folder, rather than a trip somewhere: under a card about another place it only
        // refreshes the listing behind the card.
        let reloading = state.pendingNavigation == nil
        if let pending = state.pendingNavigation {
            let current = NavigationHistory.Entry(location: state.location, selection: state.selection, expanded: state.expandedIDs)
            switch pending.intent {
            case .back:
                var departing = current
                for _ in 0..<pending.steps {
                    if let entry = state.history.goBack(current: departing) { departing = entry }
                }
            case .forward:
                var departing = current
                for _ in 0..<pending.steps {
                    if let entry = state.history.goForward(current: departing) { departing = entry }
                }
            case .push, .up, .home: state.history.push(current: current, movingTo: pending.target)
            case .restore, .open: break
            }
            if pending.target != state.location {
                state.monitorDirty = false; state.monitorNeedsValidation = false
            }
            state.location = pending.target; state.pendingNavigation = nil
            state.restorationIDs = pending.restoredSelection; state.selection = pending.restoredSelection
            // Back and Forward reopen the folders that were open; their rows are read once the listing is in.
            state.selectionSource = .history; state.expandedIDs = pending.restoredExpansion; state.childListings = [:]; state.anchorID = nil
            state.folderProblem = nil; state.openingIDs = []
            state.inlineRenameID = nil; state.deferredSnapshot = nil
            if let url = pending.target.mutationTarget {
                state.lastDirectory = url; state.addressBar.currentDirectory = url
                if pending.intent != .restore { effects.append(.recordRecent(url)) }
            } else { state.addressBar.currentDirectory = state.addressBar.home }
            // Completion requests are scoped to the old directory even if their prefix is unchanged.
            let (editor, _) = AddressEditor.reduce(state.addressBar, .cancel)
            effects.append(.cancel(.completion, state.completionGeneration)); state.addressBar = editor
            effects.append(.cancel(.monitor, state.monitorGeneration))
            state.monitorGeneration = state.monitorGeneration.next()
            if state.isActive { effects.append(.startMonitor(state.location, state.monitorGeneration)) }
        }
        if reloading { publishOwnListing(snapshot, state: &state) } else { publish(snapshot, state: &state) }
        if finished {
            state.isLoading = false
            replayMonitor(&state, effects: &effects)
            // What to select after a rename, a duplicate or an undo inside an open folder arrives with that folder's
            // listing, read after this one: the selection to restore waits for those listings (`settleRestoration`).
            state.awaitedChildren = reloadExpandedChildren(state, effects: &effects)
            if state.awaitedChildren.isEmpty { state.restorationIDs = nil }
        }
    }
    /// A root listing can't see inside expanded folders, so each refresh also re-reads them (FB2-10).
    /// Returns the folders it asked for.
    @discardableResult
    static func reloadExpandedChildren(_ state: TabState, effects: inout [TabEffect]) -> Set<ItemID> {
        var asked: Set<ItemID> = []
        for id in state.expandedIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let entry = state.snapshot.entry(id) else { continue }
            effects.append(.loadChildren(entry.url, id, state.loadGeneration, options(state, useCache: false)))
            asked.insert(id)
        }
        return asked
    }
    /// An open folder's listing from the last load arrived, failed or closed: once none is left to wait for, the
    /// selection to restore has been applied and is let go.
    static func settleRestoration(_ id: ItemID, state: inout TabState) {
        guard state.awaitedChildren.remove(id) != nil, state.awaitedChildren.isEmpty, !state.isLoading else { return }
        state.restorationIDs = nil
    }
    /// Only open folders' listings go into a snapshot, so a publication never sorts listings nobody can see.
    /// Closed folders keep theirs in `childListings`, and `.expand` puts one back at once, so a folder opened
    /// again shows its rows straight away while a fresh read runs.
    static func attachingChildren(to snapshot: PresentationSnapshot, state: TabState) -> PresentationSnapshot {
        let roots = Array(snapshot.sortedEntries.prefix(snapshot.rootCount))
        return SnapshotBuilder.build(location: snapshot.location, entries: roots, sort: snapshot.sort, phase: snapshot.phase,
                                     rankByID: snapshot.rankByID,
                                     children: state.childListings.filter { state.expandedIDs.contains($0.key) })
    }
    /// How many entries closed folders may keep between them. Past it, the folder just closed keeps its listing and
    /// the other closed ones let theirs go, so opening one big folder after another can't hold on to every listing;
    /// a folder that lost its listing is read afresh when it opens, as on its first opening.
    static let closedListingBudget = 10_000
    static func trimClosedListings(_ state: inout TabState, keeping id: ItemID) {
        let closed = state.childListings.filter { !state.expandedIDs.contains($0.key) }
        guard closed.values.reduce(0, { $0 + $1.count }) > closedListingBudget else { return }
        for key in closed.keys where key != id { state.childListings[key] = nil }
    }
    /// Listings read before Show Hidden changed list the wrong files. Closed folders forget theirs, so opening one
    /// again waits for a fresh read rather than flashing files that shouldn't show; open folders are read again anyway.
    static func forgetClosedListings(_ state: inout TabState) {
        let closed = state.childListings.keys.filter { !state.expandedIDs.contains($0) }
        guard !closed.isEmpty else { return }
        for id in closed { state.childListings[id] = nil }
        // A folder closed since the last publication still has its rows in the snapshot; they go too.
        if state.search == nil, state.inlineRenameID == nil, closed.contains(where: { state.snapshot.children[$0] != nil }) {
            present(attachingChildren(to: state.snapshot, state: state), state: &state)
        }
    }
    static func replayMonitor(_ state: inout TabState, effects: inout [TabEffect]) {
        guard state.monitorDirty || state.monitorNeedsValidation,
              state.isActive, !state.monitorIsBusy, state.pendingNavigation == nil else { return }
        state.monitorDirty = false
        if state.monitorNeedsValidation {
            state.monitorNeedsValidation = false
            effects.append(.validateNavigation(state.location, state.monitorGeneration))
        } else { effects.append(.refreshPaths([], state.monitorGeneration)) }
    }
    static func visibleSelection(_ ids: Set<ItemID>, snapshot: PresentationSnapshot, expanded: Set<ItemID>) -> Set<ItemID> {
        if snapshot.children.isEmpty {
            return Set(ids.filter { id in snapshot.index(of: id).map { $0 < snapshot.rootCount } ?? false })
        }
        return ids.intersection(Set(snapshot.visibleIDs(expanding: expanded)))
    }
    static func syncEditorHidden(_ state: inout TabState, effects: inout [TabEffect]) {
        guard state.addressBar.showHidden != state.showHidden else { return }
        let old: Generation = state.completionGeneration
        let (editor, emitted) = AddressEditor.reduce(state.addressBar, .showHiddenChanged(state.showHidden))
        state.addressBar = editor
        for effect in emitted {
            if effect == .cancelCompletions { effects.append(.cancel(.completion, old)) }
            else { effects.append(.addressEditor(effect)) }
        }
    }
    /// The failure on show when it's about a place other than the tab's own: a folder that couldn't open from here,
    /// whose card stands in for this folder's listing.
    static func failureElsewhere(_ state: TabState) -> (error: LoadError, attempted: Location)? {
        let base: PresentationSnapshot = state.underlyingSnapshot ?? state.deferredSnapshot ?? state.snapshot
        guard case .failed(let error, let attempted) = base.phase, error != .cancelled,
              attempted.canonicalNavigationLocation != state.location.canonicalNavigationLocation else { return nil }
        return (error, attempted)
    }
    /// A listing of the tab's own folder, from its monitor or a reload. While a card about another place is up, it
    /// refreshes the listing behind the card, so going back shows it current, and leaves the card alone: a change in
    /// the folder, Show Hidden Files, an operation finishing or switching tabs away and back mustn't take the card
    /// down. Only Back from the card does (`returnToListing`). A problem with the folder waits until you go back.
    static func publishOwnListing(_ incoming: PresentationSnapshot, state: inout TabState) {
        guard let card = failureElsewhere(state) else { publish(incoming, state: &state); return }
        if case .failed = incoming.phase { return }
        publish(incoming.stamped(incoming.id, phase: .failed(card.error, attempted: card.attempted)), state: &state)
    }
    /// A load that failed: its card stands in for the listing. A reload of the folder under a card about another
    /// place leaves that card up instead, and the folder's own problem waits until you go back to it.
    static func failLoad(_ error: LoadError, state: inout TabState, effects: inout [TabEffect]) {
        let attempted: Location = state.pendingNavigation?.target ?? state.location
        let underCard = state.pendingNavigation == nil && failureElsewhere(state) != nil
        state.pendingNavigation = nil; state.isLoading = false; state.restorationIDs = nil; state.awaitedChildren = []
        if !underCard {
            let base: PresentationSnapshot = state.underlyingSnapshot ?? state.deferredSnapshot ?? state.snapshot
            publish(base.stamped(base.id, phase: .failed(error, attempted: attempted)), state: &state)
        }
        replayMonitor(&state, effects: &effects)
    }
    static func publish(_ incoming: PresentationSnapshot, state: inout TabState) {
        // A sort may change while a producer is suspended. Never publish its obsolete order.
        let snapshot: PresentationSnapshot = incoming.sort == state.sort
            ? incoming : SnapshotBuilder.resort(incoming, sort: state.sort)
        if state.search != nil {
            state.underlyingSnapshot = snapshot
            state.underlyingSelection = SnapshotDiff.selection(state.restorationIDs ?? state.underlyingSelection, in: snapshot)
        } else if state.inlineRenameID != nil { state.deferredSnapshot = snapshot }
        else { present(snapshot, state: &state) }
    }
    static func present(_ incoming: PresentationSnapshot, state: inout TabState) {
        // Only an open folder's listing needs attaching; closed folders' cached ones never cost a publication anything.
        let snapshot = state.search == nil && incoming.children.isEmpty
            && state.childListings.keys.contains(where: state.expandedIDs.contains)
            ? attachingChildren(to: incoming, state: state) : incoming
        state.snapshotCounter = state.snapshotCounter &+ 1
        state.snapshot = snapshot.stamped(Generation(rawValue: state.snapshotCounter), source: state.selectionSource)
        state.selection = visibleSelection(state.restorationIDs ?? state.selection, snapshot: snapshot, expanded: state.shownExpandedIDs)
        state.anchorID = SnapshotDiff.anchor(state.anchorID, in: snapshot)
    }
}
