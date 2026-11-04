// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Cancellable, once-per-hover spring loading adds P-273 to F-067 without scheduling work.
public struct SpringLoadingModel: Sendable {
    private let clock: any HelmClock
    public let delay: TimeInterval
    public private(set) var hoveredID: ItemID?
    private var beganAt: Date?
    private var fired: Bool = false
    public init(clock: any HelmClock, delay: TimeInterval) {
        self.clock = clock; self.delay = delay.isFinite ? max(0, delay) : 1
    }
    /// Repeated updates to the same eligible row preserve its original deadline.
    public mutating func beginHover(id: ItemID, isDirectory: Bool, isPackage: Bool = false,
                                    allowsPackageContents: Bool = false) {
        guard isDirectory && (!isPackage || allowsPackageContents) else { cancel() ; return }
        guard hoveredID != id else { return }
        hoveredID = id; beganAt = clock.now(); fired = false
    }
    /// Poll from the adapter's timer; Space may request immediate spring loading (P-273).
    public mutating func poll(openImmediately: Bool = false) -> ItemID? {
        guard let id = hoveredID, let start = beganAt, !fired else { return nil }
        let elapsed = clock.now().timeIntervalSince(start)
        guard openImmediately || (elapsed.isFinite && elapsed >= delay) else { return nil }
        fired = true; return id
    }
    /// Call for leave, drop, Escape or drag termination; re-entry starts a new hover.
    public mutating func cancel() { hoveredID = nil; beganAt = nil; fired = false }
}
