// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Atomic per-item edits prevent a read/write race erasing unrelated tags (M18, F-029).
public protocol TagStorage: Sendable {
    func tags(for item: ItemID) async throws -> TagSet
    func apply(_ edit: TagEdit, to item: ItemID) async throws
}

/// One-tag mutation, independent of private Helm stars (F-029).
public enum TagEdit: Sendable {
    case add(FinderTag), remove(FinderTag)
    public func applying(to tags: TagSet) -> TagSet {
        var result = tags
        switch self { case .add(let tag): result.add(tag); case .remove(let tag): result.remove(tag) }
        return result
    }
}

/// Per-item outcome keeps partial multi-selection failure visible (M18, B-039).
public struct TagEditOutcome: Sendable, Equatable {
    public let item: ItemID
    public let failure: String?
    public init(item: ItemID, failure: String? = nil) { self.item = item; self.failure = failure }
}

/// Ordered aggregate retains successes even when other items fail (M18, B-039).
public struct TagEditResult: Sendable, Equatable {
    public let outcomes: [TagEditOutcome]
    public init(outcomes: [TagEditOutcome]) { self.outcomes = outcomes }
    public var succeeded: [ItemID] { outcomes.filter { $0.failure == nil }.map(\.item) }
    public var failures: [TagEditOutcome] { outcomes.filter { $0.failure != nil } }
    public var isPartialFailure: Bool { !succeeded.isEmpty && !failures.isEmpty }
    public static func apply(_ edit: TagEdit, to items: [ItemID], storage: any TagStorage) async -> TagEditResult {
        var seen: Set<ItemID> = []
        var results: [TagEditOutcome] = []
        for item in items where seen.insert(item).inserted {
            do { try await storage.apply(edit, to: item); results.append(TagEditOutcome(item: item)) }
            catch { results.append(TagEditOutcome(item: item, failure: String(describing: error))) }
        }
        return TagEditResult(outcomes: results)
    }
}

/// Test-only in-memory semantics; no xattrs or external metadata are touched (M18, F-029).
public actor InMemoryTagStorage: TagStorage {
    private var values: [ItemID: TagSet]
    private let deniedItems: Set<ItemID>
    public init(values: [ItemID: TagSet] = [:], deniedItems: Set<ItemID> = []) {
        self.values = values; self.deniedItems = deniedItems
    }
    public func tags(for item: ItemID) throws -> TagSet {
        if deniedItems.contains(item) { throw TagStorageFailure.denied }
        return values[item] ?? TagSet()
    }
    public func apply(_ edit: TagEdit, to item: ItemID) throws {
        values[item] = edit.applying(to: try tags(for: item))
    }
}

/// Explicit unsupported/denied states for metadata adapters (M18, B-017).
public enum TagStorageFailure: Error, Sendable { case denied, unsupported }
