// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Generation-scoped awaiting state for explicit cloud requests (F-007, F-049; B-021).
/// Cancellation stops this consumer awaiting; it does not promise provider transfer cancellation.
/// Completion never rewrites FileEntry availability or infers that unknown content is local.
public struct CloudRequestState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, awaiting, cancelled, providerReportedCompletion, failed(String)
    }
    public private(set) var requestID: UUID?
    public private(set) var itemID: ItemID?
    public private(set) var plan: CloudActionPlan?
    public private(set) var phase: Phase = .idle
    public private(set) var progress: Double?

    public init() {}

    /// Each admitted request gets a fresh identity, including A→B→A requests.
    @discardableResult
    public mutating func begin(itemID: ItemID, plan: CloudActionPlan) -> UUID? {
        guard plan == .requestExplicitMaterialization || plan == .awaitMaterialization
                || plan == .requestExplicitEviction else { return nil }
        let id = UUID()
        self.requestID = id
        self.itemID = itemID
        self.plan = plan
        phase = .awaiting
        progress = nil
        return id
    }

    @discardableResult
    public mutating func updateProgress(requestID: UUID, fraction: Double) -> Bool {
        guard self.requestID == requestID, phase == .awaiting, fraction.isFinite,
              (0...1).contains(fraction), fraction >= (progress ?? 0) else { return false }
        progress = fraction
        return true
    }

    @discardableResult
    public mutating func complete(requestID: UUID, failure: String? = nil) -> Bool {
        guard self.requestID == requestID, phase == .awaiting else { return false }
        phase = failure.map { .failed($0) } ?? .providerReportedCompletion
        return true
    }

    public mutating func cancel() {
        if phase == .awaiting { phase = .cancelled }
    }
}
