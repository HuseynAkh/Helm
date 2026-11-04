// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
// Per-invocation diagnostics at actual planning work sites (F-052, B-107).
// Synchronous and confined to one planner invocation; no shared/global test hook.
final class PlannerWork {
    var selectionComparisons: Int = 0
    var targetQueries: Int = 0
    var manifestVisits: Int = 0
    var manifestAggregations: Int = 0
    var byteLookups: Int = 0
}
