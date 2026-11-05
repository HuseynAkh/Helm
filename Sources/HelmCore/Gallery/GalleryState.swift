// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Gallery selection reuses F-038/F-041 identity policy and keeps F-048 demand viewport-bounded.
/// Eligibility is injected; this model never reads content or implicitly hydrates cloud files.
public struct GalleryState: Sendable {
    public private(set) var snapshot: PresentationSnapshot
    public private(set) var selection: SelectionModel
    public private(set) var viewport: GalleryViewport
    public private(set) var dimensions: ImageDimensions
    public private(set) var generation: UUID = UUID()
    public private(set) var completedPreview: GalleryPreviewRequest?
    private var eligibleIDs: Set<ItemID>
    public init(snapshot: PresentationSnapshot, selection: Set<ItemID> = [],
                eligibleIDs: Set<ItemID> = [], viewport: GalleryViewport = GalleryViewport(),
                dimensions: ImageDimensions = ImageDimensions(widthPoints: 640, heightPoints: 480, backingScale: 1)) {
        self.snapshot = snapshot; self.viewport = viewport; self.dimensions = dimensions
        self.eligibleIDs = eligibleIDs
        let focus = snapshot.sortedEntries.first(where: { selection.contains($0.id) })?.id
        self.selection = SelectionModel(order: snapshot.sortedIDs, selected: selection, anchor: focus, focus: focus)
    }
    public var selectedEntry: FileEntry? {
        guard let id = selection.focus, selection.selected.contains(id) else { return nil }
        return snapshot.entry(id)
    }
    public var filmstripIndex: Int? { selectedEntry.flatMap { snapshot.index(of: $0.id) } }
    public var previewRequest: GalleryPreviewRequest? { selectedEntry.flatMap { request(for: $0) } }
    public var filmstripRequests: [GalleryPreviewRequest] {
        viewport.indices(count: snapshot.sortedEntries.count).compactMap { request(for: snapshot.sortedEntries[$0]) }
    }
    public mutating func select(_ id: ItemID?) {
        if let id {
            guard snapshot.index(of: id) != nil else { return }
            selection.click(id)
        } else { selection.clear() }
        invalidate()
    }
    public mutating func move(_ movement: ContentMovement) {
        selection.move(movement, columns: max(1, selection.order.count), pageSize: max(1, viewport.visibleCellCount(count: selection.order.count)))
        invalidate()
    }
    public mutating func replaceSnapshot(_ snapshot: PresentationSnapshot, eligibleIDs: Set<ItemID>) {
        self.snapshot = snapshot; self.eligibleIDs = eligibleIDs
        selection.reconcile(order: snapshot.sortedIDs)
        invalidate()
    }
    public mutating func updateViewport(_ viewport: GalleryViewport, dimensions: ImageDimensions) {
        if self.dimensions != dimensions { invalidate() }
        self.viewport = viewport; self.dimensions = dimensions
    }
    /// A completion is accepted once and only for the current selected metadata and dimensions.
    @discardableResult
    public mutating func previewCompleted(_ request: GalleryPreviewRequest) -> Bool {
        guard previewRequest == request, completedPreview == nil else { return false }
        completedPreview = request
        return true
    }
    private func request(for entry: FileEntry) -> GalleryPreviewRequest? {
        guard eligibleIDs.contains(entry.id) else { return nil }
        return GalleryPreviewRequest(generation: generation, key: ThumbnailKey(entry: entry, dimensions: dimensions), changeToken: entry.changeToken)
    }
    private mutating func invalidate() { generation = UUID(); completedPreview = nil }
}
