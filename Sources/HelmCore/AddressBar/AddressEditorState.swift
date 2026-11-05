import Foundation

/// F-014–F-024 editor snapshot; generations protect both completions and validation (B-052).
public struct AddressEditorState: Equatable, Sendable {
    public var currentDirectory: URL
    public var home: URL
    public var showHidden: Bool
    public var text: String
    public var rows: [CompletionRow]
    public var selectedIndex: Int?
    public var isPopupVisible: Bool
    public var isEditing: Bool
    public var caretAtEnd: Bool
    public var generation: Generation
    public var pendingCommit: URL?
    public var error: String?

    public init(currentDirectory: URL, home: URL, showHidden: Bool = false) {
        self.currentDirectory = currentDirectory; self.home = home; self.showHidden = showHidden
        self.text = ""; self.rows = []; self.selectedIndex = nil
        self.isPopupVisible = false; self.isEditing = false; self.caretAtEnd = true
        self.generation = Generation(); self.pendingCommit = nil; self.error = nil
    }

    public var selectedRow: CompletionRow? {
        guard isPopupVisible, let selectedIndex, rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex]
    }

    public var ghostSuffix: String? {
        PathCompletionEngine.ghostSuffix(typed: text, selected: selectedRow, caretAtEnd: caretAtEnd,
                                         currentDirectory: currentDirectory, home: home)
    }
}

/// F-015 validation distinguishes file opening from folder navigation (B-054).
public enum AddressCommitKind: Equatable, Sendable {
    case directory, file, invalid
}

/// F-019–F-024 events. Paste supplies the full field value after native selection replacement.
public enum AddressEditorAction: Equatable, Sendable {
    case beginEditing
    case textChanged(String)
    case paste(String)
    case caretChanged(atEnd: Bool)
    case showHiddenChanged(Bool)
    case completions(Generation, [CompletionRow])
    case completionFailed(Generation, String)
    case select(Int?)
    case arrowUp, arrowDown, arrowRight, tab, backtab, acceptSelection, returnKey, escape, cancel
    case validated(Generation, URL, AddressCommitKind)
}

/// F-015/F-016 effects are executed by adapters; the reducer performs no filesystem operations.
public enum AddressEditorEffect: Equatable, Sendable {
    case cancelCompletions
    case requestCompletions(CompletionRequest)
    case validate(URL, Generation)
    case navigate(URL)
    case openFile(URL)
    case cancelled
    case invalidPathFeedback
}
