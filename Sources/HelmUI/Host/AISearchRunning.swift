#if os(macOS)
import Foundation
import HelmCore

/// Runs a search with a model's help. While one is installed, a search asked for with `usesAI` goes here instead of
/// to the store: `baseline` starts today's name search and hands its ranked lists to `deliver` rather than to the
/// store, so the runner is the only one that sends results for that search.
@MainActor protocol AISearchRunning: AnyObject {
    func run(_ query: SearchQuery, generation: Generation, tab: TabID,
             baseline: @escaping @MainActor (_ deliver: @escaping @Sendable ([SearchResult]) -> Void) -> StoreEffectCancellation,
             send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation
}
#endif
