import Foundation
import HelmCore

/// Shared manually advanced time for cache and Recent tests (F-016, F-030).
/// All reads and writes hold the lock; this invariant justifies unchecked Sendable on Swift 5.9.
public final class FakeClock: HelmClock, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var instant: Date
    public init(now: Date = Date(timeIntervalSince1970: 0)) { instant = now }
    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }
    public func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        instant = instant.addingTimeInterval(interval)
    }
}
