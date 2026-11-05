// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

extension TabReducer {
    static func stage(_ target: Location, intent: NavigationIntent, restoring: Set<ItemID> = [],
                      state: inout TabState, effects: inout [TabEffect]) {
        if state.pendingNavigation == nil, intent == .push,
           case .directory(let targetURL) = target,
           case .directory(let currentURL) = state.location,
           targetURL.standardizedFileURL.path == currentURL.standardizedFileURL.path { return }
        endSearch(&state, effects: &effects)
        effects.append(.cancel(.load, state.loadGeneration))
        state.loadGeneration = state.loadGeneration.next(); state.isLoading = true
        state.pendingNavigation = PendingNavigation(target: target, intent: intent,
                                                     restoredSelection: restoring, generation: state.loadGeneration)
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
        effects.append(.load(state.location, state.loadGeneration, options(state, useCache: useCache)))
    }
    static func restart(_ state: inout TabState, effects: inout [TabEffect]) {
        if let pending = state.pendingNavigation {
            stage(pending.target, intent: pending.intent, restoring: pending.restoredSelection, state: &state, effects: &effects)
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
            let attempted: Location = state.pendingNavigation?.target ?? state.location
            state.pendingNavigation = nil; state.isLoading = false; state.restorationIDs = nil
            let base: PresentationSnapshot = state.underlyingSnapshot ?? state.deferredSnapshot ?? state.snapshot
            publish(base.stamped(base.id, phase: .failed(error, attempted: attempted)), state: &state)
            replayMonitor(&state, effects: &effects)
            return
        }
        if let pending = state.pendingNavigation {
            let current = NavigationHistory.Entry(location: state.location, selection: state.selection)
            switch pending.intent {
            case .back: _ = state.history.goBack(current: current)
            case .forward: _ = state.history.goForward(current: current)
            case .push, .up, .home: state.history.push(current: current, movingTo: pending.target)
            case .restore: break
            }
            if pending.target != state.location {
                state.monitorDirty = false; state.monitorNeedsValidation = false
            }
            state.location = pending.target; state.pendingNavigation = nil
            state.restorationIDs = pending.restoredSelection; state.selection = pending.restoredSelection
            state.selectionSource = .history; state.expandedIDs = []; state.anchorID = nil
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
        publish(snapshot, state: &state)
        if finished {
            state.isLoading = false; state.restorationIDs = nil
            replayMonitor(&state, effects: &effects)
        }
    }
    static func replayMonitor(_ state: inout TabState, effects: inout [TabEffect]) {
        guard state.monitorDirty || state.monitorNeedsValidation,
              state.isActive, !state.isLoading, !state.monitorValidationPending, !state.monitorDegraded,
              state.pendingNavigation == nil else { return }
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
    static func present(_ snapshot: PresentationSnapshot, state: inout TabState) {
        state.snapshotCounter = state.snapshotCounter &+ 1
        state.snapshot = snapshot.stamped(Generation(rawValue: state.snapshotCounter), source: state.selectionSource)
        state.selection = visibleSelection(state.restorationIDs ?? state.selection, snapshot: snapshot, expanded: state.expandedIDs)
        state.anchorID = SnapshotDiff.anchor(state.anchorID, in: snapshot)
    }
}
