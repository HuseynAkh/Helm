// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// One immutable directory listing and its visible selection (P-043, F-038).
public struct BrowserColumn: Sendable {
    public let snapshot: PresentationSnapshot
    public var selection: SelectionModel
    public init(snapshot: PresentationSnapshot, selection: SelectionModel = SelectionModel()) {
        self.snapshot = snapshot
        var reconciled: SelectionModel = selection
        reconciled.reconcile(order: snapshot.sortedIDs)
        self.selection = reconciled
    }
}

/// Directory requests are values only; the adapter loads then calls push (P-043/F-007).
public enum ColumnNavigation: Sendable, Equatable {
    case none, load(directory: ItemID, fromColumn: Int), preview(ItemID)
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
    public mutating func push(_ snapshot: PresentationSnapshot, from column: Int, directory: ItemID) -> Bool {
        guard columns.indices.contains(column), columns[column].selection.selected == [directory],
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
        _ = navigation(in: activeColumn)
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
        guard columns.count > 1 else { return }
        columns.removeLast(); activeColumn = min(activeColumn, columns.count - 1)
        _ = navigation(in: activeColumn)
    }

    /// Reloading an ancestor invalidates descendants even when its path survives (B-009/P-080).
    @discardableResult
    public mutating func replaceSnapshot(_ snapshot: PresentationSnapshot, at column: Int) -> Bool {
        guard columns.indices.contains(column), columns[column].snapshot.location == snapshot.location else { return false }
        columns[column] = BrowserColumn(snapshot: snapshot, selection: columns[column].selection)
        truncate(after: column); activeColumn = min(activeColumn, column)
        _ = navigation(in: activeColumn)
        return true
    }

    private mutating func truncate(after column: Int) {
        columns.removeSubrange((column + 1)..<columns.count); previewTarget = nil
    }
    private mutating func navigation(in column: Int) -> ColumnNavigation {
        previewTarget = nil
        let selection: SelectionModel = columns[column].selection
        guard selection.selected.count == 1, let id = selection.selected.first,
              let entry = columns[column].snapshot.entry(id) else { return .none }
        if entry.isDirectoryLike { return .load(directory: id, fromColumn: column) }
        previewTarget = id; return .preview(id)
    }
}
