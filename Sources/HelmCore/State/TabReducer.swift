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
            case .push, .home, .restore, .open: stage(target, intent: intent, state: &next, effects: &effects)
            }
        case .goBack:
            // History moves only on commit, so a repeat before the first batch reaches one entry further (F-005).
            let steps = next.pendingNavigation?.intent == .back ? (next.pendingNavigation?.steps ?? 0) + 1 : 1
            if next.history.back.count >= steps {
                let entry = next.history.back[next.history.back.count - steps]
                stage(entry.location, intent: .back, restoring: entry.selection, expanding: entry.expanded, steps: steps,
                      state: &next, effects: &effects)
            }
        case .goForward:
            let steps = next.pendingNavigation?.intent == .forward ? (next.pendingNavigation?.steps ?? 0) + 1 : 1
            if next.history.forward.count >= steps {
                let entry = next.history.forward[next.history.forward.count - steps]
                stage(entry.location, intent: .forward, restoring: entry.selection, expanding: entry.expanded, steps: steps,
                      state: &next, effects: &effects)
            }
        case .goUp:
            if let url = next.location.mutationTarget {
                let normalized: URL = url.standardizedFileURL
                let parent: URL = normalized.deletingLastPathComponent()
                // The folder you came from is selected, as in Finder and Nautilus, so Cmd-Down goes straight back in.
                if normalized.path != "/", parent.standardizedFileURL.path != normalized.path {
                    stage(.directory(parent), intent: .up, restoring: [ItemID(url: normalized)], state: &next, effects: &effects)
                }
            }
        case .refresh:
            guard next.pendingNavigation == nil else { return (state, []) }
            restart(&next, effects: &effects)
        case .returnToListing:
            // The folder the card covered shows again as it was, kept current behind the card; a refresh after it
            // brings it fully up to date.
            guard next.pendingNavigation == nil, failureElsewhere(next) != nil else { return (state, []) }
            let base: PresentationSnapshot = next.underlyingSnapshot ?? next.deferredSnapshot ?? next.snapshot
            publish(base.stamped(base.id, phase: .ready), state: &next)
        case .loadProgress(let generation, let snapshot):
            acceptLoad(generation, snapshot: snapshot, finished: false, state: &next, effects: &effects)
        case .loadFinished(let generation, let snapshot):
            acceptLoad(generation, snapshot: snapshot, finished: true, state: &next, effects: &effects)
        case .loadFailed(let generation, let error):
            guard generation == next.loadGeneration, next.isLoading else { return (state, []) }
            failLoad(error, state: &next, effects: &effects)
        case .monitorWorkCompleted(let generation, let request, let result):
            guard next.isActive, generation == next.monitorGeneration,
                  request == next.monitorWorkGeneration, !next.monitorDegraded else { return (state, []) }
            let validated = next.monitorValidationPending
            next.monitorValidationPending = false
            // Completion is single-use, including duplicate or already queued callbacks.
            next.monitorWorkGeneration = next.monitorWorkGeneration.next()
            let reply: TabAction
            switch result {
            case .success(let snapshot): reply = .monitorSnapshot(generation, snapshot)
            case .failure(let error): reply = .monitorValidationFailed(generation, error)
            }
            (next, effects) = reduce(next, reply, context: context)
            if validated {
                if case .failure = result {
                    next.monitorNeedsValidation = true
                    // Retry only an invalidation received during this read, never the error alone.
                    if next.monitorDirty { replayMonitor(&next, effects: &effects) }
                }
                if next.pendingNavigation != nil || next.isLoading { next.monitorNeedsValidation = true }
            }
            if validated, case .success = result, next.pendingNavigation == nil, !next.isLoading {
                // A vnode watch may still refer to the replaced object. Rebind after validation.
                effects.append(.cancel(.monitor, next.monitorGeneration))
                next.monitorGeneration = next.monitorGeneration.next()
                effects.append(.startMonitor(next.location, next.monitorGeneration))
                replayMonitor(&next, effects: &effects)
            }
        case .monitorStopped(let generation, let error, let retrying):
            guard next.isActive, generation == next.monitorGeneration else { return (state, []) }
            next.monitorValidationPending = false
            next.monitorWorkGeneration = next.monitorWorkGeneration.next()
            if retrying {
                // The retry's monitorWatching reconciles; publishing failure here only flashes it (FB2-7).
                next.monitorRetrying = true; next.monitorDirty = true
                return (next, [])
            }
            next.monitorRetrying = false; next.monitorDegraded = true
            let base = next.underlyingSnapshot ?? next.deferredSnapshot ?? next.snapshot
            if failureElsewhere(next) == nil { publish(base.stamped(base.id, phase: .failed(error, attempted: next.location)), state: &next) }
        case .monitorWatching(let generation):
            guard next.isActive, generation == next.monitorGeneration else { return (state, []) }
            next.monitorDegraded = false; next.monitorRetrying = false
            // Reconcile after startup, closing the read-to-new-watch observation gap.
            next.monitorDirty = true
            replayMonitor(&next, effects: &effects)
        case .monitorValidationFailed(let generation, let error):
            guard next.isActive, generation == next.monitorGeneration, next.pendingNavigation == nil else { return (state, []) }
            // The foreground load's own result decides what is shown; revalidate after it (FB2-8).
            if next.isLoading { next.monitorNeedsValidation = true; return (next, []) }
            let base = next.underlyingSnapshot ?? next.deferredSnapshot ?? next.snapshot
            if failureElsewhere(next) == nil { publish(base.stamped(base.id, phase: .failed(error, attempted: next.location)), state: &next) }
        case .monitorSnapshot(let generation, let snapshot):
            guard next.isActive, generation == next.monitorGeneration,
                  snapshot.location == next.location else { return (state, []) }
            if next.isLoading || next.pendingNavigation != nil { next.monitorDirty = true; return (next, []) }
            publishOwnListing(snapshot, state: &next)
            reloadExpandedChildren(next, effects: &effects)
        case .monitorEvent(let generation, let event):
            guard next.isActive, generation == next.monitorGeneration else { return (state, []) }
            if next.pendingNavigation != nil {
                next.monitorDirty = true
                switch event {
                case .rootChanged, .volumeUnmounted, .unavailable: next.monitorNeedsValidation = true
                case .changed, .rescan: break
                }
                return (next, [])
            }
            switch event {
            case .changed(let paths):
                if next.monitorIsBusy { next.monitorDirty = true }
                else if next.monitorNeedsValidation { effects.append(.validateNavigation(next.location, generation)) }
                else { effects.append(.refreshPaths(paths, generation)) }
            case .rescan:
                if next.monitorIsBusy { next.monitorDirty = true }
                else if next.monitorNeedsValidation { effects.append(.validateNavigation(next.location, generation)) }
                else { effects.append(.refreshPaths([], generation)) }
            case .rootChanged, .volumeUnmounted:
                // The coalescer substitutes an unacknowledged root event whenever it publishes, so restarting here
                // would cancel a slow read forever. Record it; replay runs after the read ends (FB2-8).
                if next.monitorIsBusy { next.monitorDirty = true; next.monitorNeedsValidation = true }
                else { effects.append(.validateNavigation(next.location, generation)) }
            case .unavailable(let failure):
                if next.monitorIsBusy { next.monitorDirty = true; next.monitorNeedsValidation = true }
                else { effects.append(.validateNavigation(next.location, generation)) }
                if !next.isLoading, failureElsewhere(next) == nil {
                    let base: PresentationSnapshot = next.underlyingSnapshot ?? next.deferredSnapshot ?? next.snapshot
                    publish(base.stamped(base.id, phase: .failed(.other(String(describing: failure)), attempted: next.location)), state: &next)
                }
            }
        case .setSelection(let ids, let source):
            next.folderProblem = nil
            next.selection = visibleSelection(ids, snapshot: next.snapshot, expanded: next.shownExpandedIDs)
            next.selectionSource = source; next.restorationIDs = nil; next.awaitedChildren = []
            next.snapshot = next.snapshot.stamped(next.snapshot.id, source: source)
        case .setSort(let sort):
            if next.search != nil {
                // An order chosen during a search is the results' own. The folder keeps its sort for when it ends.
                present(SnapshotBuilder.resort(next.snapshot, sort: sort), state: &next)
            } else if sort.field != .relevance {
                // Best Match only orders search results, so a folder is never sorted by it.
                next.sort = sort
                publish(SnapshotBuilder.resort(next.deferredSnapshot ?? next.snapshot, sort: sort), state: &next)
            }
        case .setViewMode(let mode):
            next.viewMode = mode
            // The grid shows only the folder's own items, so what's selected inside the list's open folders can't
            // stay selected there, unseen, for Move to Trash or Copy to act on.
            next.selection = visibleSelection(next.selection, snapshot: next.snapshot, expanded: next.shownExpandedIDs)
        case .toggleHidden:
            next.showHidden.toggle()
            syncEditorHidden(&next, effects: &effects)
            effects.append(.persistShowHidden(next.showHidden))
            forgetClosedListings(&next)
            restart(&next, effects: &effects)
        case .showHiddenItems:
            guard !next.showHidden else { return (state, []) }
            next.showHidden = true
            syncEditorHidden(&next, effects: &effects)
            forgetClosedListings(&next)
            restart(&next, effects: &effects)
        case .settingsChanged(let settings):
            // Every change in Settings arrives here, a text or icon zoom included. Only Show Hidden Files itself
            // changing resets the tab's hidden items, so hidden items listed for a reveal, or a tab reopened with
            // them, stay through any other change.
            guard settings.showHiddenFiles != next.hiddenFilesSetting else { return (state, []) }
            next.hiddenFilesSetting = settings.showHiddenFiles
            let changed: Bool = next.showHidden != settings.showHiddenFiles
            next.showHidden = settings.showHiddenFiles; syncEditorHidden(&next, effects: &effects)
            if changed { forgetClosedListings(&next); restart(&next, effects: &effects) }
        case .expand(let id):
            next.folderProblem = nil
            if let entry = next.snapshot.entry(id), entry.isDirectoryLike {
                next.expandedIDs.insert(id); next.openingIDs.insert(id)
                effects.append(.loadChildren(entry.url, id, next.loadGeneration, options(next, useCache: false)))
                // A folder opened before shows the rows it had at once, while the fresh read runs.
                if next.search == nil, next.childListings[id] != nil, next.snapshot.children[id] == nil {
                    present(attachingChildren(to: next.snapshot, state: next), state: &next)
                }
            }
        case .collapse(let id):
            next.folderProblem = nil
            next.expandedIDs.remove(id); next.openingIDs.remove(id)
            next.selection = visibleSelection(next.selection, snapshot: next.snapshot, expanded: next.shownExpandedIDs)
            trimClosedListings(&next, keeping: id)
            settleRestoration(id, state: &next)
        case .childrenLoaded(let id, let generation, let entries):
            guard generation == next.loadGeneration, next.expandedIDs.contains(id), next.search == nil else { return (state, []) }
            next.childListings[id] = entries; next.openingIDs.remove(id)
            // Restores what the last load meant to select, such as a renamed file inside this folder.
            present(attachingChildren(to: next.snapshot, state: next), state: &next)
            // Folders left open inside this one, such as by Back, open too once their own rows are read. The selection
            // to restore waits for their rows as well, since an item selected inside one only arrives with them.
            for entry in entries where entry.isDirectoryLike && next.expandedIDs.contains(entry.id) && next.childListings[entry.id] == nil {
                effects.append(.loadChildren(entry.url, entry.id, next.loadGeneration, options(next, useCache: false)))
                if next.restorationIDs != nil { next.awaitedChildren.insert(entry.id) }
            }
            settleRestoration(id, state: &next)
        case .childrenFailed(let id, let generation, let error):
            guard generation == next.loadGeneration else { return (state, []) }
            // An open folder that couldn't be read says why, rather than snap shut without a word. One that's gone
            // when the list reads it again, after a rename or a move to the Trash inside an open folder, just closes:
            // its row goes too, and "no longer exists" would only describe what was just done to it.
            let opening = next.openingIDs.remove(id) != nil
            let reason = ContentStatePresentation.plain(error)
            if next.expandedIDs.contains(id), reason != .cancelled, opening || reason != .notFound {
                next.folderProblem = FolderProblem(url: next.snapshot.entry(id)?.url ?? id.url, error: error)
            }
            next.expandedIDs.remove(id)
            defer { settleRestoration(id, state: &next) }
            // A folder that can't be read closes, and its old listing goes, so opening it again never shows stale rows.
            let cached = next.childListings.removeValue(forKey: id) != nil
            if next.search == nil, cached || next.snapshot.children[id] != nil {
                present(attachingChildren(to: next.snapshot, state: next), state: &next)
            }
        case .refreshSelecting(let ids):
            guard next.pendingNavigation == nil else { return (state, []) }
            next.restorationIDs = ids
            restart(&next, effects: &effects)
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
                case .requestCompletions, .validate, .openFile, .connect, .cancelled, .invalidPathFeedback:
                    effects.append(.addressEditor(effect))
                }
            }
        case .activated:
            if !next.isActive {
                next.isActive = true; next.monitorGeneration = next.monitorGeneration.next()
                effects.append(.startMonitor(next.location, next.monitorGeneration))
                replayMonitor(&next, effects: &effects)
            }
        case .deactivated:
            if next.isActive {
                // A replacement watcher cannot replay changes made while this tab is inactive.
                next.monitorDirty = true
                effects.append(.cancel(.monitor, next.monitorGeneration))
                next.monitorGeneration = next.monitorGeneration.next(); next.isActive = false
            }
        case .restartMonitor:
            // Only the tab on show has a watch. A new one catches up once it reports it's watching; with updates
            // turned off none starts, and nothing is read again until a refresh.
            guard next.isActive else { return (state, []) }
            effects.append(.cancel(.monitor, next.monitorGeneration))
            next.monitorGeneration = next.monitorGeneration.next()
            effects.append(.startMonitor(next.location, next.monitorGeneration))
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
        for effect in effects {
            switch effect {
            case .cancel(.monitor, _):
                next.monitorValidationPending = false; next.monitorRetrying = false
                next.monitorWorkGeneration = next.monitorWorkGeneration.next()
            case .startMonitor:
                next.monitorDegraded = false; next.monitorRetrying = false
            case .validateNavigation:
                next.monitorNeedsValidation = false
                next.monitorWorkGeneration = next.monitorWorkGeneration.next()
                next.monitorValidationPending = true
            case .refreshPaths:
                next.monitorWorkGeneration = next.monitorWorkGeneration.next()
            default: break
            }
        }
        return (next, effects)
    }
}
