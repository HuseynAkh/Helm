// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
/// Portable metadata search preserves F-043–F-046; see README.md for adapter contracts.
/// Core owns SearchQuery/SearchResult. SearchRequest adds bounded grammar without a dependency cycle.
/// UI must display SearchRankedBatch.truncated; the Core SearchEvent cannot carry it yet.
public enum HelmSearchModule { public static let name: String = "HelmSearch" }
