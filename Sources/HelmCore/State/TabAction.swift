// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Independent cancellation identities prevent unrelated work from invalidating results (B-014/B-021/B-052).
public enum GenerationLane: Hashable, Sendable { case load, monitor, search, completion }
/// Pure tab inputs; navigation results carry both their lane generation and destination (F-005/F-008).
public enum TabAction: Sendable {
    case navigate(Location, NavigationIntent)
    case goBack, goForward, goUp, refresh
    case loadProgress(Generation, PresentationSnapshot), loadFinished(Generation, PresentationSnapshot)
    case loadFailed(Generation, LoadError)
    case monitorValidationFailed(Generation, LoadError)
    case monitorEvent(Generation, MonitorEvent), monitorSnapshot(Generation, PresentationSnapshot)
    case setSelection(Set<ItemID>, source: SelectionSource), setSort(ItemSort), setViewMode(ViewMode)
    case toggleHidden, settingsChanged(SettingsSnapshot)
    case expand(ItemID), collapse(ItemID)
    case searchStarted(SearchQuery), searchResults(Generation, [SearchResult]), searchEnded
    case addressBar(AddressEditorAction)
    case activated, deactivated
    case setScrollAnchor(ItemID?), beginInlineRename(ItemID), endInlineRename
    case cutSetChanged(Set<ItemID>)
}
/// Plain effect descriptions; the store executes I/O and routes tagged results back (F-008/F-043).
public enum TabEffect: Sendable, Equatable {
    case load(Location, Generation, LoadOptions)
    case startMonitor(Location, Generation)
    case cancel(GenerationLane, Generation)
    case startSearch(SearchQuery, Generation)
    case recordRecent(URL)
    case addressEditor(AddressEditorEffect)
    case validateNavigation(Location, Generation)
    case refreshPaths(Set<String>, Generation)
    case persistShowHidden(Bool)
}
