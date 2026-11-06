// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Restorable per-tab context preserves F-038 selection during temporary F-067 navigation.
public struct SpringNavigationContext: Equatable, Sendable {
    public let tabID: TabID
    public let location: Location
    public let selection: Set<ItemID>
    public let scrollAnchor: ItemID?
    public let scrollOffset: Double
    public init(tabID: TabID, location: Location, selection: Set<ItemID> = [],
                scrollAnchor: ItemID? = nil, scrollOffset: Double = 0) {
        self.tabID = tabID; self.location = location; self.selection = selection
        self.scrollAnchor = scrollAnchor; self.scrollOffset = scrollOffset.isFinite ? scrollOffset : 0
    }
}

/// Single-use load identity prevents same-target ABA callbacks (B-009, F-067).
public struct SpringNavigationRequest: Hashable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let target: FileEntry
    public init(id: UUID = UUID(), sessionID: UUID, target: FileEntry) {
        self.id = id; self.sessionID = sessionID; self.target = target
    }
}

/// Only commit may record history/Recent; temporary display and restoration preserve B-017.
public enum SpringNavigationEffect: Equatable, Sendable {
    case load(SpringNavigationRequest)
    case displayTemporary(SpringNavigationContext)
    case restore(SpringNavigationContext)
    case commit(SpringNavigationContext)
    /// Completion lacks object evidence; restore without committing history.
    case destinationUnverified(SpringDropRequest)
}

/// Accepted F-067 destination is frozen until execution reports completion.
public struct SpringDropRequest: Hashable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let proposal: FileDropProposal
    public let target: FileEntry
    public init(id: UUID = UUID(), sessionID: UUID, proposal: FileDropProposal, target: FileEntry) {
        self.id = id; self.sessionID = sessionID; self.proposal = proposal; self.target = target
    }
}
