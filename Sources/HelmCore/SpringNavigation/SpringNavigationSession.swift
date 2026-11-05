// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Pure F-067 spring unwind transaction; deadlines and source validation use existing models.
/// Virtual destinations are deliberately unsupported (B-031); hosts must not substitute Home.
public struct SpringNavigationSession: Sendable {
    public let id: UUID
    public let original: SpringNavigationContext
    public private(set) var stack: [SpringNavigationContext] = []
    public private(set) var pending: SpringNavigationRequest?
    public private(set) var acceptedDrop: SpringDropRequest?
    public private(set) var isEnded: Bool = false
    private var timing: SpringLoadingModel
    private var drag: DropSession
    private var hover: FileEntry?
    private let sourcesAreLocal: Bool
    public var current: SpringNavigationContext { stack.last ?? original }

    public init(original: SpringNavigationContext, clock: any HelmClock,
                delay: TimeInterval, sources: [DraggedItem]) {
        self.id = UUID(); self.original = original
        self.timing = SpringLoadingModel(clock: clock, delay: delay)
        self.drag = DropSession(sources: sources)
        self.sourcesAreLocal = sources.allSatisfy { LexicalLocalPath($0.url).map { !$0.hasParent } ?? false }
    }
    public mutating func beginHover(_ target: FileEntry?) {
        guard !isEnded, acceptedDrop == nil else { return }
        guard let target, let path = LexicalLocalPath(target.url), !path.hasParent, target.isDirectoryLike else { leaveHover(); return }
        if let hover, !Self.sameTarget(hover, target) { leaveHover() }
        hover = target
        timing.beginHover(id: target.id, isDirectory: true)
    }
    public mutating func leaveHover() {
        timing.cancel(); hover = nil; pending = nil
    }
    public mutating func poll(openImmediately: Bool = false) -> [SpringNavigationEffect] {
        guard !isEnded, acceptedDrop == nil, let target = hover,
              timing.poll(openImmediately: openImmediately) == target.id else { return [] }
        let request = SpringNavigationRequest(sessionID: id, target: target)
        pending = request
        return [.load(request)]
    }
    public mutating func hoverOpened(request: SpringNavigationRequest,
                                     target: FileEntry) -> [SpringNavigationEffect] {
        guard !isEnded, pending == request else { return [] }
        pending = nil
        guard Self.sameTarget(target, request.target) else { return [] }
        let context = SpringNavigationContext(tabID: original.tabID, location: .directory(target.url))
        stack.append(context)
        return [.displayTemporary(context)]
    }
    public mutating func loadFailed(request: SpringNavigationRequest) -> [SpringNavigationEffect] {
        guard pending == request, !isEnded else { return [] }
        pending = nil
        return [.restore(current)]
    }
    public mutating func retreat() -> [SpringNavigationEffect] {
        guard !isEnded, acceptedDrop == nil else { return [] }
        leaveHover()
        if !stack.isEmpty { stack.removeLast() }
        return [.restore(current)]
    }
    /// Host supplies fresh destination facts; this admits intent only, never executes a drop.
    public mutating func acceptDrop(target: FileEntry, destination: DropDestination,
                                    modifiers: DropModifiers = [], allowedOperations: Set<DropOperation>) -> SpringDropRequest? {
        guard !isEnded, sourcesAreLocal, acceptedDrop == nil, let path = LexicalLocalPath(target.url), !path.hasParent, target.isDirectoryLike,
              case .directory(let destinationURL) = destination.location,
              let destinationPath = LexicalLocalPath(destinationURL), !destinationPath.hasParent,
              destinationPath.key == path.key else { return nil }
        let proposal = drag.proposal(destination: destination, modifiers: modifiers, allowedOperations: allowedOperations)
        guard proposal.operation != nil else { return nil }
        let request = SpringDropRequest(sessionID: id, proposal: proposal, target: target)
        acceptedDrop = request; leaveHover()
        return request
    }
    public mutating func dropCompleted(request: SpringDropRequest, success: Bool,
                                       destination: FileEntry) -> [SpringNavigationEffect] {
        guard !isEnded, acceptedDrop == request else { return [] }
        guard success, Self.sameTarget(destination, request.target) else { return cancel() }
        guard request.target.objectIdentity != nil, destination.objectIdentity != nil else {
            let effects = cancel()
            return [.destinationUnverified(request)] + effects
        }
        let context = SpringNavigationContext(tabID: original.tabID, location: request.proposal.destination.location)
        finish()
        return [.commit(context)]
    }
    public mutating func cancel() -> [SpringNavigationEffect] {
        guard !isEnded else { return [] }
        finish()
        return [.restore(original)]
    }
    /// Closing the owner cancels silently: never reopen a closed tab to restore its context.
    public mutating func tabClosed(_ tabID: TabID) {
        if tabID == original.tabID { finish() }
    }
    private static func sameTarget(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        guard let left = LexicalLocalPath(lhs.url), let right = LexicalLocalPath(rhs.url),
              !left.hasParent, !right.hasParent else { return false }
        return left.key == right.key && lhs.kind == rhs.kind && lhs.objectIdentity == rhs.objectIdentity
    }
    private mutating func finish() {
        isEnded = true; leaveHover(); acceptedDrop = nil; stack = []; drag.end()
    }
}
