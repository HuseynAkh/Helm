import Foundation
import HelmCore

/// Quiet-window batching has a maximum age so sustained writes cannot starve refresh (B-016).
public struct EventCoalescer: Sendable {
    private let clock: any HelmClock
    private let quietInterval: TimeInterval
    private let maximumInterval: TimeInterval
    private var first: Date?
    private var last: Date?
    private var paths: Set<String> = []
    public init(clock: any HelmClock = SystemHelmClock(), quietInterval: TimeInterval = 0.25, maximumInterval: TimeInterval = 1) {
        self.clock = clock; self.quietInterval = max(0, quietInterval); self.maximumInterval = max(0, maximumInterval)
    }
    public mutating func receive(_ event: MonitorEvent) -> [MonitorEvent] {
        switch event {
        case .changed(let newPaths):
            if first == nil { first = clock.now() }
            last = clock.now(); paths.formUnion(newPaths)
            return flushIfDue()
        default:
            paths.removeAll(); first = nil; last = nil
            return [event]
        }
    }
    public mutating func flushIfDue() -> [MonitorEvent] {
        guard let first, let last else { return [] }
        let now = clock.now()
        guard now.timeIntervalSince(first) >= maximumInterval || now.timeIntervalSince(last) >= quietInterval else { return [] }
        let event = MonitorEvent.changed(paths: paths)
        paths.removeAll(); self.first = nil; self.last = nil
        return [event]
    }
}
