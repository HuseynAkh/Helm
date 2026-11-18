#if os(macOS)
import Foundation
import HelmCore
import HelmFileSystem
import HelmOperations

/// An item's permissions were changed through Helm, put back or changed again, or an Undo or Redo of that was refused.
public struct PermissionEvent: Sendable, Equatable {
    public let item: URL
    /// What went wrong, or nil when the change was made.
    public let message: String?
    public init(item: URL, message: String? = nil) { self.item = item; self.message = message }
}

/// Permissions changes, which Properties makes: one item's mode at a time, never inside a folder. The executor, which
/// moves and makes items, has no part in them, but each is one entry in the window's history, undone and redone in
/// turn with the window's other changes.
extension OperationCoordinator {
    /// Changes `item`'s permissions from `before` to `after` and records it in `history`, so Undo puts `before` back.
    /// It's refused, with nothing changed, unless the item is still the one with `identity` and has `before`, and is
    /// the person's own on a disk that keeps permissions. Answers the mode the disk keeps now.
    public func changePermissions(of item: URL, identity: FileObjectIdentity, from before: UInt16, to after: UInt16,
                                  history: WindowOperationHistory) async -> Result<UInt16, Failure> {
        guard let request = await history.beginPermissionChange() else { return .failure(.busy) }
        switch await Self.writePermissions(item, identity: identity, from: before, to: after) {
        case .success(let kept):
            await history.finishPermissionChange(request: request,
                                                 change: PermissionChange(item: item, identity: identity, before: before, after: kept))
            permissionEvents.send(PermissionEvent(item: item))
            return .success(kept)
        case .failure(let refusal):
            await history.finishPermissionChange(request: request, change: nil, failure: refusal.message)
            return .failure(.message(refusal.message))
        }
    }

    /// Edit › Undo of a permissions change: the mode it found is put back, while the item still has the mode it left.
    func undoPermissionChange(history: WindowOperationHistory) async -> Result<OperationResult, Failure> {
        guard let (request, change) = await history.beginPermissionUndo() else { return .failure(.busy) }
        switch await Self.writePermissions(change.item, identity: change.identity, from: change.after, to: change.before) {
        case .success:
            await history.finishPermissionUndo(request: request, restored: true)
            permissionEvents.send(PermissionEvent(item: change.item))
            return .success(OperationResult(id: OperationID(), command: .recovery, outcomes: []))
        case .failure(let refusal):
            let message = Self.permissionsText(refusal, item: change.item, verb: "put back")
            await history.finishPermissionUndo(request: request, restored: false, failure: message)
            permissionEvents.send(PermissionEvent(item: change.item, message: message))
            return .failure(.message(message))
        }
    }

    /// Edit › Redo of a permissions change: made again, while the item still has the mode its Undo put back, as a new
    /// entry.
    func redoPermissionChange(history: WindowOperationHistory) async -> Result<OperationResult, Failure> {
        guard let (request, change) = await history.beginPermissionRedo() else { return .failure(.busy) }
        switch await Self.writePermissions(change.item, identity: change.identity, from: change.before, to: change.after) {
        case .success(let kept):
            await history.finishPermissionChange(request: request, change: PermissionChange(item: change.item, identity: change.identity,
                                                                                            before: change.before, after: kept))
            permissionEvents.send(PermissionEvent(item: change.item))
            return .success(OperationResult(id: OperationID(), command: .recovery, outcomes: []))
        case .failure(let refusal):
            let message = Self.permissionsText(refusal, item: change.item, verb: "changed again")
            await history.finishPermissionChange(request: request, change: nil, failure: message)
            permissionEvents.send(PermissionEvent(item: change.item, message: message))
            return .failure(.message(message))
        }
    }

    /// Off the main thread, so a disk that's slow to answer holds up only this change.
    private static func writePermissions(_ item: URL, identity: FileObjectIdentity, from before: UInt16,
                                         to after: UInt16) async -> Result<UInt16, PermissionRefusal> {
        await Task.detached(priority: .userInitiated) {
            PermissionsWriter.change(item, identity: identity, from: before, to: after)
        }.value
    }

    /// Why an Undo or Redo of a permissions change was refused, naming the item, since it's said in the browser window.
    static func permissionsText(_ refusal: PermissionRefusal, item: URL, verb: String) -> String {
        let name = "“\(item.lastPathComponent)”"
        switch refusal {
        case .changed, .link: return "\(name) has changed since, so its permissions can’t be \(verb)."
        case .missing: return "\(name) is no longer there, so its permissions can’t be \(verb)."
        case .notOwner: return "\(name) isn’t yours any more, so its permissions can’t be \(verb)."
        case .locked: return "\(name) is locked, so its permissions can’t be \(verb)."
        case .readOnlyVolume: return "\(name)’s disk is read-only, so its permissions can’t be \(verb)."
        case .notKept: return "\(name)’s disk doesn’t keep permissions, so they can’t be \(verb)."
        case .notPermitted: return "\(name)’s permissions can’t be \(verb): you don’t have permission to change them."
        case .failed(let reason): return "\(name)’s permissions can’t be \(verb): \(reason)."
        }
    }
}
#endif
