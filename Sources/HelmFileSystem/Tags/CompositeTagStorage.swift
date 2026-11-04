// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Selects an optional provider only on unsupported metadata, preserving denied failures (F-029, B-039).
public struct CompositeTagStorage: TagStorage {
    private let primary: any TagStorage
    private let fallback: (any TagStorage)?
    public init(primary: any TagStorage = XattrTagStorage(), fallback: (any TagStorage)? = nil) {
        self.primary = primary
        self.fallback = fallback
    }
    public func tags(for item: ItemID) async throws -> TagSet {
        do { return try await primary.tags(for: item) }
        catch {
            guard isUnsupported(error), let fallback else { throw error }
            return try await fallback.tags(for: item)
        }
    }
    public func apply(_ edit: TagEdit, to item: ItemID) async throws {
        do { try await primary.apply(edit, to: item) }
        catch {
            guard isUnsupported(error), let fallback else { throw error }
            try await fallback.apply(edit, to: item)
        }
    }
    private func isUnsupported(_ error: Error) -> Bool {
        if let failure = error as? TagAdapterError { return failure == .unsupportedFilesystem }
        if let failure = error as? TagStorageFailure, case .unsupported = failure { return true }
        return false
    }
}

/// URL selection edits retain ordered, deduplicated partial outcomes (F-029, B-039).
public struct TagBulkApplier: Sendable {
    private let storage: any TagStorage
    public init(storage: any TagStorage) { self.storage = storage }
    public func apply(_ edit: TagEdit, to urls: [URL]) async -> TagEditResult {
        // Reject remote URLs before ItemID converts them into local paths.
        var seen: Set<URL> = []
        var outcomes: [TagEditOutcome] = []
        var seenItems: Set<ItemID> = []
        for url in urls where seen.insert(url).inserted {
            let item = ItemID(url: url)
            guard url.isFileURL else {
                outcomes.append(TagEditOutcome(item: item, failure: "Tag metadata requires a file URL"))
                continue
            }
            guard seenItems.insert(item).inserted else { continue }
            do {
                try await storage.apply(edit, to: item)
                outcomes.append(TagEditOutcome(item: item))
            } catch {
                outcomes.append(TagEditOutcome(item: item, failure: String(describing: error)))
            }
        }
        return TagEditResult(outcomes: outcomes)
    }
}
