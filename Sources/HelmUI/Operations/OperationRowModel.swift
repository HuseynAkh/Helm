// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmOperations

/// F-061 progress is measured in executor steps, never fabricated bytes; failures remain visible (B-038).
public struct OperationRowModel: Sendable, Identifiable {
    public let id: OperationID
    public let title: String
    public let progress: OperationProgress?
    public let result: OperationResult?
    private let detailCache = OperationDetailCache()
    public let cancellationRequested: Bool
    public init(id: OperationID, title: String, progress: OperationProgress? = nil,
                result: OperationResult? = nil, cancellationRequested: Bool = false) {
        self.id = id; self.title = title
        self.progress = progress?.id == id ? progress : nil
        self.result = result?.id == id ? result : nil
        self.cancellationRequested = cancellationRequested
    }
    public var canCancel: Bool { result == nil && !cancellationRequested }
    public var fraction: Double? {
        guard let progress = progress, progress.itemsTotal > 0 else { return nil }
        return Double(min(max(0, progress.itemsDone), progress.itemsTotal)) / Double(progress.itemsTotal)
    }
    public var status: String {
        if let result = result {
            let counts = "\(result.succeededCount) steps completed, \(result.failedCount) unsuccessful"
            if let error = result.error { return counts + " — " + Self.message(for: error) }
            return counts
        }
        if cancellationRequested { return "Cancelling…" }
        guard let progress = progress, progress.itemsTotal > 0 else { return "Preparing…" }
        return "\(min(max(0, progress.itemsDone), progress.itemsTotal)) of \(progress.itemsTotal) steps"
    }
    /// F-061 uncertain outcomes remain visible even when Details is collapsed (B-100).
    public var requiresReconciliation: Bool { result?.outcomes.contains { $0.requiresReconciliation } ?? false }
    var hasDetails: Bool { result?.outcomes.isEmpty == false }
    var detailPageCount: Int { ((result?.outcomes.count ?? 0) + 49) / 50 }
    var formattedDetailCount: Int { detailCache.count }
    func detailPage(_ page: Int) -> [String] {
        guard let result, page >= 0, page < detailPageCount else { return [] }
        return detailCache.page(page) {
            result.outcomes[(page * 50)..<min(page * 50 + 50, result.outcomes.count)].map(Self.detail)
        }
    }
    public var details: [String] { result?.outcomes.map(Self.detail) ?? [] }
    private static func detail(_ outcome: ItemOutcome) -> String {
            let source = outcome.step.source?.path ?? "New item"
            let destination = outcome.destination ?? outcome.step.destination
            let path = source + (destination.map { " → \($0.path)" } ?? "")
            let state: String
            switch outcome.result {
            case .success: state = "Completed"
            case .failure(let error): state = Self.message(for: error)
            }
            return path + ": " + state + (outcome.requiresReconciliation ? " — Check filesystem state before retrying." : "")
    }
    public static func message(for error: OperationError) -> String {
        switch error {
        case .cancelled: return "Cancelled"
        case .notAttempted: return "Not attempted"
        case .invalidPlan: return "Invalid operation plan"
        case .busy: return "Another operation is running"
        case .verificationUnavailable: return "Copy verification unavailable"
        case .verificationFailed: return "Copy verification failed"
        case .conflict: return "Destination conflict"
        case .timedOut: return "Timed out; completion is uncertain"
        case .sourceChanged(let url): return "Source changed: \(url.path)"
        case .other(let message): return message
        }
    }
}
