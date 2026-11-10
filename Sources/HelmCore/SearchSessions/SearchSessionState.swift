// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Availability is evidence supplied by the source, never inferred from empty results (F-046).
public enum SearchSessionIndex: Sendable, Equatable { case unknown, available, unavailable }
/// Enumeration disclosure remains independent of index availability and result count (F-046).
public enum SearchSessionFallback: Sendable, Equatable {
    case none, metadataUnavailable, knownUnindexed, userRequested
}
/// Additive event envelope retains existing ranked events and explicit source facts (F-046, B-026).
public enum SearchSessionEvent: Sendable, Equatable {
    case search(SearchEvent)
    case disclosure(index: SearchSessionIndex, fallback: SearchSessionFallback, unsupportedCriteria: Bool)
    case finished
    case failed(String)
}
/// Request UUIDs reject A→B→A callbacks; final gathering still permits live updates (F-043, B-021).
public struct SearchSessionState: Sendable, Equatable {
    public private(set) var query: SearchQuery?
    public private(set) var generation: UUID?
    public private(set) var batch: SearchRankedBatch?
    public private(set) var isGathering: Bool = false
    public private(set) var isAcceptingEvents: Bool = false
    public private(set) var isShutdown: Bool = false
    public private(set) var index: SearchSessionIndex = .unknown
    public private(set) var fallback: SearchSessionFallback = .none
    public private(set) var unsupportedCriteria: Bool = false
    public private(set) var error: String?
    public init() {}

    /// Empty text exits only when typed criteria are also absent (F-043, P15-1).
    @discardableResult
    public mutating func start(_ query: SearchQuery) -> UUID? {
        guard !isShutdown else { return nil }
        let previousBatch = batch
        self = SearchSessionState()
        guard !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !query.filters.isEmpty else { return nil }
        batch = previousBatch
        self.query = query
        let request = UUID()
        generation = request; isGathering = true; isAcceptingEvents = true
        return request
    }
    @discardableResult
    public mutating func refresh() -> UUID? {
        guard let query else { return nil }
        return start(query)
    }
    public mutating func cancel() {
        generation = nil; isGathering = false; isAcceptingEvents = false
    }
    public mutating func shutdown() { cancel(); isShutdown = true }

    @discardableResult
    public mutating func receive(_ event: SearchSessionEvent, generation: UUID) -> Bool {
        guard !isShutdown, isAcceptingEvents, self.generation == generation else { return false }
        switch event {
        case .search(.gathering): isGathering = true
        case .search(.results(let batch, let isFinal)):
            self.batch = batch
            if isFinal { isGathering = false }
        case .search(.notIndexed): index = .unavailable
        case .disclosure(let index, let fallback, let unsupportedCriteria):
            self.index = index; self.fallback = fallback; self.unsupportedCriteria = unsupportedCriteria
        case .finished: isGathering = false; isAcceptingEvents = false
        case .failed(let message): error = message; isGathering = false; isAcceptingEvents = false
        }
        return true
    }
}
