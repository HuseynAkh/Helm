// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Pure transitions preserve navigation/selection while rejecting callbacks from retired work (B-009/B-069).
public enum TabReducer {
    public static func reduce(_ state: TabState, _ action: TabAction, context: ReducerContext) -> (TabState, [TabEffect]) {
        var next: TabState = state
        var effects: [TabEffect] = []
        switch action {
        case .navigate(let target, let intent):
            switch intent {
            case .back: return reduce(state, .goBack, context: context)
            case .forward: return reduce(state, .goForward, context: context)
            case .up: return reduce(state, .goUp, context: context)
            case .push, .home, .restore: stage(target, intent: intent, state: &next, effects: &effects)
            }
        case .goBack:
            if let entry = next.history.back.last {
                stage(entry.location, intent: .back, restoring: entry.selection, state: &next, effects: &effects)
            }
        case .goForward:
            if let entry = next.history.forward.last {
                stage(entry.location, intent: .forward, restoring: entry.selection, state: &next, effects: &effects)
            }
        case .goUp:
            if let url = next.location.mutationTarget {
                let normalized: URL = url.standardizedFileURL
                let parent: URL = normalized.deletingLastPathComponent()
                if parent.path != normalized.path { stage(.directory(parent), intent: .up, state: &next, effects: &effects) }
            }
        case .refresh:
            guard next.pendingNavigation == nil else { return (state, []) }
            startLoad(&next, useCache: false, effects: &effects)
        case .loadProgress(let generation, let snapshot):
            acceptLoad(generation, snapshot: snapshot, finished: false, state: &next, effects: &effects)
        case .loadFinished(let generation, let snapshot):
            acceptLoad(generation, snapshot: snapshot, finished: true, state: &next, effects: &effects)
        case .loadFailed(let generation, let error):
            guard generation == next.loadGeneration, next.isLoading else { return (state, []) }
            let attempted: Location = next.pendingNavigation?.target ?? next.location
            next.pendingNavigation = nil; next.isLoading = false; next.restorationIDs = nil
            let base: PresentationSnapshot = next.underlyingSnapshot ?? next.snapshot
            publish(base.stamped(base.id, phase: .failed(error, attempted: attempted)), state: &next)
        case .monitorSnapshot(let generation, let snapshot):
            guard next.isActive, generation == next.monitorGeneration, next.pendingNavigation == nil,
                  !next.isLoading, snapshot.location == next.location else { return (state, []) }
            publish(snapshot, state: &next)
        case .monitorEvent(let generation, let event):
            guard next.isActive, generation == next.monitorGeneration, next.pendingNavigation == nil else { return (state, []) }
            switch event {
            case .changed(let paths): effects.append(.refreshPaths(paths, generation))
            case .rescan: effects.append(.refreshPaths([], generation))
            case .rootChanged, .volumeUnmounted: effects.append(.validateNavigation(next.location, generation))
            case .unavailable(let failure):
                let base: PresentationSnapshot = next.underlyingSnapshot ?? next.snapshot
                publish(base.stamped(base.id, phase: .failed(.other(String(describing: failure)), attempted: next.location)), state: &next)
            }
        case .setSelection(let ids, let source):
            next.selection = visibleSelection(ids, snapshot: next.snapshot, expanded: next.expandedIDs)
            next.selectionSource = source; next.restorationIDs = nil
            next.snapshot = next.snapshot.stamped(next.snapshot.id, source: source)
        case .setSort(let sort):
            next.sort = sort
            if next.search != nil {
                present(SnapshotBuilder.resort(next.snapshot, sort: sort), state: &next)
                if let base = next.underlyingSnapshot { next.underlyingSnapshot = SnapshotBuilder.resort(base, sort: sort) }
            } else { publish(SnapshotBuilder.resort(next.snapshot, sort: sort), state: &next) }
        case .setViewMode(let mode): next.viewMode = mode
        case .toggleHidden:
            next.showHidden.toggle()
            syncEditorHidden(&next, effects: &effects)
            effects.append(.persistShowHidden(next.showHidden))
            restart(&next, effects: &effects)
        case .settingsChanged(let settings):
            let changed: Bool = next.showHidden != settings.showHiddenFiles
            next.showHidden = settings.showHiddenFiles; syncEditorHidden(&next, effects: &effects)
            if changed { restart(&next, effects: &effects) }
        case .expand(let id):
            if next.snapshot.entry(id)?.isDirectoryLike == true { next.expandedIDs.insert(id) }
        case .collapse(let id):
            next.expandedIDs.remove(id)
            next.selection = visibleSelection(next.selection, snapshot: next.snapshot, expanded: next.expandedIDs)
        case .searchStarted(let query): startSearch(query, state: &next, effects: &effects)
        case .searchResults(let generation, let results):
            guard generation == next.searchGeneration, next.search != nil else { return (state, []) }
            next.search?.results = results; next.search?.isGathering = false
            var ranks: [ItemID: Int] = [:]
            for result in results { ranks[result.entry.id] = min(ranks[result.entry.id] ?? Int.max, result.rank) }
            let order: ItemSort = next.snapshot.rankByID == nil ? .relevance : next.snapshot.sort
            present(SnapshotBuilder.build(location: next.location, entries: results.map(\.entry), sort: order, rankByID: ranks), state: &next)
        case .searchEnded: endSearch(&next, effects: &effects)
        case .addressBar(let action):
            let (editor, editorEffects) = AddressEditor.reduce(next.addressBar, action)
            next.addressBar = editor
            for effect in editorEffects {
                switch effect {
                case .navigate(let url): stage(.directory(url), intent: .push, state: &next, effects: &effects)
                case .cancelCompletions: effects.append(.cancel(.completion, state.completionGeneration))
                case .requestCompletions, .validate, .openFile, .cancelled, .invalidPathFeedback:
                    effects.append(.addressEditor(effect))
                }
            }
        case .activated:
            if !next.isActive {
                next.isActive = true; next.monitorGeneration = next.monitorGeneration.next()
                effects.append(.startMonitor(next.location, next.monitorGeneration))
            }
        case .deactivated:
            if next.isActive {
                effects.append(.cancel(.monitor, next.monitorGeneration))
                next.monitorGeneration = next.monitorGeneration.next(); next.isActive = false
            }
        case .setScrollAnchor(let id): next.anchorID = SnapshotDiff.anchor(id, in: next.snapshot)
        case .beginInlineRename(let id):
            if next.selection.contains(id) { next.inlineRenameID = id }
        case .endInlineRename:
            next.inlineRenameID = nil
            if let snapshot = next.deferredSnapshot {
                next.deferredSnapshot = nil; publish(snapshot, state: &next)
            }
        case .cutSetChanged(let ids): next.cutIDs = ids
        }
        return (next, effects)
    }
}
