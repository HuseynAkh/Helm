// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Live rename failures for F-054/P-071, including operation-supplied collisions (B-046).
public enum InlineRenameError: Error, Equatable, Sendable {
    case invalid(FileNameError), collision
    public var message: String {
        switch self {
        case .collision: return "An item with that name already exists."
        case .invalid(.empty): return "Enter a name."
        case .invalid(.separator): return "A name cannot contain a slash."
        case .invalid(.nul): return "A name cannot contain a NUL character."
        case .invalid(.dot): return "The names “.” and “..” are reserved."
        case .invalid(.tooLong): return "A name must fit within 255 UTF-8 bytes."
        }
    }
}
/// Rename keyboard routing is local to the field editor (P-071/B-118).
public enum InlineRenameKey: Sendable { case escape, returnKey, tab }
/// Pure rename intent for F-054/P-071; the operation adapter performs validation and I/O.
public struct InlineRenameRequest: Equatable, Sendable {
    public let session: UInt64
    public let attempt: UInt64
    public let item: ItemID
    public let name: ValidFileName
    public let nextItem: ItemID?
    public init(session: UInt64, item: ItemID, name: ValidFileName, nextItem: ItemID? = nil, attempt: UInt64 = 0) {
        self.session = session; self.attempt = attempt; self.item = item; self.name = name; self.nextItem = nextItem
    }
}
/// Editing state uses UTF-16 selection offsets for the AppKit field editor (P-071/B-066).
public struct InlineRenameSession: Equatable, Sendable {
    public let token: UInt64
    public let item: ItemID
    public let originalName: String
    public var text: String
    public let selectedRange: NSRange
    public var error: InlineRenameError?
    public init(token: UInt64, item: ItemID, originalName: String, text: String,
                selectedRange: NSRange, error: InlineRenameError? = nil) {
        self.token = token; self.item = item; self.originalName = originalName
        self.text = text; self.selectedRange = selectedRange; self.error = error
    }
}
/// Single-item inline rename replaces F-054's modal alert; rejects stale edits and B-046 traversal.
/// Pending operations retain the session for collision feedback; no filesystem access occurs here.
public struct InlineRenameModel: Sendable {
    public private(set) var editing: InlineRenameSession?
    public private(set) var pending: InlineRenameRequest?
    private var counter: UInt64 = 0
    private var attempt: UInt64 = 0
    public init() {}

    @discardableResult
    public mutating func begin(_ entry: FileEntry) -> UInt64 {
        counter &+= 1
        let name: String = entry.name
        var stem: String = name
        if !entry.isDirectoryLike, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot])
        }
        editing = InlineRenameSession(token: counter, item: entry.id, originalName: name, text: name,
                                      selectedRange: NSRange(location: 0, length: stem.utf16.count))
        pending = nil
        return counter
    }

    public mutating func edit(_ text: String, session: UInt64) {
        guard var current = editing, current.token == session, pending == nil else { return }
        current.text = text; current.error = validationError(text); editing = current
    }

    public mutating func cancel() { editing = nil; pending = nil }

    /// Caller supplies the current visible order, so vanished entries cannot emit a request.
    /// Tab's next target is captured by identity, never a future row index; it does not wrap.
    @discardableResult
    public mutating func handle(_ key: InlineRenameKey, session: UInt64,
                                visibleOrder: [ItemID]) -> InlineRenameRequest? {
        guard var current = editing, current.token == session else { return nil }
        if key == .escape { cancel(); return nil }
        guard pending == nil else { return nil }
        guard let index = visibleOrder.firstIndex(of: current.item) else { cancel(); return nil }
        guard let name = ValidFileName(current.text) else {
            current.error = validationError(current.text); editing = current; return nil
        }
        let next: ItemID? = key == .tab && index + 1 < visibleOrder.count ? visibleOrder[index + 1] : nil
        attempt &+= 1
        let request: InlineRenameRequest = InlineRenameRequest(session: session, item: current.item, name: name, nextItem: next, attempt: attempt)
        pending = request
        return request
    }

    /// Matching the full request also rejects a stale collision after editing and resubmission.
    /// Return the next identity only after success; the adapter starts its editor from a fresh entry.
    @discardableResult
    public mutating func complete(_ request: InlineRenameRequest, error: InlineRenameError? = nil) -> ItemID? {
        guard pending == request, var current = editing, current.token == request.session else { return nil }
        pending = nil
        if let error { current.error = error; editing = current; return nil }
        cancel(); return request.nextItem
    }

    public mutating func reconcile(existingIDs: Set<ItemID>) {
        if let editing, !existingIDs.contains(editing.item) { cancel() }
    }

    private func validationError(_ text: String) -> InlineRenameError? {
        if case .failure(let error) = FileNameValidator.validate(text) { return .invalid(error) }
        return nil
    }
}
