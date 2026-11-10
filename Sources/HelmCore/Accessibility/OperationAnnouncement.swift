// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// One value per operation supplies meaningful F-061 milestones and persistent error text (B-049).
/// The UI owns delivery/retention; this value performs no notifications or operations.
public struct OperationAnnouncement: Sendable {
    public enum Event: Sendable {
        case started
        case progress(Double)
        case completed
        case failed(reason: String)
        case cancelled
    }
    public let operationName: String
    public let milestonePercent: Int
    public let minimumInterval: TimeInterval
    private var lastPercent: Int = 0
    private var lastDate: Date?
    private var started: Bool = false
    private var terminal: Bool = false

    public init(operationName: String, milestonePercent: Int = 10, minimumInterval: TimeInterval = 2) {
        self.operationName = operationName
        self.milestonePercent = min(100, max(1, milestonePercent))
        self.minimumInterval = minimumInterval.isFinite ? max(0, minimumInterval) : 2
    }

    /// Progress is finite, monotonic and throttled. Terminal events bypass throttling, once only.
    /// A clock rewind reopens the time gate; repeated or regressive milestones remain suppressed.
    public mutating func announcement(for event: Event, formatting: AccessibilityFormatting) -> String? {
        guard !terminal else { return nil }
        switch event {
        case .started:
            guard !started else { return nil }
            started = true
            let now: Date = formatting.clock.now()
            if now.timeIntervalSinceReferenceDate.isFinite { lastDate = now }
            return operationName + " started"
        case .progress(let fraction):
            guard fraction.isFinite else { return nil }
            let percent: Int = Int((min(1, max(0, fraction)) * 100).rounded(.down))
            let milestone: Int = percent == 100 ? 100 : (percent / milestonePercent) * milestonePercent
            guard milestone > lastPercent else { return nil }
            let now: Date = formatting.clock.now()
            guard now.timeIntervalSinceReferenceDate.isFinite else { return nil }
            if let previous = lastDate {
                let elapsed: TimeInterval = now.timeIntervalSince(previous)
                if elapsed >= 0 && elapsed < minimumInterval { return nil }
            }
            started = true
            lastPercent = milestone
            lastDate = now
            return "\(operationName), \(formatting.count(milestone)) percent"
        case .completed:
            terminal = true
            return operationName + " completed"
        case .failed(let reason):
            terminal = true
            let detail: String = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return operationName + " failed: " + (detail.isEmpty ? "Unknown error" : detail)
        case .cancelled:
            terminal = true
            return operationName + " cancelled"
        }
    }
}
