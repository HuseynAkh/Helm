// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmOperations

/// F-061 progress is measured in the items a person chose (executor steps grouped by item), never fabricated bytes;
/// failures remain visible (B-038).
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
            // Counted in items, as chosen: one replaced file is one item, not the steps that replaced it.
            let total = result.items.count
            let counts = result.failedCount == 0 ? "Done" : "\(result.succeededItemCount) of \(total) done"
            guard let error = result.error else { return counts }
            // The item that failed is named, so the row says what to look at without opening Details.
            let failed = result.failedItemNames
            guard let first = failed.first, error != .cancelled else { return counts + ". " + Self.message(for: error) }
            let which = failed.count == 1 ? "“\(first)”" : "“\(first)” and \(failed.count - 1) more"
            return counts + ". " + which + ": " + Self.message(for: error)
        }
        if cancellationRequested { return "Cancelling…" }
        guard let progress = progress, progress.itemsTotal > 0 else { return "Preparing…" }
        let done = min(max(0, progress.itemsDone), progress.itemsTotal)
        if let name = progress.currentName, !name.isEmpty { return "\(done) of \(progress.itemsTotal) · \(name)" }
        return "\(done) of \(progress.itemsTotal)"
    }
    /// F-061 uncertain outcomes remain visible even when Details is collapsed (B-100).
    public var requiresReconciliation: Bool { result?.outcomes.contains { $0.requiresReconciliation } ?? false }
    var hasDetails: Bool { result?.outcomes.isEmpty == false }
    /// Points the row needs in the panel: its title and status, the progress bar while it runs, and once it's done the
    /// partly-done warning and the Details control, which a fixed height used to cut off.
    var panelHeight: CGFloat {
        guard result != nil else { return 56 }
        var height: CGFloat = 52
        if requiresReconciliation { height += 18 }
        if hasDetails { height += 24 }
        return height
    }
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
            case .success: state = "Done"
            case .failure(let error): state = Self.message(for: error)
            }
            return path + ": " + state + (outcome.requiresReconciliation ? " — may be only partly done; check it before trying again." : "")
    }
    /// Plain words for what went wrong, never an internal code name such as "permissionDenied".
    public static func message(for error: OperationError) -> String {
        switch error {
        case .cancelled: return "Stopped."
        case .notAttempted: return "Not started."
        case .invalidPlan: return "Helm couldn’t work out how to do this."
        case .busy: return "Another operation is still running."
        case .verificationUnavailable: return "Helm couldn’t check that the copy is complete."
        case .verificationFailed: return "The copy doesn’t match the original."
        case .conflict: return "An item with that name is already there."
        case .timedOut: return "The disk stopped responding, so this may be only partly done."
        case .sourceChanged(let url): return "“\(url.lastPathComponent)” changed while Helm was working."
        case .other(let message): return plain(message)
        }
    }
    /// File-system failures arrive as their case names. Turn the known ones into sentences.
    static func plain(_ raw: String) -> String {
        switch raw {
        case "permissionDenied": return "You don’t have permission."
        case "notFound": return "It’s no longer there."
        case "timedOut": return "The disk stopped responding."
        case "unsupported": return "This disk doesn’t support that."
        case _ where raw.hasPrefix("collision"): return "An item with that name is already there."
        case _ where raw.hasPrefix("other(\"") && raw.hasSuffix("\")"):
            return plain(String(raw.dropFirst(7).dropLast(2)))
        case "No space": return "There isn’t enough space on the disk."
        default: return raw
        }
    }
}
