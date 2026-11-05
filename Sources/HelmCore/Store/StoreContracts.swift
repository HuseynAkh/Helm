// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Atomic window/tab delivery preserves F-002/F-005 and prevents mismatched selection (B-009/B-011).
public struct WindowStoreSnapshot: Sendable {
    public let window: WindowState
    public let tabs: [TabID: TabState]
    public let sequence: UInt64
    public let timestamp: Date
    public init(window: WindowState, tabs: [TabID: TabState], sequence: UInt64, timestamp: Date) {
        self.window = window; self.tabs = tabs; self.sequence = sequence; self.timestamp = timestamp
    }
}

/// FIFO inputs preserve custom-tab ownership and history actions (F-002/F-005/F-068).
public enum WindowStoreAction: Sendable {
    case window(WindowAction)
    case addTab(TabState, activate: Bool)
    case tab(TabID, TabAction)
    case persistSession
    case shutdown
}

/// Existing reducer effects retain their original generations (B-014/B-021); persistence preserves F-068.
public enum StoreEffect: Sendable {
    case tab(TabID, TabEffect)
    case window(WindowEffect)
    case persistSession(WindowStoreSnapshot)
}

/// Cancellation is synchronous and idempotent, preserving retired-work isolation (B-014/B-021).
@MainActor public final class StoreEffectCancellation {
    private var body: (@MainActor () -> Void)?
    public init(_ body: @escaping @MainActor () -> Void) { self.body = body }
    public func cancel() {
        let action = body; body = nil; action?()
    }
}

/// Adapters execute F-008/F-043 effects and return cancellation for long-lived lane work.
/// Callbacks may arrive from any context; preserve reducer generations when emitting actions.
@MainActor public protocol EffectRunner: AnyObject {
    func run(_ effect: StoreEffect,
             send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation?
}

/// Locked admission gives concurrent producers one total FIFO order (F-002, B-020).
/// All mutable storage is guarded by lock; reducer state remains exclusively on MainActor.
final class StoreMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [WindowStoreAction] = []
    private var head: Int = 0
    private var scheduled: Bool = false
    private var closed: Bool = false
    func append(_ action: WindowStoreAction) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        pending.append(action)
        if scheduled { return false }
        scheduled = true; return true
    }
    func pop() -> WindowStoreAction? {
        lock.lock(); defer { lock.unlock() }
        guard head < pending.count else {
            pending.removeAll(keepingCapacity: true); head = 0; scheduled = false; return nil
        }
        let action = pending[head]; head += 1
        return action
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true; pending.removeAll(); head = 0; scheduled = false
    }
}
