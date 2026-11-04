// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// One immutable directory listing and its visible selection (P-043, F-038).
public struct BrowserColumn: Sendable {
    public let id: UUID
    fileprivate var pendingRequest: ColumnLoadRequest?
    public let snapshot: PresentationSnapshot
    public var selection: SelectionModel
    public init(snapshot: PresentationSnapshot, selection: SelectionModel = SelectionModel()) {
        self.id = UUID(); self.pendingRequest = nil
        self.snapshot = snapshot
        var reconciled: SelectionModel = selection
        reconciled.reconcile(order: snapshot.sortedIDs)
        self.selection = reconciled
    }
}

/// A column-owned, single-use load identity rejects stale same-folder replies (B-009/F-007).
public struct ColumnLoadRequest: Sendable, Equatable {
    public let columnID: UUID
    public let generation: UUID
    public let directory: ItemID
    public let fromColumn: Int
    public init(columnID: UUID, generation: UUID = UUID(), directory: ItemID, fromColumn: Int) {
        self.columnID = columnID; self.generation = generation
        self.directory = directory; self.fromColumn = fromColumn
    }
}

/// Directory requests are values only; the adapter loads then calls push (P-043/F-007).
public enum ColumnNavigation: Sendable, Equatable {
    case none, load(ColumnLoadRequest), preview(ItemID)
    public var loadRequest: ColumnLoadRequest? {
        if case .load(let request) = self { return request }
        return nil
    }
}

/// Column navigation extends F-035/F-038 to P-043; packages preview rather than traverse.
public struct ColumnBrowserState: Sendable {
    public private(set) var columns: [BrowserColumn]
    public private(set) var activeColumn: Int
    public private(set) var previewTarget: ItemID?

    public init(root: PresentationSnapshot) {
        self.columns = [BrowserColumn(snapshot: root)]; self.activeColumn = 0; self.previewTarget = nil
    }

    @discardableResult
    public mutating func select(_ id: ItemID, in column: Int, command: Bool = false, shift: Bool = false) -> ColumnNavigation {
        guard columns.indices.contains(column), columns[column].snapshot.entry(id) != nil else { return .none }
        let previous: Set<ItemID> = columns[column].selection.selected
        columns[column].selection.click(id, command: command, shift: shift)
        activeColumn = column
        if previous != columns[column].selection.selected { truncate(after: column) }
        return navigation(in: column)
    }

    /// Rejects late loads if the parent selection changed or the returned location is unrelated.
    @discardableResult
    public mutating func push(_ snapshot: PresentationSnapshot, request: ColumnLoadRequest) -> Bool {
        let column = request.fromColumn
        let directory = request.directory
        guard columns.indices.contains(column), columns[column].id == request.columnID,
              columns[column].pendingRequest == request, columns[column].selection.selected == [directory],
              columns[column].snapshot.entry(directory)?.isDirectoryLike == true,
              case .directory(let url) = snapshot.location, ItemID(url: url) == directory else { return false }
        truncate(after: column)
        columns.append(BrowserColumn(snapshot: snapshot)); activeColumn = column + 1; previewTarget = nil
        return true
    }

    /// Left returns focus to the parent; its selected directory remains highlighted.
    public mutating func moveLeft() {
        guard activeColumn > 0 else { return }
        activeColumn -= 1; truncate(after: activeColumn)
        columns[activeColumn].pendingRequest = nil
        refreshPreview(in: activeColumn)
    }

    @discardableResult
    public mutating func moveRight() -> ColumnNavigation {
        if activeColumn + 1 < columns.count {
            activeColumn += 1
            return navigation(in: activeColumn)
        }
        return navigation(in: activeColumn)
    }

    public mutating func pop() {
        if columns.count > 1 { truncate(after: columns.count - 2) }
        else { columns[0].pendingRequest = nil }
        activeColumn = min(activeColumn, columns.count - 1)
        columns[activeColumn].pendingRequest = nil
        refreshPreview(in: activeColumn)
    }

    /// Reloading an ancestor invalidates descendants even when its path survives (B-009/P-080).
    @discardableResult
    public mutating func replaceSnapshot(_ snapshot: PresentationSnapshot, at column: Int) -> Bool {
        guard columns.indices.contains(column), columns[column].snapshot.location == snapshot.location else { return false }
        columns[column] = BrowserColumn(snapshot: snapshot, selection: columns[column].selection)
        truncate(after: column); activeColumn = min(activeColumn, column)
        columns[activeColumn].pendingRequest = nil
        refreshPreview(in: activeColumn)
        return true
    }

    private mutating func truncate(after column: Int) {
        columns[column].pendingRequest = nil
        columns.removeSubrange((column + 1)..<columns.count); previewTarget = nil
    }
    private mutating func refreshPreview(in column: Int) {
        previewTarget = nil
        let selection = columns[column].selection.selected
        if selection.count == 1, let id = selection.first,
           let entry = columns[column].snapshot.entry(id), !entry.isDirectoryLike { previewTarget = id }
    }
    private mutating func navigation(in column: Int) -> ColumnNavigation {
        previewTarget = nil
        for index in column..<columns.count { columns[index].pendingRequest = nil }
        let selection: SelectionModel = columns[column].selection
        guard selection.selected.count == 1, let id = selection.selected.first,
              let entry = columns[column].snapshot.entry(id) else { return .none }
        if entry.isDirectoryLike {
            let request = ColumnLoadRequest(columnID: columns[column].id, directory: id, fromColumn: column)
            columns[column].pendingRequest = request
            return .load(request)
        }
        previewTarget = id; return .preview(id)
    }
}
