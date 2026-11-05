import Foundation

/// Injected wall time makes Recent age and cache expiry deterministic (F-016, F-030).
public protocol HelmClock: Sendable { func now() -> Date }
/// Production wall clock for F-030 timestamps; sleeping is owned by task lifetimes.
public struct SystemHelmClock: HelmClock {
    public init() {}
    public func now() -> Date { Date() }
}
