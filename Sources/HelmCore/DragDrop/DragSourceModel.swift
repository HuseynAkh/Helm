// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Unmaterialized external promise metadata (P-271); names are labels, never trusted paths.
public struct PromisedFilePlaceholder: Hashable, Sendable {
    public let identifier: String
    public let suggestedName: String
    public let contentTypeIdentifier: String?
    public init(identifier: String, suggestedName: String, contentTypeIdentifier: String? = nil) {
        self.identifier = identifier; self.suggestedName = suggestedName; self.contentTypeIdentifier = contentTypeIdentifier
    }
}
/// External representations remain distinct, preventing web URLs becoming file paths (B-106).
public enum ExternalDropContent: Hashable, Sendable {
    case fileURLs([URL]), promisedFiles([PromisedFilePlaceholder]), text(String), unsupported
}
/// Stable selection and stack counts preserve F-067 and native selection semantics (P-278/P-280).
public struct DragSourceModel: Hashable, Sendable {
    public let items: [DraggedItem]
    public var itemCountBadge: Int? { items.count > 1 ? items.count : nil }
    public var imageCount: Int { min(items.count, maximumImages) }
    private let maximumImages: Int
    /// Selection is resolved against visible snapshot order, including expanded rows.
    public init(clickedID: ItemID, selectedIDs: Set<ItemID>, orderedItems: [DraggedItem], maximumImages: Int = 3) {
        let wanted = selectedIDs.contains(clickedID) ? selectedIDs : [clickedID]
        var seen: Set<ItemID> = []
        self.items = orderedItems.contains(where: { $0.id == clickedID })
            ? orderedItems.filter { wanted.contains($0.id) && seen.insert($0.id).inserted } : []
        self.maximumImages = max(0, maximumImages)
    }
    public static func exceedsThreshold(deltaX: Double, deltaY: Double, threshold: Double = 4) -> Bool {
        guard deltaX.isFinite, deltaY.isFinite, threshold.isFinite, threshold >= 0 else { return false }
        return hypot(deltaX, deltaY) >= threshold && (deltaX != 0 || deltaY != 0)
    }
    /// File URLs win over promises, which win over plain text representations.
    public static func classify(urls: [URL], promises: [PromisedFilePlaceholder] = [], text: String? = nil) -> ExternalDropContent {
        var seen: Set<URL> = []
        let files = urls.filter(\.isFileURL).map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        if !files.isEmpty { return .fileURLs(files) }
        if !promises.isEmpty { return .promisedFiles(promises) }
        if let text, !text.isEmpty { return .text(text) }
        return .unsupported
    }
}
