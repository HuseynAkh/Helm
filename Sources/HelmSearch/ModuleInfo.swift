// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
/// Portable metadata search preserves F-043–F-046; see README.md for adapter contracts.
/// Core owns query, symbolic scopes, filter clauses, request/specification and ranked batches.
/// SearchEvent.results retains the batch truncation flag; UI must display it.
/// SearchEngine emits cumulative ranked snapshots; supply a diagnostic sink for terminal errors.
/// CompositeSearchSource carries explicit fallback disclosure; adapters own Spotlight lifecycle.
/// SearchCriteriaEditor treats Finder RawQuery as read-only opaque data.
public enum HelmSearchModule { public static let name: String = "HelmSearch" }
