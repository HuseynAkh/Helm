// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Session-scoped source validation preserves F-067 order without repeating overlap sorting.
/// Keep one value per native drag, replace sources on payload changes, and end on exit/completion.
/// Execution still revalidates filesystem state; this cache contains only immutable drag metadata.
public struct DropSession: Sendable {
    public let id: UUID
    private var validation: DropSourceValidation
    public private(set) var isEnded: Bool = false
    internal private(set) var validationCount: Int = 1
    public init(sources: [DraggedItem]) {
        self.id = UUID(); self.validation = DropSourceValidation(sources: sources)
    }
    public mutating func replaceSources(_ sources: [DraggedItem]) {
        guard !isEnded, sources != validation.sources else { return }
        validation = DropSourceValidation(sources: sources)
        validationCount += 1
    }
    public mutating func end() {
        isEnded = true
        validation = DropSourceValidation(sources: [])
    }
    public func proposal(destination: DropDestination, modifiers: DropModifiers = [],
                         allowedOperations: Set<DropOperation> = [.copy, .move, .moveToTrash]) -> DropProposal {
        // Ended sessions have no sources and cannot authorize a drop or retain user paths.
        DropPlanner.proposal(validation: validation, destination: destination,
                             modifiers: modifiers, allowedOperations: allowedOperations)
    }
}

struct DropSourceValidation: Sendable {
    let sources: [DraggedItem]
    let paths: [[String]]
    let rejection: DropRejection?
    let overlaps: Bool
    init(sources: [DraggedItem]) {
        self.sources = sources
        self.paths = sources.map { $0.url.standardizedFileURL.pathComponents }
        if sources.isEmpty { rejection = .emptySources }
        else if !sources.allSatisfy({ $0.url.isFileURL }) { rejection = .invalidFileURL }
        else if !sources.allSatisfy({ $0.id == ItemID(url: $0.url) }) { rejection = .identityMismatch }
        else { rejection = nil }
        self.overlaps = rejection == nil && DropPlanner.hasOverlappingPaths(paths)
    }
}
