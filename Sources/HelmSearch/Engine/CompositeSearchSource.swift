// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Value-only Spotlight boundary; NSMetadataItem never crosses actors (F-046).
public struct SearchMetadataRecord: Sendable, Equatable {
    public let candidate: SearchCandidate
    public let tags: Set<String>
    public init(candidate: SearchCandidate, tags: Set<String> = []) { self.candidate = candidate; self.tags = tags }
}
/// Index availability is explicit, never inferred from an empty result (B-099).
public enum SearchIndexAvailability: Sendable { case available, unavailable, knownUnindexed }
/// Adapter snapshot carries source truncation through merged ranking (B-026).
public struct SearchMetadataSnapshot: Sendable {
    public let records: [SearchMetadataRecord]
    public let availability: SearchIndexAvailability
    public let truncated: Bool
    public init(records: [SearchMetadataRecord], availability: SearchIndexAvailability = .available, truncated: Bool = false) {
        self.records = records; self.availability = availability; self.truncated = truncated
    }
}
/// Adapters must enforce scope/hidden/package policy and release query resources on cancellation (B-021).
/// This is a finite snapshot seam; macOS live-update lifecycle remains the adapter's responsibility.
public protocol MetadataSearchSource: Sendable {
    func snapshot(for specification: SearchSpecification) async throws -> SearchMetadataSnapshot
}
/// Portable scripted metadata source exercises adapter-independent search (F-046).
public struct FakeMetadataSearchSource: MetadataSearchSource {
    public let value: SearchMetadataSnapshot
    public let delayNanoseconds: UInt64
    public init(snapshot: SearchMetadataSnapshot, delayNanoseconds: UInt64 = 0) {
        self.value = snapshot; self.delayNanoseconds = delayNanoseconds
    }
    public func snapshot(for specification: SearchSpecification) async throws -> SearchMetadataSnapshot {
        try Task.checkCancellation()
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return value
    }
}
/// UI-visible fallback reasons preserve deliberate, privacy-aware fallback (F-046, B-099).
public enum SearchFallbackReason: Sendable, Equatable { case metadataUnavailable, knownUnindexed, userRequested }
/// A non-nil reason discloses enumeration even when no results were found (F-046).
public struct SearchFallbackDisclosure: Sendable, Equatable {
    public let reason: SearchFallbackReason?
    public let unsupportedCriteria: Bool
    public init(reason: SearchFallbackReason?, unsupportedCriteria: Bool = false) {
        self.reason = reason; self.unsupportedCriteria = unsupportedCriteria
    }
}
/// Ranked results and fallback disclosure travel together to presentation (F-046).
public struct CompositeSearchResult: Sendable {
    public let batch: SearchRankedBatch
    public let disclosure: SearchFallbackDisclosure
    public init(batch: SearchRankedBatch, disclosure: SearchFallbackDisclosure) { self.batch = batch; self.disclosure = disclosure }
}
/// Merges before applying the legacy candidate cap, with metadata winning duplicate paths (F-045).
public struct CompositeSearchSource: Sendable {
    private let metadata: any MetadataSearchSource
    private let enumeration: SearchEngine
    private let clock: any HelmClock
    public init(metadata: any MetadataSearchSource, enumeration: SearchEngine, clock: any HelmClock = SystemHelmClock()) {
        self.metadata = metadata; self.enumeration = enumeration; self.clock = clock
    }
    public func search(_ request: SearchRequest, context: SearchRankingContext, userRequestedFallback: Bool = false,
                       options: SearchWalkOptions = SearchWalkOptions(),
                       diagnostic: @Sendable (SearchDiagnostic) -> Void = { _ in }) async throws -> CompositeSearchResult {
        try Task.checkCancellation()
        let specification = try SearchQueryParser.compile(request)
        let snapshot = try await metadata.snapshot(for: specification)
        try Task.checkCancellation()
        let reason: SearchFallbackReason?
        switch snapshot.availability {
        case .unavailable: reason = .metadataUnavailable
        case .knownUnindexed: reason = .knownUnindexed
        case .available: reason = userRequestedFallback ? .userRequested : nil
        }
        let roots = try await enumeration.metadataRoots(for: request.scope)
        var values = snapshot.records.filter { record in
            let path = record.candidate.entry.url.standardizedFileURL.path
            let inScope = roots?.contains { SearchRanker.contains(path, root: $0.path) } ?? true
            return inScope && specification.matches(record.candidate.entry, tags: record.tags)
        }.map(\.candidate)
        var truncated = snapshot.truncated
        var unsupported = false
        if reason != nil {
            if specification.requiresTags || request.scope == .recents { unsupported = true; truncated = true }
            else {
                let walk = try await enumeration.candidates(request, options: options, diagnostic: diagnostic)
                let metadataPaths = Set(values.map { $0.entry.url.standardizedFileURL.path })
                values.append(contentsOf: walk.values.filter { !metadataPaths.contains($0.entry.url.standardizedFileURL.path) })
                truncated = truncated || walk.truncated
            }
        }
        try Task.checkCancellation()
        let batch = SearchRanker.rank(values, context: enumeration.rankingContext(request, context), clock: clock, upstreamTruncated: truncated)
        return CompositeSearchResult(batch: batch, disclosure: SearchFallbackDisclosure(reason: reason, unsupportedCriteria: unsupported))
    }
}
