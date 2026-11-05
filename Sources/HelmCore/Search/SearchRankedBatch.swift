// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Visible bounds prevent claiming an older exact match was considered when it was not (B-026).
public struct SearchRankedBatch: Sendable, Equatable {
    public let results: [SearchResult]
    public let truncated: Bool
    public let candidateLimitReached: Bool
    public let consideredCount: Int
    public init(results: [SearchResult], truncated: Bool, candidateLimitReached: Bool, consideredCount: Int) {
        self.results = results; self.truncated = truncated; self.candidateLimitReached = candidateLimitReached; self.consideredCount = consideredCount
    }
}
